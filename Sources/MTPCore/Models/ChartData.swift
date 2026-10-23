import Foundation

/// Turns a query result into chart points. Pure, so the UI only draws.
/// Mirrors TablePlus' result "Chart" tab (x-axis / y-axis column pickers, bar/line/pie) and adds:
/// automatic axis suggestion, several y columns, a series (color) column and aggregation.
public enum ChartKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case bar, line, area, point, pie
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .bar: return "Bar"
        case .line: return "Line"
        case .area: return "Area"
        case .point: return "Scatter"
        case .pie: return "Pie"
        }
    }
}

public enum ChartAggregate: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, sum, average, count, min, max
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "No aggregation"
        case .sum: return "Sum"
        case .average: return "Average"
        case .count: return "Count"
        case .min: return "Min"
        case .max: return "Max"
        }
    }
}

public struct ChartConfig: Equatable, Codable, Sendable {
    public var kind: ChartKind
    public var x: String?
    public var ys: [String]
    /// Optional column whose values split the data into colored series.
    public var series: String?
    public var aggregate: ChartAggregate

    public init(kind: ChartKind = .bar, x: String? = nil, ys: [String] = [], series: String? = nil, aggregate: ChartAggregate = .none) {
        self.kind = kind
        self.x = x
        self.ys = ys
        self.series = series
        self.aggregate = aggregate
    }

    public var isComplete: Bool { x != nil && (!ys.isEmpty || aggregate == .count) }
}

/// X value with its natural ordering.
public enum ChartX: Hashable, Comparable, Sendable {
    case number(Double)
    case date(Date)
    case text(String)

    public static func < (a: ChartX, b: ChartX) -> Bool {
        switch (a, b) {
        case (.number(let l), .number(let r)): return l < r
        case (.date(let l), .date(let r)): return l < r
        case (.text(let l), .text(let r)): return l.localizedStandardCompare(r) == .orderedAscending
        default: return a.label < b.label
        }
    }

    public var label: String {
        switch self {
        case .number(let v): return v.rounded() == v && abs(v) < 1e15 ? String(Int64(v)) : String(v)
        case .date(let d): return ChartData.dateLabel(d)
        case .text(let s): return s
        }
    }
}

public enum ChartXKind: Sendable { case number, date, text }

public struct ChartPoint: Identifiable, Hashable, Sendable {
    public var id: Int
    public var x: ChartX
    public var series: String
    public var value: Double
}

public struct ChartData: Sendable {
    public var points: [ChartPoint]
    public var xKind: ChartXKind
    public var series: [String]
    /// Rows skipped because the y value was NULL or not a number.
    public var skippedRows: Int
    /// True when the input was cut to `ChartData.maxRows`.
    public var truncated: Bool

    public static let maxRows = 20_000
    /// Pie charts stay readable up to this many slices; the rest is folded into "Other".
    public static let maxSlices = 12

    // MARK: Suggestion

    /// First date/time column (else first text-like column) as x, numeric columns as y — so the tab shows
    /// something useful immediately instead of an empty "pick an axis" state.
    public static func suggest(for result: QueryResult) -> ChartConfig {
        let cols = result.columns
        let numeric = cols.filter(\.isNumeric).map(\.name)
        let temporal = cols.first { [.date, .timestamp, .time].contains($0.kind) }
        let label = cols.first { !$0.isNumeric && [.text, .enumeration, .boolean, .uuid, .other].contains($0.kind) }
        var x = (temporal ?? label)?.name
        var ys = numeric.filter { $0 != x }
        // Ids are rarely what one wants to plot.
        let measures = ys.filter { !isIDLike($0) }
        if !measures.isEmpty { ys = measures }
        if x == nil, let first = numeric.first {
            x = first
            ys = Array(numeric.dropFirst())
        }
        let kind: ChartKind = temporal != nil ? .line : .bar
        // One measure: several y columns usually have unrelated scales (a count next to a revenue flattens the count).
        return ChartConfig(kind: kind, x: x, ys: Array(ys.prefix(1)), series: nil, aggregate: ys.isEmpty ? .count : .none)
    }

    static func isIDLike(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == "id" || n.hasSuffix("_id") || n.hasSuffix("id") && n.count <= 4
    }

    // MARK: Build

