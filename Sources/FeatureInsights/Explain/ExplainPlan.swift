import Foundation

/// One labelled value of a plan node (conditions, sort keys, extra properties).
public struct PlanDetail: Hashable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Trigger timing reported by EXPLAIN ANALYZE of a write.
public struct PlanTrigger: Hashable, Sendable {
    public var name: String
    public var relation: String?
    public var time: Double?
    public var calls: Double?
}

/// One node of a PostgreSQL plan (`EXPLAIN (FORMAT JSON)`), with derived timing.
public struct PlanNode: Identifiable, Hashable, Sendable {
    /// Pre-order position in the plan (root = 0).
    public var id: Int
    public var depth: Int
    public var nodeType: String
    public var parentRelationship: String?
    public var subplanName: String?
    public var relationName: String?
    public var schema: String?
    public var alias: String?
    public var indexName: String?
    public var cteName: String?
    public var functionName: String?
    public var joinType: String?
    public var strategy: String?
    public var partialMode: String?
    public var operation: String?
    public var command: String?
    public var scanDirection: String?
    public var parallelAware: Bool

    public var startupCost: Double
    public var totalCost: Double
    public var planRows: Double
    public var planWidth: Double

    /// ANALYZE only: per-loop averages, in milliseconds / rows.
    public var actualStartupTime: Double?
    public var actualTotalTime: Double?
    public var actualRows: Double?
    public var actualLoops: Double?
    public var workersPlanned: Int?
    public var workersLaunched: Int?

    public var sharedHitBlocks: Double?
    public var sharedReadBlocks: Double?
    public var sharedDirtiedBlocks: Double?
    public var sharedWrittenBlocks: Double?
    public var tempReadBlocks: Double?
    public var tempWrittenBlocks: Double?

    /// Filter, Index Cond, Hash Cond, Join Filter, Sort Key, Rows Removed by Filter… in display order.
    public var conditions: [PlanDetail]
    /// VERBOSE output columns.
    public var output: [String]
    /// Every other property, sorted by label.
    public var properties: [PlanDetail]
    public var children: [PlanNode]

    /// Wall-clock time spent in this node and its children (ms), corrected for loops and parallel workers.
    public var inclusiveTime: Double?
    /// `inclusiveTime` minus the children's (ms), never negative.
    public var exclusiveTime: Double?
    /// Total cost minus the children's total cost, never negative.
    public var exclusiveCost: Double

    public var wasExecuted: Bool { (actualLoops ?? 1) > 0 }

    /// Planner estimate vs reality, ≥ 1; nil without ANALYZE or when the node never ran.
    public var misestimateFactor: Double? {
        guard let actual = actualRows, let loops = actualLoops, loops > 0 else { return nil }
        let hi = max(planRows, actual)
        let lo = max(min(planRows, actual), 1)
        return hi / lo
    }

    /// True when the planner expected fewer rows than it got.
    public var isUnderestimated: Bool { (actualRows ?? 0) > planRows }

    /// Name as printed by FORMAT TEXT ("HashAggregate", "Hash Left Join", "Parallel Seq Scan"…).
    public var displayName: String {
        var name = nodeType
        switch nodeType {
        case "Aggregate":
            switch strategy {
            case "Sorted": name = "GroupAggregate"
            case "Hashed": name = "HashAggregate"
            case "Mixed": name = "MixedAggregate"
            default: name = "Aggregate"
            }
            if let partialMode, partialMode != "Simple" { name = "\(partialMode) \(name)" }
        case "ModifyTable":
            name = operation ?? "ModifyTable"
        case "SetOp":
            name = (strategy == "Hashed" ? "HashSetOp" : "SetOp") + (command.map { " \($0)" } ?? "")
        case "Hash Join", "Merge Join", "Nested Loop":
            if let joinType, joinType != "Inner" {
                name = nodeType == "Nested Loop" ? "Nested Loop \(joinType) Join" : nodeType.replacingOccurrences(of: " Join", with: " \(joinType) Join")
            }
        default:
            break
        }
        if parallelAware && !name.hasPrefix("Parallel") { name = "Parallel " + name }
        if scanDirection == "Backward" { name += " Backward" }
        return name
    }

