#!/bin/zsh
# Builds TableExtra.app: release binaries, Info.plist, icon, bundled libpq + deps, pg_dump / pg_restore / psql
# (Contents/Helpers, built by scripts/build-pg-tools.sh), signature.
#   scripts/build-app.sh            -> build/TableExtra.app
#   scripts/build-app.sh --install  -> also copies it to /Applications
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/TableExtra.app"
VERSION="$(cat VERSION 2>/dev/null || echo 1.0.0)"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

echo "→ swift build ($CONFIG)"
swift build -c "$CONFIG" --product TableExtra
swift build -c "$CONFIG" --product tableextra-mcp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/TableExtra" "$APP/Contents/MacOS/TableExtra"
cp "$BIN/tableextra-mcp" "$APP/Contents/MacOS/tableextra-mcp"
# SwiftPM resource bundles, if any target declares resources.
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
cp README.md "$APP/Contents/Resources/" 2>/dev/null || true
mkdir -p "$APP/Contents/Resources/docs" && cp docs/*.md "$APP/Contents/Resources/docs/" 2>/dev/null || true

echo "→ icon"
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TableExtra</string>
  <key>CFBundleDisplayName</key><string>TableExtra</string>
  <key>CFBundleIdentifier</key><string>fr.koa-dev.TableExtra</string>
  <key>CFBundleExecutable</key><string>TableExtra</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSLocalNetworkUsageDescription</key><string>TableExtra connects to databases on your local network.</string>
  <key>NSHumanReadableCopyright</key><string>TableExtra contributors</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>TableExtra connection URL</string>
      <key>CFBundleURLSchemes</key><array><string>tableextra</string><string>mytableplus</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SQL File</string>
      <key>CFBundleTypeExtensions</key><array><string>sql</string><string>psql</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>SQLite Database</string>
      <key>CFBundleTypeExtensions</key><array><string>sqlite</string><string>sqlite3</string><string>db</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "→ bundling Homebrew dylibs"
FW="$APP/Contents/Frameworks"
typeset -A seen
bundle_deps() {
  local target="$1"
  local dep
  for dep in $(otool -L "$target" | tail -n +2 | awk '{print $1}' | grep -E '^/opt/homebrew|^/usr/local/(opt|Cellar)'); do
    local name="${dep:t}"
    if [[ -z "${seen[$name]:-}" ]]; then
      seen[$name]=1
      cp "$dep" "$FW/$name"
      chmod u+w "$FW/$name"
      install_name_tool -id "@rpath/$name" "$FW/$name" 2>/dev/null
      bundle_deps "$FW/$name"
    fi
    install_name_tool -change "$dep" "@rpath/$name" "$target" 2>/dev/null
  done
}
# PostgreSQL client tools for Backup / Restore, so users need no local install (and a sandboxed build can run them).
PGBIN="$("$ROOT/scripts/build-pg-tools.sh")"
HELPERS="$APP/Contents/Helpers"
mkdir -p "$HELPERS"
for tool in pg_dump pg_restore psql; do
  cp "$PGBIN/$tool" "$HELPERS/$tool"
  chmod u+w "$HELPERS/$tool"
done
echo "  $("$PGBIN/pg_dump" --version)"
for exe in "$APP/Contents/MacOS/TableExtra" "$APP/Contents/MacOS/tableextra-mcp" "$HELPERS"/*(N); do
  bundle_deps "$exe"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe" 2>/dev/null || true
done
for lib in "$FW"/*.dylib(N); do
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done

# A stable identity matters: the Keychain remembers "Always Allow" per code identity. Ad-hoc signatures change
# with every build, so each rebuild would ask for the password items again. Override with CODESIGN_IDENTITY
# (e.g. "-" for ad-hoc, or another certificate name).
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDS="$(security find-identity -v -p codesigning 2>/dev/null)"
  IDENTITY="$(print -r -- "$IDS" | grep -m1 '"Developer ID Application' | sed -E 's/.*"(.*)"/\1/')"
  [[ -z "$IDENTITY" ]] && IDENTITY="$(print -r -- "$IDS" | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/')"
fi
IDENTITY="${IDENTITY:--}"
echo "→ codesign (${IDENTITY})"
for lib in "$FW"/*.dylib(N); do codesign --force --sign "$IDENTITY" --timestamp=none "$lib" >/dev/null 2>&1; done
for tool in "$HELPERS"/*(N); do
  codesign --force --sign "$IDENTITY" --timestamp=none --identifier "fr.koa-dev.TableExtra.${tool:t}" "$tool"
done
codesign --force --sign "$IDENTITY" --timestamp=none --identifier fr.koa-dev.TableExtra.mcp "$APP/Contents/MacOS/tableextra-mcp"
codesign --force --sign "$IDENTITY" --timestamp=none --identifier fr.koa-dev.TableExtra "$APP"

# Sanity check: no Homebrew paths left.
if otool -L "$APP/Contents/MacOS/TableExtra" "$HELPERS"/* "$FW"/*.dylib | grep -q /opt/homebrew; then
  echo "warning: Homebrew paths still referenced" >&2
fi
echo "✓ $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/TableExtra.app"
  osascript -e 'tell application "TableExtra" to quit' >/dev/null 2>&1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "✓ installed to $DEST"
fi
