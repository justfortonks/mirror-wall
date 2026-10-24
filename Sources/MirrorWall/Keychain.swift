import Foundation
import Security

/// Secrets Mirror Wall keeps in the login keychain rather than its preferences file: today the
/// relay's team token. One generic password per name, readable only by Mirror Wall.
enum Keychain {
    private static let service = "com.justfortonks.mirrorwall"

    static func string(_ name: String) -> String? {
        var query = base(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value` under `name`; an empty value removes it.
    @discardableResult
    static func set(_ value: String, for name: String) -> Bool {
        SecItemDelete(base(name) as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = base(name)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Mirror Wall \(name)"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func base(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }
}