    /// "using idx on public.orders o", "on cte_name"…
    public var targetDescription: String? {
        var parts: [String] = []
        if let indexName { parts.append("using \(indexName)") }
        if let relationName {
            var rel = schema.map { "\($0).\(relationName)" } ?? relationName
            if let alias, alias != relationName { rel += " \(alias)" }
            parts.append("on \(rel)")
        } else if let cteName {
            parts.append("on \(cteName)" + (alias.map { $0 != cteName ? " \($0)" : "" } ?? ""))
        } else if let functionName {
            parts.append("on \(functionName)" + (alias.map { $0 != functionName ? " \($0)" : "" } ?? ""))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Pre-order list of this node and its descendants.
    public var flattened: [PlanNode] {
        var out: [PlanNode] = []
        func walk(_ n: PlanNode) {
            out.append(n)
            n.children.forEach(walk)
        }
        walk(self)
        return out
    }
}

public struct ExplainPlan: Sendable {
    public var root: PlanNode
    public var planningTime: Double?
    public var executionTime: Double?
    public var triggers: [PlanTrigger]
    /// JIT total time (ms) when JIT kicked in.
    public var jitTime: Double?
    public var jitFunctions: Int?
    /// Non-default planner settings (EXPLAIN SETTINGS).
    public var settings: [PlanDetail]
    public var planningSharedHit: Double?
    public var planningSharedRead: Double?

    /// True when the plan carries actual timings (EXPLAIN ANALYZE).
    public var isAnalyze: Bool { root.actualTotalTime != nil }
    public var totalCost: Double { root.totalCost }
    public var nodes: [PlanNode] { root.flattened }

    /// Denominator for the time-share bars: execution time, else the root's inclusive time.
    public var totalTime: Double? {
        if let executionTime, executionTime > 0 { return executionTime }
        return root.inclusiveTime
    }

    /// Fraction (0…1) of the whole statement spent in this node alone: time with ANALYZE, cost otherwise.
    public func share(of node: PlanNode) -> Double {
        if isAnalyze, let total = totalTime, total > 0 { return min(1, (node.exclusiveTime ?? 0) / total) }
        guard root.totalCost > 0 else { return 0 }
        return min(1, node.exclusiveCost / root.totalCost)
    }

    /// The node with the highest exclusive time (or exclusive cost without ANALYZE).
    public var mostExpensiveNodeID: Int? {
        let all = nodes
        guard all.count > 1 else { return all.first?.id }
        if isAnalyze { return all.max { ($0.exclusiveTime ?? 0) < ($1.exclusiveTime ?? 0) }?.id }
        return all.max { $0.exclusiveCost < $1.exclusiveCost }?.id
    }

    public func node(id: Int) -> PlanNode? { nodes.first { $0.id == id } }
}

public enum ExplainPlanError: Error, LocalizedError, Equatable {
    case invalidJSON(String)
    case missingPlan

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let m): return "The plan is not valid JSON: \(m)"
        case .missingPlan: return "The JSON does not contain a \"Plan\" object"
        }
    }
}

/// Pure parser for `EXPLAIN (FORMAT JSON[, VERBOSE, BUFFERS, ANALYZE, SETTINGS])` output.
public enum ExplainPlanParser {
    /// Keys rendered as conditions, in this order.
    static let conditionKeys = [
        "Index Cond", "Recheck Cond", "TID Cond", "Hash Cond", "Merge Cond", "Join Filter", "Filter", "One-Time Filter",
        "Rows Removed by Index Recheck", "Rows Removed by Join Filter", "Rows Removed by Filter",
        "Sort Key", "Presorted Key", "Group Key", "Hash Key", "Cache Key", "Sort Method", "Heap Fetches",
    ]

