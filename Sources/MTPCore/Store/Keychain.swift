import Foundation
import Security

public enum Keychain {
    public static let service = "fr.koa-dev.TableExtra"
    /// Service used while the app was called MyTablePlus; read as a fallback and copied to `service`.
    static let legacyService = "fr.koa-dev.MyTablePlus"
    /// TablePlus stores database passwords under this service with account "<ConnectionID>_database".
    public static let tablePlusService = "com.tableplus.TablePlus"

    public static func get(account: String, service: String = Keychain.service) -> String? {
        if let value = read(account: account, service: service) {
            if service == Keychain.service { adoptIfNeeded(value, account: account) }
            return value
        }
        guard service == Keychain.service, let legacy = read(account: account, service: legacyService) else { return nil }
        set(legacy, account: account, service: service)
        return legacy
    }

    /// Items written by earlier (ad-hoc signed) builds trust only those builds, so macOS asks again for each item.
    /// Re-creating the item once from the current, stably signed app makes it the owner and stops the prompts.
    private static func adoptIfNeeded(_ value: String, account: String) {
        let key = "keychain.adopted.\(account)"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key), isStablySigned else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = "TableExtra — \(account)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            defaults.set(true, forKey: key)
        } else {
            // Never lose the password: put it back through the regular path.
            set(value, account: account)
        }
    }

    /// True when the running binary has a certificate-based signature (not ad-hoc), so adopting items is lasting.
    static let isStablySigned: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return (dict[kSecCodeInfoCertificates as String] as? [Any])?.isEmpty == false
    }()

    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func set(_ value: String?, account: String, service: String = Keychain.service) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return true
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "TableExtra — \(account)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            if ok, isStablySigned { UserDefaults.standard.set(true, forKey: "keychain.adopted.\(account)") }
            return ok
        }
        return status == errSecSuccess
    }

    public static func delete(account: String, service: String = Keychain.service) {
        set(nil, account: account, service: service)
    }

    static func databaseAccount(_ id: UUID) -> String { "\(id.uuidString).database" }
    static func sshAccount(_ id: UUID) -> String { "\(id.uuidString).ssh" }

    public static func secrets(for id: UUID) -> ConnectionSecrets {
        ConnectionSecrets(password: get(account: databaseAccount(id)), sshPassword: get(account: sshAccount(id)))
    }

    public static func store(_ secrets: ConnectionSecrets, for id: UUID) {
        set(secrets.password, account: databaseAccount(id))
        set(secrets.sshPassword, account: sshAccount(id))
    }

    public static func removeSecrets(for id: UUID) {
        delete(account: databaseAccount(id))
        delete(account: sshAccount(id))
    }
}
