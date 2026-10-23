import MTPCore
import XCTest
@testable import FeatureDataTransfer

/// Runs against a fake TablePlus data folder and private stores; never touches the Keychain (passwords off).
final class TablePlusMigrationTests: XCTestCase {
    static func makeFakeTablePlus(in dir: URL) throws -> URL {
        let data = dir.appendingPathComponent("Data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let connections: [[String: Any]] = [
            ["ID": "TP-PROD", "ConnectionName": "Prod RDS", "Driver": "PostgreSQL", "DatabaseHost": "prod.example.invalid", "DatabasePort": "5432",
             "DatabaseUser": "app", "DatabaseName": "shop", "Enviroment": "production", "statusColor": "#FF0000", "GroupID": "G1", "tLSMode": 0],
            ["ID": "TP-STAGING", "ConnectionName": "Staging", "Driver": "PostgreSQL", "DatabaseHost": "staging.example.invalid", "DatabasePort": "6543",
             "DatabaseUser": "app", "DatabaseName": "shop_staging", "Enviroment": "staging", "GroupID": "G1",
             "isOverSSH": true, "ServerAddress": "bastion.example.invalid", "ServerPort": "22", "ServerUser": "ec2-user"],
            ["ID": "TP-LITE", "ConnectionName": "Local file", "Driver": "SQLite", "DatabasePath": "/tmp/x.sqlite", "Enviroment": "local"],
            ["ID": "TP-MYSQL", "ConnectionName": "Legacy", "Driver": "MySQL", "DatabaseHost": "mysql.example.invalid"],
        ]
        let groups: [[String: Any]] = [["ID": "G1", "Name": "AWS"], ["ID": "G2", "Name": "Unused"]]
        try PropertyListSerialization.data(fromPropertyList: connections, format: .binary, options: 0).write(to: data.appendingPathComponent("Connections.plist"))
        try PropertyListSerialization.data(fromPropertyList: groups, format: .xml, options: 0).write(to: data.appendingPathComponent("ConnectionGroups.plist"))

        let day = data.appendingPathComponent("History/TP-PROD/3 March 2026", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try "SELECT 1".write(to: day.appendingPathComponent("794000000.sql"), atomically: true, encoding: .utf8)
        try "SELECT * FROM orders".write(to: day.appendingPathComponent("794000100.sql"), atomically: true, encoding: .utf8)
        let other = data.appendingPathComponent("History/TP-STAGING/4 March 2026", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "SELECT 2".write(to: other.appendingPathComponent("794100000.sql"), atomically: true, encoding: .utf8)
        return data
    }

    func testPreviewAndSelectiveImport() throws {
        let dir = try tempDir()
        let data = try Self.makeFakeTablePlus(in: dir)
        let importer = TablePlusImporter(dataDirectory: data)
        XCTAssertTrue(importer.isAvailable)
        let preview = try importer.preview()
        XCTAssertEqual(preview.connections.map(\.name), ["Prod RDS", "Staging", "Local file"])
        XCTAssertEqual(preview.skipped.map(\.driver), ["MySQL"])
        XCTAssertEqual(preview.groups.map(\.name), ["AWS"])
        XCTAssertEqual(preview.historyFileCount, 3)
        XCTAssertEqual(TablePlusMigration.historyCounts(in: data), ["TP-PROD": 2, "TP-STAGING": 1])
        let staging = try XCTUnwrap(preview.connections.first { $0.name == "Staging" })
        XCTAssertEqual(staging.environment, .staging)
        XCTAssertEqual(staging.port, 6543)
        XCTAssertTrue(staging.ssh.enabled)

        let store = ConnectionStore(url: dir.appendingPathComponent("connections.json"))
        let history = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        let prod = try XCTUnwrap(preview.connections.first { $0.name == "Prod RDS" })
        let lite = try XCTUnwrap(preview.connections.first { $0.name == "Local file" })
        let summary = TablePlusMigration.run(importer: importer, preview: preview, selected: [prod.id, lite.id],
                                             importPasswords: false, importHistory: true, store: store, history: history)
        XCTAssertEqual(summary, TablePlusImportSummary(connections: 2, groups: 1, passwords: 0, historyEntries: 2))
        XCTAssertEqual(Set(store.connections.map(\.name)), ["Prod RDS", "Local file"])
        XCTAssertEqual(store.groups.map(\.name), ["AWS"])
        let saved = try XCTUnwrap(store.connections.first { $0.name == "Prod RDS" })
        XCTAssertEqual(saved.groupID, store.groups.first?.id)
        XCTAssertEqual(saved.environment, .production)
        XCTAssertEqual(saved.tablePlusID, "TP-PROD")
        let entries = history.entries(connectionID: saved.id)
        XCTAssertEqual(entries.map(\.sql).sorted(), ["SELECT * FROM orders", "SELECT 1"])
        XCTAssertEqual(entries.first?.source, "tableplus")

        // A second preview hides what was already imported; importing the rest reuses the group.
        let again = try importer.preview(existing: store.connections)
        XCTAssertEqual(again.connections.map(\.name), ["Staging"])
        let second = TablePlusMigration.run(importer: importer, preview: again, selected: Set(again.connections.map(\.id)),
                                            importPasswords: false, importHistory: false, store: store, history: history)
        XCTAssertEqual(second.groups, 0)
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.connections.first { $0.name == "Staging" }?.groupID, store.groups.first?.id)
    }

    func testMissingTablePlusFolder() throws {
        let importer = TablePlusImporter(dataDirectory: try tempDir().appendingPathComponent("nope"))
        XCTAssertFalse(importer.isAvailable)
        XCTAssertThrowsError(try importer.preview())
        XCTAssertTrue(TablePlusMigration.historyFiles(in: importer.dataDirectory).isEmpty)
    }
}
