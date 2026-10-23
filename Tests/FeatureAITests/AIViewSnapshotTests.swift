import AppKit
import MTPCore
import MTPUIKit
import SwiftUI
import XCTest
@testable import FeatureAI

/// Renders the AI panel and settings to PNG for a visual check (MTP_SNAPSHOT_DIR=<folder>); skipped otherwise.
/// Uses canned messages and a fake `claude`: no real Claude call.
@MainActor
final class AIViewSnapshotTests: XCTestCase {
    final class FakeBridge: AIEditorBridge {
        var editorSQL = "SELECT 1"
        var selectedSQL: String?
        var lastError: String?
        func insertSQL(_ sql: String, replaceAll: Bool) {}
    }

    var dir: URL!
    let suiteName = "mtp.ai.snapshot.tests"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["MTP_SNAPSHOT_DIR"] != nil else { throw XCTSkip("MTP_SNAPSHOT_DIR not set") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-snap-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `claude mcp get` (MCP settings) hits this fake instead of the real CLI.
        let fake = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho 'No MCP server found with name: tableextra' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        AISettings.defaults = UserDefaults(suiteName: suiteName)!
        AISettings.claudePath = fake.path
    }

    override func tearDownWithError() throws {
        AISettings.defaults.removePersistentDomain(forName: suiteName)
        AISettings.defaults = .standard
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func snap<V: View>(_ view: V, _ name: String, sizes: [CGSize]) throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MTP_SNAPSHOT_DIR"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (i, size) in sizes.enumerated() {
            for dark in [false, true] {
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("render failed: \(name)") }
                host.cacheDisplay(in: host.bounds, to: rep)
                let suffix = (i == 0 ? "" : "-\(Int(size.width))") + (dark ? "-dark" : "-light")
                try rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name)\(suffix).png"))
                window.contentView = nil
            }
        }
    }

    func context() -> StandaloneWorkspaceContext {
        var c = ConnectionConfig(name: "Scratch", driver: .sqlite)
        c.filePath = dir.appendingPathComponent("x.sqlite").path
        return StandaloneWorkspaceContext(connection: c, secrets: ConnectionSecrets())
    }

    func testAssistantSnapshots() throws {
        let ctx = context()
        let bridge = FakeBridge()
        let empty = AIAssistantModel(context: ctx, bridge: bridge)
        try snap(AIAssistantView(model: empty), "ai-empty", sizes: [CGSize(width: 340, height: 620), CGSize(width: 280, height: 480)])

        let chat = AIAssistantModel(context: ctx, bridge: bridge)
        let answer = "Here you go:\n```sql\nSELECT c.id, c.email, sum(o.total) AS revenue\nFROM customers c\nJOIN orders o ON o.customer_id = c.id\nGROUP BY c.id\nORDER BY revenue DESC\nLIMIT 10;\n```\nAssumes `orders.total` is the order amount."
        chat.messages = [
            AIChatMessage(role: .user, title: nil, text: "", segments: [.text("Top 10 customers by revenue")]),
            AIChatMessage(role: .assistant, text: answer, segments: AIMarkdown.segments(answer), footnote: "claude-sonnet · 3.2 s"),
            AIChatMessage(role: .user, title: "Explain", text: "", segments: [.code(language: "sql", code: "SELECT 1")]),
            AIChatMessage(role: .error, text: "claude exited with status 1", segments: [.text("claude exited with status 1")]),
        ]
        chat.input = "Orders shipped late last month"
        try snap(AIAssistantView(model: chat), "ai-chat", sizes: [CGSize(width: 340, height: 760), CGSize(width: 280, height: 560)])
    }

    func testSettingsSnapshots() throws {
        try snap(AISettingsView(), "ai-settings", sizes: [CGSize(width: 640, height: 560)])
        try snap(MCPSettingsView(), "mcp-settings", sizes: [CGSize(width: 640, height: 1000)])
    }
}
