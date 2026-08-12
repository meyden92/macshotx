import Foundation
import Security

/// Destination secrets live in the macOS Keychain, never in config.json
/// (PRD §6.9.4). Service: dev.macshot.app, account: <destination-id>.<field>.
enum Keychain {
    static let service = "dev.macshot.app"

    static func secretAccount(for destinationID: UUID, field: String) -> String {
        "destination.\(destinationID.uuidString).\(field)"
    }

    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func get(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
