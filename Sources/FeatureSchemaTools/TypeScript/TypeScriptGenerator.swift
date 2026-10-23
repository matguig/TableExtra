import Foundation
import MTPCore

public struct TypeScriptOptions: Sendable, Hashable {
    public enum Style: String, CaseIterable, Sendable, Identifiable {
        /// kysely-codegen compatible: ColumnType helpers, Generated<…>, `interface DB`.
        case kysely
        /// Plain row interfaces (no Kysely import), handy for API types.
        case interfaces

        public var id: String { rawValue }
        public var displayName: String { self == .kysely ? "Kysely" : "Plain interfaces" }
    }

    public var style: Style
    /// Property and DB keys in camelCase (to pair with Kysely's CamelCasePlugin).
    public var camelCase: Bool
    public var includeViews: Bool
    /// Also emit Zod schemas (row + insert) after the types.
    public var zod: Bool
    /// Alphabetical properties like kysely-codegen; false keeps the column order.
    public var sortProperties: Bool
    /// JSDoc from table/column comments.
    public var includeComments: Bool
    /// Tables of this schema get unqualified DB keys and interface names.
    public var defaultSchema: String
    /// Domain name → base type, so domains map to their underlying TypeScript type.
    public var domains: [String: String]

    public init(style: Style = .kysely, camelCase: Bool = false, includeViews: Bool = true, zod: Bool = false,
                sortProperties: Bool = true, includeComments: Bool = true, defaultSchema: String = "public",
                domains: [String: String] = [:]) {
        self.style = style
        self.camelCase = camelCase
        self.includeViews = includeViews
        self.zod = zod
        self.sortProperties = sortProperties
        self.includeComments = includeComments
        self.defaultSchema = defaultSchema
        self.domains = domains
    }
}

/// Generates Kysely (kysely-codegen style) / plain TypeScript types and optional Zod schemas from introspected tables.
public enum TypeScriptGenerator {
    /// `enums` maps an enum type name (optionally "schema.name") to its labels.
    public static func generate(tables: [TableDetails], enums: [String: [String]], options: TypeScriptOptions = TypeScriptOptions()) -> String {
        var g = Generator(options: options, enums: enums)
        return g.run(tables)
    }

    // MARK: Naming helpers (internal for tests)

    static func pascalCase(_ s: String) -> String {
        let parts = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        var out = parts.map { p -> String in
            guard let f = p.first else { return "" }
            return f.uppercased() + p.dropFirst()
        }.joined()
        if out.isEmpty { out = "T" }
        if out.first!.isNumber { out = "_" + out }
        return out
    }

    /// snake_case → snakeCase, like Kysely's CamelCasePlugin.
    static func camelCase(_ s: String) -> String {
        var out = ""
        var upperNext = false
        for (i, ch) in s.enumerated() {
            if ch == "_" && i > 0 {
                upperNext = true
                continue
            }
            if upperNext {
                out += ch.uppercased()
                upperNext = false
            } else {
                out.append(ch)
            }
        }
        return out
    }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    static func isIdentifier(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil
    }

