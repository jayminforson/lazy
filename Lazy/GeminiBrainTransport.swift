import Foundation

/// Primary brain transport: Google Gemini's free tier called directly over
/// its OpenAI-compatible chat-completions endpoint (SSE streaming, vision
/// via base64 image parts).
///
/// Chain order (locked): Gemini free direct → local `opencode serve` →
/// Cloudflare worker. This transport is attempt #1; when it is unconfigured
/// (no key) or fails, `CompanionManager.respond` falls through to the local
/// bridge inside `OpenCodeChatClient.analyzeScreenshots`, and if that fails
/// too, to the worker fallback — so every failure layer is silent to the
/// user until the whole chain is exhausted.
///
/// API key (one of exactly two allowed credentials, never logged):
///   1. `~/Library/Application Support/com.yourcompany.leanring-buddy/gemini-api-key`
///   2. UserDefaults `clickyGeminiAPIKey`
///
/// On 429 the transport demotes the smart model to the fast model once and
/// retries before giving up to the next chain link.
@MainActor
final class GeminiBrainTransport {

    // MARK: - Configuration

    /// OpenAI-compatible Gemini endpoint (supports Bearer auth, SSE,
    /// content-part arrays with base64 image URLs). Internal: the A5 agent
    /// tool loop reuses the exact same endpoint.
    static let chatCompletionsEndpoint = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

    /// Semantic picker choices (same "fast"/"smart" keys the panel stores)
    /// mapped to free-tier Gemini model IDs. Neither is a reasoning model —
    /// parity with the old OpenCode mapping (low time-to-first-word).
    private static let modelIDBySemanticChoice: [String: String] = [
        "fast": "gemini-3.5-flash-lite",
        "smart": "gemini-3.6-flash"
    ]

    /// Rate-limit demotion target — always the fast/cheap model.
    private static let fallbackModelID = "gemini-3.5-flash-lite"

    /// Per-request timeout. Multi-monitor screenshots are large and the
    /// smart model can reason for a while before its first delta.
    /// Per-pass idle timeout (M4.5d: was 180 — a wedged free-tier stream
    /// then held the turn for three minutes with zero visible text; 60 s
    /// of TOTAL silence is generous for a live stream and bounds each
    /// stall. The turn watchdog below caps the whole turn regardless).
    private static let requestTimeoutInSeconds: TimeInterval = 60

    /// UserDefaults key holding the persisted text-only conversation history.
    private static let historyUserDefaultsKey = "geminiBrainConversationHistory"

    /// Cap on persisted messages (user + assistant turns, always stored in
    /// pairs). Oldest pairs drop off first so prefill stays bounded forever.
    private static let maximumHistoryMessageCount = 60

    /// Application Support subdirectory + file that holds the API key
    /// (chmod 600 by convention — file permissions are the user's to set).
    private static let keyDirectoryName = "com.yourcompany.leanring-buddy"
    private static let keyFileName = "gemini-api-key"

    /// UserDefaults fallback for the key (documented second location).
    private static let apiKeyUserDefaultsKey = "clickyGeminiAPIKey"

    /// Freshness hook (M4): appended ONLY to this transport's system prompt.
    /// The serve/worker fallback links never see the marker format, so a
    /// failed-over turn can never leak a raw [SEARCH: ...] into speech.
    private static let currentInfoSearchInstruction = """
    current information (web search hook):
    your training data has a cutoff; today's date is stated in your prompt. whenever your answer depends on anything that might have changed since your training data — news, weather, sports scores, prices, versions and releases, rankings, "latest", "today", "this week", who won, what's new — reply with EXACTLY this and nothing else, as your entire reply:
    [SEARCH: <short web search query>]
    the app runs the web search and sends the results back to you; then you answer naturally using them. the marker must be the very first characters of your reply — no apology, no preamble, no sentence before it, and nothing after it. never combine it with other tags like [TASK:] or [GUI:], and never use it for questions about their screen, app control, or knowledge you're sure hasn't changed.
    """

