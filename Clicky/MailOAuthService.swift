//
//  MailOAuthService.swift
//  Clicky
//
//  M6.1 — OAuth2 authorization-code + PKCE for mail providers, ported from
//  Lazy's Phase 4 engine (app/providers/oauth.py): a loopback HTTP listener
//  on an ephemeral local port catches the browser redirect, tokens are
//  exchanged/refreshed here and live ONLY in the macOS Keychain. Google
//  desktop clients require "localhost" in the redirect (not 127.0.0.1) —
//  same quirk Lazy worked around.
//

import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - Client config (seeded from Lazy's Google Cloud project)

/// The OAuth client id/secret pair for one provider. Gmail's comes from
/// Lazy's existing Google Cloud Desktop client (copied into Clicky's
/// Application Support at seed time); Outlook's is entered by the user after
/// they register an Azure app.
struct OAuthClientConfig {
    let clientId: String
    let clientSecret: String
}

enum MailOAuthClients {

    /// `~/Library/Application Support/com.yourcompany.leanring-buddy/mail-clients.json`
    static var clientsFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yourcompany.leanring-buddy", isDirectory: true)
            .appendingPathComponent("mail-clients.json")
    }

    static func config(for provider: MailProvider) -> OAuthClientConfig? {
        guard let data = try? Data(contentsOf: clientsFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerJSON = json[provider.rawValue] as? [String: Any],
              let clientId = providerJSON["clientId"] as? String,
              !clientId.isEmpty
        else {
            return nil
        }
        let clientSecret = (providerJSON["clientSecret"] as? String) ?? ""
        return OAuthClientConfig(clientId: clientId, clientSecret: clientSecret)
    }
}

// MARK: - Loopback server

/// One-shot loopback HTTP listener: waits for the OAuth redirect GET, checks
/// the state param, answers with a "you can close this tab" page, and hands
/// the code back. Everything runs on the main actor; the NW callbacks hop in.
final class LoopbackOAuthServer {

    private var listener: NWListener?
    private var continuation: CheckedContinuation<String?, Never>?
    private var didResume = false
    private var didNotifyPort = false

    /// The ephemeral port the listener bound (valid once `onPortReady` fired).
    private(set) var port: UInt16 = 0

    /// Starts the listener, calls `onPortReady` (returns false to abort),
    /// then waits for the redirect code — nil on timeout/abort/failure.
    func waitForCode(
        expectedState: String,
        timeoutSeconds: TimeInterval = 300,
        onPortReady: @escaping (UInt16) -> Bool
    ) async -> String? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            guard let portZero = NWEndpoint.Port(rawValue: 0),
                  let listener = try? NWListener(using: parameters, on: portZero)
            else {
                print("🪝 OAuth loopback: listener creation failed")
                self.resume(with: nil)
                return
            }
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handle(connection, expectedState: expectedState)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard !self.didNotifyPort else { return }
                        self.didNotifyPort = true
                        guard let boundPort = listener.port?.rawValue,
                              onPortReady(boundPort)
                        else {
                            print("🪝 OAuth loopback: port ready but setup aborted")
                            self.resume(with: nil)
                            return
                        }
                        self.port = boundPort
                    case .failed(let error):
                        print("🪝 OAuth loopback: listener failed — \(error)")
                        self.resume(with: nil)
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.resume(with: nil)
            }
        }
    }

    private func handle(_ connection: NWConnection, expectedState: String) {
        connection.start(queue: .main)
        receiveRequest(connection, buffer: Data(), expectedState: expectedState)
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data, expectedState: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let requestHead = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                    self.respondAndExtractCode(requestHead, connection: connection, expectedState: expectedState)
                } else if error != nil || isComplete || buffer.count > 16_384 {
                    connection.cancel()
                } else {
                    self.receiveRequest(connection, buffer: buffer, expectedState: expectedState)
                }
            }
        }
    }

    private func respondAndExtractCode(_ requestHead: String, connection: NWConnection, expectedState: String) {
        // First line: "GET /?code=…&state=… HTTP/1.1"
        let firstLine = requestHead.components(separatedBy: "\r\n").first ?? ""
        let headParts = firstLine.components(separatedBy: " ")
        var receivedCode: String?
        if headParts.count >= 2,
           let components = URLComponents(string: "http://localhost" + headParts[1]),
           let items = components.queryItems {
            let state = items.first(where: { $0.name == "state" })?.value
            receivedCode = items.first(where: { $0.name == "code" })?.value
            if state != expectedState {
                print("🪝 OAuth loopback: state mismatch — rejecting redirect")
                receivedCode = nil
            }
        }

        let page: String
        if receivedCode != nil {
            page = "<html><body style='font-family: -apple-system; padding: 40px;'><h2>✅ Signed in</h2><p>You can close this tab and return to Lazy.</p></body></html>"
        } else {
            page = "<html><body style='font-family: -apple-system; padding: 40px;'><h2>⚠️ Sign-in failed</h2><p>This tab can be closed — the error is reported back to Lazy.</p></body></html>"
        }
        let body = Data(page.utf8)
        let head = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: head + body, completion: .contentProcessed { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { connection.cancel() }
        })

        if let receivedCode {
            print("🪝 OAuth loopback: received authorization code")
            resume(with: receivedCode)
        } else {
            // A stray GET (favicon, prefetch) shouldn't kill the flow — only
            // fail when the request actually carried OAuth error params.
            if firstLine.contains("error=") {
                print("🪝 OAuth loopback: browser reported an error — \(firstLine.prefix(160))")
                resume(with: nil)
            }
        }
    }

    private func resume(with code: String?) {
        guard !didResume else { return }
        didResume = true
        listener?.cancel()
        listener = nil
        continuation?.resume(returning: code)
        continuation = nil
    }
}

