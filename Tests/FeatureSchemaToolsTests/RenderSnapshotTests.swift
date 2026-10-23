import AppKit
import MTPCore
import MTPUIKit
import SwiftUI
import XCTest
@testable import FeatureSchemaTools

/// Visual check: renders the three screens to PNGs in $MTP_RENDER_DIR (skipped when unset).
@MainActor
final class RenderSnapshotTests: XCTestCase {
    func renderDir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["MTP_RENDER_DIR"] else { throw XCTSkip("MTP_RENDER_DIR not set") }
        return URL(fileURLWithPath: dir)
    }

    func write<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        r.scale = 2
        let cg = try XCTUnwrap(r.cgImage)
        try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: url)
    }

    func context() async throws -> StandaloneWorkspaceContext {
        let (config, secrets) = try TestDB.config()
        let ctx = StandaloneWorkspaceContext(connection: config, secrets: secrets)
        try await ctx.prepare()
        return ctx
    }

    func testRenderSchemaDiff() async throws {
        let dir = try renderDir()
        let ctx = try await context()
        defer { ctx.client.close() }
        let scratch = "mtp_diff_render_" + UUID().uuidString.prefix(6).lowercased()
        _ = try await ctx.client.query("""
            CREATE SCHEMA \(scratch);
            CREATE TABLE \(scratch).customers (id bigserial PRIMARY KEY, email text NOT NULL, full_name text, country text, legacy text);
            CREATE TABLE \(scratch).old_stuff (id int);
            """)
        defer { Task { _ = try? await ctx.client.query("DROP SCHEMA IF EXISTS \(scratch) CASCADE") } }
        ctx.schemas.append(scratch)
        // Same test database registered as a "production" connection to show the warning banner.
        var prod = ctx.connection
        prod.id = UUID()
        prod.name = "shop (prod alias)"
        prod.environment = .production
        let model = SchemaDiffModel(context: ctx, connections: [prod], secrets: { _ in try! TestDB.config().1 })
        model.sourceSchema = "public"
        model.targetConnectionID = prod.id
        model.targetSchema = scratch
        await model.compare()
        XCTAssertNil(model.errorMessage)
        model.selection = DiffItem(kind: .table, name: "customers", change: .changed, summary: "", symbol: "").id
        try write(SchemaDiffContent(model: model), size: CGSize(width: 1300, height: 820), to: dir.appendingPathComponent("schema-diff.png"))
        _ = try await ctx.client.query("DROP SCHEMA IF EXISTS \(scratch) CASCADE")
    }

    func testRenderTypeScriptExport() async throws {
        let dir = try renderDir()
        let ctx = try await context()
        defer { ctx.client.close() }
        let model = TypeScriptExportModel(context: ctx, schema: "public", tables: nil)
        await model.load()
        XCTAssertFalse(model.output.isEmpty)
        try write(TypeScriptExportContent(model: model), size: CGSize(width: 1100, height: 700), to: dir.appendingPathComponent("typescript-export.png"))
    }

    func testRenderERDiagram() async throws {
        let dir = try renderDir()
        guard ProcessInfo.processInfo.environment["TABLEEXTRA_HOME"] != nil else { throw XCTSkip("TABLEEXTRA_HOME not set") }
        let ctx = try await context()
        defer { ctx.client.close() }
        let model = ERDiagramModel(context: ctx, schema: "public")
        await model.load()
        model.viewportResized(CGSize(width: 1200, height: 740))
        model.fit()
        model.select("orders")
        try write(ERDiagramContent(model: model), size: CGSize(width: 1200, height: 800), to: dir.appendingPathComponent("er-diagram.png"))
        try XCTUnwrap(model.pngData()).write(to: dir.appendingPathComponent("er-diagram-export.png"))
        DiagramLayoutFile.delete(connectionID: ctx.connection.id, schema: "public")
    }
}
