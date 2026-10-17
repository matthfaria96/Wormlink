import Foundation
import Security

/// Senhas guardadas como "senha de internet" no Chaves, no mesmo formato do Cyberduck
/// (servidor + conta + protocolo + porta). Assim os dois apps enxergam as mesmas senhas.
public enum Keychain {
    private static func query(for b: Bookmark) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: b.hostname,
            kSecAttrAccount as String: b.username,
            kSecAttrProtocol as String: b.connectionProtocol.keychainProtocol,
            kSecAttrPort as String: b.port,
        ]
    }

    public static func password(for b: Bookmark) -> String? {
        var q = query(for: b)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setPassword(_ password: String, for b: Bookmark) -> Bool {
        let data = Data(password.utf8)
        let q = query(for: b)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(b.hostname) (\(b.username))"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public static func deletePassword(for b: Bookmark) {
        SecItemDelete(query(for: b) as CFDictionary)
    }

    // MARK: Frases secretas de chaves SSH

    private static func keyQuery(_ path: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Wormlink SSH",
         kSecAttrAccount as String: path]
    }

    public static func keyPassphrase(for path: String) -> String? {
        var q = keyQuery(path)
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func setKeyPassphrase(_ passphrase: String, for path: String) {
        SecItemDelete(keyQuery(path) as CFDictionary)
        var add = keyQuery(path)
        add[kSecValueData as String] = Data(passphrase.utf8)
        add[kSecAttrLabel as String] = "Wormlink: frase secreta de \((path as NSString).lastPathComponent)"
        SecItemAdd(add as CFDictionary, nil)
    }
}
