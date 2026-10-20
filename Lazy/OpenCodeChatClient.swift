import Foundation

/// Talks to the locally running OpenCode headless server (`opencode serve`)
/// as Clicky's primary chat brain.
///
/// Why this exists: OpenCode's free models (space-bunny-free, step-5-preview-free,
/// etc.) return a FreeTierError when called from external HTTP APIs — they may
/// only be used from within OpenCode. OpenCode's own local server API is the
/// sanctioned path: Clicky sends prompts to 127.0.0.1:4096, the server calls the
/// model with the user's local OpenCode credentials.
///
/// The server is normally kept alive by the com.clicky.opencode-serve
/// LaunchAgent; this client also spawns it as a fallback if the health check
/// fails, so chat works even if the LaunchAgent was unloaded.
@MainActor
final class OpenCodeChatClient {

    // MARK: - Configuration

    /// The local OpenCode headless server. Loopback only — never exposed off-machine.
    private static let serverBaseURL = "http://127.0.0.1:4096"

    /// LaunchAgent label keeping the local server alive (KeepAlive + RunAtLoad).
    private static let launchAgentLabel = "com.clicky.opencode-serve"

    /// How long to wait for the local server to come up after spawning it.
    private static let serverStartupTimeoutInSeconds: TimeInterval = 12

    /// Generous per-request timeout: multi-monitor screenshots are large and the
    /// "smart" model can reason for a while before replying.
    private static let requestTimeoutInSeconds: TimeInterval = 240

    /// UserDefaults key holding the OpenCode session ID used for conversation
    /// memory. The server keeps the message history; Clicky just reuses the
    /// same session so follow-up questions have context.
    private static let storedSessionIDKey = "openCodeChatSessionID"

    /// UserDefaults key holding the server-written summary of the most
    /// recently rotated-out session — the richest seed for the next session.
    private static let storedSessionSummaryKey = "clickySessionSummary"

    /// Caps the persisted rotation summary so it stays a compact seed and
    /// never bloats UserDefaults.
    private static let maximumPersistedSessionSummaryCharacterCount = 2_000

    /// Model used for rotation summarization — always the fast free model;
    /// summary quality doesn't need the smart one and should stay quick.
    private static let summarizeModelID = "space-bunny-free"

    /// Semantic model choices stored by the panel picker, mapped to real
    /// OpenCode model IDs. Both are free vision models chosen by
    /// `scripts/model-latency-bench.swift` (measures time-to-first-delta on
    /// the real Clicky request path): "fast" is the lowest-latency model
    /// (warm runs ~1.1–2.0s to the first visible word); "smart" trades a
    /// little speed for a newer multimodal model (~1.6–3.1s). Deliberately
    /// NOT a reasoning model — the previous "smart" (step-5-preview-free)
    /// thought for 5.5s+ (sometimes 20s) before replying.
    private static let bridgeModelIDBySemanticChoice: [String: String] = [
        "fast": "space-bunny-free",
        "smart": "mimo-v2.6-flash-free"
    ]

    /// Rotate to a fresh conversation session once the stored one reaches
    /// this many messages (user + assistant turns). Every request re-prefills
    /// the whole session server-side; the unrotated session had grown to 87
    /// messages / ~443K input tokens, which alone cost tens of seconds per
    /// reply. The new session is seeded with a compact recap (see
    /// `sessionNeedsConversationSeed`) so memory still feels continuous.
    private static let sessionRotationMessageThreshold = 40

    /// Candidate install locations for the opencode binary, checked when the
    /// server needs to be spawned. Ordered by likelihood: the standalone
    /// installer first, then common package managers.
    private static let openCodeBinaryCandidatePaths = [
        NSHomeDirectory() + "/.opencode/bin/opencode",
        "/opt/homebrew/bin/opencode",
        "/usr/local/bin/opencode"
    ]

    // MARK: - Public API

    /// The model's reply, plus the prefix already queued for speech via
    /// `onSentenceReady` (so the caller speaks only the remainder).
    struct StreamedReply {
        /// Full reply text including any [POINT:...] tag — authoritative.
        let fullReplyText: String
        /// Exact prefix of `fullReplyText` already delivered sentence-by-
        /// sentence through `onSentenceReady`. Empty when no early speech
        /// happened (e.g., the /event stream was unavailable).
        let alreadySpokenReplyPrefix: String
    }

    /// Fire-and-forget preflight: brings the server and conversation session
    /// up so the next request doesn't pay for cold checks. Safe to call
    /// repeatedly — overlapping calls share one in-flight warmup.
    func warmUp() {
        guard warmUpTask == nil else { return }
        warmUpTask = Task { [weak self] in
            guard let self else { return }
            try? await self.ensureServerIsRunning()
            _ = try? await self.ensureSessionExists()
            self.warmUpTask = nil
        }
    }

