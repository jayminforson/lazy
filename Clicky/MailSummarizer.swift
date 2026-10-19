//
//  MailSummarizer.swift
//  Clicky
//
//  M6.2 — 1–2 sentence board summaries, ported from Lazy's
//  mailschool.generate_summary: Gemini fast model when a key exists (Lazy's
//  local-LLM slot → Clicky's free-tier fast model), extractive fallback on
//  any failure. Results are cached in message.summary by MailManager — one
//  summary per message, ever.
//

import Foundation

enum MailSummarizer {

    /// Summarize one message. `meeting` is reused so the extracted
    /// date/time/link can be appended even when the model omits them.
    static func summarize(subject: String, body: String, meeting: MailClassifier.MeetingDetails) async -> String {
        if let text = await geminiSummary(subject: subject, body: body, meeting: meeting) {
            return text
        }
        return MailClassifier.extractiveSummary(body: body, meeting: meeting)
    }

    // MARK: - Gemini fast model (strict $0 free tier, key already on disk)

    private static func geminiSummary(subject: String, body: String, meeting: MailClassifier.MeetingDetails) async -> String? {
        let apiKey = GeminiBrainTransport.loadAPIKey()
        guard !apiKey.isEmpty, let url = URL(string: GeminiBrainTransport.chatCompletionsEndpoint) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Lazy's make_summary_prompt, verbatim in spirit.
        let bodyExcerpt = String(body.prefix(2000))
        let userPrompt = """
        Summarize this email in 1-2 short sentences. \
        Focus on what action is needed and any dates or deadlines. \
        If it's a meeting or event invite, include the exact date, time, and meeting link. \
        Be direct — no greetings, no sign-offs.

        Subject: \(subject)

        Body:
        \(bodyExcerpt)

        Summary:
        """
        let payload: [String: Any] = [
            "model": GeminiBrainTransport.modelID(for: "fast"),
            "max_tokens": 60,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": "You are a concise email summarizer. Reply with only the summary."],
                ["role": "user", "content": userPrompt]
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

            var text = content
                .replacingOccurrences(of: "Summary:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 10 else { return nil }
            if text.count > 300 {
                text = String(text.prefix(297)) + "…"
            }
            // Lazy appended the extracted meeting details regardless — cheap
            // insurance that date/time/link always reach the board.
            let extras = MailClassifier.meetingExtras(meeting)
            if !extras.isEmpty {
                text += " | " + extras.joined(separator: " | ")
            }
            return text
        } catch {
            return nil
        }
    }
}