    public static func build(_ result: QueryResult, config: ChartConfig) -> ChartData {
        guard let xName = config.x, let xi = result.columns.firstIndex(where: { $0.name == xName }) else {
            return ChartData(points: [], xKind: .text, series: [], skippedRows: 0, truncated: false)
        }
        let rows = result.rows.prefix(maxRows)
        let yNames = config.kind == .pie ? Array(config.ys.prefix(1)) : config.ys
        let yIdx = yNames.compactMap { y in result.columns.firstIndex { $0.name == y } }
        let si = config.series.flatMap { s in result.columns.firstIndex { $0.name == s } }
        let xKind = detectXKind(result.columns[xi], samples: rows.prefix(200).map { $0[safe: xi] ?? nil })

        // (x, series) -> values, in first-seen order.
        var order: [GroupKey] = []
        var buckets: [GroupKey: [Double]] = [:]
        var skipped = 0
        for row in rows {
            guard let raw = row[safe: xi] ?? nil, let x = parseX(raw, kind: xKind) else { skipped += 1; continue }
            let seriesValue = si.flatMap { row[safe: $0] ?? nil } ?? nil
            if config.aggregate == .count && yIdx.isEmpty {
                let key = GroupKey(x: x, series: seriesValue ?? "count")
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(1)
                continue
            }
            var any = false
            for yi in yIdx {
                guard let s = row[safe: yi] ?? nil, let v = Double(s.trimmingCharacters(in: .whitespaces)) else { continue }
                any = true
                let name = seriesName(y: result.columns[yi].name, seriesValue: seriesValue, multipleY: yIdx.count > 1)
                let key = GroupKey(x: x, series: name)
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(v)
            }
            if !any { skipped += 1 }
        }

        var points: [ChartPoint] = []
        var id = 0
        for key in order {
            let values = buckets[key] ?? []
            if config.aggregate == .none {
                // Keep every row; duplicates on x simply stack/overlap like the raw result.
                for v in values { points.append(ChartPoint(id: id, x: key.x, series: key.series, value: v)); id += 1 }
            } else {
                points.append(ChartPoint(id: id, x: key.x, series: key.series, value: aggregate(values, config.aggregate)))
                id += 1
            }
        }
        if xKind != .text || config.kind == .line || config.kind == .area {
            points.sort { $0.x == $1.x ? $0.id < $1.id : $0.x < $1.x }
        }
        if config.kind == .pie { points = foldPie(points) }
        var seenSeries: [String] = []
        for p in points where !seenSeries.contains(p.series) { seenSeries.append(p.series) }
        return ChartData(points: points, xKind: xKind, series: seenSeries, skippedRows: skipped, truncated: result.rows.count > maxRows)
    }

    private struct GroupKey: Hashable { var x: ChartX; var series: String }

    static func seriesName(y: String, seriesValue: String?, multipleY: Bool) -> String {
        switch (seriesValue, multipleY) {
        case (nil, _): return y
        case (let s?, false): return s
        case (let s?, true): return "\(y) · \(s)"
        }
    }

    static func aggregate(_ values: [Double], _ mode: ChartAggregate) -> Double {
        guard !values.isEmpty else { return 0 }
        switch mode {
        case .none, .sum: return values.reduce(0, +)
        case .average: return values.reduce(0, +) / Double(values.count)
        case .count: return Double(values.count)
        case .min: return values.min() ?? 0
        case .max: return values.max() ?? 0
        }
    }

    /// Largest slices first; everything past `maxSlices - 1` becomes "Other".
    static func foldPie(_ points: [ChartPoint]) -> [ChartPoint] {
        var totals: [ChartX: Double] = [:]
        var order: [ChartX] = []
        for p in points {
            if totals[p.x] == nil { order.append(p.x) }
            totals[p.x, default: 0] += p.value
        }
        let sorted = order.sorted { (totals[$0] ?? 0) > (totals[$1] ?? 0) }
        var out = sorted.prefix(maxSlices - 1).enumerated().map { ChartPoint(id: $0.offset, x: $0.element, series: "value", value: totals[$0.element] ?? 0) }
        let rest = sorted.dropFirst(maxSlices - 1).reduce(0.0) { $0 + (totals[$1] ?? 0) }
        if sorted.count > maxSlices - 1, rest > 0 {
            out.append(ChartPoint(id: out.count, x: .text("Other"), series: "value", value: rest))
        }
        return out
    }

    // MARK: Parsing

    static func detectXKind(_ column: ResultColumn, samples: [String?]) -> ChartXKind {
        switch column.kind {
        case .date, .timestamp: return .date
        case .integer, .decimal: return .number
        default:
            let values = samples.compactMap { $0 }.prefix(50)
            if !values.isEmpty, values.allSatisfy({ parseDate($0) != nil }) { return .date }
            return .text
        }
    }

    static func parseX(_ raw: String, kind: ChartXKind) -> ChartX? {
        switch kind {
        case .number: return Double(raw.trimmingCharacters(in: .whitespaces)).map(ChartX.number)
        case .date: return parseDate(raw).map(ChartX.date)
        case .text: return .text(raw)
        }
    }

    private static let formatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX", "yyyy-MM-dd HH:mm:ss.SSSSSSX", "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ssX",
        "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy-MM",
    ].map { f in
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = f
        return df
    }

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 7, s.first?.isNumber == true else { return nil }
        // PostgreSQL prints fractional seconds with 1–6 digits; pad so one pattern fits.
        let normalized = s.replacingOccurrences(of: #"(\.\d{1,6})(?=[+-]|$)"#, with: "$1", options: .regularExpression)
        for f in formatters {
            if let d = f.date(from: normalized) { return d }
        }
        if let dot = normalized.firstIndex(of: "."), let end = normalized[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let frac = String(normalized[normalized.index(after: dot)..<end])
            let padded = String(normalized[..<dot]) + "." + frac.padding(toLength: 6, withPad: "0", startingAt: 0) + String(normalized[end...])
            for f in formatters { if let d = f.date(from: padded) { return d } }
        }
        return nil
    }

    // Values are parsed as UTC, so they are labelled in UTC too: a `date` column stays "18 May 2026", not "…at 02:00".
    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func dateLabel(_ d: Date) -> String {
        Int(d.timeIntervalSince1970) % 86_400 == 0 ? dateOnlyFormatter.string(from: d) : dateTimeFormatter.string(from: d)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
