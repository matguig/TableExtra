import AppKit
import SwiftUI

/// UserDefaults keys shared by the app (feature modules use their own prefixed keys).
enum SettingKey {
    static let pageSize = "pageSize"
    static let nullText = "nullText"
    static let editorFontSize = "editorFontSize"
    static let gridFontSize = "gridFontSize"
    static let appearance = "appearance"
    static let uppercaseCompletion = "uppercaseCompletion"
    static let autoCompletion = "autoCompletion"
    static let queryRowLimit = "queryRowLimit"
    static let confirmOnClose = "confirmOnClose"
    static let restoreWorkspaces = "restoreWorkspaces"
    static let showRowNumbers = "showRowNumbers"
    static let indentWidth = "indentWidth"
    static let estimateCountThreshold = "estimateCountThreshold"
    static let openInsightsOnConnect = "openInsightsOnConnect"
}

enum AppSettings {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            SettingKey.pageSize: 300,
            SettingKey.nullText: "NULL",
            SettingKey.editorFontSize: 13.0,
            SettingKey.gridFontSize: 12.0,
            SettingKey.appearance: "system",
            SettingKey.uppercaseCompletion: true,
            SettingKey.autoCompletion: true,
            SettingKey.queryRowLimit: 10_000,
            SettingKey.restoreWorkspaces: true,
            SettingKey.showRowNumbers: true,
            SettingKey.indentWidth: 2,
            SettingKey.estimateCountThreshold: 500_000,
            SettingKey.openInsightsOnConnect: true,
        ])
    }

    static var pageSize: Int { max(10, UserDefaults.standard.integer(forKey: SettingKey.pageSize)) }
    static var nullText: String { UserDefaults.standard.string(forKey: SettingKey.nullText) ?? "NULL" }
    static var queryRowLimit: Int { max(100, UserDefaults.standard.integer(forKey: SettingKey.queryRowLimit)) }
    static var indentWidth: Int { max(1, UserDefaults.standard.integer(forKey: SettingKey.indentWidth)) }

    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: SettingKey.appearance) {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