    // MARK: - State

    /// Loaded once at init; empty means "transport not configured" and the
    /// chain starts at the local bridge instead. Never logged anywhere.
    private let apiKey: String

    /// Text-only conversation history (roles + text content; old screenshots
    /// are never re-sent — every turn carries a fresh capture anyway).
    private var conversationHistoryMessages: [ConversationHistoryMessage]

    private struct ConversationHistoryMessage: Codable {
        let role: String
        let content: String
    }

    enum TransportError: LocalizedError {
        case rateLimited
        case httpFailure(statusCode: Int, bodySnippet: String)
        case streamError(message: String)
        case emptyReply
        /// M4.5d turn watchdog: the whole turn (search + up to three passes)
        /// blew its hard wall clock — cancelled, never left hanging.
        case turnTimedOut(seconds: Int)

        var errorDescription: String? {
            switch self {
            case .rateLimited:
                return "Gemini free tier rate-limited (429)"
            case .httpFailure(let statusCode, let bodySnippet):
                return "Gemini HTTP \(statusCode): \(bodySnippet)"
            case .streamError(let message):
                return "Gemini stream error: \(message)"
            case .emptyReply:
                return "Gemini returned an empty reply"
            case .turnTimedOut(let seconds):
                return "Gemini brain turn timed out after \(seconds)s"
            }
        }

        /// True when retrying with a demoted (cheaper) model is worthwhile.
        var shouldDemoteModel: Bool {
            if case .rateLimited = self { return true }
            return false
        }
    }

    init() {
        apiKey = Self.loadAPIKey()
        conversationHistoryMessages = Self.loadPersistedHistory()

        if apiKey.isEmpty {
            print("🧠 Gemini direct: disabled (no API key) — chain starts at local bridge")
        } else {
            print("🧠 Gemini direct: enabled (smart=\(Self.modelIDBySemanticChoice["smart"] ?? ""), fast=\(Self.modelIDBySemanticChoice["fast"] ?? ""))")
        }
    }

    /// True when a key is present — `CompanionManager` skips attempt #1 otherwise.
    var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Public API

    /// Mirrors `OpenCodeChatClient.analyzeScreenshots`: streams the reply
    /// through the same sentence/display callbacks and returns the same
    /// `StreamedReply` shape (already-spoken prefix for the TTS remainder).
    ///
    /// M4.5d — the whole turn (proactive search + up to three model passes)
    /// races a hard wall clock. A wedged SSE stream or a stalled link can
    /// no longer hold the turn open with zero visible text — the 2026-10-20
    /// freeze was exactly that: search silently dead → marker round → up to
    /// 3 × idle timeout of nothing. On expiry the in-flight turn is
    /// cancelled; `respond`'s catch falls through the chain, and if the
    /// whole chain is dead the failure is spoken honestly via the system
    /// voice + chip (no invisible hanging anywhere). User interrupts stay
    /// interrupts: only a FIRED watchdog converts the cancellation into a
    /// timeout error.
    private static let turnDeadlineSeconds: Double = 240

    func analyzeScreenshots(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        semanticModelChoice: String,
        userPrompt: String,
        conversationSeed: String?,
        searchQueryHint: String? = nil,
        onSentenceReady: ((String) -> Void)? = nil,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> OpenCodeChatClient.StreamedReply {
        let turnTask = Task {
            try await runChatTurn(
                images: images,
                systemPrompt: systemPrompt,
                semanticModelChoice: semanticModelChoice,
                userPrompt: userPrompt,
                conversationSeed: conversationSeed,
                searchQueryHint: searchQueryHint,
                onSentenceReady: onSentenceReady,
                onDelta: onDelta
            )
        }
        let watchdog = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: UInt64(Self.turnDeadlineSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return false }
            let seconds = Int(Self.turnDeadlineSeconds)
            print("🛑 Gemini direct: turn deadline (\(seconds)s) — cancelling the brain turn")
            BrainLog.line("brain: TURN DEADLINE \(seconds)s — cancelling")
            LazyAnalytics.trackResponseError(error: "gemini-turn-deadline")
            turnTask.cancel()
            return true
        }
        defer { watchdog.cancel() }
        do {
            return try await turnTask.value
        } catch is CancellationError {
            // An outer cancel (user interrupt) cascades into BOTH children —
            // the watchdog never fired. Only a fired watchdog = real timeout.
            let deadlineFired = await watchdog.value
            if deadlineFired {
                throw TransportError.turnTimedOut(seconds: Int(Self.turnDeadlineSeconds))
            }
            throw CancellationError()
        }
    }