// MARK: - OAuth service

enum MailOAuthService {

    // Provider endpoints — exactly Lazy's Phase 4 sets.
    private static func authorizeURLString(for provider: MailProvider) -> String {
        switch provider {
        case .gmail: return "https://accounts.google.com/o/oauth2/v2/auth"
        case .outlook: return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        }
    }

    private static func tokenURL(for provider: MailProvider) -> URL? {
        switch provider {
        case .gmail: return URL(string: "https://oauth2.googleapis.com/token")
        case .outlook: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        }
    }

    private static func revokeURL(for provider: MailProvider) -> URL? {
        switch provider {
        case .gmail: return URL(string: "https://oauth2.googleapis.com/revoke")
        case .outlook: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/revoke")
        }
    }

    /// Send + read scopes, requested together at first consent (Lazy added
    /// compose later and had to re-consent; asking once avoids that).
    private static func scopes(for provider: MailProvider) -> String {
        switch provider {
        case .gmail:
            return [
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/gmail.compose"
            ].joined(separator: " ")
        case .outlook:
            return ["Mail.Read", "Mail.Send", "offline_access", "openid", "email"].joined(separator: " ")
        }
    }

    // MARK: Stored tokens (Keychain only)

    static func storedTokens(for provider: MailProvider) -> OAuthTokens? {
        guard let dictionary = KeychainStore.loadJSON(
            service: KeychainStore.mailService,
            account: provider.keychainAccount
        ) else { return nil }
        return OAuthTokens(dictionary: dictionary)
    }

    static func storeTokens(_ tokens: OAuthTokens, for provider: MailProvider) {
        KeychainStore.saveJSON(
            service: KeychainStore.mailService,
            account: provider.keychainAccount,
            object: tokens.dictionary
        )
    }

    static func deleteTokens(for provider: MailProvider) {
        KeychainStore.delete(service: KeychainStore.mailService, account: provider.keychainAccount)
    }

    // MARK: Full interactive connect

    /// Runs the browser flow end-to-end. Returns fresh tokens, or nil when
    /// the user cancels, the client config is missing, or the exchange fails.
    static func connect(_ provider: MailProvider) async -> OAuthTokens? {
        guard let config = MailOAuthClients.config(for: provider) else {
            print("📧 OAuth(\(provider.rawValue)): no OAuth client configured — \(provider == .outlook ? "register an Azure app and put its id in mail-clients.json" : "seed mail-clients.json")")
            return nil
        }

        let state = randomState()
        let pkce = pkcePair()
        let server = LoopbackOAuthServer()

        let code = await server.waitForCode(expectedState: state) { port in
            guard let url = buildAuthorizeURL(
                provider: provider,
                config: config,
                redirectURI: redirectURI(provider: provider, port: port),
                state: state,
                codeChallenge: pkce.challenge
            ) else { return false }
            print("📧 OAuth(\(provider.rawValue)): opening browser to sign in")
            NSWorkspace.shared.open(url)
            return true
        }
        guard let code else {
            print("📧 OAuth(\(provider.rawValue)): sign-in cancelled or timed out")
            return nil
        }

        let redirectURIValue = redirectURI(provider: provider, port: server.port)
        guard let tokens = await exchangeCode(
            code,
            provider: provider,
            config: config,
            codeVerifier: pkce.verifier,
            redirectURI: redirectURIValue
        ) else { return nil }

        storeTokens(tokens, for: provider)
        print("📧 OAuth(\(provider.rawValue)): connected — access token stored in Keychain")
        return tokens
    }

