//
//  OllamaBrainTransport.swift
//  Lazy
//
//  M9 — the offline brain rung: streams replies from a LOCAL Ollama server
//  (127.0.0.1:11434) when the network is down (fast path, before the cloud
//  links — they can only burn timeout budget) or when every cloud link has
//  already failed (final rung, before the honest spoken failure line).
//
//  Text-only BY DESIGN: the pulled instruct models (qwen2.5 1.5/3/7B) have
//  no vision, so screenshots never ride along — the appended offline note
//  tells the model it has neither screen nor internet access, so it can't
//  fake either (M7 truthfulness rule carries the rest). Conversation
//  context comes in as the same history pairs the worker link gets, so M8
//  per-conversation memory keeps working offline.
//
//  $0 forever: Ollama is free + local; no new credential (exactly two, as
//  locked). CPU-only inference on this machine — num_predict is capped so
//  a reply can never pin the CPU unboundedly.
//

import Foundation

final class OllamaBrainTransport {
    static let endpoint = "http://127.0.0.1:11434/api/chat"
    static let tagsEndpoint = "http://127.0.0.1:11434/api/tags"

    /// User-overridable model (`defaults write com.yourcompany.leanring-buddy
    /// clickyOllamaModel -string 'qwen2.5:7b-instruct'`); falls back to the
    /// first installed model when the configured one isn't pulled.
    static let modelDefaultsKey = "clickyOllamaModel"
    static let defaultModelID = "qwen2.5:3b-instruct"

    /// CPU-only cap: bounds generation time (~400 tokens ≈ well under a
    /// minute on the 3B model) — replies are short by the persona rule
    /// anyway; this keeps a runaway generation from wedging the machine.
    private static let maximumResponseTokens = 400

    /// Time-to-first-byte allowance: covers the one-time model load from
    /// disk (a few seconds on first use) before tokens start streaming.
    /// Once streaming, tokens arrive every ~100ms so the idle timer never
    /// trips mid-generation.
    private static let requestTimeoutInSeconds: TimeInterval = 120

    enum TransportError: Error, LocalizedError {
        case notReachable
        case httpFailure(statusCode: Int, bodySnippet: String)
        case streamError(message: String)

        var errorDescription: String? {
            switch self {
            case .notReachable:
                return "local Ollama server is not reachable"
            case .httpFailure(let statusCode, let bodySnippet):
                return "Ollama HTTP \(statusCode): \(bodySnippet)"
            case .streamError(let message):
                return "Ollama stream error: \(message)"
            }
        }
    }

    // MARK: - Reachability + model resolution