    /// The actual turn (the pre-M4.5d analyzeScreenshots body, renamed —
    /// the public entry above wraps it in the turn watchdog).
    private func runChatTurn(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        semanticModelChoice: String,
        userPrompt: String,
        conversationSeed: String?,
        searchQueryHint: String? = nil,
        onSentenceReady: ((String) -> Void)? = nil,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> OpenCodeChatClient.StreamedReply {
        // Text-only mirror of this user turn, appended to history only after
        // the reply succeeds (a failed attempt must not pollute memory).
        var historyUserTurnText = images.map { $0.label }.joined(separator: "\n")
        if let conversationSeed, !conversationSeed.isEmpty, conversationHistoryMessages.isEmpty {
            historyUserTurnText += "\n" + conversationSeed
        }
        historyUserTurnText += "\n" + userPrompt

        let messages = buildRequestMessages(
            images: images,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            conversationSeed: conversationSeed
        )

        let primaryModelID = Self.modelID(for: semanticModelChoice)
        let sentenceStreamer = OpenCodeChatClient.SentenceStreamer(
            onSentenceReady: onSentenceReady,
            onDelta: onDelta
        )

        print("🧠 Gemini direct: model=\(primaryModelID), \(images.count) image(s), history=\(conversationHistoryMessages.count)")

        let brainStartedAt = ProcessInfo.processInfo.systemUptime
        var passMessages = messages

        // M4.5b — proactive single-pass search: a high-precision cue match
        // searches BEFORE the first model call, so a current-info ask costs one
        // round-trip instead of marker-pass + search + answer-pass (the "a
        // little bit slower" the user felt). The marker hook below stays as the
        // fallback for queries the cues miss — but NEVER on a turn where we
        // already searched, success or failure (M4.5d: a failed search left
        // `searchedAhead` false, so the model still got the [SEARCH:] hook and
        // the marker round re-searched the same dead endpoint — up to three
        // model passes of nothing, which is what froze the drill).
        var searchAttemptedAhead = false
        var searchedAhead = false
        if let hint = searchQueryHint, CompanionManager.warrantsProactiveSearch(hint) {
            searchAttemptedAhead = true
            let searchStartedAt = ProcessInfo.processInfo.systemUptime
            let note = await Self.proactiveSearchNote(for: hint)
            let searchMilliseconds = Int((ProcessInfo.processInfo.systemUptime - searchStartedAt) * 1000)
            LazyLatency.mark("web-search")
            let partText: String
            if let note {
                searchedAhead = true
                print("⏱ WebSearch: \(searchMilliseconds)ms (proactive) — answering in one model pass")
                partText = note
            } else {
                // M4.5d — one search attempt per turn, and an honest one: the
                // model is TOLD the search failed instead of being left to
                // guess (fabricated match times were the drill's worst
                // output) or pointed at a hook it must not use again.
                print("⏱ WebSearch: \(searchMilliseconds)ms — search unavailable, telling the model not to guess")
                BrainLog.line("websearch: proactive search unavailable for \"\(hint.prefix(60))\" — honest note appended")
                partText = Self.searchUnavailableNote
            }
            // Fold the note into the user turn as one more text part — the
            // same shape `userPrompt` uses. content is an ARRAY of parts
            // (screenshots + labels + prompt), so treating it as a String
            // would wipe the screenshots and the question.
            if var lastMessage = passMessages.last, lastMessage["role"] as? String == "user" {
                if var parts = lastMessage["content"] as? [[String: Any]] {
                    parts.append(["type": "text", "text": partText])
                    lastMessage["content"] = parts
                } else {
                    lastMessage["content"] = ((lastMessage["content"] as? String) ?? "") + "\n\n" + partText
                }
                passMessages[passMessages.count - 1] = lastMessage
            }
        }

        // Freshness: the search-hook instruction rides only on THIS link.
        // Suppressed whenever we already searched — success OR failure: one
        // search attempt per turn, no exceptions (M4.5d).
        if !searchAttemptedAhead,
           var systemMessage = passMessages.first, systemMessage["role"] as? String == "system" {
            let baseSystemPrompt = (systemMessage["content"] as? String) ?? ""
            systemMessage["content"] = baseSystemPrompt + "\n\n" + Self.currentInfoSearchInstruction
            passMessages[0] = systemMessage
        }

        // One smart→fast demotion budget shared by every pass (the search
        // rounds below reuse it instead of getting their own).
        var isRunningOnFallbackModel = false

        func runPass(_ passMessages: [[String: Any]]) async throws -> String {
            let passModelID = isRunningOnFallbackModel ? Self.fallbackModelID : primaryModelID
            do {
                return try await streamCompletion(
                    modelID: passModelID,
                    messages: passMessages,
                    sentenceStreamer: sentenceStreamer
                )
            } catch let transportError as TransportError where transportError.shouldDemoteModel && passModelID != Self.fallbackModelID {
                // Rate limit fires before any content delta streams (no
                // partial speech to unwind) — demote and retry once.
                print("⚠️ Gemini direct: \(passModelID) rate-limited — demoting to \(Self.fallbackModelID)")
                LazyAnalytics.trackResponseError(error: "gemini-demote: \(passModelID) 429")
                isRunningOnFallbackModel = true
                return try await streamCompletion(
                    modelID: Self.fallbackModelID,
                    messages: passMessages,
                    sentenceStreamer: sentenceStreamer
                )
            }
        }

        // Freshness fallback: a strict [SEARCH: ...] reply means the model still
        // needs the web — search keylessly (WebSearch), feed the results back,
        // let it answer. Marker rounds never touch the streamer, so TTS and the
        // chat bubble only ever see the final real reply. Max two search rounds
        // keeps latency bounded; the proactive path above usually makes this
        // loop run exactly once.
        var searchRoundsUsed = 0
        var finalReplyText = ""
        var passesRun = 0

        while true {
            passesRun += 1
            let passText = try await runPass(passMessages)
            guard let searchQuery = Self.extractStrictSearchMarker(from: passText)
                ?? Self.extractAnySearchMarker(from: passText) else {
                finalReplyText = passText
                break
            }
            guard searchRoundsUsed < 2 else {
                // Budget spent — never let the raw marker reach speech.
                print("🌐 brain: search-round budget exhausted — honest fallback line")
                BrainLog.line("brain: search-round budget exhausted — honest fallback line")
                finalReplyText = "my search hook didn't come back with anything — try asking me again in a moment."
                break
            }
            searchRoundsUsed += 1
            print("🌐 brain: [SEARCH: \(searchQuery)] → fetching")
            BrainLog.line("brain: marker round \(searchRoundsUsed) — [SEARCH: \(searchQuery)]")
            let outcomeNote = await Self.searchOutcomeNote(for: searchQuery)
            passMessages.append(["role": "assistant", "content": passText])
            passMessages.append(["role": "user", "content": outcomeNote])
        }

        let brainSeconds = ProcessInfo.processInfo.systemUptime - brainStartedAt
        let searchStatus = searchedAhead ? "searched first" : (searchAttemptedAhead ? "search failed (honest note)" : "no proactive search")
        print(String(
            format: "⏱ Gemini brain: %.1fs · %@ · %d model pass(es)",
            brainSeconds,
            searchStatus,
            passesRun
        ))
        BrainLog.line(String(
            format: "brain: turn %.1fs · %@ · %d pass(es)",
            brainSeconds,
            searchStatus,
            passesRun
        ))

        rememberExchange(userTurnText: historyUserTurnText, replyText: finalReplyText)

        return OpenCodeChatClient.StreamedReply(
            fullReplyText: finalReplyText,
            alreadySpokenReplyPrefix: sentenceStreamer.alreadySpokenReplyPrefix
        )
    }

    // MARK: - Freshness search hook

    /// Search marker: the reply (trimmed) STARTS with `[SEARCH: ...]` — the
    /// only shape the hold-back logic lets through untouched. Anything after
    /// the marker's first `]` (e.g. a habitual trailing [POINT:none] tag) is
    /// discarded, never searched for. Lenient parsing would risk speaking a
    /// marker as if it were content.
    static func extractStrictSearchMarker(from replyText: String) -> String? {
        let trimmedReply = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedReply.lowercased().hasPrefix("[search:") else { return nil }
        guard let closeIndex = trimmedReply.firstIndex(of: "]") else { return nil }
        let queryStartIndex = trimmedReply.index(trimmedReply.startIndex, offsetBy: "[search:".count)
        guard queryStartIndex < closeIndex else { return nil }
        let innerQuery = String(trimmedReply[queryStartIndex..<closeIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !innerQuery.isEmpty else { return nil }
        return innerQuery
    }

    /// Fallback for models that put the marker AFTER prose (an apology
    /// sentence, then the marker) — the strict check above would miss it,
    /// the marker text would reach speech, and no search would run. The
    /// preamble has already streamed by this point; the search round still
    /// answers the original question afterwards.
    static func extractAnySearchMarker(from replyText: String) -> String? {
        let markerPattern = #"\[\s*search:\s*([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: markerPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: replyText, range: NSRange(replyText.startIndex..., in: replyText)),
              let queryRange = Range(match.range(at: 1), in: replyText) else {
            return nil
        }
        let innerQuery = String(replyText[queryRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !innerQuery.isEmpty else { return nil }
        return innerQuery
    }

    /// M4.5b results block for a search that ran BEFORE the model call.
    /// Returns nil when the search found nothing — the caller then just lets
    /// the model answer from its own knowledge, never inventing freshness.
    private static func proactiveSearchNote(for query: String) async -> String? {
        guard let results = await WebSearch.search(query), !results.isEmpty else { return nil }
        let resultLines = results
            .map { "- \($0.title) | \($0.url)\n  \($0.snippet)" }
            .joined(separator: "\n")
        return """
        (web search results for \u{201C}\(query)\u{201D}, fetched just now — trust these over your older knowledge:)
        \(resultLines)

        (times in these results are often stated in another timezone — convert them to the user's local zone before answering)
        """
    }

    /// Keyless search round-trip note for the second pass — honest on
    /// failure (the truthful-failure convention: no invented freshness).
    private static func searchOutcomeNote(for query: String) async -> String {
        guard let results = await WebSearch.search(query), !results.isEmpty else {
            return """
            web search is unavailable right now (the query was: \(query)). answer the user's original question from your own knowledge; if the topic is time-sensitive, briefly say you couldn't verify it online.
            """
        }
        let resultLines = results
            .map { "- \($0.title) | \($0.url)\n  \($0.snippet)" }
            .joined(separator: "\n")
        return """
        web search results for \u{201C}\(query)\u{201D}:
        \(resultLines)

        use these current results to answer the user's original question, in your normal voice and style; when they conflict with your older knowledge, trust the results. times in these results are often stated in another timezone — convert them to the user's local zone before answering. this turn's search budget is spent: never emit a search marker again, answer from these results.
        """
    }

    /// M4.5d — what the model is told when a cue-matched search came back
    /// empty. The old behavior (telling it nothing) let it fabricate live
    /// facts — an invented football fixture time was the visible symptom of
    /// the 2026-10-20 freeze. Never mentions the marker (mentioning the hook
    /// invites using it).
    private static let searchUnavailableNote = """
    (web search is UNAVAILABLE right now — the search engines did not answer, so there is nothing current to check. do NOT guess times, scores, prices, versions, or other live facts. answer from the date and time context only when you safely can, and when the question truly needs today's live information, say plainly that you couldn't verify it online.)
    """

    // MARK: - Request building

    private func buildRequestMessages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        userPrompt: String,
        conversationSeed: String?
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]

        // Prior turns are text-only (screenshots are never replayed).
        for historyMessage in conversationHistoryMessages {
            messages.append([
                "role": historyMessage.role,
                "content": historyMessage.content
            ])
        }

        // Mirrors ClaudeAPI/OpenCodeChatClient layout: each screenshot is
        // followed by a text part carrying its label, then (on a fresh
        // history) the conversation seed, then the user's prompt.
        var userContentParts: [[String: Any]] = []
        for image in images {
            userContentParts.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
                ]
            ])
            userContentParts.append([
                "type": "text",
                "text": image.label
            ])
        }
        if let conversationSeed, !conversationSeed.isEmpty, conversationHistoryMessages.isEmpty {
            userContentParts.append([
                "type": "text",
                "text": conversationSeed
            ])
        }
        userContentParts.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": userContentParts])

        return messages
    }

