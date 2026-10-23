import CoreGraphics
import Foundation

/// Automatic layered layout from the foreign-key graph.
/// Referenced tables end up in the left-most layers; each connected component is laid out on its own
/// (layers + barycenter ordering to reduce crossings), then components are packed in rows and
/// tables without any relationship go into a grid at the end.
public enum ERLayout {
    public struct Node: Hashable, Sendable {
        public var id: String
        public var size: CGSize
        public init(id: String, size: CGSize) {
            self.id = id
            self.size = size
        }
    }

    /// `child` has a foreign key referencing `parent`.
    public struct Edge: Hashable, Sendable {
        public var child: String
        public var parent: String
        public init(child: String, parent: String) {
            self.child = child
            self.parent = parent
        }
    }

    public struct Spacing: Sendable {
        public var layerGap: CGFloat = 90
        public var nodeGap: CGFloat = 36
        public var componentGap: CGFloat = 120
        public var maxColumnHeight: CGFloat = 1800
        public var margin: CGFloat = 40
        public init() {}
    }

    /// Top-left corner of every node.
    public static func layout(nodes: [Node], edges: [Edge], spacing: Spacing = Spacing()) -> [String: CGPoint] {
        let ids = Set(nodes.map(\.id))
        let sizes = Dictionary(nodes.map { ($0.id, $0.size) }, uniquingKeysWith: { a, _ in a })
        let validEdges = Set(edges.filter { $0.child != $0.parent && ids.contains($0.child) && ids.contains($0.parent) })
        var parents: [String: Set<String>] = [:]
        var children: [String: Set<String>] = [:]
        var neighbours: [String: Set<String>] = [:]
        for e in validEdges {
            parents[e.child, default: []].insert(e.parent)
            children[e.parent, default: []].insert(e.child)
            neighbours[e.child, default: []].insert(e.parent)
            neighbours[e.parent, default: []].insert(e.child)
        }

        // Connected components, in a stable order (by name).
        var seen = Set<String>()
        var components: [[String]] = []
        var isolated: [String] = []
        for id in nodes.map(\.id).sorted() where !seen.contains(id) {
            guard neighbours[id] != nil else {
                seen.insert(id)
                isolated.append(id)
                continue
            }
            var comp: [String] = []
            var stack = [id]
            seen.insert(id)
            while let n = stack.popLast() {
                comp.append(n)
                for m in (neighbours[n] ?? []).sorted() where !seen.contains(m) {
                    seen.insert(m)
                    stack.append(m)
                }
            }
            components.append(comp.sorted())
        }

        // Lay out each component in its own coordinate space.
        var blocks: [(positions: [String: CGPoint], size: CGSize)] = components.map { comp in
            layoutComponent(comp, parents: parents, children: children, sizes: sizes, spacing: spacing)
        }
        blocks.sort { $0.size.width * $0.size.height > $1.size.width * $1.size.height }
        if !isolated.isEmpty {
            blocks.append(grid(isolated, sizes: sizes, spacing: spacing))
        }

        // Shelf-pack blocks into rows.
        let totalArea = blocks.reduce(CGFloat(0)) { $0 + $1.size.width * $1.size.height }
        let widest = blocks.map(\.size.width).max() ?? 0
        let rowWidth = max(widest, sqrt(totalArea) * 1.6)
        var out: [String: CGPoint] = [:]
        var x = spacing.margin
        var y = spacing.margin
        var rowHeight: CGFloat = 0
        for b in blocks {
            if x > spacing.margin && x + b.size.width > rowWidth + spacing.margin {
                x = spacing.margin
                y += rowHeight + spacing.componentGap
                rowHeight = 0
            }
            for (id, p) in b.positions { out[id] = CGPoint(x: p.x + x, y: p.y + y) }
            x += b.size.width + spacing.componentGap
            rowHeight = max(rowHeight, b.size.height)
        }
        return out
    }

