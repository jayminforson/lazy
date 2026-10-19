//
//  MailModels.swift
//  Clicky
//
//  M6.1 — shared mail types: providers, OAuth token blob, and the stored
//  message shape. Ported conceptually from Lazy's Phase 4 data model
//  (accounts, messages, sync cursors) minus the parts Clicky doesn't need.
//

import Foundation

/// Supported mail providers. Gmail is fully wired (Lazy's existing Google
/// OAuth client); Outlook ships the same flow but needs an Azure app
/// registration before its Connect button can succeed.
enum MailProvider: String, CaseIterable, Codable {
    case gmail
    case outlook

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        }
    }

    /// Keychain account string for this provider's token blob.
    var keychainAccount: String { "\(rawValue):tokens" }
}

/// OAuth tokens for one provider. Refresh lives in MailOAuthService.
struct OAuthTokens {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String

    var dictionary: [String: Any] {
        [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "expires_at": expiresAt.timeIntervalSince1970,
            "scope": scope
        ]
    }

    init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    init?(dictionary: [String: Any]) {
        guard let accessToken = dictionary["access_token"] as? String, !accessToken.isEmpty else { return nil }
        let refreshToken = (dictionary["refresh_token"] as? String) ?? ""
        let expiresAtSeconds = (dictionary["expires_at"] as? Double) ?? 0
        let scope = (dictionary["scope"] as? String) ?? ""
        self.init(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtSeconds),
            scope: scope
        )
    }
}

/// One synced message, normalized across providers — the store's insert shape.
struct MailStoreMessage {
    let provider: MailProvider
    let providerID: String
    let threadID: String?
    let senderName: String?
    let senderEmail: String?
    let subject: String
    let body: String
    let receivedAt: Date
}
