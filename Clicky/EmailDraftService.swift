//
//  EmailDraftService.swift
//  Clicky
//
//  M6.4 — reply drafting + approval binding, ported from Lazy's
//  app/services/drafts.py: the exact DRAFT_SYSTEM_PROMPT, the Gemini fast
//  model in the local-3B slot (strict $0 — same free key as the brain), a
//  simple fallback reply when the model fails, and the SHA-256-prefix
//  content hash that binds an approval to the exact body (PRD F-13 — an
//  edit after approval invalidates it). The lifecycle (create → approve →
//  send → audit) lives in MailManager; this file is the pure piece.
//

import CryptoKit
import Foundation

enum EmailDraftService {

    /// Lazy's DRAFT_SYSTEM_PROMPT, verbatim.
    static let draftSystemPrompt = """
    You are an email drafting assistant. Given an original email, draft a \
    short, professional reply. Return ONLY the reply body — no greeting \
    like 'Hi', no signature, no subject line, no preamble. Keep it under \
    150 words. Be direct and helpful.
    """

    static let draftTokens = 200

    /// Lazy's `_hash_draft`: exact-content hash bound to the approval.
    static func hashDraft(_ body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Lazy's `extract_reply_address`: "Name <addr@x.com>" → addr; falls
    /// back to the first bare address. (Sync already stores the parsed
    /// address separately — this is the header-shaped fallback.)
    static func extractReplyAddress(from header: String) -> String? {
        if let match = header.range(of: #"<([^>]+)>"#, options: .regularExpression) {
            let inner = header[match]
            let address = String(inner.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if address.contains("@") { return address }
        }
        return header.range(of: #"[\w.+-]+@[\w.-]+"#, options: .regularExpression)
            .map { String(header[$0]) }
    }

    /// Lazy's `make_draft_prompt`, same shape.
    static func makeDraftPrompt(originalSubject: String, originalBody: String, userInstruction: String) -> String {
        var parts = ["Original subject: \(originalSubject)", "Original email:\n\(String(originalBody.prefix(4000)))"]
        if !userInstruction.isEmpty {
            parts.append("User instruction for the reply: \(userInstruction)")
        }
        parts.append("Draft the reply body:")
        return parts.joined(separator: "\n\n")
    }

    /// Generate the reply body. Gemini fast model; on any failure Lazy's
    /// fallback: the user's instruction verbatim, else a simple ack.
    static func generateReplyBody(originalSubject: String, originalBody: String, userInstruction: String) async -> String {
        if let body = await geminiDraft(subject: originalSubject, body: originalBody, instruction: userInstruction) {
            return body
        }
        if !userInstruction.isEmpty {
            return userInstruction
        }
        return "Thanks for your email. I'll get back to you soon."
    }

    // MARK: - Gemini fast model (strict $0 free tier, key already on disk)

    private static func geminiDraft(subject: String, body: String, instruction: String) async -> String? {
        let apiKey = GeminiBrainTransport.loadAPIKey()
        guard !apiKey.isEmpty, let url = URL(string: GeminiBrainTransport.chatCompletionsEndpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": GeminiBrainTransport.modelID(for: "fast"),
            "max_tokens": draftTokens,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": draftSystemPrompt],
                ["role": "user", "content": makeDraftPrompt(originalSubject: subject, originalBody: body, userInstruction: instruction)]
            ]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let content = (choices.first?["message"] as? [String: Any])?["content"] as? String
            else { return nil }

            var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Free models drift: strip wrapping quotes and a stray label
            // line the prompt forbade.
            if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
                text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = text.replacingOccurrences(of: #"(?i)^reply body:\s*"#, with: "", options: .regularExpression)
            guard !text.isEmpty else { return nil }
            if text.count > 1200 {
                text = String(text.prefix(1197)) + "…"
            }
            return text
        } catch {
            return nil
        }
    }
}
