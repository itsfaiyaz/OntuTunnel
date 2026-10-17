import Foundation
import Security

/// API tokens and the Let's Encrypt account key live in the login
/// keychain, never in config.json.
enum Keychain {
    private static let service = "com.ontu.ontutunnel"
    private static let oldService = "com.adimyra.localbridge"

    /// Reads the item, falling back to the app's old name (LocalBridge).
    static func get(_ account: String) -> Data? {
        if let d = get(account, service: service) { return d }
        guard let d = get(account, service: oldService) else { return nil }
        set(account, d)
        return d
    }

    private static func get(_ account: String, service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func string(_ account: String) -> String {
        get(account).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func set(_ account: String, _ data: Data?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data, !data.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "OntuTunnel \(account)"
        SecItemAdd(add as CFDictionary, nil)
    }

    static func set(_ account: String, _ value: String) {
        set(account, value.isEmpty ? nil : Data(value.utf8))
    }
}

enum SecretKey {
    static let cloudflareToken = "cloudflare.token"
    static let hostingerToken = "hostinger.token"
    static let godaddyKey = "godaddy.key"
    static let godaddySecret = "godaddy.secret"
    static func acmeAccountKey(staging: Bool) -> String { staging ? "acme.staging.key" : "acme.key" }
    static func acmeKid(staging: Bool) -> String { staging ? "acme.staging.kid" : "acme.kid" }
}