    // MARK: - Streaming

    private func streamCompletion(
        modelID: String,
        messages: [[String: Any]],
        sentenceStreamer: OpenCodeChatClient.SentenceStreamer
    ) async throws -> String {
        guard let endpointURL = URL(string: Self.chatCompletionsEndpoint) else {
            throw TransportError.streamError(message: "invalid Gemini endpoint URL")
        }
        // M4.5b: per-pass visibility — ttft (request → first delta) is what the
        // user actually feels, and a marker round shows up here as two passes.
        let passStartedAt = ProcessInfo.processInfo.systemUptime
        var firstDeltaAt: TimeInterval?

        let requestBody: [String: Any] = [
            "model": modelID,
            "stream": true,
            "messages": messages
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw TransportError.streamError(message: "could not encode Gemini request body")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeoutInSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransportError.streamError(message: "no HTTP response from Gemini")
        }

        if httpResponse.statusCode != 200 {
            var bodySnippet = ""
            for try await line in bytes.lines {
                bodySnippet += line
                if bodySnippet.count > 400 { break }
            }
            if httpResponse.statusCode == 429
                || bodySnippet.contains("RESOURCE_EXHAUSTED")
                || bodySnippet.lowercased().contains("rate limit") {
                throw TransportError.rateLimited
            }
            throw TransportError.httpFailure(
                statusCode: httpResponse.statusCode,
                bodySnippet: String(bodySnippet.prefix(400))
            )
        }

        var accumulatedReplyText = ""
        // Freshness hold-back: deltas buffer while the reply could still
        // turn into a strict [SEARCH: ...] marker — a marker must never
        // reach the streamer (it would be spoken). The moment the text
        // diverges from the marker shape, everything buffered releases and
        // streaming continues live as normal content.
        var heldBackText = ""
        var isStreamingLive = false

        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }

            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8),
                  let eventJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }

            // Mid-stream error payloads (quota surprises, content blocks).
            if let errorInfo = eventJSON["error"] as? [String: Any] {
                let errorMessage = (errorInfo["message"] as? String) ?? ""
                if errorMessage.lowercased().contains("rate")
                    || errorMessage.contains("429")
                    || errorMessage.contains("RESOURCE_EXHAUSTED") {
                    throw TransportError.rateLimited
                }
                throw TransportError.streamError(message: errorMessage.isEmpty ? "unknown stream error" : errorMessage)
            }

            guard let choices = eventJSON["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let deltaText = delta["content"] as? String,
                  !deltaText.isEmpty else {
                continue
            }

            accumulatedReplyText += deltaText
            if firstDeltaAt == nil {
                firstDeltaAt = ProcessInfo.processInfo.systemUptime
            }

            if !isStreamingLive {
                heldBackText += deltaText
                let trimmedHeldText = heldBackText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Whitespace-only so far — a marker reply may open with
                // newlines; keep holding.
                if trimmedHeldText.isEmpty { continue }
                let loweredHeldText = trimmedHeldText.lowercased()
                let couldStillBecomeMarker = "[search: ".hasPrefix(loweredHeldText)
                    || loweredHeldText.hasPrefix("[search:")
                if couldStillBecomeMarker { continue }
                // Diverged — this is real content: release the buffer.
                isStreamingLive = true
                sentenceStreamer.appendDelta(heldBackText)
                heldBackText = ""
                continue
            }

            sentenceStreamer.appendDelta(deltaText)
        }

        guard !accumulatedReplyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TransportError.emptyReply
        }

        // Whole reply held back: a strict marker stays silent (the search
        // round owns it); anything else that merely shared the marker's
        // opening gets released so no content is swallowed.
        if !isStreamingLive,
           Self.extractStrictSearchMarker(from: accumulatedReplyText) == nil {
            sentenceStreamer.appendDelta(heldBackText)
        }
        print(String(
            format: "⏱ Gemini pass: ttft=%dms total=%dms",
            firstDeltaAt.map { Int(($0 - passStartedAt) * 1000) } ?? -1,
            Int((ProcessInfo.processInfo.systemUptime - passStartedAt) * 1000)
        ))
        return accumulatedReplyText
    }

    // MARK: - Conversation history

    private func rememberExchange(userTurnText: String, replyText: String) {
        conversationHistoryMessages.append(ConversationHistoryMessage(role: "user", content: userTurnText))
        conversationHistoryMessages.append(ConversationHistoryMessage(role: "assistant", content: replyText))

        // Drop oldest pairs first — history is always stored in pairs, so
        // trimming by two keeps roles aligned.
        while conversationHistoryMessages.count > Self.maximumHistoryMessageCount {
            conversationHistoryMessages.removeFirst(2)
        }
        persistHistory()
    }

    private func persistHistory() {
        guard let encodedHistory = try? JSONEncoder().encode(conversationHistoryMessages) else { return }
        UserDefaults.standard.set(encodedHistory, forKey: Self.historyUserDefaultsKey)
    }

    private static func loadPersistedHistory() -> [ConversationHistoryMessage] {
        guard let encodedHistory = UserDefaults.standard.data(forKey: historyUserDefaultsKey),
              var decodedHistory = try? JSONDecoder().decode([ConversationHistoryMessage].self, from: encodedHistory) else {
            return []
        }
        // A crash could have left an unpaired tail — drop it so pairs stay aligned.
        if decodedHistory.count % 2 != 0 {
            decodedHistory.removeLast()
        }
        return decodedHistory
    }

    // MARK: - Key loading

    // Internal (not private): the A5 agent tool loop loads the same key
    // from the same two locations — one loader, never logged.
    static func loadAPIKey() -> String {
        let keyFileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(keyDirectoryName)
            .appendingPathComponent(keyFileName)

        if let keyFileURL,
           let rawKeyFromFile = try? String(contentsOf: keyFileURL, encoding: .utf8) {
            let trimmedKeyFromFile = rawKeyFromFile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKeyFromFile.isEmpty {
                return trimmedKeyFromFile
            }
        }

        if let rawKeyFromDefaults = UserDefaults.standard.string(forKey: apiKeyUserDefaultsKey) {
            let trimmedKeyFromDefaults = rawKeyFromDefaults.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKeyFromDefaults.isEmpty {
                return trimmedKeyFromDefaults
            }
        }

        return ""
    }

    static func modelID(for semanticModelChoice: String) -> String {
        modelIDBySemanticChoice[semanticModelChoice] ?? modelIDBySemanticChoice["fast"] ?? fallbackModelID
    }
}
