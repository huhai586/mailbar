import Foundation
import Security

enum Keychain {
    static let service = "com.huhai.mail-client"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ data: Data, account: String) throws {
        // 先原地更新：旧条目是别的签名的程序（旧版 MailBar、命令行工具）建的时，删除可能被拒绝，再添加就会得到 -25299（条目已存在）
        let updated = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        if updated != errSecItemNotFound { SecItemDelete(query(account: account) as CFDictionary) }
        var add = query(account: account)
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw MailError.keychain(status) }
    }

    static func load(account: String) -> Data? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