    /// Sends labeled screenshots plus the user's prompt to the local OpenCode
    /// server. While the model generates, complete sentences stream in through
    /// the server's /event SSE and are reported via `onSentenceReady` so TTS
    /// can start speaking before generation finishes; the returned
    /// `StreamedReply` marks exactly how much of the reply was already spoken.
    ///
    /// `onDelta` fires on every raw text delta with the *accumulated* reply
    /// text so far, cut at any trailing `[POINT:...]` tag — safe to display
    /// verbatim in a chat bubble or text overlay.
    ///
    /// Mirrors ClaudeAPI.analyzeImageStreaming's image layout: each screenshot
    /// is followed by a text part carrying its label (screen name + pixel
    /// dimensions), then the user's prompt as the final text part.
    func analyzeScreenshots(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        semanticModelChoice: String,
        userPrompt: String,
        conversationSeed: String? = nil,
        onSentenceReady: ((String) -> Void)? = nil,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> StreamedReply {
        try await ensureServerIsRunning()
        let sessionID = try await ensureSessionExists()
        let imageFileURLs = try writeImagesToTemporaryFiles(images: images)
        defer { removeTemporaryImageFiles(urls: imageFileURLs) }

        var messageParts: [[String: Any]] = []
        for (imageIndex, image) in images.enumerated() {
            messageParts.append([
                "type": "file",
                "mime": "image/jpeg",
                "url": imageFileURLs[imageIndex].absoluteString
            ])
            messageParts.append([
                "type": "text",
                "text": image.label
            ])
        }

        // A just-rotated session has no server-side memory — lead with a
        // compact recap of recent exchanges so follow-up questions still make
        // sense, then the actual prompt.
        if sessionNeedsConversationSeed {
            sessionNeedsConversationSeed = false
            if let conversationSeed, !conversationSeed.isEmpty {
                messageParts.append(["type": "text", "text": conversationSeed])
            }
        }

        messageParts.append([
            "type": "text",
            "text": userPrompt
        ])

        let requestBody: [String: Any] = [
            "model": [
                "providerID": "opencode",
                "modelID": Self.bridgeModelID(for: semanticModelChoice)
            ],
            "system": systemPrompt,
            // Normal chat replies run with the agent's mutating tools
            // disabled — bash/write/edit belong to explicit [AGENT:...]
            // runs only (ToolGate names the policy; the agent path gets
            // the full set + the per-turn approval log). Read-only tools
            // stay available so the model can still inspect files it
            // already knows about.
            "tools": ToolGate.chatDisabledTools,
            "parts": messageParts
        ]

        print("🧠 OpenCode bridge: model=\(Self.bridgeModelID(for: semanticModelChoice)), \(images.count) image(s), session \(sessionID) messages=\(validatedSessionMessageCount)")

        // Subscribe to the event stream BEFORE posting the message so no
        // generated tokens are missed, then cancel on the way out.
        let sentenceStreamer = SentenceStreamer(onSentenceReady: onSentenceReady, onDelta: onDelta)
        let eventListenerTask = Task { [weak self] in
            await self?.listenForReplyDeltas(sessionID: sessionID, sentenceStreamer: sentenceStreamer)
        }
        defer { eventListenerTask.cancel() }

        let responseJSON: [String: Any]
        do {
            responseJSON = try await withOneRetry(delaySeconds: 15) {
                try await self.postJSON(
                    path: "/session/\(sessionID)/message",
                    body: requestBody
                )
            }
            // The exchange added a user message and an assistant message —
            // keep the local count fresh between preflight validations so the
            // rotation log stays accurate.
            validatedSessionMessageCount += 2
        } catch {
            // A failed request often means the preflight caches went stale
            // (server restarted, session deleted) — force revalidation next time.
            invalidatePreflightCaches()
            throw error
        }

        guard let replyParts = responseJSON["parts"] as? [[String: Any]] else {
            throw makeBridgeError(message: "reply contained no parts")
        }

        let replyText = replyParts
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()

        guard !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw makeBridgeError(message: "model returned an empty reply")
        }

        return StreamedReply(
            fullReplyText: replyText,
            alreadySpokenReplyPrefix: sentenceStreamer.alreadySpokenReplyPrefix
        )
    }

    // MARK: - Agent Runs (computer-use: file/shell work)

    /// Result of a multi-step agent run executed with the OpenCode agent's
    /// full tool set.
    struct AgentRunOutcome {
        /// The model's final one-line summary after tools finished (may be
        /// empty when the run was stopped before the model could summarize).
        let finalSummaryText: String
        /// Number of distinct tool calls observed during the run.
        let toolCallCount: Int
        /// True when the run was stopped early (timeout, tool cap, or the
        /// user cancelled).
        let didStopEarly: Bool
        /// Short reason for an early stop: "timed out", "hit the step
        /// limit", "cancelled".
        let earlyStopReason: String?
        /// Non-nil when the run failed outright (server/bridge error).
        let failureDescription: String?
    }

