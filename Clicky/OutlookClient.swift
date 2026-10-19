//
//  OutlookClient.swift
//  Clicky
//
//  M6.1 — Microsoft Graph mail client (profile, recent ids, full fetch,
//  send). Port of Lazy's Phase 4 outlook adapter; uses receivedDateTime
//  filtering for both initial and incremental sync (personal-scale mail
//  volume makes delta queries unnecessary). Connect needs the user's own
//  Azure app registration — the Settings card shows the steps.
//

import Foundation

struct OutlookClient {

    private let graphBase = "https://graph.microsoft.com/v1.0"

    // MARK: - Profile

    /// The signed-in address (mail, else userPrincipalName).
    func fetchProfile(accessToken: String) async -> String? {
        guard let url = URL(string: "\(graphBase)/me?$select=mail,userPrincipalName") else { return nil }
        guard let (data, _) = await authorizedGet(url: url, accessToken: accessToken),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["mail"] as? String) ?? (json["userPrincipalName"] as? String)
    }

    // MARK: - Listing (initial + incremental share the same filter query)

    /// Message ids received since the given date (newest first).
    func recentMessageIDs(accessToken: String, since date: Date, maxResults: Int = 100) async -> [String] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let filterDate = isoFormatter.string(from: date)
        var components = URLComponents(string: "\(graphBase)/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "$select", value: "id"),
            URLQueryItem(name: "$filter", value: "receivedDateTime ge \(filterDate)"),
            URLQueryItem(name: "$orderby", value: "receivedDateTime desc"),
            URLQueryItem(name: "$top", value: String(maxResults))
        ]
        guard let url = components.url,
              let (data, _) = await authorizedGet(url: url, accessToken: accessToken),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let values = json["value"] as? [[String: Any]] ?? []
        return values.compactMap { $0["id"] as? String }
    }

    // MARK: - Full message fetch

    func fetchMessage(accessToken: String, id: String) async -> MailStoreMessage? {
        guard let url = URL(string: "\(graphBase)/me/messages/\(id)?$select=id,conversationId,from,subject,body,receivedDateTime") else { return nil }
        guard let (data, _) = await authorizedGet(url: url, accessToken: accessToken),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let from = json["from"] as? [String: Any]
        let fromAddress = from?["emailAddress"] as? [String: Any]
        let senderName = fromAddress?["name"] as? String
        let senderEmail = fromAddress?["address"] as? String
        let body = (json["body"] as? [String: Any])?["content"] as? String ?? ""

        var receivedAt = Date()
        if let receivedString = json["receivedDateTime"] as? String {
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime]
            if let parsed = isoFormatter.date(from: receivedString) {
                receivedAt = parsed
            }
        }

        return MailStoreMessage(
            provider: .outlook,
            providerID: id,
            threadID: json["conversationId"] as? String,
            senderName: senderName,
            senderEmail: senderEmail,
            subject: (json["subject"] as? String) ?? "(no subject)",
            body: body,
            receivedAt: receivedAt
        )
    }

    // MARK: - Send (M6.4)

    /// Sends via /me/sendMail. `messageJSON` is a Graph message dict built by
    /// the caller: subject, toRecipients, body {contentType, content}.
    func send(accessToken: String, messageJSON: [String: Any]) async -> Bool {
        guard let url = URL(string: "\(graphBase)/me/sendMail") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "message": messageJSON,
            "saveToSentItems": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data.prefix(300), encoding: .utf8) ?? ""
                print("📧 Outlook: send failed \(http.statusCode) — \(bodyText)")
            }
            return (200..<300).contains(http.statusCode)
        } catch {
            print("📧 Outlook: send failed — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private helpers

    private func authorizedGet(url: URL, accessToken: String) async -> (Data, URLResponse)? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let bodyText = String(data: data.prefix(200), encoding: .utf8) ?? ""
                print("📧 Outlook: GET \(url.path) → \(http.statusCode) — \(bodyText)")
                return nil
            }
            return (data, response)
        } catch {
            print("📧 Outlook: GET \(url.path) failed — \(error.localizedDescription)")
            return nil
        }
    }
}