    static func layoutComponent(_ comp: [String], parents: [String: Set<String>], children: [String: Set<String>],
                                sizes: [String: CGSize], spacing: Spacing) -> (positions: [String: CGPoint], size: CGSize) {
        let members = Set(comp)
        // Longest-path layering; edges closing a cycle are ignored.
        var layer: [String: Int] = [:]
        var onStack = Set<String>()
        func assign(_ n: String) -> Int {
            if let l = layer[n] { return l }
            onStack.insert(n)
            var l = 0
            for p in (parents[n] ?? []).sorted() where members.contains(p) && !onStack.contains(p) {
                l = max(l, assign(p) + 1)
            }
            onStack.remove(n)
            layer[n] = l
            return l
        }
        for n in comp { _ = assign(n) }

        let maxLayer = layer.values.max() ?? 0
        var layers: [[String]] = Array(repeating: [], count: maxLayer + 1)
        for n in comp { layers[layer[n] ?? 0].append(n) }
        // Initial order: most connected first, then name, which keeps hubs near the middle after sweeps.
        for i in layers.indices {
            layers[i].sort {
                let a = (parents[$0]?.count ?? 0) + (children[$0]?.count ?? 0)
                let b = (parents[$1]?.count ?? 0) + (children[$1]?.count ?? 0)
                return a == b ? $0 < $1 : a > b
            }
        }

        // Barycenter sweeps.
        func index(_ l: [String]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: l.enumerated().map { ($0.element, Double($0.offset)) })
        }
        for _ in 0..<6 {
            if layers.count > 1 {
                for i in 1..<layers.count {
                    let prev = index(layers[i - 1])
                    let current = index(layers[i])
                    layers[i].sort { a, b in
                        let ba = barycenter(a, parents[a], prev) ?? current[a]!
                        let bb = barycenter(b, parents[b], prev) ?? current[b]!
                        return ba == bb ? current[a]! < current[b]! : ba < bb
                    }
                }
                for i in stride(from: layers.count - 2, through: 0, by: -1) {
                    let next = index(layers[i + 1])
                    let current = index(layers[i])
                    layers[i].sort { a, b in
                        let ba = barycenter(a, children[a], next) ?? current[a]!
                        let bb = barycenter(b, children[b], next) ?? current[b]!
                        return ba == bb ? current[a]! < current[b]! : ba < bb
                    }
                }
            }
        }

        // Columns: a layer taller than maxColumnHeight wraps into several columns.
        var columns: [[String]] = []
        for l in layers {
            var col: [String] = []
            var h: CGFloat = 0
            for n in l {
                let nh = sizes[n]?.height ?? 100
                if !col.isEmpty && h + nh > spacing.maxColumnHeight {
                    columns.append(col)
                    col = []
                    h = 0
                }
                col.append(n)
                h += nh + spacing.nodeGap
            }
            if !col.isEmpty { columns.append(col) }
        }

        let heights = columns.map { col in col.reduce(CGFloat(0)) { $0 + (sizes[$1]?.height ?? 100) } + CGFloat(max(col.count - 1, 0)) * spacing.nodeGap }
        let total = heights.max() ?? 0
        var positions: [String: CGPoint] = [:]
        var x: CGFloat = 0
        for (ci, col) in columns.enumerated() {
            let width = col.map { sizes[$0]?.width ?? 200 }.max() ?? 200
            var y = (total - heights[ci]) / 2
            for n in col {
                positions[n] = CGPoint(x: x, y: y)
                y += (sizes[n]?.height ?? 100) + spacing.nodeGap
            }
            x += width + spacing.layerGap
        }
        return (positions, CGSize(width: max(x - spacing.layerGap, 0), height: total))
    }

    static func barycenter(_ n: String, _ linked: Set<String>?, _ order: [String: Double]) -> Double? {
        let values = (linked ?? []).compactMap { order[$0] }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    static func grid(_ ids: [String], sizes: [String: CGSize], spacing: Spacing) -> (positions: [String: CGPoint], size: CGSize) {
        let perRow = max(1, Int(ceil(sqrt(Double(ids.count) * 1.5))))
        var positions: [String: CGPoint] = [:]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for (i, id) in ids.enumerated() {
            if i > 0 && i % perRow == 0 {
                x = 0
                y += rowHeight + spacing.nodeGap
                rowHeight = 0
            }
            let s = sizes[id] ?? CGSize(width: 200, height: 100)
            positions[id] = CGPoint(x: x, y: y)
            x += s.width + spacing.nodeGap
            width = max(width, x - spacing.nodeGap)
            rowHeight = max(rowHeight, s.height)
        }
        return (positions, CGSize(width: width, height: y + rowHeight))
    }

    /// Number of crossing edge pairs between consecutive columns (diagnostics and tests).
    static func crossings(edges: [Edge], positions: [String: CGPoint]) -> Int {
        let segs = edges.compactMap { e -> (CGPoint, CGPoint)? in
            guard let a = positions[e.child], let b = positions[e.parent] else { return nil }
            return (a, b)
        }
        var count = 0
        for i in segs.indices {
            for j in segs.indices where j > i {
                if intersects(segs[i].0, segs[i].1, segs[j].0, segs[j].1) { count += 1 }
            }
        }
        return count
    }

    private static func intersects(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func ccw(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        if p1 == p3 || p1 == p4 || p2 == p3 || p2 == p4 { return false }
        let d1 = ccw(p3, p4, p1), d2 = ccw(p3, p4, p2), d3 = ccw(p1, p2, p3), d4 = ccw(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
