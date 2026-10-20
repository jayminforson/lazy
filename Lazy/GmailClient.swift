//
//  GmailClient.swift
//  Clicky
//
//  M6.1 — Gmail REST client (profile, recent-ids, incremental history,
//  full-message fetch, send). Port of Lazy's Phase 4 gmail adapter
//  (readonly + compose scopes) onto URLSession. All calls take a valid
//  access token; refresh lives in MailOAuthService.
//

import Foundation

struct GmailClient {

    private let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    // MARK: - Profile

    /// The signed-in address ("…@gmail.com"); nil on any failure.
    func fetchProfile(accessToken: String) async -> String? {
        guard let url = URL(string: "\(baseURL)/profile") else { return nil }
        guard let (data, _) = await authorizedGet(url: url, accessToken: accessToken) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["emailAddress"] as? String
    }

    // MARK: - Listing

    /// Result of the initial bounded listing: message ids plus the account's
    /// current historyId, which seeds the incremental cursor.
    /// `failed` distinguishes "no new mail" from "the request failed" —
    /// before M6.10 the caller recorded both as a successful empty sync,
    /// which silently hid rate-limit/HTTP errors (mail stopped arriving
    /// while Settings still showed "synced").
    struct RecentListing {
        let messageIDs: [String]
        let historyID: String?
        let failed: Bool
    }

    /// Gmail serializes `historyId` as a JSON **number** (int64), not a
    /// string — `as? String` always returned nil, so the incremental cursor
    /// was never seeded and every 90 s poll re-listed 7 days of mail and
    /// re-fetched up to 60 known messages (M6.10 root cause). Accept both.
    static func historyIDString(_ json: [String: Any]) -> String? {
        if let string = json["historyId"] as? String, !string.isEmpty { return string }
        if let number = json["historyId"] as? NSNumber { return number.stringValue }
        return nil
    }