    /// Returns valid tokens, transparently refreshing when the access token
    /// expires within 60 s. Nil = refresh failed → reconnect needed.
    static func validTokens(for provider: MailProvider) async -> OAuthTokens? {
        guard let tokens = storedTokens(for: provider) else { return nil }
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens
        }
        return await refresh(provider)
    }

    static func refresh(_ provider: MailProvider) async -> OAuthTokens? {
        guard let config = MailOAuthClients.config(for: provider),
              let current = storedTokens(for: provider),
              !current.refreshToken.isEmpty,
              let tokenURL = tokenURL(for: provider)
        else {
            print("📧 OAuth(\(provider.rawValue)): refresh impossible — no refresh token stored")
            return nil
        }

        let parameters: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": config.clientId,
            "client_secret": config.clientSecret
        ]
        guard let json = await postForm(url: tokenURL, parameters: parameters),
              var refreshed = parseTokens(json: json, previousRefreshToken: current.refreshToken)
        else {
            print("📧 OAuth(\(provider.rawValue)): token refresh failed — reconnect needed")
            return nil
        }
        if refreshed.refreshToken.isEmpty {
            refreshed.refreshToken = current.refreshToken
        }
        storeTokens(refreshed, for: provider)
        return refreshed
    }

    /// Best-effort revocation on disconnect (Lazy's revoke was non-fatal too).
    static func revoke(_ provider: MailProvider) {
        guard let tokens = storedTokens(for: provider),
              let revokeURL = revokeURL(for: provider)
        else { return }
        let token = tokens.refreshToken.isEmpty ? tokens.accessToken : tokens.refreshToken
        var request = URLRequest(url: revokeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(["token": token])
        Task {
            _ = try? await URLSession.shared.data(for: request)
            print("📧 OAuth(\(provider.rawValue)): revocation sent (non-fatal on failure)")
        }
    }

    // MARK: - Exchange helpers

    private static func exchangeCode(
        _ code: String,
        provider: MailProvider,
        config: OAuthClientConfig,
        codeVerifier: String,
        redirectURI: String
    ) async -> OAuthTokens? {
        guard let tokenURL = tokenURL(for: provider) else { return nil }
        let parameters: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "redirect_uri": redirectURI,
            "code_verifier": codeVerifier
        ]
        guard let json = await postForm(url: tokenURL, parameters: parameters),
              let tokens = parseTokens(json: json, previousRefreshToken: nil)
        else {
            print("📧 OAuth(\(provider.rawValue)): code exchange failed")
            return nil
        }
        return tokens
    }

    private static func postForm(url: URL, parameters: [String: String]) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode(parameters)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard (200..<300).contains(http.statusCode) else {
                let bodyText = String(data: data.prefix(300), encoding: .utf8) ?? ""
                print("📧 OAuth: token endpoint \(http.statusCode) — \(bodyText)")
                return nil
            }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            print("📧 OAuth: token request failed — \(error.localizedDescription)")
            return nil
        }
    }

    private static func parseTokens(json: [String: Any], previousRefreshToken: String?) -> OAuthTokens? {
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else { return nil }
        let expiresIn: Double
        if let expiresInInt = json["expires_in"] as? Int {
            expiresIn = Double(expiresInInt)
        } else if let expiresInDouble = json["expires_in"] as? Double {
            expiresIn = expiresInDouble
        } else if let expiresInString = json["expires_in"] as? String, let parsed = Double(expiresInString) {
            expiresIn = parsed
        } else {
            expiresIn = 3600
        }
        let refreshToken = (json["refresh_token"] as? String) ?? previousRefreshToken ?? ""
        let scope = (json["scope"] as? String) ?? ""
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: scope
        )
    }

    // MARK: - URL / crypto helpers

    /// Google desktop clients redirect on "localhost"; Microsoft uses
    /// 127.0.0.1 (Lazy chose the host by provider the same way).
    private static func redirectURI(provider: MailProvider, port: UInt16) -> String {
        let host = provider == .gmail ? "localhost" : "127.0.0.1"
        return "http://\(host):\(port)/"
    }

    private static func buildAuthorizeURL(
        provider: MailProvider,
        config: OAuthClientConfig,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL? {
        var components = URLComponents(string: authorizeURLString(for: provider))
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes(for: provider)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        if provider == .gmail {
            items.append(URLQueryItem(name: "access_type", value: "offline"))
            items.append(URLQueryItem(name: "include_granted_scopes", value: "true"))
        }
        components?.queryItems = items
        return components?.url
    }

    private static func formEncode(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8) ?? Data()
    }

    private static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    private static func pkcePair() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncodedString()
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        return (verifier, challengeData.base64URLEncodedString())
    }
}

// MARK: - base64url (Gmail uses it for bodies and raw messages)

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: base64)
    }
}
