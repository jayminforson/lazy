//
//  GeminiAgentToolLoop.swift
//  Clicky
//
//  M4 A5 / M5.2 — [AGENT:] AND [GUI:] runs executed DIRECTLY against
//  Gemini's free tier (OpenAI-compatible function calling) with local tool
//  execution: bash/read/write/edit run on this machine, plus the unified
//  UI tools (osascript, screenshot with AX badges, ui click/type/key/hotkey/
//  scroll, wait) dispatched to the CompanionManager handler on the main
//  actor. Caps come from the caller (M5: 30 tool calls / 300 s) and there
//  are no hard executor blocks — full unblock is a locked M5 decision
//  (sudo simply fails because nothing can prompt for a password).
//
//  Chain (locked): Gemini direct (key present) → for UI-style goals the
//  legacy per-step computer-use loop, otherwise opencode serve
//  `runAgentTask` → Cloudflare worker (no tools). `run()` returning nil
//  means "skip / fall through": no key, or the direct path failed BEFORE
//  any tool executed. Once a valid assistant message arrives the direct
//  path owns the run — later failures become an outcome, never a silent
//  re-run (side effects must not double-execute).
//

import Foundation

enum GeminiAgentToolLoop {

    /// Tool result a UI handler returns: the text result plus, for the
    /// screenshot tool, the grounded JPEG the loop attaches as a follow-up
    /// vision message (mirrors the chat path's image_url shape).
    typealias UIHandlerResult = (text: String, imageData: Data?)

    /// Tools whose execution needs CompanionManager instance state (screen
    /// capture, AX index, input posting) — routed to the injected main-actor
    /// handler instead of the detached sync executor.
    private static let uiHandlerToolNames: Set<String> = ["osascript", "screenshot", "ui", "wait"]

    // MARK: - Errors

    private enum ToolLoopError: LocalizedError {
        case rateLimited
        case httpFailure(statusCode: Int, bodySnippet: String)
        case invalidResponse
        case noMessage

        var errorDescription: String? {
            switch self {
            case .rateLimited:
                return "Gemini free tier rate-limited (429)"
            case .httpFailure(let statusCode, let bodySnippet):
                return "Gemini HTTP \(statusCode): \(bodySnippet)"
            case .invalidResponse:
                return "Gemini returned a non-JSON response"
            case .noMessage:
                return "Gemini returned no assistant message"
            }
        }
    }

    // MARK: - Tool definitions (OpenAI function-calling schema)