    /// Message ids received since the given date (initial bounded sync —
    /// Lazy's `lookback_days` window).
    func recentListing(accessToken: String, since date: Date, maxResults: Int = 100) async -> RecentListing {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy/MM/dd"
        let query = "after:\(dayFormatter.string(from: date))"
        var components = URLComponents(string: "\(baseURL)/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        guard let url = components.url else {
            return RecentListing(messageIDs: [], historyID: nil, failed: true)
        }
        guard let (data, _) = await authorizedGet(url: url, accessToken: accessToken),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return RecentListing(messageIDs: [], historyID: nil, failed: true) }
        let messages = json["messages"] as? [[String: Any]] ?? []
        return RecentListing(
            messageIDs: messages.compactMap { $0["id"] as? String },
            historyID: Self.historyIDString(json),
            failed: false
        )
    }

    // MARK: - Incremental sync

    struct HistoryResult {
        let messageIDs: [String]
        /// Cursor for the next incremental pass (the response's historyId).
        let nextCursor: String?
        /// True when the cursor aged out of Gmail's history window — the
        /// caller must fall back to a fresh recent-listing sync.
        let cursorTooOld: Bool
        /// True when the request failed (HTTP/network/parse). The cursor is
        /// left untouched so the next pass retries the same window instead of
        /// silently skipping mail (M6.10).
        let failed: Bool
    }

    /// Incremental changes since the stored history cursor (Gmail history
    /// API — same cursor approach Lazy used).
    func historyChanges(accessToken: String, startHistoryID: String, maxResults: Int = 100) async -> HistoryResult {
        var components = URLComponents(string: "\(baseURL)/history")!
        components.queryItems = [
            URLQueryItem(name: "startHistoryId", value: startHistoryID),
            URLQueryItem(name: "historyTypes", value: "message"),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        guard let url = components.url else {
            return HistoryResult(messageIDs: [], nextCursor: nil, cursorTooOld: false, failed: true)
        }
        guard let (data, response) = await authorizedGet(url: url, accessToken: accessToken, failOnNonSuccess: false) else {
            // Network failure (a 4xx/5xx would have returned the response) —
            // keep the cursor, report the failure, back off.
            return HistoryResult(messageIDs: [], nextCursor: nil, cursorTooOld: false, failed: true)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 404 || http.statusCode == 410 {
                print("📧 Gmail: history cursor too old (\(http.statusCode)) — full re-listing next")
                return HistoryResult(messageIDs: [], nextCursor: nil, cursorTooOld: true, failed: false)
            }
            // Real error (401/429/5xx) — NOT "no changes". Keep the cursor so
            // the next pass retries the same window.
            return HistoryResult(messageIDs: [], nextCursor: nil, cursorTooOld: false, failed: true)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return HistoryResult(messageIDs: [], nextCursor: nil, cursorTooOld: false, failed: true)
        }
        let historyEntries = json["history"] as? [[String: Any]] ?? []
        var ids: [String] = []
        for entry in historyEntries {
            let added = entry["messagesAdded"] as? [[String: Any]] ?? []
            for addition in added {
                if let id = (addition["message"] as? [String: Any])?["id"] as? String {
                    ids.append(id)
                }
            }
        }
        let nextCursor = Self.historyIDString(json) ?? startHistoryID
        return HistoryResult(
            messageIDs: Array(Set(ids)).sorted(),
            nextCursor: nextCursor,
            cursorTooOld: false,
            failed: false
        )
    }

    // MARK: - Full message fetch

    /// Fetches one message (format=full) and normalizes it to the store shape.
    func fetchMessage(accessToken: String, id: String) async -> MailStoreMessage? {
        var components = URLComponents(string: "\(baseURL)/messages/\(id)")!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        guard let url = components.url,
              let (data, _) = await authorizedGet(url: url, accessToken: accessToken),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        func headerValue(_ name: String) -> String? {
            headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String
        }

        let fromHeader = headerValue("From") ?? ""
        let (senderName, senderEmail) = Self.parseFromHeader(fromHeader)
        let subject = headerValue("Subject") ?? "(no subject)"
        let receivedAt = Self.parseRFC2822Date(headerValue("Date")) ?? Date()
        let body = Self.textPlainBody(from: payload) ?? ""

        return MailStoreMessage(
            provider: .gmail,
            providerID: id,
            threadID: json["threadId"] as? String,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: subject,
            body: body,
            receivedAt: receivedAt
        )
    }

    // MARK: - Send (M6.4 uses this; built now for parity)

    /// Sends an RFC-822 message (already MIME-encoded by the caller).
    func send(accessToken: String, rfc822: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)/messages/send") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["raw": Data(rfc822.utf8).base64URLEncodedString()]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data.prefix(300), encoding: .utf8) ?? ""
                print("📧 Gmail: send failed \(http.statusCode) — \(bodyText)")
            }
            return (200..<300).contains(http.statusCode)
        } catch {
            print("📧 Gmail: send failed — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private helpers

    /// `failOnNonSuccess: false` returns the response even on 4xx/5xx so the
    /// caller can inspect the status — `historyChanges` needs to see 404/410
    /// (cursor aged out → fall back to a fresh listing) instead of having it
    /// flattened into a generic failure. Defaults to nil-on-error for
    /// callers that only care about success.
    private func authorizedGet(url: URL, accessToken: String, failOnNonSuccess: Bool = true) async -> (Data, URLResponse)? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data.prefix(200), encoding: .utf8) ?? ""
                print("📧 Gmail: GET \(url.path) → \(http.statusCode) — \(bodyText)")
                if failOnNonSuccess { return nil }
                return (data, response)
            }
            return (data, response)
        } catch {
            print("📧 Gmail: GET \(url.path) failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// "Some Name <a@b.c>" → ("Some Name", "a@b.c"); bare address handled.
    static func parseFromHeader(_ from: String) -> (name: String?, email: String?) {
        if let bracketRange = from.range(of: "<"), let closeRange = from.range(of: ">") {
            let name = String(from[..<bracketRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let email = String(from[bracketRange.upperBound..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? nil : name, email.isEmpty ? nil : email)
        }
        let bare = from.trimmingCharacters(in: .whitespaces)
        return (nil, bare.isEmpty ? nil : bare)
    }

    /// RFC-2822 date ("Tue, 13 Oct 2026 11:20:00 +0000") → Date.
    static func parseRFC2822Date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss ZZZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// Depth-first walk of the MIME payload for the text/plain part.
    static func textPlainBody(from payload: [String: Any]) -> String? {
        let mimeType = (payload["mimeType"] as? String)?.lowercased() ?? ""
        if mimeType.hasPrefix("text/plain") {
            if let bodyData = (payload["body"] as? [String: Any])?["data"] as? String,
               let decoded = Data(base64URLEncoded: bodyData),
               let text = String(data: decoded, encoding: .utf8) {
                return text
            }
        }
        let parts = payload["parts"] as? [[String: Any]] ?? []
        for part in parts {
            if let text = textPlainBody(from: part) { return text }
        }
        return nil
    }
}