    /// Keys mapped to typed fields (not repeated in `properties`).
    static let typedKeys: Set<String> = [
        "Node Type", "Parent Relationship", "Subplan Name", "Relation Name", "Schema", "Alias", "Index Name", "CTE Name",
        "Function Name", "Join Type", "Strategy", "Partial Mode", "Operation", "Command", "Scan Direction", "Parallel Aware",
        "Startup Cost", "Total Cost", "Plan Rows", "Plan Width", "Actual Startup Time", "Actual Total Time", "Actual Rows",
        "Actual Loops", "Workers Planned", "Workers Launched", "Shared Hit Blocks", "Shared Read Blocks",
        "Shared Dirtied Blocks", "Shared Written Blocks", "Temp Read Blocks", "Temp Written Blocks", "Output", "Plans", "Workers",
    ]

    public static func parse(json: String) throws -> ExplainPlan {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { throw ExplainPlanError.invalidJSON("not UTF-8") }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ExplainPlanError.invalidJSON(error.localizedDescription)
        }
        let top: [String: Any]
        if let array = object as? [Any], let first = array.first as? [String: Any] {
            top = first
        } else if let dict = object as? [String: Any] {
            top = dict
        } else {
            throw ExplainPlanError.missingPlan
        }
        guard let planDict = top["Plan"] as? [String: Any] else { throw ExplainPlanError.missingPlan }

        var counter = 0
        let root = parseNode(planDict, depth: 0, parallelism: 1, counter: &counter)

