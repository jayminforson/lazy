//
//  KeychainStore.swift
//  Clicky
//
//  M6.1 — minimal macOS Keychain wrapper (SecItem) for mail OAuth tokens.
//  Lazy kept its tokens under service "com.lazy.assistant"; Clicky uses a
//  bundle-scoped service so the two apps never collide. Tokens never touch
//  UserDefaults, SQLite, or logs (Lazy's N-04 rule, carried over).
//

import Foundation
import Security

enum KeychainStore {

    /// Service name for every mail token item (account = "gmail:tokens" /
    /// "outlook:tokens").
    static let mailService = "com.yourcompany.leanring-buddy.mail"

    // M7.3 — every primitive is `nonisolated`: SecItem* is thread-safe by
    // contract and these wrappers touch nothing isolated. The stall dumps
    // in brain.log (2026-10-22 morning, 3–4.1 s each, frames 19–22) pinned
    // a SYNCHRONOUS Keychain decrypt running on the main actor via the
    // mail token check — callers can now hop off-main (MailOAuthService
    // validTokens/refresh do).

    @discardableResult
    nonisolated static func save(service: String, account: String, data: Data) -> Bool {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status != errSecSuccess {
            print("🔐 Keychain: save \(service)/\(account) failed (OSStatus \(status))")
        }
        return status == errSecSuccess
    }

    nonisolated static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    nonisolated static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            print("🔐 Keychain: delete \(service)/\(account) failed (OSStatus \(status))")
        }
    }

    // MARK: - JSON convenience (token blobs are JSON dicts)

    @discardableResult
    nonisolated static func saveJSON(service: String, account: String, object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return save(service: service, account: account, data: data)
    }

    nonisolated static func loadJSON(service: String, account: String) -> [String: Any]? {
        guard let data = load(service: service, account: account) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