    private static let toolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "bash",
                "description": "Run a shell command in the user's home directory; returns combined stdout+stderr and the exit code (30s cap). sudo cannot prompt for a password here, so it just fails — use user-level commands.",
                "parameters": [
                    "type": "object",
                    "properties": ["command": ["type": "string"]],
                    "required": ["command"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "read",
                "description": "Read a UTF-8 text file and return its contents (large files are truncated).",
                "parameters": [
                    "type": "object",
                    "properties": ["path": ["type": "string"]],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "write",
                "description": "Create or overwrite a UTF-8 text file; parent folders are created as needed.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"]
                    ],
                    "required": ["path", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "edit",
                "description": "Replace old_string with new_string in a file. old_string must occur exactly once — read the file first if unsure.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "old_string": ["type": "string"],
                        "new_string": ["type": "string"]
                    ],
                    "required": ["path", "old_string", "new_string"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "osascript",
                "description": "Run one AppleScript via osascript and return its stdout (30s cap). Use to control apps — Finder, System Events, Spotify, Music, Safari, …",
                "parameters": [
                    "type": "object",
                    "properties": ["script": ["type": "string"]],
                    "required": ["script"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "screenshot",
                "description": "Capture the current screen (the screen under the cursor) with amber numbered badges burned onto clickable elements. Returns the pixel dimensions plus a legend mapping each badge index to a label and pixel coordinates. Call this before any ui action; badge indices refresh with every screenshot.",
                "parameters": [
                    "type": "object",
                    "properties": [:]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "ui",
                "description": "Perform one UI action in the frontmost app with synthetic input. Coordinates are screenshot pixels from your latest screenshot (origin top-left). Prefer click_element with a badge index when a legend entry matches — it works even on background windows.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["click", "click_element", "type", "key", "hotkey", "scroll"]
                        ],
                        "x": ["type": "integer", "description": "click: pixel x"],
                        "y": ["type": "integer", "description": "click: pixel y"],
                        "element": ["type": "integer", "description": "click_element: badge index from the latest screenshot legend"],
                        "text": ["type": "string", "description": "type: text to type at the focused field"],
                        "key": ["type": "string", "description": "key: single key name (return, tab, escape, space, delete, arrowup, arrowdown, arrowleft, arrowright, home, end, pageup, pagedown)"],
                        "keys": ["type": "array", "items": ["type": "string"], "description": "hotkey: modifier+key names, e.g. [\"cmd\",\"s\"]"],
                        "dx": ["type": "integer", "description": "scroll: horizontal delta"],
                        "dy": ["type": "integer", "description": "scroll: vertical delta, positive scrolls down"]
                    ],
                    "required": ["action"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "wait",
                "description": "Pause so the UI can settle (windows animate, fields take focus) before your next screenshot or action. 0.5–2s is typical; max 10s.",
                "parameters": [
                    "type": "object",
                    "properties": ["seconds": ["type": "number"]],
                    "required": ["seconds"]
                ]
            ]
        ]
    ]

    // MARK: - Runner

    /// Runs one [AGENT:] / [GUI:] goal through the direct Gemini tool loop.
    /// Returns nil = skip/fall-through (no key, or the direct path failed
    /// before any tool ran). UI tools go to `uiToolHandler` on the main
    /// actor; file/shell tools run on the detached sync executor.
    static func run(
        goal: String,
        systemPrompt: String,
        semanticModelChoice: String,
        maximumToolCallCount: Int,
        maximumDurationInSeconds: TimeInterval,
        uiToolHandler: (@MainActor (String, String) async -> UIHandlerResult)? = nil,
        onToolProgress: @escaping (String) -> Void
    ) async throws -> OpenCodeChatClient.AgentRunOutcome? {
        let apiKey = GeminiBrainTransport.loadAPIKey()
        guard !apiKey.isEmpty else { return nil }

        var activeModelID = GeminiBrainTransport.modelID(for: semanticModelChoice)
        let fastModelID = GeminiBrainTransport.modelID(for: "fast")
        var didDemoteModel = false
        var requestMessages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": "Task: \(goal). Begin now. When the task is complete, reply with one short sentence summarizing what you did."]
        ]
        var executedToolCallCount = 0
        var didCommitToDirectPath = false
        let runStartDate = Date()
        print("🧠 Gemini agent direct: tool loop starting (model=\(activeModelID), goal=\(goal.prefix(120)))")

        while true {
            guard !Task.isCancelled else { throw CancellationError() }
            if Date().timeIntervalSince(runStartDate) >= maximumDurationInSeconds {
                return earlyStopOutcome(toolCallCount: executedToolCallCount, reason: "timed out")
            }
            guard executedToolCallCount < maximumToolCallCount else {
                return earlyStopOutcome(toolCallCount: executedToolCallCount, reason: "hit the step limit")
            }

            let responseJSON: [String: Any]
            do {
                responseJSON = try await postChatRequest(
                    requestMessages: requestMessages,
                    modelID: activeModelID,
                    apiKey: apiKey
                )
            } catch let error as ToolLoopError {
                if case .rateLimited = error, !didDemoteModel, activeModelID != fastModelID {
                    activeModelID = fastModelID
                    didDemoteModel = true
                    print("🧠 Gemini agent direct: 429 → demoting to \(fastModelID) once")
                    continue
                }
                if !didCommitToDirectPath {
                    print("🧠 Gemini agent direct: failed before any tool ran (\(error.localizedDescription)) — falling through to serve")
                    return nil
                }
                return failureOutcome(toolCallCount: executedToolCallCount, description: error.localizedDescription)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if !didCommitToDirectPath {
                    print("🧠 Gemini agent direct: failed before any tool ran (\(error.localizedDescription)) — falling through to serve")
                    return nil
                }
                return failureOutcome(toolCallCount: executedToolCallCount, description: error.localizedDescription)
            }

            guard let assistantMessage = (responseJSON["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
                if didCommitToDirectPath {
                    return failureOutcome(toolCallCount: executedToolCallCount, description: ToolLoopError.noMessage.localizedDescription)
                }
                print("🧠 Gemini agent direct: no assistant message — falling through to serve")
                return nil
            }
            didCommitToDirectPath = true

            let toolCalls = assistantMessage["tool_calls"] as? [[String: Any]] ?? []
            let assistantContent = (assistantMessage["content"] as? String) ?? ""

            if toolCalls.isEmpty {
                let summary = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
                print("🧠 Gemini agent direct: run finished with summary (\(executedToolCallCount) tool call(s))")
                return OpenCodeChatClient.AgentRunOutcome(
                    finalSummaryText: summary,
                    toolCallCount: executedToolCallCount,
                    didStopEarly: false,
                    earlyStopReason: nil,
                    failureDescription: nil
                )
            }

            // Echo the assistant turn back (tool_calls intact) so the API
            // accepts the following tool results.
            var echoedAssistantMessage: [String: Any] = ["role": "assistant", "content": assistantContent]
            echoedAssistantMessage["tool_calls"] = toolCalls
            requestMessages.append(echoedAssistantMessage)

            // Screenshot grounding for this turn — attached as ONE user
            // message after all of the turn's tool results (protocol order).
            var pendingScreenshotImageData: Data?

            for toolCall in toolCalls {
                guard !Task.isCancelled else { throw CancellationError() }
                if Date().timeIntervalSince(runStartDate) >= maximumDurationInSeconds {
                    return earlyStopOutcome(toolCallCount: executedToolCallCount, reason: "timed out")
                }

                let callIdentifier = (toolCall["id"] as? String) ?? "call_\(executedToolCallCount + 1)"
                let functionPayload = toolCall["function"] as? [String: Any] ?? [:]
                let toolName = (functionPayload["name"] as? String) ?? ""
                let toolArgumentsJSON = (functionPayload["arguments"] as? String) ?? "{}"

                let progressDetail = toolProgressDetail(toolName: toolName, argumentsJSON: toolArgumentsJSON)
                let progressLine = progressDetail.isEmpty ? "→ \(toolName)" : "→ \(toolName): \(progressDetail)"
                print("🧠 Gemini agent direct: agent step \(executedToolCallCount + 1)/\(maximumToolCallCount) \(progressLine)")
                onToolProgress(progressLine)

                let handlerResult: UIHandlerResult
                if uiHandlerToolNames.contains(toolName), let uiToolHandler {
                    handlerResult = await uiToolHandler(toolName, toolArgumentsJSON)
                } else {
                    let syncResultText = await Task.detached {
                        executeToolSynchronously(name: toolName, argumentsJSON: toolArgumentsJSON)
                    }.value
                    handlerResult = (text: syncResultText, imageData: nil)
                }
                guard !Task.isCancelled else { throw CancellationError() }

                executedToolCallCount += 1
                requestMessages.append([
                    "role": "tool",
                    "tool_call_id": callIdentifier,
                    "content": String(handlerResult.text.prefix(8000))
                ])
                if let screenshotImageData = handlerResult.imageData {
                    pendingScreenshotImageData = screenshotImageData
                }
            }

            if let screenshotImageData = pendingScreenshotImageData {
                requestMessages.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(screenshotImageData.base64EncodedString())"
                            ]
                        ],
                        [
                            "type": "text",
                            "text": "the current screen for your screenshot call — pixel dimensions and the badge legend are in the tool result above"
                        ]
                    ]
                ])
            }
        }
    }

    private static func earlyStopOutcome(toolCallCount: Int, reason: String) -> OpenCodeChatClient.AgentRunOutcome {
        print("🧠 Gemini agent direct: stopped early — \(reason) after \(toolCallCount) tool call(s)")
        return OpenCodeChatClient.AgentRunOutcome(
            finalSummaryText: "",
            toolCallCount: toolCallCount,
            didStopEarly: true,
            earlyStopReason: reason,
            failureDescription: nil
        )
    }

    private static func failureOutcome(toolCallCount: Int, description: String) -> OpenCodeChatClient.AgentRunOutcome {
        print("🧠 Gemini agent direct: run failed — \(description)")
        return OpenCodeChatClient.AgentRunOutcome(
            finalSummaryText: "",
            toolCallCount: toolCallCount,
            didStopEarly: false,
            earlyStopReason: nil,
            failureDescription: description
        )
    }

    /// One non-streaming chat-completions round (mirrors the transport's
    /// endpoint + Bearer auth; no vision — agent runs are text-only).
    private static func postChatRequest(
        requestMessages: [[String: Any]],
        modelID: String,
        apiKey: String
    ) async throws -> [String: Any] {
        guard let endpointURL = URL(string: GeminiBrainTransport.chatCompletionsEndpoint) else {
            throw ToolLoopError.invalidResponse
        }
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": requestMessages,
            "tools": toolDefinitions,
            "tool_choice": "auto"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolLoopError.invalidResponse
        }
        if httpResponse.statusCode == 429 { throw ToolLoopError.rateLimited }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodySnippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw ToolLoopError.httpFailure(statusCode: httpResponse.statusCode, bodySnippet: bodySnippet)
        }
        guard let responseJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolLoopError.invalidResponse
        }
        return responseJSON
    }

    /// Console detail for one pending tool call (mirrors the serve path's
    /// "→ bash: <command>" / "→ read: <path>" shape, extended for the M5
    /// unified tools).
    private static func toolProgressDetail(toolName: String, argumentsJSON: String) -> String {
        guard let arguments = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] else {
            return ""
        }
        if let command = arguments["command"] as? String {
            return String(command.prefix(80))
        }
        if let script = arguments["script"] as? String {
            return String(script.prefix(80))
        }
        if let path = arguments["path"] as? String {
            return path
        }
        if let seconds = arguments["seconds"] {
            return "\(seconds)s"
        }
        if let action = arguments["action"] as? String {
            switch action {
            case "click":
                return "click (\(arguments["x"] ?? "?"), \(arguments["y"] ?? "?"))"
            case "click_element":
                return "element \(arguments["element"] ?? "?")"
            case "type":
                if let typedText = arguments["text"] as? String {
                    return "type \"\(typedText.prefix(40))\""
                }
                return "type"
            case "key":
                return "key \(arguments["key"] ?? "?")"
            case "hotkey":
                if let keyNames = arguments["keys"] as? [String] {
                    return keyNames.joined(separator: "+")
                }
                return "hotkey"
            case "scroll":
                return "scroll (\(arguments["dx"] ?? "?"), \(arguments["dy"] ?? "?"))"
            default:
                return action
            }
        }
        return ""
    }

    // MARK: - Local tool executors

    /// Runs one tool call to completion. Off-main on purpose (blocking
    /// file/process IO) — spawned via `Task.detached` from the runner.
    nonisolated static func executeToolSynchronously(name: String, argumentsJSON: String) -> String {
        guard let arguments = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] else {
            return "error: arguments were not valid JSON"
        }
        switch name {
        case "bash":
            guard let command = arguments["command"] as? String, !command.isEmpty else {
                return "error: missing command"
            }
            return runBashCommand(command)
        case "read":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return "error: missing path"
            }
            return readTextFile(atPath: path)
        case "write":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return "error: missing path"
            }
            guard let content = arguments["content"] as? String else {
                return "error: missing content"
            }
            return writeTextFile(content, atPath: path)
        case "edit":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return "error: missing path"
            }
            guard let oldString = arguments["old_string"] as? String, !oldString.isEmpty else {
                return "error: missing old_string"
            }
            let newString = (arguments["new_string"] as? String) ?? ""
            return editTextFile(path: path, oldString: oldString, newString: newString)
        default:
            return "error: unknown tool '\(name)'"
        }
    }

    /// Bash with no executor-level blocks (M5 full unblock — a locked user
    /// decision): sudo just fails because nothing can prompt for a password.
    /// 30 s wall clock, combined stdout+stderr, home as cwd.
    nonisolated private static func runBashCommand(_ command: String) -> String {
        let workDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lazy-agent-tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        let runIdentifier = UUID().uuidString
        let standardOutputURL = temporaryDirectoryURL.appendingPathComponent("\(runIdentifier).out")
        let standardErrorURL = temporaryDirectoryURL.appendingPathComponent("\(runIdentifier).err")
        FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
        FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workDirectoryURL
        guard let standardOutputHandle = try? FileHandle(forWritingTo: standardOutputURL),
              let standardErrorHandle = try? FileHandle(forWritingTo: standardErrorURL) else {
            return "error: could not open output files"
        }
        process.standardOutput = standardOutputHandle
        process.standardError = standardErrorHandle

        do {
            try process.run()
        } catch {
            return "error: could not launch command — \(error.localizedDescription)"
        }

        let timeoutItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)
        process.waitUntilExit()
        timeoutItem.cancel()

        try? standardOutputHandle.close()
        try? standardErrorHandle.close()

        let standardOutputText = (try? String(contentsOf: standardOutputURL, encoding: .utf8)) ?? ""
        let standardErrorText = (try? String(contentsOf: standardErrorURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: standardOutputURL)
        try? FileManager.default.removeItem(at: standardErrorURL)

        var combinedOutput = standardOutputText
        if !standardErrorText.isEmpty {
            combinedOutput += (combinedOutput.isEmpty ? "" : "\n") + standardErrorText
        }
        let didTimeOut = timeoutItem.isCancelled == false && process.terminationReason == .uncaughtSignal
        let trimmedOutput = String(combinedOutput.prefix(6000))
        if didTimeOut {
            return "timed out after 30s (killed)\n" + trimmedOutput
        }
        if process.terminationStatus != 0 {
            return "exit code \(process.terminationStatus)\n" + trimmedOutput
        }
        return trimmedOutput.isEmpty ? "(no output)" : trimmedOutput
    }

    nonisolated private static func readTextFile(atPath path: String) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return "error: no such file — \(expandedPath)"
        }
        if isDirectory.boolValue {
            return "error: path is a directory — \(expandedPath)"
        }
        guard let fileContents = try? String(contentsOf: URL(fileURLWithPath: expandedPath), encoding: .utf8) else {
            return "error: could not read \(expandedPath) as UTF-8 text"
        }
        if fileContents.utf8.count > 100_000 {
            let prefixBytes = Data(fileContents.utf8.prefix(100_000))
            let truncatedText = String(decoding: prefixBytes, as: UTF8.self)
            return truncatedText + "\n…(truncated at 100KB — file is \(fileContents.utf8.count) bytes)"
        }
        return fileContents
    }

    nonisolated private static func writeTextFile(_ content: String, atPath path: String) -> String {
        guard content.utf8.count <= 1_000_000 else {
            return "error: content over the 1MB write cap"
        }
        let expandedPath = (path as NSString).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expandedPath)
        let parentDirectoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return "error: could not write \(expandedPath) — \(error.localizedDescription)"
        }
        return "wrote \(content.utf8.count) bytes to \(expandedPath)"
    }

    nonisolated private static func editTextFile(path: String, oldString: String, newString: String) -> String {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let fileContents = try? String(contentsOf: URL(fileURLWithPath: expandedPath), encoding: .utf8) else {
            return "error: could not read \(expandedPath) as UTF-8 text"
        }
        let occurrenceCount = fileContents.components(separatedBy: oldString).count - 1
        if occurrenceCount == 0 {
            return "error: old_string not found in \(expandedPath)"
        }
        if occurrenceCount > 1 {
            return "error: old_string occurs \(occurrenceCount) times in \(expandedPath) — provide more surrounding context"
        }
        let editedContents = fileContents.replacingOccurrences(of: oldString, with: newString)
        do {
            try editedContents.write(to: URL(fileURLWithPath: expandedPath), atomically: true, encoding: .utf8)
        } catch {
            return "error: could not write \(expandedPath) — \(error.localizedDescription)"
        }
        return "edited \(expandedPath)"
    }
}