    static func propertyKey(_ s: String) -> String {
        isIdentifier(s) ? s : "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func stringLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    // MARK: Generator

    enum Helper: String, CaseIterable {
        case arrayType = "ArrayType", generated = "Generated", generatedAlways = "GeneratedAlways", int8 = "Int8", interval = "Interval",
             json = "Json", jsonValue = "JsonValue", numeric = "Numeric", point = "Point", timestamp = "Timestamp"
    }

    /// Resolved type of one column for each output flavour.
    struct ResolvedType {
        var kysely: String
        var plain: String
        var zodSelect: String
        var zodInsert: String
        var helpers: Set<Helper> = []
        /// ColumnType-based helper (needs ArrayType<> inside arrays).
        var isColumnType = false
    }

    struct Generator {
        let options: TypeScriptOptions
        let enums: [String: [String]]
        var usedHelpers = Set<Helper>()
        var usedEnums: [String: (typeName: String, values: [String])] = [:]
        var reservedNames = Set(Helper.allCases.map(\.rawValue) + ["ColumnType", "DB", "JsonArray", "JsonObject", "JsonPrimitive", "ArrayTypeImpl", "IPostgresInterval"])
        var kysely: Bool { options.style == .kysely }

        init(options: TypeScriptOptions, enums: [String: [String]]) {
            self.options = options
            self.enums = enums
        }

        func isDefaultSchema(_ schema: String) -> Bool { schema.isEmpty || schema == options.defaultSchema || schema == "main" }

        func key(_ name: String) -> String { options.camelCase ? TypeScriptGenerator.camelCase(name) : name }

        mutating func uniqueName(_ base: String, suffix: String) -> String {
            var name = base
            if reservedNames.contains(name) { name += suffix }
            var i = 2
            while reservedNames.contains(name) {
                name = "\(base)\(suffix)\(i)"
                i += 1
            }
            reservedNames.insert(name)
            return name
        }

        mutating func enumType(schema: String, name: String, values: [String]) -> String {
            let k = isDefaultSchema(schema) ? name : "\(schema).\(name)"
            if let e = usedEnums[k] { return e.typeName }
            let base = TypeScriptGenerator.pascalCase(isDefaultSchema(schema) ? name : "\(schema)_\(name)")
            let typeName = uniqueName(base, suffix: "Enum")
            usedEnums[k] = (typeName, values)
            return typeName
        }

        func enumValues(schema: String, udt: String) -> [String]? {
            enums[udt] ?? enums["\(schema).\(udt)"]
        }

        mutating func resolve(_ c: ColumnDef, schema: String) -> ResolvedType {
            var udt = c.udtName
            var isArray = false
            if udt.hasPrefix("_") {
                udt.removeFirst()
                isArray = true
            } else if c.dataType.hasSuffix("[]") {
                isArray = true
            }
            var element: ResolvedType
            if !isArray, let values = c.enumValues {
                let n = enumType(schema: schema, name: udt, values: values)
                element = ResolvedType(kysely: n, plain: n, zodSelect: TypeScriptGenerator.lowerFirst(n) + "Schema", zodInsert: TypeScriptGenerator.lowerFirst(n) + "Schema")
            } else if let values = enumValues(schema: schema, udt: udt) {
                let n = enumType(schema: schema, name: udt, values: values)
                element = ResolvedType(kysely: n, plain: n, zodSelect: TypeScriptGenerator.lowerFirst(n) + "Schema", zodInsert: TypeScriptGenerator.lowerFirst(n) + "Schema")
            } else {
                element = Self.base(options.domains[udt] ?? udt)
            }
            guard isArray else { return element }
            var out = element
            if element.isColumnType {
                out.kysely = "ArrayType<\(element.kysely)>"
                out.helpers.insert(.arrayType)
                out.isColumnType = true
            } else {
                out.kysely = Self.arrayOf(element.kysely)
            }
            out.plain = Self.arrayOf(element.plain)
            out.zodSelect = "z.array(\(element.zodSelect))"
            out.zodInsert = "z.array(\(element.zodInsert))"
            return out
        }

        static func arrayOf(_ t: String) -> String { t.contains(" ") || t.contains("|") ? "(\(t))[]" : "\(t)[]" }

        static func base(_ udt: String) -> ResolvedType {
            func simple(_ ts: String, _ zod: String) -> ResolvedType { ResolvedType(kysely: ts, plain: ts, zodSelect: zod, zodInsert: zod) }
            switch udt.lowercased() {
            case "bool", "boolean":
                return simple("boolean", "z.boolean()")
            case "int2", "int4", "float4", "float8", "oid", "smallint", "integer", "int", "real", "double precision", "float", "double", "tinyint", "mediumint":
                return simple("number", "z.number()")
            case "int8", "bigint":
                return ResolvedType(kysely: "Int8", plain: "string", zodSelect: "z.string()", zodInsert: "z.union([z.bigint(), z.number(), z.string()])",
                                    helpers: [.int8], isColumnType: true)
            case "numeric", "decimal":
                return ResolvedType(kysely: "Numeric", plain: "string", zodSelect: "z.string()", zodInsert: "z.union([z.number(), z.string()])",
                                    helpers: [.numeric], isColumnType: true)
            case "date", "timestamp", "timestamptz", "datetime":
                return ResolvedType(kysely: "Timestamp", plain: "Date", zodSelect: "z.date()", zodInsert: "z.union([z.date(), z.string()])",
                                    helpers: [.timestamp], isColumnType: true)
            case "interval":
                return ResolvedType(kysely: "Interval", plain: "string", zodSelect: "z.unknown()", zodInsert: "z.union([z.number(), z.string()])",
                                    helpers: [.interval], isColumnType: true)
            case "json", "jsonb":
                return ResolvedType(kysely: "Json", plain: "JsonValue", zodSelect: "z.unknown()", zodInsert: "z.unknown()",
                                    helpers: [.json, .jsonValue], isColumnType: true)
            case "uuid":
                return simple("string", "z.string().uuid()")
            case "bytea", "blob":
                return simple("Buffer", "z.instanceof(Buffer)")
            case "point":
                return ResolvedType(kysely: "Point", plain: "Point", zodSelect: "z.object({ x: z.number(), y: z.number() })",
                                    zodInsert: "z.object({ x: z.number(), y: z.number() })", helpers: [.point])
            case "text", "varchar", "bpchar", "char", "name", "citext", "money", "time", "timetz", "inet", "cidr", "macaddr", "macaddr8",
                 "xml", "tsvector", "tsquery", "bit", "varbit", "ltree", "character varying", "character", "clob":
                return simple("string", "z.string()")
            default:
                let k = ValueKind.infer(typeName: udt)
                switch k {
                case .integer: return simple("number", "z.number()")
                case .text: return simple("string", "z.string()")
                case .boolean: return simple("boolean", "z.boolean()")
                default: return simple("unknown", "z.unknown()")
                }
            }
        }

        struct Property {
            var key: String
            var type: String
            var zodSelect: String
            var zodInsert: String
            var comment: String?
        }

        struct Interface {
            var name: String
            var dbKey: String
            var comment: String?
            var properties: [Property]
        }

        mutating func run(_ input: [TableDetails]) -> String {
            let kinds: Set<DBObjectKind> = options.includeViews ? [.table, .foreignTable, .view, .materializedView] : [.table, .foreignTable]
            let tables = input.filter { kinds.contains($0.object.kind) }
                .sorted { dbKeyRaw($0) < dbKeyRaw($1) }

            // Reserve table names first so tables keep their natural interface names.
            var names: [String: String] = [:]
            for t in tables {
                let base = TypeScriptGenerator.pascalCase(isDefaultSchema(t.object.schema) ? t.object.name : "\(t.object.schema)_\(t.object.name)")
                names[t.object.id] = uniqueName(base, suffix: "Table")
            }

            var interfaces: [Interface] = []
            for t in tables {
                var props: [Property] = []
                for c in t.columns.sorted(by: { $0.ordinal < $1.ordinal }) {
                    let r = resolve(c, schema: t.object.schema)
                    usedHelpers.formUnion(r.helpers)
                    var type = kysely ? r.kysely : r.plain
                    if c.isNullable { type += " | null" }
                    let isView = t.object.kind == .view || t.object.kind == .materializedView
                    if kysely && !isView {
                        if c.isGenerated {
                            type = "GeneratedAlways<\(type)>"
                            usedHelpers.insert(.generatedAlways)
                        } else if c.hasServerDefault {
                            type = "Generated<\(type)>"
                            usedHelpers.insert(.generated)
                        }
                    }
                    var zs = r.zodSelect
                    var zi = r.zodInsert
                    if c.isNullable {
                        zs += ".nullable()"
                        zi += ".nullable()"
                    }
                    if c.isNullable || c.hasServerDefault { zi += ".optional()" }
                    props.append(Property(key: TypeScriptGenerator.propertyKey(key(c.name)), type: type, zodSelect: zs, zodInsert: zi,
                                          comment: options.includeComments ? c.comment : nil))
                }
                if options.sortProperties { props.sort { $0.key.trimmingCharacters(in: ["\""]) < $1.key.trimmingCharacters(in: ["\""]) } }
                interfaces.append(Interface(name: names[t.object.id] ?? "T", dbKey: TypeScriptGenerator.propertyKey(dbKey(t)),
                                            comment: options.includeComments ? t.object.comment : nil, properties: props))
            }
            if usedHelpers.contains(.json) && !kysely { usedHelpers.remove(.json) }
            if kysely && usedHelpers.contains(.json) { usedHelpers.insert(.jsonValue) }
            return render(interfaces)
        }

        func dbKeyRaw(_ t: TableDetails) -> String {
            isDefaultSchema(t.object.schema) ? t.object.name : "\(t.object.schema).\(t.object.name)"
        }

        func dbKey(_ t: TableDetails) -> String {
            isDefaultSchema(t.object.schema) ? key(t.object.name) : "\(key(t.object.schema)).\(key(t.object.name))"
        }

        func jsDoc(_ comment: String?, indent: String) -> [String] {
            guard let comment, !comment.isEmpty else { return [] }
            let lines = comment.replacingOccurrences(of: "*/", with: "* /").split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count == 1 { return ["\(indent)/** \(lines[0]) */"] }
            return ["\(indent)/**"] + lines.map { "\(indent) * \($0)" } + ["\(indent) */"]
        }

        func helperDeclaration(_ h: Helper) -> String {
            switch h {
            case .arrayType:
                return """
                export type ArrayType<T> = ArrayTypeImpl<T> extends (infer U)[]
                  ? U[]
                  : ArrayTypeImpl<T>;

                export type ArrayTypeImpl<T> = T extends ColumnType<infer S, infer I, infer U>
                  ? ColumnType<S[], I[], U[]>
                  : T[];
                """
            case .generated:
                return """
                export type Generated<T> = T extends ColumnType<infer S, infer I, infer U>
                  ? ColumnType<S, I | undefined, U>
                  : ColumnType<T, T | undefined, T>;
                """
            case .generatedAlways:
                return """
                export type GeneratedAlways<T> = T extends ColumnType<infer S, infer _I, infer _U>
                  ? ColumnType<S, never, never>
                  : ColumnType<T, never, never>;
                """
            case .int8:
                return "export type Int8 = ColumnType<string, bigint | number | string, bigint | number | string>;"
            case .interval:
                return "export type Interval = ColumnType<IPostgresInterval, IPostgresInterval | number | string, IPostgresInterval | number | string>;"
            case .json:
                return "export type Json = ColumnType<JsonValue, string, string>;"
            case .jsonValue:
                return """
                export type JsonArray = JsonValue[];

                export type JsonObject = {
                  [x: string]: JsonValue | undefined;
                };

                export type JsonPrimitive = boolean | number | string | null;

                export type JsonValue = JsonArray | JsonObject | JsonPrimitive;
                """
            case .numeric:
                return "export type Numeric = ColumnType<string, number | string, number | string>;"
            case .point:
                return """
                export type Point = {
                  x: number;
                  y: number;
                };
                """
            case .timestamp:
                return "export type Timestamp = ColumnType<Date, Date | string, Date | string>;"
            }
        }

        func render(_ interfaces: [Interface]) -> String {
            var blocks: [String] = []
            blocks.append("""
            /**
             * This file was generated by TableExtra.
             * Please do not edit it manually.
             */
            """)

            var imports: [String] = []
            var helpers = usedHelpers
            if !kysely {
                // Plain interfaces: ColumnType-based helpers collapse to their select types.
                helpers = helpers.intersection([.jsonValue, .point])
            }
            if kysely { imports.append("import type { ColumnType } from \"kysely\";") }
            if kysely && helpers.contains(.interval) { imports.append("import type { IPostgresInterval } from \"postgres-interval\";") }
            if options.zod { imports.append("import { z } from \"zod\";") }
            if !imports.isEmpty { blocks.append(imports.joined(separator: "\n")) }

            // Helpers and enums sorted together by name, as kysely-codegen does.
            var aliases: [(String, String)] = helpers.map { ($0.rawValue, helperDeclaration($0)) }
            for (_, e) in usedEnums {
                let values = e.values.sorted().map { TypeScriptGenerator.stringLiteral($0) }
                aliases.append((e.typeName, "export type \(e.typeName) = \(values.isEmpty ? "never" : values.joined(separator: " | "));"))
            }
            for (_, decl) in aliases.sorted(by: { $0.0 < $1.0 }) { blocks.append(decl) }

            for i in interfaces {
                var lines = jsDoc(i.comment, indent: "")
                lines.append("export interface \(i.name) {")
                for p in i.properties {
                    lines += jsDoc(p.comment, indent: "  ")
                    lines.append("  \(p.key): \(p.type);")
                }
                lines.append("}")
                blocks.append(lines.joined(separator: "\n"))
            }

            if kysely {
                var lines = ["export interface DB {"]
                for i in interfaces.sorted(by: { $0.dbKey.trimmingCharacters(in: ["\""]) < $1.dbKey.trimmingCharacters(in: ["\""]) }) {
                    lines.append("  \(i.dbKey): \(i.name);")
                }
                lines.append("}")
                blocks.append(lines.joined(separator: "\n"))
            }

            if options.zod {
                for (_, e) in usedEnums.sorted(by: { $0.value.typeName < $1.value.typeName }) {
                    let values = e.values.map { TypeScriptGenerator.stringLiteral($0) }.joined(separator: ", ")
                    blocks.append("export const \(TypeScriptGenerator.lowerFirst(e.typeName))Schema = z.enum([\(values)]);")
                }
                for i in interfaces {
                    let base = TypeScriptGenerator.lowerFirst(i.name)
                    var sel = ["export const \(base)Schema = z.object({"]
                    var ins = ["export const \(base)InsertSchema = z.object({"]
                    for p in i.properties {
                        sel.append("  \(p.key): \(p.zodSelect),")
                        ins.append("  \(p.key): \(p.zodInsert),")
                    }
                    sel.append("});")
                    ins.append("});")
                    blocks.append(sel.joined(separator: "\n"))
                    blocks.append(ins.joined(separator: "\n"))
                }
            }
            return blocks.joined(separator: "\n\n") + "\n"
        }
    }
}