    /// One GET /api/tags answers both questions: is the server up, and
    /// which model should we use. Localhost call — sub-millisecond when
    /// running, instant connection-refused when not. No caching: the
    /// answers must reflect reality every turn (user may start/stop
    /// Ollama or pull a new model between turns).
    private func resolveModel() async throws -> String {
        guard let tagsURL = URL(string: Self.tagsEndpoint) else {
            throw TransportError.notReachable
        }
        var request = URLRequest(url: tagsURL)
        request.timeoutInterval = 3

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw TransportError.notReachable
        }
        guard let tagsJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = tagsJSON["models"] as? [[String: Any]], !models.isEmpty else {
            // Server up but nothing pulled — nothing can answer.
            throw TransportError.notReachable
        }
        let installedModelNames = models.compactMap { $0["name"] as? String }
        let configuredModel = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
            ?? Self.defaultModelID
        if installedModelNames.contains(configuredModel) {
            return configuredModel
        }
        // Configured model not pulled — first installed beats no answer
        // (logged by the caller's turn line so a surprise swap is visible).
        return installedModelNames[0]
    }

    /// Cheap probe for UI/launch status ("Offline brain · model · ready").
    func isReachable() async -> Bool {
        (try? await resolveModel()) != nil
    }

    // MARK: - Streaming chat turn

    /// Same shape as `GeminiBrainTransport.analyzeScreenshots` so the chain
    /// wiring reads uniformly — `images` is accepted and IGNORED (no
    /// vision): passing [] from the call site keeps the signature honest.
    func analyzeScreenshots(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        userPrompt: String,
        conversationHistoryPairs: [(userPlaceholder: String, assistantResponse: String)],
        onSentenceReady: ((String) -> Void)? = nil,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> OpenCodeChatClient.StreamedReply {
        let modelID = try await resolveModel()

        guard let endpointURL = URL(string: Self.endpoint) else {
            throw TransportError.streamError(message: "invalid Ollama endpoint URL")
        }

        // Offline honesty line rides on the SAME system prompt the persona
        // already lives in — the model is told exactly what it doesn't have
        // (screen, internet) instead of being left to assume both.
        let offlineSystemPrompt = systemPrompt + """

        Offline mode: you are running locally on the user's Mac with NO
        internet access and NO screen input this turn. Never claim you
        searched, checked, or looked at anything online or on screen. If a
        question needs current information, say plainly that you couldn't
        verify it right now. Keep the same short, warm style.
        """

        var messages: [[String: String]] = [
            ["role": "system", "content": offlineSystemPrompt]
        ]
        // M8 memory: the same per-conversation pairs the worker link gets.
        for pair in conversationHistoryPairs {
            messages.append(["role": "user", "content": pair.userPlaceholder])
            messages.append(["role": "assistant", "content": pair.assistantResponse])
        }
        messages.append(["role": "user", "content": userPrompt])

        let requestBody: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "stream": true,
            "keep_alive": "5m",
            "options": [
                "num_predict": Self.maximumResponseTokens
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw TransportError.streamError(message: "could not encode Ollama request body")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutInSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let sentenceStreamer = OpenCodeChatClient.SentenceStreamer(
            onSentenceReady: onSentenceReady,
            onDelta: onDelta
        )

        print("🦙 Ollama: model=\(modelID), history=\(conversationHistoryPairs.count) exchanges")
        BrainLog.line("ollama: model=\(modelID), history=\(conversationHistoryPairs.count) exchanges")

        let turnStartedAt = ProcessInfo.processInfo.systemUptime
        var firstTokenAt: TimeInterval?

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransportError.notReachable
        }
        if httpResponse.statusCode != 200 {
            var bodySnippet = ""
            for try await line in bytes.lines {
                bodySnippet += line
                if bodySnippet.count > 300 { break }
            }
            throw TransportError.httpFailure(
                statusCode: httpResponse.statusCode,
                bodySnippet: String(bodySnippet.prefix(300))
            )
        }

        // NDJSON: one JSON object per line. `message.content` carries the
        // token delta; `done` marks the final frame; an `error` key can
        // appear mid-stream (model unloaded, malformed request).
        var accumulatedReplyText = ""
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let chunkJSON = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if let errorMessage = chunkJSON["error"] as? String, !errorMessage.isEmpty {
                throw TransportError.streamError(message: errorMessage)
            }
            if let message = chunkJSON["message"] as? [String: Any],
               let deltaText = message["content"] as? String,
               !deltaText.isEmpty {
                if firstTokenAt == nil {
                    firstTokenAt = ProcessInfo.processInfo.systemUptime
                    LazyLatency.mark("ollama-first-token")
                }
                accumulatedReplyText += deltaText
                sentenceStreamer.appendDelta(deltaText)
            }
            if (chunkJSON["done"] as? Bool) == true {
                break
            }
        }

        let totalSeconds = ProcessInfo.processInfo.systemUptime - turnStartedAt
        let ttftMilliseconds = firstTokenAt.map {
            Int(($0 - turnStartedAt) * 1000)
        } ?? Int(totalSeconds * 1000)
        print("⏱ Ollama: ttft=\(ttftMilliseconds)ms total=\(String(format: "%.1f", totalSeconds))s — model=\(modelID)")
        BrainLog.line("ollama: ttft=\(ttftMilliseconds)ms total=\(String(format: "%.1f", totalSeconds))s — model=\(modelID)")

        guard !accumulatedReplyText.isEmpty else {
            throw TransportError.streamError(message: "empty reply from \(modelID)")
        }

        return OpenCodeChatClient.StreamedReply(
            fullReplyText: accumulatedReplyText,
            alreadySpokenReplyPrefix: sentenceStreamer.alreadySpokenReplyPrefix
        )
    }
}
