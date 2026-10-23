import CoreGraphics
import MTPCore
import MTPUIKit
import XCTest
@testable import FeatureSchemaTools

final class ERDiagramTests: XCTestCase {
    func testLayeredLayoutPutsReferencedTablesLeftAndDoesNotOverlap() {
        let names = ["customers", "orders", "products", "order_items", "audit_log", "kysely_migration"]
        let nodes = names.map { ERLayout.Node(id: $0, size: CGSize(width: 200, height: 140)) }
        let edges = [ERLayout.Edge(child: "orders", parent: "customers"),
                     ERLayout.Edge(child: "order_items", parent: "orders"),
                     ERLayout.Edge(child: "order_items", parent: "products")]
        let p = ERLayout.layout(nodes: nodes, edges: edges)
        XCTAssertEqual(Set(p.keys), Set(names))
        XCTAssertLessThan(p["customers"]!.x, p["orders"]!.x)
        XCTAssertLessThan(p["orders"]!.x, p["order_items"]!.x)
        XCTAssertLessThan(p["products"]!.x, p["order_items"]!.x)
        let rects = names.map { CGRect(origin: p[$0]!, size: CGSize(width: 200, height: 140)) }
        for i in rects.indices { for j in rects.indices where i < j { XCTAssertFalse(rects[i].intersects(rects[j]), "\(names[i]) overlaps \(names[j])") } }
    }

    func testLayoutHandlesCyclesAndHundredTablesQuickly() {
        var nodes: [ERLayout.Node] = []
        var edges: [ERLayout.Edge] = []
        for i in 0..<120 {
            nodes.append(ERLayout.Node(id: "t\(i)", size: CGSize(width: 180, height: CGFloat(60 + (i % 7) * 20))))
            if i > 0 { edges.append(ERLayout.Edge(child: "t\(i)", parent: "t\((i * 7) % i)")) }
            if i % 10 == 9 { edges.append(ERLayout.Edge(child: "t\(i - 9)", parent: "t\(i)")) } // cycles
        }
        let start = Date()
        let p = ERLayout.layout(nodes: nodes, edges: edges)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(p.count, 120)
        let rects = nodes.map { CGRect(origin: p[$0.id]!, size: $0.size) }
        var overlaps = 0
        for i in rects.indices { for j in rects.indices where i < j && rects[i].intersects(rects[j]) { overlaps += 1 } }
        XCTAssertEqual(overlaps, 0)
    }

    func testLayoutFileRoundTripUnderAppHome() throws {
        guard ProcessInfo.processInfo.environment["TABLEEXTRA_HOME"] != nil else { throw XCTSkip("TABLEEXTRA_HOME not set") }
        let id = UUID()
        let file = DiagramLayoutFile(positions: ["orders": [10, 20]], displayMode: .keys, showViews: true)
        try file.save(connectionID: id, schema: "public")
        defer { DiagramLayoutFile.delete(connectionID: id, schema: "public") }
        XCTAssertTrue(DiagramLayoutFile.url(connectionID: id, schema: "public").path.hasPrefix(AppPaths.diagramsDirectory.path))
        XCTAssertEqual(DiagramLayoutFile.load(connectionID: id, schema: "public"), file)
    }

    @MainActor
    func testModelLoadsTestDatabaseRelationships() async throws {
        guard ProcessInfo.processInfo.environment["TABLEEXTRA_HOME"] != nil else { throw XCTSkip("TABLEEXTRA_HOME not set") }
        let (config, secrets) = try TestDB.config()
        let ctx = StandaloneWorkspaceContext(connection: config, secrets: secrets)
        try await ctx.prepare()
        defer { ctx.client.close() }
        let model = ERDiagramModel(context: ctx, schema: "public")
        await model.load()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(Set(model.tables.map(\.name)), ["customers", "orders", "products", "order_items", "audit_log", "kysely_migration"])
        let pairs = Set(model.edges.map { "\($0.child).\($0.childColumn ?? "")->\($0.parent).\($0.parentColumn ?? "")" })
        XCTAssertEqual(pairs, ["orders.customer_id->customers.id", "order_items.order_id->orders.id", "order_items.product_id->products.id"])
        model.select("orders")
        XCTAssertEqual(model.related, ["customers", "order_items"])
        model.search = "item"
        XCTAssertEqual(model.matches, ["order_items"])
        model.open("order_items")
        XCTAssertEqual(ctx.openedTables.last?.name, "order_items")
        model.mode = .keys
        let items = try XCTUnwrap(model.tables.first { $0.name == "order_items" })
        XCTAssertTrue(items.visibleColumns(.keys).allSatisfy { $0.isPrimaryKey || $0.isForeignKey })
        XCTAssertNotNil(model.pngData())
        DiagramLayoutFile.delete(connectionID: config.id, schema: "public")
    }
}
