import Foundation

/// Groups long object lists for the sidebar:
/// - series: tables that differ only by a date/number suffix (`events_20260725`, `events_20260726`…) fold
///   into one `events_*` node whose children show just the suffix;
/// - prefix folders (optional): names sharing their first `_` token (`ai_item_price`, `ai_report`) fold into
///   an `ai` folder whose children drop the shared prefix, so long names stay readable in a narrow sidebar.
public enum ObjectGrouping {
    public indirect enum Node: Identifiable, Hashable, Sendable {
        case object(DBObject, display: String)
        case group(id: String, title: String, kind: GroupKind, children: [Node])

        public var id: String {
            switch self {
            case .object(let o, _): return o.id
            case .group(let id, _, _, _): return id
            }
        }

        /// Number of objects below this node.
        public var objectCount: Int {
            switch self {
            case .object: return 1
            case .group(_, _, _, let children): return children.reduce(0) { $0 + $1.objectCount }
            }
        }

        /// Sum of estimated rows of the objects below this node (nil when none is known).
        public var estimatedRows: Int64? {
            switch self {
            case .object(let o, _): return o.estimatedRows
            case .group(_, _, _, let children):
                let values = children.compactMap(\.estimatedRows)
                return values.isEmpty ? nil : values.reduce(0, +)
            }
        }
    }

    public enum GroupKind: String, Hashable, Sendable { case series, prefix }

    /// Minimum members for a series or a prefix folder.
    public static let minimumGroupSize = 3

    /// Builds the node list for one kind of object (already filtered and sorted by name).
    /// `prefixFolders` only applies when there are more than `prefixThreshold` objects.
    public static func nodes(for objects: [DBObject], prefixFolders: Bool, prefixThreshold: Int = 25) -> [Node] {
        let series = foldSeries(objects.map { Node.object($0, display: $0.name) }, stripping: "")
        guard prefixFolders, objects.count > prefixThreshold else { return series }
        return foldPrefixes(series)
    }

    // MARK: Series

    private static let suffixPattern = try! NSRegularExpression(
        pattern: #"^(.+?)[_-](\d{8}|\d{4}_\d{2}_\d{2}|\d{4}_\d{2}|\d{6}|\d{4}|p\d+|part\d+|\d{1,3})$"#)

    /// Splits `events_20260725` into ("events", "20260725").
    public static func seriesKey(_ name: String) -> (base: String, suffix: String)? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = suffixPattern.firstMatch(in: name, range: range),
              let b = Range(m.range(at: 1), in: name), let s = Range(m.range(at: 2), in: name) else { return nil }
        return (String(name[b]), String(name[s]))
    }

    /// `20260725` → `2026-07-25`, `2026_07` → `2026-07`; anything else unchanged.
    public static func prettySuffix(_ s: String) -> String {
        let digits = s.filter(\.isNumber)
        if s.count == 8, digits.count == 8 {
            let a = Array(s)
            return "\(String(a[0..<4]))-\(String(a[4..<6]))-\(String(a[6..<8]))"
        }
        if s.contains("_"), digits.count == s.count - s.filter({ $0 == "_" }).count { return s.replacingOccurrences(of: "_", with: "-") }
        return s
    }

    private static func foldSeries(_ nodes: [Node], stripping prefix: String) -> [Node] {
        var buckets: [String: [(Node, String)]] = [:]
        for n in nodes {
            if case .object(let o, _) = n, let key = seriesKey(o.name) { buckets[key.base, default: []].append((n, key.suffix)) }
        }
        let grouped = buckets.filter { $0.value.count >= minimumGroupSize }
        var out: [Node] = []
        var emitted = Set<String>()
        for n in nodes {
            guard case .object(let o, let display) = n else { out.append(n); continue }
            if let key = seriesKey(o.name), let members = grouped[key.base] {
                if emitted.insert(key.base).inserted {
                    let children = members.map { m -> Node in
                        guard case .object(let mo, _) = m.0 else { return m.0 }
                        return .object(mo, display: prettySuffix(m.1))
                    }
                    let title = String(key.base.dropFirst(prefix.count)) + "_*"
                    out.append(.group(id: "series:\(o.schema).\(o.kind.rawValue).\(key.base)", title: title, kind: .series, children: children))
                }
            } else {
                out.append(.object(o, display: display))
            }
        }
        return out
    }

    // MARK: Prefix folders

    private static func baseName(_ n: Node) -> String {
        switch n {
        case .object(let o, _): return o.name
        case .group(_, let title, _, _): return title
        }
    }

    private static func prefixToken(_ name: String) -> String? {
        guard let i = name.firstIndex(of: "_"), name.distance(from: name.startIndex, to: i) >= 2 else { return nil }
        return String(name[..<i])
    }

    private static func firstObject(_ n: Node) -> DBObject? {
        switch n {
        case .object(let o, _): return o
        case .group(_, _, _, let children): return children.lazy.compactMap(firstObject).first
        }
    }

    private static func foldPrefixes(_ nodes: [Node]) -> [Node] {
        var counts: [String: Int] = [:]
        for n in nodes { if let p = prefixToken(baseName(n)) { counts[p, default: 0] += n.objectCount } }
        let folders = Set(counts.filter { $0.value >= minimumGroupSize }.keys)
        // A single folder holding every object only adds a click.
        if folders.count == 1, let only = folders.first, counts[only] == nodes.reduce(0, { $0 + $1.objectCount }) { return nodes }
        guard !folders.isEmpty else { return nodes }

        var members: [String: [Node]] = [:]
        var order: [String] = []   // folder tokens and loose node ids, in original order
        var loose: [String: Node] = [:]
        for n in nodes {
            guard let p = prefixToken(baseName(n)), folders.contains(p) else {
                order.append("node:" + n.id)
                loose[n.id] = n
                continue
            }
            let strip = p.count + 1
            let child: Node
            switch n {
            case .object(let o, _): child = .object(o, display: String(o.name.dropFirst(strip)))
            case .group(let id, let title, let kind, let children): child = .group(id: id, title: String(title.dropFirst(strip)), kind: kind, children: children)
            }
            if members[p] == nil { order.append("folder:" + p) }
            members[p, default: []].append(child)
        }
        return order.compactMap { key in
            if key.hasPrefix("node:") { return loose[String(key.dropFirst(5))] }
            let p = String(key.dropFirst(7))
            guard let children = members[p] else { return nil }
            let o = children.lazy.compactMap(firstObject).first
            let id = "prefix:\(o?.schema ?? "").\(o?.kind.rawValue ?? "").\(p)"
            return .group(id: id, title: p, kind: .prefix, children: children)
        }
    }
}
