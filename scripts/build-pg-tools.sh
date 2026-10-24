#!/bin/zsh
# Builds pg_dump, pg_restore and psql from the official PostgreSQL sources, for Contents/Helpers.
#   scripts/build-pg-tools.sh   -> prints the folder holding the three tools (cached in build/pgtools/<version>-p<patch level>)
# Built --without-readline: psql only runs scripts here, and GNU readline (GPL) must not ship in the app.
# One patch: scripts and pg_restore set transaction_timeout only where the server has it (17+), so restores into older
# servers work in a single transaction (upstream writes a plain SET that PostgreSQL 16 and older reject).
# The tools link to @rpath/libpq.5.dylib, the Homebrew libpq bundled in Contents/Frameworks, and to the OpenSSL that
# libpq itself uses, so the app carries a single copy of each.
set -euo pipefail

PG_VERSION="18.6"
PG_SHA256="555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f"
PATCH_LEVEL="1"   # bump when the patch below changes, to rebuild the cached tools

ROOT="${0:A:h:h}"
WORK="$ROOT/build/pgtools"
OUT="$WORK/$PG_VERSION-p$PATCH_LEVEL/bin"
if [[ -x "$OUT/pg_dump" && -x "$OUT/pg_restore" && -x "$OUT/psql" ]]; then
  print -r -- "$OUT"
  exit 0
fi

LIBPQ="$(brew --prefix libpq)/lib/libpq.5.dylib"
CRYPTO="$(otool -L "$LIBPQ" | awk '/libcrypto/ {print $1}')"
OPENSSL="${CRYPTO:h:h}"
[[ -d "$OPENSSL/include/openssl" ]] || { echo "error: OpenSSL headers not found next to $CRYPTO" >&2; exit 1; }

mkdir -p "$WORK"
TARBALL="$WORK/postgresql-$PG_VERSION.tar.bz2"
if [[ ! -f "$TARBALL" ]]; then
  echo "→ downloading PostgreSQL $PG_VERSION" >&2
  curl -fsSL "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2" -o "$TARBALL.part"
  mv "$TARBALL.part" "$TARBALL"
fi
if [[ "$(shasum -a 256 "$TARBALL" | awk '{print $1}')" != "$PG_SHA256" ]]; then
  rm -f "$TARBALL"
  echo "error: checksum mismatch for postgresql-$PG_VERSION.tar.bz2" >&2
  exit 1
fi

SRC="$WORK/postgresql-$PG_VERSION"
rm -rf "$SRC"
tar -xjf "$TARBALL" -C "$WORK"
cd "$SRC"
ARCHIVER=src/bin/pg_dump/pg_backup_archiver.c
perl -pi -e 's/ahprintf\(AH, "SET transaction_timeout = 0;\\n"\);/ahprintf(AH, "SELECT pg_catalog.set_config(name, \x270\x27, false) FROM pg_catalog.pg_settings WHERE name = \x27transaction_timeout\x27;\\n");/' "$ARCHIVER"
grep -q "WHERE name = 'transaction_timeout'" "$ARCHIVER" || { echo "error: transaction_timeout patch did not apply" >&2; exit 1; }
echo "→ configuring (OpenSSL from ${OPENSSL})" >&2
# The prefix is never installed to: it only names libpq's install path, rewritten to @rpath below.
PREFIX="/nonexistent/tableextra-pg"
MACOSX_DEPLOYMENT_TARGET=14.0 ./configure --prefix="$PREFIX" --without-readline --without-icu --with-openssl \
  --with-zlib --without-lz4 --without-zstd --without-gssapi \
  --with-includes="$OPENSSL/include" --with-libraries="$OPENSSL/lib" >"$WORK/configure.log" 2>&1 \
  || { tail -20 "$WORK/configure.log" >&2; exit 1; }
echo "→ compiling pg_dump, pg_restore, psql" >&2
pgmake() {
  MACOSX_DEPLOYMENT_TARGET=14.0 make -j"$(sysctl -n hw.ncpu)" "$@" >>"$WORK/make.log" 2>&1 \
    || { tail -30 "$WORK/make.log" >&2; exit 1; }
}
# Generated catalog headers first: the client directories need them but a parallel make does not order them.
pgmake -C src/backend generated-headers
pgmake -C src/bin/pg_dump
pgmake -C src/bin/psql

rm -rf "$OUT"
mkdir -p "$OUT"
cp src/bin/pg_dump/pg_dump src/bin/pg_dump/pg_restore src/bin/psql/psql "$OUT/"
for tool in "$OUT"/*; do
  install_name_tool -change "$PREFIX/lib/libpq.5.dylib" "@rpath/libpq.5.dylib" "$tool"
  if otool -L "$tool" | grep -qE "$PREFIX|readline"; then
    echo "error: ${tool:t} still links $(otool -L "$tool" | grep -E "$PREFIX|readline")" >&2
    exit 1
  fi
done
cd "$ROOT"
rm -rf "$SRC"
print -r -- "$OUT"