    /// Runs a multi-step file/shell task with the OpenCode agent's full
    /// tool set in a DEDICATED throwaway session — tool-heavy turns never
    /// pollute the chat session's history or its 40-message rotation.
    /// Streams tool-call progress via `onToolProgress` and stops early —
    /// including a server-side abort so bash actually stops — on timeout,
    /// tool cap, or cooperative task cancellation.
    func runAgentTask(
        goal: String,
        systemPrompt: String,
        semanticModelChoice: String,
        maximumToolCallCount: Int,
        maximumDurationInSeconds: TimeInterval,
        onToolProgress: ((String) -> Void)? = nil
    ) async throws -> AgentRunOutcome {
        try await ensureServerIsRunning()

        let createdSession = try await postJSON(path: "/session", body: ["title": "lazy-agent-run"])
        guard let agentSessionID = createdSession["id"] as? String else {
            throw makeBridgeError(message: "server did not return an agent session ID")
        }
        print("🧠 OpenCode bridge: agent run session \(agentSessionID), model=\(Self.bridgeModelID(for: semanticModelChoice)), goal=\(goal.prefix(120))")

        let progressTracker = AgentRunProgressTracker()
        let durationCapTask = Task { [maximumDurationInSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(maximumDurationInSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            progressTracker.noteEarlyStop(reason: "timed out")
            await self.abortSessionTurn(sessionID: agentSessionID)
        }
        // Subscribe to the event stream BEFORE posting the message so no
        // tool-call parts are missed, then cancel on the way out.
        let eventListenerTask = Task { [weak self] in
            await self?.listenForAgentRunEvents(
                sessionID: agentSessionID,
                progressTracker: progressTracker,
                maximumToolCallCount: maximumToolCallCount,
                onToolProgress: onToolProgress
            )
        }
        defer {
            durationCapTask.cancel()
            eventListenerTask.cancel()
        }

        var finalSummaryText = ""
        do {
            let responseJSON = try await withOneRetry(delaySeconds: 15) {
                try await self.postJSON(
                    path: "/session/\(agentSessionID)/message",
                    body: [
                        "model": [
                            "providerID": "opencode",
                            "modelID": Self.bridgeModelID(for: semanticModelChoice)
                        ],
                        "system": systemPrompt,
                        "parts": [[
                            "type": "text",
                            "text": "Task: \(goal). Begin now. When the task is complete, reply with one short sentence summarizing what you did."
                        ]]
                    ]
                )
            }
            let replyParts = responseJSON["parts"] as? [[String: Any]] ?? []
            finalSummaryText = replyParts
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
        } catch {
            // Cancellation means a new interaction interrupted the run —
            // abort server-side so bash stops too, then propagate.
            if Task.isCancelled {
                await abortSessionTurn(sessionID: agentSessionID)
                await deleteAgentRunSession(sessionID: agentSessionID)
                throw CancellationError()
            }
            await deleteAgentRunSession(sessionID: agentSessionID)
            // A timeout/cap abort can surface as an HTTP error from the
            // interrupted POST — report it as an early stop, not a failure.
            if progressTracker.didStopEarly {
                return AgentRunOutcome(
                    finalSummaryText: "",
                    toolCallCount: progressTracker.observedToolCallCount,
                    didStopEarly: true,
                    earlyStopReason: progressTracker.earlyStopReason,
                    failureDescription: nil
                )
            }
            throw error
        }

        await deleteAgentRunSession(sessionID: agentSessionID)

        return AgentRunOutcome(
            finalSummaryText: finalSummaryText.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCallCount: progressTracker.observedToolCallCount,
            didStopEarly: progressTracker.didStopEarly,
            earlyStopReason: progressTracker.earlyStopReason,
            failureDescription: nil
        )
    }

    /// Shared mutable state for one agent run, safe to touch from both the
    /// event listener and the awaiting caller (always on the MainActor —
    /// this class is nested inside the @MainActor client).
    private final class AgentRunProgressTracker {
        private var observedToolCallIdentifiers: Set<String> = []
        private(set) var didStopEarly = false
        private(set) var earlyStopReason: String?

        var observedToolCallCount: Int { observedToolCallIdentifiers.count }

        /// Returns true when this tool call was not seen before — progress
        /// lines are emitted once per call (the server sends a part update
        /// per state change; callID dedupes them).
        func noteToolCall(identifier: String) -> Bool {
            guard !observedToolCallIdentifiers.contains(identifier) else { return false }
            observedToolCallIdentifiers.insert(identifier)
            return true
        }

        func noteEarlyStop(reason: String) {
            didStopEarly = true
            earlyStopReason = reason
        }
    }

    /// Listens to the server's /event SSE bus during an agent run and turns
    /// tool-part updates into one human-readable progress line per tool
    /// call. When the tool cap is hit, marks the run stopped and aborts it
    /// server-side. Fails soft: losing the stream just means no progress
    /// lines — the POST response still carries the final summary.
    private func listenForAgentRunEvents(
        sessionID: String,
        progressTracker: AgentRunProgressTracker,
        maximumToolCallCount: Int,
        onToolProgress: ((String) -> Void)?
    ) async {
        guard let eventURL = URL(string: "\(Self.serverBaseURL)/event") else { return }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: eventURL))
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("🧠 OpenCode bridge: /event unavailable during agent run — no step progress")
                return
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data:") else { continue }

                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let payloadData = payload.data(using: .utf8),
                      let eventJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                      // Tool parts arrive as `message.part.updated` events
                      // (verified live: one event per state change — pending,
                      // running, completed — all sharing one callID).
                      (eventJSON["type"] as? String) == "message.part.updated",
                      let properties = eventJSON["properties"] as? [String: Any],
                      (properties["sessionID"] as? String) == sessionID,
                      let part = properties["part"] as? [String: Any],
                      (part["type"] as? String) == "tool",
                      let toolName = part["tool"] as? String else {
                    continue
                }

                let toolState = part["state"] as? [String: Any]
                let toolStatus = (toolState?["status"] as? String) ?? ""
                // Progress text: bash carries its command in input.command;
                // file tools carry input.filePath; completed parts fill in
                // state.title. Pending events have neither — skip them and
                // report the call once real input is visible.
                let toolInput = toolState?["input"] as? [String: Any]
                let toolDetailText = (toolInput?["command"] as? String)
                    ?? (toolInput?["filePath"] as? String)
                    ?? (toolState?["title"] as? String)
                    ?? ""
                guard toolStatus != "pending" || !toolDetailText.isEmpty else { continue }

                let toolCallIdentifier = (part["callID"] as? String) ?? UUID().uuidString
                guard progressTracker.noteToolCall(identifier: toolCallIdentifier) else { continue }

                let progressLine = toolDetailText.isEmpty
                    ? "→ \(toolName)"
                    : "→ \(toolName): \(toolDetailText)"
                print("🧠 OpenCode bridge: agent step \(progressTracker.observedToolCallCount)/\(maximumToolCallCount) \(progressLine)")
                onToolProgress?(progressLine)

                if progressTracker.observedToolCallCount >= maximumToolCallCount {
                    progressTracker.noteEarlyStop(reason: "hit the step limit")
                    await abortSessionTurn(sessionID: sessionID)
                    return
                }
            }
        } catch {
            if !(error is CancellationError) {
                print("🧠 OpenCode bridge: agent-run event stream ended early (\(error))")
            }
        }
    }

    /// Best-effort server-side abort of a session's in-flight turn — this
    /// is what actually stops bash commands; cancelling the HTTP request
    /// alone would leave the agent running on the server.
    private func abortSessionTurn(sessionID: String) async {
        guard let url = URL(string: "\(Self.serverBaseURL)/session/\(sessionID)/abort") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
        print("🧠 OpenCode bridge: aborted agent-run turn in \(sessionID)")
    }

    /// Best-effort cleanup of the throwaway agent-run session so abandoned
    /// runs don't accumulate server-side. Failures are ignored — the
    /// session is disposable either way.
    private func deleteAgentRunSession(sessionID: String) async {
        guard let url = URL(string: "\(Self.serverBaseURL)/session/\(sessionID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    /// One step of a computer-use (GUI click/type) run: sends the goal, the
    /// action history, and a fresh screenshot to a DEDICATED throwaway
    /// session and returns the raw reply — expected to be exactly one
    /// [GUI_*] action tag (parsing happens in the caller). Stateless by
    /// design: each step carries full context in one message and the
    /// session is deleted afterwards, so prefill never accumulates old
    /// screenshots across a multi-step run.
    func runComputerUseStep(
        goal: String,
        actionHistoryText: String,
        currentStepNumber: Int,
        maximumStepCount: Int,
        screenshotImageData: Data,
        screenshotPixelWidth: Int,
        screenshotPixelHeight: Int,
        indexedElementLegendText: String? = nil,
        semanticModelChoice: String
    ) async throws -> String {
        try await ensureServerIsRunning()

        let createdSession = try await postJSON(path: "/session", body: ["title": "lazy-computer-use"])
        guard let computerUseSessionID = createdSession["id"] as? String else {
            throw makeBridgeError(message: "server did not return a computer-use session ID")
        }

        let screenshotImageFileURL = try writeComputerUseScreenshotToTemporaryFile(imageData: screenshotImageData)

        var stepReplyText = ""
        var stepMessageParts: [[String: Any]] = [
            [
                "type": "file",
                "mime": "image/jpeg",
                "url": screenshotImageFileURL.absoluteString
            ],
            [
                "type": "text",
                "text": "current screen (\(screenshotPixelWidth)x\(screenshotPixelHeight) pixels)"
            ],
            [
                "type": "text",
                "text": "step \(currentStepNumber) of at most \(maximumStepCount). actions so far: \(actionHistoryText). reply with exactly one action tag."
            ]
        ]
        if let indexedElementLegendText {
            stepMessageParts.append(["type": "text", "text": indexedElementLegendText])
        }
        do {
            let responseJSON = try await withOneRetry(delaySeconds: 10) {
                try await self.postJSON(
                    path: "/session/\(computerUseSessionID)/message",
                    body: [
                        "model": [
                            "providerID": "opencode",
                            "modelID": Self.bridgeModelID(for: semanticModelChoice)
                        ],
                        "system": """
                        \(computerUseStepSystemPromptPrefix)
                        goal: \(goal)
                        """,
                        "parts": stepMessageParts
                    ]
                )
            }
            let replyParts = responseJSON["parts"] as? [[String: Any]] ?? []
            stepReplyText = replyParts
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
        } catch {
            try? FileManager.default.removeItem(at: screenshotImageFileURL)
            await deleteAgentRunSession(sessionID: computerUseSessionID)
            throw error
        }

        try? FileManager.default.removeItem(at: screenshotImageFileURL)
        await deleteAgentRunSession(sessionID: computerUseSessionID)
        return stepReplyText
    }

    /// The static per-step action-tag rules for computer-use runs — the
    /// goal and history are appended per request by `runComputerUseStep`.
    /// (Kept here so the per-step request is self-contained; the main
    /// companion prompt only teaches the plan-level [GUI:...] tag.)
    private var computerUseStepSystemPromptPrefix: String {
        """
        you're operating the user's mac for clicky, a menu bar companion. you see one screenshot of their cursor screen, labeled with its pixel dimensions. coordinates are in that image's pixel space: origin top-left, x rightward, y downward.
        reply with EXACTLY ONE action tag and nothing else — no prose, no explanation, no markdown:
        - [GUI_CLICK_EL:n] — press the element whose amber badge shows n (ONLY when numbered badges are drawn on the screen; this presses the control precisely, works on background windows, and needs no coordinates)
        - [GUI_CLICK:x,y] — click at those coordinates
        - [GUI_TYPE:text] — type text wherever the keyboard focus currently is (click a field first if needed)
        - [GUI_KEY:name] — press one key: return, tab, escape, space, delete, arrowup, arrowdown, arrowleft, arrowright, home, end, pageup, pagedown
        - [GUI_HOTKEY:mod,mod,key] — modifier combo; mods are cmd, shift, option, control (example: [GUI_HOTKEY:cmd,space])
        - [GUI_SCROLL:dx,dy] — scroll; positive dy scrolls down, positive dx scrolls right
        - [GUI_DONE:summary] — the goal is complete; write a few-word summary
        use the newest screenshot only. when your target has an amber badge, prefer [GUI_CLICK_EL:n] over coordinates; otherwise prefer GUI_CLICK to focus a field before GUI_TYPE. when the goal is achieved, reply GUI_DONE immediately without extra steps.
        """
    }

    /// Writes the per-step screenshot to the same temp folder the chat
    /// path uses; deleted immediately after the request.
    private func writeComputerUseScreenshotToTemporaryFile(imageData: Data) throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-brain-images", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let imageURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try imageData.write(to: imageURL)
        return imageURL
    }

    // MARK: - Event Stream (early speech)

    /// Listens to the server's /event SSE bus and feeds text deltas for this
    /// session's reply into the sentence streamer. Fails soft: any problem
    /// just means no early speech — the non-streaming reply still carries the
    /// full text.
    private func listenForReplyDeltas(sessionID: String, sentenceStreamer: SentenceStreamer) async {
        guard let eventURL = URL(string: "\(Self.serverBaseURL)/event") else { return }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: eventURL))
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("🧠 OpenCode bridge: /event unavailable (\((response as? HTTPURLResponse)?.statusCode ?? -1)) — no early speech")
                return
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data:") else { continue }

                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let payloadData = payload.data(using: .utf8),
                      let eventJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                      (eventJSON["type"] as? String) == "message.part.delta",
                      let properties = eventJSON["properties"] as? [String: Any],
                      (properties["sessionID"] as? String) == sessionID,
                      (properties["field"] as? String) == "text",
                      let deltaText = properties["delta"] as? String,
                      !deltaText.isEmpty else {
                    continue
                }

                sentenceStreamer.appendDelta(deltaText)
            }
        } catch {
            if !(error is CancellationError) {
                print("🧠 OpenCode bridge: /event stream ended early (\(error)) — continuing without early speech")
            }
        }
    }

    /// Accumulates streamed deltas and emits complete sentences as they
    /// appear. Sentence emission stops entirely once "[" is seen — that's
    /// the [POINT:...] tag, which must never be spoken and is handled by
    /// the caller after the full reply arrives.
    ///
    /// Also reports the accumulated reply text (cut at any trailing POINT
    /// tag) via `onDelta` so a text UI can render the reply live while the
    /// model is still generating.
    /// Internal (not private) so `GeminiBrainTransport` can share the exact
    /// same sentence/display streaming contract for chain attempt #1.
    @MainActor
    final class SentenceStreamer {
        private var unemittedText = ""
        private var emittedSentenceText = ""
        private var accumulatedReplyText = ""
        private let onSentenceReady: ((String) -> Void)?
        private let onDelta: ((String) -> Void)?

        init(onSentenceReady: ((String) -> Void)?, onDelta: ((String) -> Void)?) {
            self.onSentenceReady = onSentenceReady
            self.onDelta = onDelta
        }

        /// Exact prefix of the reply already delivered for speech.
        var alreadySpokenReplyPrefix: String { emittedSentenceText }

        /// Accumulated reply text with any trailing [POINT:...] tag cut off —
        /// safe to display verbatim.
        var displayText: String {
            if let pointTagStartIndex = accumulatedReplyText.firstIndex(of: "[") {
                return String(accumulatedReplyText[..<pointTagStartIndex])
            }
            return accumulatedReplyText
        }

        func appendDelta(_ deltaText: String) {
            accumulatedReplyText += deltaText
            if accumulatedReplyText.contains("[") {
                // POINT tag begun — the display text is now frozen at the
                // pre-tag content. Report that final text once, then stop.
                if !hasReportedFrozenDisplayText {
                    hasReportedFrozenDisplayText = true
                    onDelta?(displayText)
                }
            } else {
                onDelta?(displayText)
            }

            unemittedText += deltaText
            guard !unemittedText.contains("[") else { return }
            while let (sentence, remainder) = Self.extractFirstSentence(from: unemittedText) {
                unemittedText = remainder
                emittedSentenceText += sentence
                onSentenceReady?(sentence)
            }
        }

        private var hasReportedFrozenDisplayText = false

        /// Splits off the first whitespace-terminated sentence in `text`.
        /// Returns nil when no complete sentence is present yet (or the
        /// terminator looks like an ellipsis, e.g. "..." or "wait...").
        private static func extractFirstSentence(from text: String) -> (sentence: String, remainder: String)? {
            let characters = Array(text)
            var scanIndex = 0

            while scanIndex < characters.count {
                let character = characters[scanIndex]
                guard character == "." || character == "!" || character == "?" else {
                    scanIndex += 1
                    continue
                }

                // Consume repeated terminators ("?!", "...").
                var terminatorEnd = scanIndex + 1
                while terminatorEnd < characters.count,
                      characters[terminatorEnd] == "." || characters[terminatorEnd] == "!" || characters[terminatorEnd] == "?" {
                    terminatorEnd += 1
                }
                // Consume closing quotes/brackets after the terminator.
                while terminatorEnd < characters.count,
                      characters[terminatorEnd] == "\"" || characters[terminatorEnd] == "'"
                        || characters[terminatorEnd] == ")" || characters[terminatorEnd] == "]"
                        || characters[terminatorEnd] == "\u{201D}" || characters[terminatorEnd] == "\u{2019}" {
                    terminatorEnd += 1
                }

                // An ellipsis ("...") is a pause, not a sentence end.
                if character == "." && terminatorEnd - scanIndex >= 3 {
                    scanIndex = terminatorEnd
                    continue
                }

                // Terminator at the very end of the buffer: wait for more deltas.
                guard terminatorEnd < characters.count else { return nil }

                if characters[terminatorEnd].isWhitespace {
                    let sentence = String(characters[0..<terminatorEnd])
                    let remainder = String(characters[terminatorEnd...])
                    guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    return (sentence, remainder)
                }

                scanIndex = terminatorEnd + 1
            }

            return nil
        }
    }

    // MARK: - Server Lifecycle

    /// How long a successful health/session preflight is trusted before
    /// revalidating — keeps two serial loopback round trips off the reply
    /// path. A failed request invalidates both caches immediately.
    private static let preflightCacheLifetimeInSeconds: TimeInterval = 30

    private var lastHealthCheckSucceededAt: Date?
    private var lastSessionValidatedAt: Date?
    private var validatedSessionID: String?
    /// Message count of the validated session at last check, logged with each
    /// request so prefill bloat stays visible in the console.
    private var validatedSessionMessageCount: Int = 0
    /// Set when a fresh session is created; the next request injects a
    /// compact conversation recap so the new session isn't amnesiac.
    private var sessionNeedsConversationSeed = false
    private var warmUpTask: Task<Void, Never>?

    private func invalidatePreflightCaches() {
        lastHealthCheckSucceededAt = nil
        lastSessionValidatedAt = nil
    }

    private func isServerHealthy() async -> Bool {
        guard let url = URL(string: "\(Self.serverBaseURL)/global/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            return false
        }
        return httpResponse.statusCode == 200
    }

    /// Ensures the local OpenCode server is answering on port 4096. Normally
    /// the LaunchAgent keeps it alive; when the health check fails this first
    /// restarts that service (a wedged process still holds the port, so a
    /// direct spawn could never succeed while it lives), then falls back to
    /// spawning the binary directly (covers the LaunchAgent being unloaded).
    private func ensureServerIsRunning() async throws {
        if let lastHealthCheckSucceededAt,
           Date().timeIntervalSince(lastHealthCheckSucceededAt) < Self.preflightCacheLifetimeInSeconds {
            return
        }

        if await isServerHealthy() {
            lastHealthCheckSucceededAt = Date()
            return
        }

        print("🧠 OpenCode bridge: server not healthy — restarting the LaunchAgent service")
        if restartLaunchAgentService() {
            if await waitForServerHealth() {
                print("🧠 OpenCode bridge: service restart restored health")
                lastHealthCheckSucceededAt = Date()
                return
            }
            throw makeBridgeError(message: "local OpenCode server restarted but is still not answering — it may be wedged")
        }

        print("🧠 OpenCode bridge: LaunchAgent not loaded — attempting direct spawn")
        try spawnOpenCodeServerProcess()
        if await waitForServerHealth() {
            lastHealthCheckSucceededAt = Date()
            return
        }
        throw makeBridgeError(message: "local OpenCode server did not start within \(Int(Self.serverStartupTimeoutInSeconds))s")
    }

    /// Polls the health endpoint for up to `serverStartupTimeoutInSeconds`.
    private func waitForServerHealth() async -> Bool {
        let startupDeadline = Date().addingTimeInterval(Self.serverStartupTimeoutInSeconds)
        while Date() < startupDeadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isServerHealthy() {
                return true
            }
        }
        return false
    }

    /// Restarts the serve LaunchAgent via `launchctl kickstart -k` — kills a
    /// hung process and starts a fresh one immediately. Returns false when the
    /// job isn't loaded (the caller then falls back to a direct spawn).
    private func restartLaunchAgentService() -> Bool {
        let restartProcess = Process()
        restartProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        restartProcess.arguments = [
            "kickstart", "-k", "gui/\(getuid())/\(Self.launchAgentLabel)"
        ]
        restartProcess.standardOutput = FileHandle.nullDevice
        restartProcess.standardError = FileHandle.nullDevice
        do {
            try restartProcess.run()
        } catch {
            return false
        }
        restartProcess.waitUntilExit()
        return restartProcess.terminationStatus == 0
    }

    private func spawnOpenCodeServerProcess() throws {
        guard let openCodeBinaryPath = Self.openCodeBinaryCandidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw makeBridgeError(message: "opencode binary not found in any known location")
        }

        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: openCodeBinaryPath)
        serverProcess.arguments = ["serve", "--port", "4096"]
        serverProcess.standardOutput = FileHandle.nullDevice
        serverProcess.standardError = FileHandle.nullDevice
        try serverProcess.run()
    }

    // MARK: - Session Management

    /// Returns the stored conversation session ID when it still exists and is
    /// below the rotation threshold; otherwise creates a fresh session and
    /// marks it for seeding with a conversation recap. Conversation memory
    /// therefore survives app restarts (as long as the user does not delete
    /// sessions in OpenCode itself) without ever letting the prefill grow
    /// unbounded.
    private func ensureSessionExists() async throws -> String {
        if let validatedSessionID,
           let lastSessionValidatedAt,
           Date().timeIntervalSince(lastSessionValidatedAt) < Self.preflightCacheLifetimeInSeconds {
            return validatedSessionID
        }

        if let storedSessionID = UserDefaults.standard.string(forKey: Self.storedSessionIDKey),
           let messageCount = await sessionMessageCount(sessionID: storedSessionID),
           messageCount < Self.sessionRotationMessageThreshold {
            validatedSessionID = storedSessionID
            validatedSessionMessageCount = messageCount
            lastSessionValidatedAt = Date()
            return storedSessionID
        }

        // Missing, deleted server-side, or grown past the threshold — start a
        // new session. If the old session is still on the server, ask the
        // server to summarize it first so the next seed carries real
        // continuity (best-effort — failures fall through to the app-side
        // recap seed and never block rotation).
        let rotatingSessionID = validatedSessionID
            ?? UserDefaults.standard.string(forKey: Self.storedSessionIDKey)
        if let rotatingSessionID {
            await bestEffortSummarizeRotatingSession(sessionID: rotatingSessionID)
        }

        let createdSession = try await postJSON(path: "/session", body: ["title": "clicky"])
        guard let newSessionID = createdSession["id"] as? String else {
            throw makeBridgeError(message: "server did not return a session ID")
        }
        UserDefaults.standard.set(newSessionID, forKey: Self.storedSessionIDKey)
        validatedSessionID = newSessionID
        validatedSessionMessageCount = 0
        sessionNeedsConversationSeed = true
        lastSessionValidatedAt = Date()
        print("🧠 OpenCode bridge: created session \(newSessionID) (previous one rotated out)")
        return newSessionID
    }

    /// Number of messages in a session, or nil when the session is gone.
    /// One exchange counts as two messages (user + assistant), so the
    /// rotation threshold covers roughly half as many turns.
    private func sessionMessageCount(sessionID: String) async -> Int? {
        guard let url = URL(string: "\(Self.serverBaseURL)/session/\(sessionID)/message") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url)),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return nil
        }
        return messages.count
    }

    // MARK: - Rotation Summaries

    /// Summary of the most recently rotated-out session — the richest seed
    /// source for a fresh session, including after an app relaunch.
    var persistedSessionSummary: String? {
        UserDefaults.standard.string(forKey: Self.storedSessionSummaryKey)
    }

    private func persistSessionSummary(_ summaryText: String) {
        let cappedSummaryText = String(summaryText.prefix(Self.maximumPersistedSessionSummaryCharacterCount))
        UserDefaults.standard.set(cappedSummaryText, forKey: Self.storedSessionSummaryKey)
    }

    /// Summarizes a session that's about to rotate out and persists the
    /// result. Silent on every failure — rotation itself must never be
    /// blocked by summarization.
    private func bestEffortSummarizeRotatingSession(sessionID: String) async {
        // Session already deleted server-side — nothing to summarize.
        guard await sessionMessageCount(sessionID: sessionID) != nil else { return }

        guard let summaryText = await summarizeSession(sessionID: sessionID) else {
            print("🧠 OpenCode bridge: rotation summarize failed — keeping previous summary (if any)")
            return
        }
        persistSessionSummary(summaryText)
        print("🧠 OpenCode bridge: rotated-out session summarized (\(summaryText.count) chars)")
    }

    /// Asks the server to summarize a session. The server writes the summary
    /// into the session as its newest message (markdown sections starting
    /// with "## "), which is then read back. Returns nil on any failure.
    private func summarizeSession(sessionID: String) async -> String? {
        guard let summarizeURL = URL(string: "\(Self.serverBaseURL)/session/\(sessionID)/summarize") else {
            return nil
        }

        var summarizeRequest = URLRequest(url: summarizeURL)
        summarizeRequest.httpMethod = "POST"
        summarizeRequest.timeoutInterval = 60
        let summarizeRequestBody: [String: Any] = [
            "providerID": "opencode",
            "modelID": Self.summarizeModelID
        ]
        summarizeRequest.httpBody = try? JSONSerialization.data(withJSONObject: summarizeRequestBody)
        summarizeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (_, response) = try? await URLSession.shared.data(for: summarizeRequest),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }

        return await mostRecentSummaryText(sessionID: sessionID)
    }

    /// Reads back the summary message the server just wrote into the session.
    private func mostRecentSummaryText(sessionID: String) async -> String? {
        guard let messagesURL = URL(string: "\(Self.serverBaseURL)/session/\(sessionID)/message") else {
            return nil
        }
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: messagesURL)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let lastMessage = messages.last,
              let messageParts = lastMessage["parts"] as? [[String: Any]] else {
            return nil
        }

        let summaryText = messageParts
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summaryText.isEmpty ? nil : summaryText
    }

    // MARK: - Image Files

    /// OpenCode file parts reference files by URL rather than base64 payloads,
    /// so screenshots are written to a temp directory for the duration of the
    /// request and deleted immediately afterwards (screen contents are never
    /// kept on disk longer than the request itself).
    private func writeImagesToTemporaryFiles(images: [(data: Data, label: String)]) throws -> [URL] {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-brain-images", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        return try images.map { image in
            let imageURL = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
            try image.data.write(to: imageURL)
            return imageURL
        }
    }

    private func removeTemporaryImageFiles(urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Retry

    /// One quiet retry for transient brain failures — rate limits, upstream
    /// 5xx, header timeouts, dropped connections. Permanent errors (auth,
    /// bad requests, empty replies) are not retried, and cancellation
    /// always propagates immediately.
    private func withOneRetry<T>(
        delaySeconds: Double,
        _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            guard Self.isRetryableBridgeError(error) else { throw error }
            print("↻ OpenCode bridge: transient failure — retrying in \(Int(delaySeconds))s: \(error)")
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            if Task.isCancelled { throw CancellationError() }
            return try await operation()
        }
    }

    private static func isRetryableBridgeError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        let text = (error as NSError).localizedDescription.lowercased()
        for marker in ["http 429", "http 500", "http 502", "http 503", "http 504",
                       "free tier", "rate limit", "too many requests",
                       "service unavailable", "upstream", "timed out", "timeout",
                       "internal server error", "connection refused"] {
            if text.contains(marker) { return true }
        }
        return false
    }

    // MARK: - HTTP

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "\(Self.serverBaseURL)\(path)") else {
            throw makeBridgeError(message: "invalid URL for path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.requestTimeoutInSeconds
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if Task.isCancelled { throw CancellationError() }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw makeBridgeError(message: "no HTTP response")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        // OpenCode error payloads look like {"name": "ErrorName", "data": {...}}
        if let errorName = json["name"] as? String, json["parts"] == nil {
            let errorData = json["data"]
            let serverMessage = (errorData as? [String: Any])?["message"] as? String
                ?? String(describing: errorData ?? errorName)
            throw makeBridgeError(message: "\(errorName): \(serverMessage)")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodySnippet = String(data: data, encoding: .utf8) ?? ""
            throw makeBridgeError(message: "HTTP \(httpResponse.statusCode): \(bodySnippet.prefix(200))")
        }

        return json
    }

    // MARK: - Helpers

    private static func bridgeModelID(for semanticModelChoice: String) -> String {
        bridgeModelIDBySemanticChoice[semanticModelChoice] ?? bridgeModelIDBySemanticChoice["fast"]!
    }

    private func makeBridgeError(message: String) -> NSError {
        NSError(
            domain: "OpenCodeChatClient",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