        let triggers: [PlanTrigger] = (top["Triggers"] as? [[String: Any]] ?? []).map {
            PlanTrigger(name: string($0["Trigger Name"]) ?? "trigger", relation: string($0["Relation"]),
                        time: number($0["Time"]), calls: number($0["Calls"]))
        }
        var jitTime: Double?
        var jitFunctions: Int?
        if let jit = top["JIT"] as? [String: Any] {
            jitFunctions = number(jit["Functions"]).map { Int($0) }
            if let timing = jit["Timing"] as? [String: Any] {
                jitTime = number(timing["Total"]) ?? (timing["Total"] as? [String: Any]).flatMap { number($0["Total"]) }
            }
        }
        let settings = (top["Settings"] as? [String: Any] ?? [:])
            .map { PlanDetail($0.key, string($0.value) ?? "") }
            .sorted { $0.label < $1.label }
        let planning = top["Planning"] as? [String: Any]
        return ExplainPlan(root: root,
                           planningTime: number(top["Planning Time"]),
                           executionTime: number(top["Execution Time"]),
                           triggers: triggers,
                           jitTime: jitTime,
                           jitFunctions: jitFunctions,
                           settings: settings,
                           planningSharedHit: number(planning?["Shared Hit Blocks"]),
                           planningSharedRead: number(planning?["Shared Read Blocks"]))
    }

    private static func parseNode(_ d: [String: Any], depth: Int, parallelism: Double, counter: inout Int) -> PlanNode {
        let id = counter
        counter += 1
        let nodeType = string(d["Node Type"]) ?? "Unknown"

        var conditions: [PlanDetail] = []
        for key in conditionKeys {
            guard let raw = d[key] else { continue }
            var value = render(raw)
            if key == "Sort Method" {
                if let used = number(d["Sort Space Used"]) {
                    value += " (\(Int(used)) kB \(string(d["Sort Space Type"]) ?? ""))".replacingOccurrences(of: " )", with: ")")
                }
            }
            conditions.append(PlanDetail(key, value))
        }
        let skip = typedKeys.union(conditionKeys).union(["Sort Space Used", "Sort Space Type"])
        var properties: [PlanDetail] = d.compactMap { key, value in
            guard !skip.contains(key) else { return nil }
            return PlanDetail(key, render(value))
        }
        properties.sort { $0.label < $1.label }

        let workersLaunched = number(d["Workers Launched"]).map { Int($0) }
        // Children of Gather run in the leader plus every launched worker at the same time.
        var childParallelism = parallelism
        if nodeType == "Gather" || nodeType == "Gather Merge" {
            childParallelism = Double(max(0, workersLaunched ?? number(d["Workers Planned"]).map { Int($0) } ?? 0) + 1)
        }
        let children = (d["Plans"] as? [[String: Any]] ?? []).map {
            parseNode($0, depth: depth + 1, parallelism: childParallelism, counter: &counter)
        }

        let actualTotal = number(d["Actual Total Time"])
        let loops = number(d["Actual Loops"])
        var inclusive: Double?
        if let actualTotal {
            inclusive = actualTotal * (loops ?? 1) / max(parallelism, 1)
        }
        var exclusive: Double?
        if let inclusive {
            let childTime = children.reduce(0) { $0 + ($1.inclusiveTime ?? 0) }
            exclusive = max(0, inclusive - childTime)
        }
        let totalCost = number(d["Total Cost"]) ?? 0
        let childCost = children.reduce(0) { $0 + $1.totalCost }

        return PlanNode(
            id: id, depth: depth, nodeType: nodeType,
            parentRelationship: string(d["Parent Relationship"]),
            subplanName: string(d["Subplan Name"]),
            relationName: string(d["Relation Name"]),
            schema: string(d["Schema"]),
            alias: string(d["Alias"]),
            indexName: string(d["Index Name"]),
            cteName: string(d["CTE Name"]),
            functionName: string(d["Function Name"]),
            joinType: string(d["Join Type"]),
            strategy: string(d["Strategy"]),
            partialMode: string(d["Partial Mode"]),
            operation: string(d["Operation"]),
            command: string(d["Command"]),
            scanDirection: string(d["Scan Direction"]),
            parallelAware: (d["Parallel Aware"] as? Bool) ?? false,
            startupCost: number(d["Startup Cost"]) ?? 0,
            totalCost: totalCost,
            planRows: number(d["Plan Rows"]) ?? 0,
            planWidth: number(d["Plan Width"]) ?? 0,
            actualStartupTime: number(d["Actual Startup Time"]),
            actualTotalTime: actualTotal,
            actualRows: number(d["Actual Rows"]),
            actualLoops: loops,
            workersPlanned: number(d["Workers Planned"]).map { Int($0) },
            workersLaunched: workersLaunched,
            sharedHitBlocks: number(d["Shared Hit Blocks"]),
            sharedReadBlocks: number(d["Shared Read Blocks"]),
            sharedDirtiedBlocks: number(d["Shared Dirtied Blocks"]),
            sharedWrittenBlocks: number(d["Shared Written Blocks"]),
            tempReadBlocks: number(d["Temp Read Blocks"]),
            tempWrittenBlocks: number(d["Temp Written Blocks"]),
            conditions: conditions,
            output: (d["Output"] as? [Any])?.compactMap { string($0) } ?? [],
            properties: properties,
            children: children,
            inclusiveTime: inclusive,
            exclusiveTime: exclusive,
            exclusiveCost: max(0, totalCost - childCost)
        )
    }

    // MARK: JSON value helpers

    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber:
            // JSONSerialization maps true/false to NSNumber too; those are not numbers here.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            return Double(s)
        default:
            return nil
        }
    }

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return formatNumber(n.doubleValue)
        default: return nil
        }
    }

    static func render(_ v: Any) -> String {
        switch v {
        case let a as [Any]: return a.map(render).joined(separator: ", ")
        case let d as [String: Any]: return d.keys.sorted().map { "\($0): \(render(d[$0] ?? ""))" }.joined(separator: ", ")
        case is NSNull: return "null"
        default: return string(v) ?? "\(v)"
        }
    }

    static func formatNumber(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }
}
