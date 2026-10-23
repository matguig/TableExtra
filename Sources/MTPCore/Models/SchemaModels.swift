import Foundation

public enum DBObjectKind: String, Codable, CaseIterable, Sendable {
    case table, view, materializedView, foreignTable, function, procedure, sequence, type

    public var sectionTitle: String {
        switch self {
        case .table: return "Tables"
        case .view: return "Views"
        case .materializedView: return "Materialized Views"
        case .foreignTable: return "Foreign Tables"
        case .function: return "Functions"
        case .procedure: return "Procedures"
        case .sequence: return "Sequences"
        case .type: return "Types"
        }
    }

    public var symbolName: String {
        switch self {
        case .table: return "tablecells"
        case .view: return "eye"
        case .materializedView: return "square.stack.3d.up"
        case .foreignTable: return "link"
        case .function: return "function"
        case .procedure: return "gearshape"
        case .sequence: return "number"
        case .type: return "t.square"
        }
    }

    /// Objects whose rows can be browsed in a data tab.
    public var hasData: Bool {
        switch self {
        case .table, .view, .materializedView, .foreignTable: return true
        default: return false
        }
    }
}

public struct DBObject: Hashable, Identifiable, Sendable, Codable {
    public var schema: String
    public var name: String
    public var kind: DBObjectKind
    public var comment: String?
    /// Planner estimate (pg_class.reltuples) or exact count for SQLite.
    public var estimatedRows: Int64?
    public var sizeBytes: Int64?
    /// Function signature, e.g. "order_total(p_order bigint)".
    public var signature: String?
    public var oid: UInt32?

    public init(schema: String, name: String, kind: DBObjectKind, comment: String? = nil, estimatedRows: Int64? = nil,
                sizeBytes: Int64? = nil, signature: String? = nil, oid: UInt32? = nil) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.comment = comment
        self.estimatedRows = estimatedRows
        self.sizeBytes = sizeBytes
        self.signature = signature
        self.oid = oid
    }

    public var id: String { "\(kind.rawValue):\(schema).\(signature ?? name)" }
    public var qualifiedName: String { schema.isEmpty ? name : "\(schema).\(name)" }
}

public struct ColumnDef: Hashable, Identifiable, Sendable, Codable {
    public var name: String
    /// Full formatted type, e.g. "character varying(255)", "numeric(10,2)", "order_status".
    public var dataType: String
    /// Underlying type name ("varchar", "int8", "order_status").
    public var udtName: String
    public var isNullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var isIdentity: Bool
    public var comment: String?
    public var ordinal: Int
    /// Values when the column type is an enum.
    public var enumValues: [String]?
    public var foreignKey: ForeignKeyRef?
    public var isGenerated: Bool

    public init(name: String, dataType: String, udtName: String? = nil, isNullable: Bool = true, defaultValue: String? = nil,
                isPrimaryKey: Bool = false, isIdentity: Bool = false, comment: String? = nil, ordinal: Int = 0,
                enumValues: [String]? = nil, foreignKey: ForeignKeyRef? = nil, isGenerated: Bool = false) {
        self.name = name
        self.dataType = dataType
        self.udtName = udtName ?? dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.isIdentity = isIdentity
        self.comment = comment
        self.ordinal = ordinal
        self.enumValues = enumValues
        self.foreignKey = foreignKey
        self.isGenerated = isGenerated
    }

    public var id: String { name }
    public var kind: ValueKind { enumValues != nil ? .enumeration : ValueKind.infer(typeName: udtName) }
    /// Server fills the value when omitted (serial, identity, default now()...).
    public var hasServerDefault: Bool { defaultValue != nil || isIdentity || isGenerated }
}

public struct ForeignKeyRef: Hashable, Sendable, Codable {
    public var constraintName: String
    public var columns: [String]
    public var refSchema: String
    public var refTable: String
    public var refColumns: [String]
    public var onUpdate: String?
    public var onDelete: String?

    public init(constraintName: String, columns: [String], refSchema: String, refTable: String, refColumns: [String],
                onUpdate: String? = nil, onDelete: String? = nil) {
        self.constraintName = constraintName
        self.columns = columns
        self.refSchema = refSchema
        self.refTable = refTable
        self.refColumns = refColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }
}

public struct IndexDef: Hashable, Identifiable, Sendable, Codable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    public var method: String
    public var definition: String
    public var predicate: String?
    public var sizeBytes: Int64?
    public var scans: Int64?

    public init(name: String, columns: [String], isUnique: Bool = false, isPrimary: Bool = false, method: String = "btree",
                definition: String = "", predicate: String? = nil, sizeBytes: Int64? = nil, scans: Int64? = nil) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.definition = definition
        self.predicate = predicate
        self.sizeBytes = sizeBytes
        self.scans = scans
    }

    public var id: String { name }
}

public enum ConstraintKind: String, Codable, Sendable {
    case primaryKey = "PRIMARY KEY"
    case foreignKey = "FOREIGN KEY"
    case unique = "UNIQUE"
    case check = "CHECK"
    case exclusion = "EXCLUDE"
}

public struct ConstraintDef: Hashable, Identifiable, Sendable, Codable {
    public var name: String
    public var kind: ConstraintKind
    public var columns: [String]
    public var definition: String
    public var foreignKey: ForeignKeyRef?

    public init(name: String, kind: ConstraintKind, columns: [String], definition: String, foreignKey: ForeignKeyRef? = nil) {
        self.name = name
        self.kind = kind
        self.columns = columns
        self.definition = definition
        self.foreignKey = foreignKey
    }

    public var id: String { name }
}

public struct TriggerDef: Hashable, Identifiable, Sendable, Codable {
    public var name: String
    public var timing: String
    public var events: String
    public var definition: String
    public var isEnabled: Bool

    public init(name: String, timing: String, events: String, definition: String, isEnabled: Bool = true) {
        self.name = name
        self.timing = timing
        self.events = events
        self.definition = definition
        self.isEnabled = isEnabled
    }

    public var id: String { name }
}

/// Everything known about one table; used by structure tabs, diff, codegen and AI context.
public struct TableDetails: Sendable, Codable, Hashable {
    public var object: DBObject
    public var columns: [ColumnDef]
    public var indexes: [IndexDef]
    public var constraints: [ConstraintDef]
    public var triggers: [TriggerDef]

    public init(object: DBObject, columns: [ColumnDef], indexes: [IndexDef] = [], constraints: [ConstraintDef] = [], triggers: [TriggerDef] = []) {
        self.object = object
        self.columns = columns
        self.indexes = indexes
        self.constraints = constraints
        self.triggers = triggers
    }

    public var primaryKey: [String] {
        if let pk = constraints.first(where: { $0.kind == .primaryKey }) { return pk.columns }
        return columns.filter(\.isPrimaryKey).map(\.name)
    }

    public var foreignKeys: [ForeignKeyRef] { constraints.compactMap(\.foreignKey) }
}

public struct ServerInfo: Sendable, Hashable {
    public var product: String
    public var version: String
    public var numericVersion: Int
    public var currentDatabase: String
    public var currentUser: String

    public init(product: String, version: String, numericVersion: Int = 0, currentDatabase: String = "", currentUser: String = "") {
        self.product = product
        self.version = version
        self.numericVersion = numericVersion
        self.currentDatabase = currentDatabase
        self.currentUser = currentUser
    }
}
