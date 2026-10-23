//
//  CompanionManager+Runs.swift
//  Clicky
//
//  Agent-run and computer-use (GUI) execution: caps, progress, AX-style step actions, and the system-level input posting helpers.
//  Split from CompanionManager.swift — same type, other file.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import IOKit
import PostHog
import ScreenCaptureKit
import SwiftUI

extension CompanionManager {
    // MARK: - Agent Run Execution (computer-use)

    /// Tool-call cap per agent run (M5 — shared by the unified loop, the
    /// serve fallback, and the legacy GUI fallback): a confused free-tier
    /// model still fails cheap, but 30 is enough to finish real UI walks.
    private static let maximumAgentRunToolCallCount = 30

    /// Wall-clock cap per agent run (M5: 5 minutes); hitting it aborts the
    /// run server-side (bash included) and reports the early stop to the user.
    private static let maximumAgentRunDurationInSeconds: TimeInterval = 300

    /// System prompt for the unified run session (M5.2): file/shell work
    /// AND clicking/typing through the real screen, full access — the only
    /// hard contracts are the screenshot-first UI rule and the one-sentence
    /// spoken-outcome summary. No executor blocks (locked full-unblock
    /// decision); sudo is called out honestly as unable to prompt.
    private static let agentRunSystemPrompt = """
    you're executing a task for clicky, a mac menu bar companion. the user asked for this and you are running it autonomously with real tools. you have full access:
    - bash, read, write, edit — file and shell work of any kind
    - osascript — control apps with AppleScript (Finder, System Events, Spotify, Music, Safari, …)
    - screenshot — capture the cursor screen with amber numbered badges on clickable elements; the result gives pixel dimensions and a legend (badge index → label + coordinates)
    - ui — click (x,y in screenshot pixels), click_element (badge index — prefer it when a badge matches; it works on background windows), type, key, hotkey, scroll
    - wait — pause so the UI can settle
    rules:
    - for clicking or typing through visible apps: screenshot first, then act; badge indices refresh on every screenshot — re-screenshot when an index goes stale
    - coordinates are screenshot pixels from your latest screenshot, origin top-left
    - after a click that opens something, take another screenshot (or wait) before acting again
    - sudo can't prompt for a password here so it just fails — use user-level commands
    - when the task is done (verify with a screenshot when unsure), reply with ONE short sentence summarizing what you did — it gets spoken aloud to the user
    """

    /// Executes a [AGENT:...] run (and, with `prefersComputerUseFallback`,
    /// a [GUI:] run): unified direct Gemini tool loop first — file/shell
    /// tools plus screenshot/ui/osascript/wait — streaming tool-call
    /// progress into the typed chat console (voice stays quiet apart from
    /// periodic still-working beats), then the outcome. Caps: 30 tool calls
    /// / 5 minutes; user cancellation stops the run. UI-style goals fall
    /// back to the legacy per-step computer-use loop when the direct path
    /// can't run (no Gemini key / failed before any tool), since the serve
    /// fallback has no UI tools.
    func executeAgentRun(goal: String, source: ReplySource, prefersComputerUseFallback: Bool = false) async -> OpenCodeChatClient.AgentRunOutcome {
        isAgentRunActive = true
        activeAgentRunProgressLines = []
        activeStepIndexedElements = []
        activeStepScreenshotCapture = nil
        defer { isAgentRunActive = false }

        let agentRunSourceLabel = source == .voice ? "voice" : "typed"
        LazyAnalytics.trackAgentRunStarted(source: agentRunSourceLabel)
        LazyLatency.mark("agent-run-started")
        let agentRunStartDate = Date()
        print("🤖 Agent run started (\(agentRunSourceLabel)): \(goal)")

        // Voice: a quiet "still working on it" beat every ~30s so a long
        // run doesn't feel wedged — typed already sees live step lines.
        var stillWorkingBeatsTask: Task<Void, Never>?
        if source == .voice {
            stillWorkingBeatsTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, let self, self.isAgentRunActive else { return }
                    self.voiceState = .responding
                    if self.replyNeedsSystemVoiceFallback || self.isElevenLabsVoiceDisabledToday {
                        self.speakViaSystemVoice("still working on it.")
                    } else {
                        try? await self.elevenLabsTTSClient.speakText("still working on it.")
                    }
                    guard !Task.isCancelled, self.isAgentRunActive else { return }
                    self.voiceState = .processing
                }
            }
        }
        defer { stillWorkingBeatsTask?.cancel() }

        do {
            // Per-turn tool approval for either path (M5: unified tool set
            // when the direct loop can run, else the serve set) — printed
            // once, caps enforced separately.
            if GeminiBrainTransport.loadAPIKey().isEmpty {
                print(ToolGate.agentTurnApprovalLogLine)
            } else {
                print(ToolGate.unifiedTurnApprovalLogLine)
            }
            // Direct Gemini function-calling loop first (key present); nil =
            // fall-through: legacy computer-use for UI goals, serve
            // `runAgentTask` otherwise. Once the direct path lands its first
            // assistant message it owns the run, so side effects never
            // execute twice.
            let agentRunOutcome: OpenCodeChatClient.AgentRunOutcome
            if let directAgentOutcome = try await GeminiAgentToolLoop.run(
                goal: goal,
                systemPrompt: Self.agentRunSystemPrompt,
                semanticModelChoice: effectiveSemanticModelChoice,
                maximumToolCallCount: Self.maximumAgentRunToolCallCount,
                maximumDurationInSeconds: Self.maximumAgentRunDurationInSeconds,
                uiToolHandler: { [weak self] toolName, argumentsJSON in
                    guard let self else { return (text: "error: companion is gone", imageData: nil) }
                    return await self.executeUnifiedUITool(name: toolName, argumentsJSON: argumentsJSON)
                },
                onToolProgress: { [weak self] progressLine in
                    self?.handleAgentRunProgressLine(progressLine, source: source)
                }
            ) {
                agentRunOutcome = directAgentOutcome
            } else if prefersComputerUseFallback {
                // No key / direct failed before any tool: a UI goal goes to
                // the legacy per-step loop (serve runComputerUseStep does
                // the clicking) — its outcome line is the user-facing result.
                print("🤖 Agent run: falling back to the legacy computer-use loop (direct path unavailable)")
                let legacyOutcomeLine = await executeComputerUseRun(goal: goal, source: source)
                agentRunOutcome = OpenCodeChatClient.AgentRunOutcome(
                    finalSummaryText: legacyOutcomeLine,
                    toolCallCount: activeAgentRunProgressLines.count,
                    didStopEarly: false,
                    earlyStopReason: nil,
                    failureDescription: nil
                )
            } else {
                agentRunOutcome = try await openCodeChatClient.runAgentTask(
                    goal: goal,
                    systemPrompt: Self.agentRunSystemPrompt,
                    semanticModelChoice: effectiveSemanticModelChoice,
                    maximumToolCallCount: Self.maximumAgentRunToolCallCount,
                    maximumDurationInSeconds: Self.maximumAgentRunDurationInSeconds,
                    onToolProgress: { [weak self] progressLine in
                        self?.handleAgentRunProgressLine(progressLine, source: source)
                    }
                )
            }
            let agentRunDurationMilliseconds = Int(Date().timeIntervalSince(agentRunStartDate) * 1000)
            if agentRunOutcome.failureDescription == nil {
                LazyAnalytics.trackAgentRunCompleted(
                    durationMilliseconds: agentRunDurationMilliseconds,
                    toolCallCount: agentRunOutcome.toolCallCount
                )
            } else {
                LazyAnalytics.trackAgentRunAborted(reason: "error")
            }
            LazyLatency.mark("agent-run-finished")
            print("🤖 Agent run finished: \(agentRunOutcome.toolCallCount) tool call(s), \(agentRunDurationMilliseconds)ms, stoppedEarly=\(agentRunOutcome.didStopEarly)")
            return agentRunOutcome
        } catch is CancellationError {
            // A new interaction interrupted the run (PTT re-press, typed
            // message, Stop button) — the client already aborted it
            // server-side so bash stopped too.
            LazyAnalytics.trackAgentRunAborted(reason: "cancelled")
            return OpenCodeChatClient.AgentRunOutcome(
                finalSummaryText: "",
                toolCallCount: activeAgentRunProgressLines.count,
                didStopEarly: true,
                earlyStopReason: "cancelled",
                failureDescription: nil
            )
        } catch {
            LazyAnalytics.trackAgentRunAborted(reason: "error")
            LazyAnalytics.trackResponseError(error: "agent: \(error.localizedDescription)")
            recordLastError("agent run failed — \(String(error.localizedDescription.prefix(160)))")
            return OpenCodeChatClient.AgentRunOutcome(
                finalSummaryText: "",
                toolCallCount: activeAgentRunProgressLines.count,
                didStopEarly: false,
                earlyStopReason: nil,
                failureDescription: error.localizedDescription
            )
        }
    }

    /// One user-facing outcome line from a run outcome (failure / early
    /// stop / summary) — shared by respond's run branch and the M5.3
    /// confirmation path so both word it identically.
    static func agentRunOutcomeLine(_ agentRunOutcome: OpenCodeChatClient.AgentRunOutcome) -> String {
        if let failureDescription = agentRunOutcome.failureDescription {
            return "The agent run failed: \(failureDescription)"
        }
        if agentRunOutcome.didStopEarly {
            let stopReasonText = agentRunOutcome.earlyStopReason ?? "was stopped"
            return "I stopped the agent run — \(stopReasonText) after \(agentRunOutcome.toolCallCount) steps."
        }
        if agentRunOutcome.finalSummaryText.isEmpty {
            return "Done."
        }
        return agentRunOutcome.finalSummaryText
    }

    /// Routes one agent-run tool progress line: appended to the run's line
    /// array (feeds caps, stop detection, and outcome step counts) and logged
    /// to the console — but never shown in the chat bubble or transcript
    /// (locked UX: runs display plan + outcome only).
    private func handleAgentRunProgressLine(_ progressLine: String, source: ReplySource) {
        activeAgentRunProgressLines.append(progressLine)
        print("🤖 Agent run: \(progressLine)")
    }

    /// Cancels the in-flight agent run (Stop button, "stop" voice command,
    /// or a new interaction). Cancelling the response task propagates into
    /// `runAgentTask`, which aborts the run server-side so bash stops too.
    /// Also cancels in-flight computer-use runs (the loop stops at its next
    /// step boundary).
    func cancelActiveAgentRun() {
        guard isAgentRunActive else { return }
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        isAgentRunActive = false
        chatIsResponding = false
        chatStreamingReplyText = ""
        if voiceState == .processing || voiceState == .responding {
            voiceState = .idle
        }
        print("🤖 Agent run cancelled by user")
    }

    // MARK: - M5.2 Unified UI Tools (screenshot / ui / osascript / wait)

    /// Executes one unified-loop UI tool on the main actor: badged screen
    /// capture, synthetic input posting, AppleScript, or a settle wait.
    /// Returns the tool-result text plus, for screenshot, the grounded JPEG
    /// the loop attaches as a vision message.
    func executeUnifiedUITool(name: String, argumentsJSON: String) async -> (text: String, imageData: Data?) {
        guard let arguments = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any] else {
            return (text: "error: arguments were not valid JSON", imageData: nil)
        }
        switch name {
        case "screenshot":
            return await captureUnifiedScreenshotResult()
        case "ui":
            let actionResultText = await executeUnifiedUIAction(arguments)
            return (text: actionResultText, imageData: nil)
        case "osascript":
            guard let script = arguments["script"] as? String, !script.isEmpty else {
                return (text: "error: missing script", imageData: nil)
            }
            guard let scriptOutput = await Self.runCommand(
                "/usr/bin/osascript",
                arguments: ["-e", script]
            ) else {
                return (text: "error: osascript failed (non-zero exit, timeout, or launch failure)", imageData: nil)
            }
            return (text: scriptOutput.isEmpty ? "(no output)" : scriptOutput, imageData: nil)
        case "wait":
            let requestedSeconds = (arguments["seconds"] as? Double) ?? 1.0
            let clampedSeconds = min(max(requestedSeconds, 0.1), 10.0)
            try? await Task.sleep(nanoseconds: UInt64(clampedSeconds * 1_000_000_000))
            return (text: "waited \(String(format: "%.1f", clampedSeconds))s", imageData: nil)
        default:
            return (text: "error: unknown tool '\(name)'", imageData: nil)
        }
    }

    /// The screenshot tool: fresh cursor-screen capture, AX badge index,
    /// badges burned into the JPEG, legend returned as text. Stores the
    /// capture + index that ui actions resolve against.
    private func captureUnifiedScreenshotResult() async -> (text: String, imageData: Data?) {
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                return (text: "error: no screen capture", imageData: nil)
            }
            let indexedElements = AXElementIndexer.indexElements(capture: cursorScreenCapture)
            activeStepIndexedElements = indexedElements
            activeStepScreenshotCapture = cursorScreenCapture
            let groundedImageData = AXElementIndexer.overlayBadges(
                on: cursorScreenCapture.imageData,
                elements: indexedElements,
                capture: cursorScreenCapture
            )
            var resultLines = [
                "screenshot \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels, origin top-left — use these pixel coordinates for ui actions"
            ]
            if indexedElements.isEmpty {
                resultLines.append("no AX badges on this screen — click via coordinates")
            } else {
                resultLines.append(AXElementIndexer.legendText(for: indexedElements))
            }
            print("🖥 Unified screenshot: \(indexedElements.isEmpty ? "0" : "\(indexedElements.count)") badges")
            return (text: resultLines.joined(separator: "\n"), imageData: groundedImageData)
        } catch {
            return (text: "error: screen capture failed — \(error.localizedDescription)", imageData: nil)
        }
    }

    /// The ui tool: one synthetic-input action against the latest
    /// screenshot's coordinate space / badge index, then a short settle so
    /// the next screenshot sees a stable screen (mirrors the legacy 500 ms
    /// step settle at a lighter weight).
    private func executeUnifiedUIAction(_ arguments: [String: Any]) async -> String {
        guard let actionName = arguments["action"] as? String else {
            return "error: missing action"
        }
        let actionResultText: String
        switch actionName {
        case "click":
            guard let xCoordinate = arguments["x"] as? Int, let yCoordinate = arguments["y"] as? Int else {
                return "error: click needs x and y (screenshot pixels from your latest screenshot)"
            }
            guard let latestCapture = activeStepScreenshotCapture else {
                return "error: take a screenshot first — click coordinates convert against it"
            }
            let globalClickLocation = computerUseGlobalLocation(
                screenshotPixelX: CGFloat(xCoordinate),
                screenshotPixelY: CGFloat(yCoordinate),
                screenCapture: latestCapture
            )
            postMouseClick(at: globalClickLocation)
            print("🖥 Unified ui click screenshot (\(xCoordinate), \(yCoordinate)) → global (\(Int(globalClickLocation.x)), \(Int(globalClickLocation.y)))")
            actionResultText = "clicked (\(xCoordinate), \(yCoordinate))"
        case "click_element":
            guard let elementIndex = arguments["element"] as? Int else {
                return "error: click_element needs element (badge index from the latest legend)"
            }
            guard let indexedElement = activeStepIndexedElements.first(where: { $0.index == elementIndex }) else {
                return "error: badge \(elementIndex) is not in the latest screenshot — take a fresh screenshot first"
            }
            let didPress = AXElementIndexer.performPress(indexedElement.element)
            guard didPress else {
                return "error: AXPress on badge \(elementIndex) (\(indexedElement.role) '\(indexedElement.title)') was rejected"
            }
            print("🖥 Unified ui press badge \(elementIndex) (\(indexedElement.role) '\(indexedElement.title)')")
            actionResultText = "pressed badge \(elementIndex) (\(indexedElement.role) '\(indexedElement.title)')"
        case "type":
            guard let typedText = arguments["text"] as? String else {
                return "error: type needs text"
            }
            postComputerUseTypedText(typedText)
            print("🖥 Unified ui typed \(typedText.prefix(80))")
            actionResultText = "typed \"\(typedText.prefix(120))\""
        case "key":
            guard let keyName = arguments["key"] as? String,
                  Self.computerUseKeyCodeByKeyNames[keyName.lowercased()] != nil else {
                return "error: key must be one of: return, tab, escape, space, delete, forwarddelete, arrowup, arrowdown, arrowleft, arrowright, home, end, pageup, pagedown"
            }
            postComputerUseKeyPress(keyName: keyName)
            print("🖥 Unified ui key \(keyName)")
            actionResultText = "pressed key \(keyName)"
        case "hotkey":
            guard let keyNames = (arguments["keys"] as? [String])?.map({ $0.lowercased() }),
                  !keyNames.isEmpty,
                  let mainKeyName = keyNames.last,
                  Self.computerUseKeyCodeByKeyNames[mainKeyName] != nil
                    || Self.computerUseModifierKeyCodes[mainKeyName] != nil else {
                return "error: hotkey needs keys like [\"cmd\",\"s\"] (modifiers: cmd, shift, option, control)"
            }
            postComputerUseHotKey(keyNames: keyNames)
            print("🖥 Unified ui hotkey \(keyNames.joined(separator: "+"))")
            actionResultText = "pressed \(keyNames.joined(separator: "+"))"
        case "scroll":
            guard let deltaX = arguments["dx"] as? Int, let deltaY = arguments["dy"] as? Int else {
                return "error: scroll needs dx and dy (positive dy scrolls down)"
            }
            postComputerUseScroll(deltaX: deltaX, deltaY: deltaY)
            print("🖥 Unified ui scroll (\(deltaX), \(deltaY))")
            actionResultText = "scrolled (\(deltaX), \(deltaY))"
        default:
            return "error: unknown ui action '\(actionName)'"
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        return actionResultText
    }

    // MARK: - Computer-Use Run Execution (GUI click/type agent)

    /// Step cap per computer-use run — free models are weak at UI
    /// navigation, so a confused run fails cheap.
    private static let maximumComputerUseStepCount = 12

    /// Wall-clock cap per computer-use run.
    private static let maximumComputerUseDurationInSeconds: TimeInterval = 120

    /// Pause after each action so the UI can settle (windows animate,
    /// fields take focus) before the next screenshot is captured.
    private static let computerUseStepSettleDurationNanoseconds: UInt64 = 500_000_000

    /// Consecutive per-step replies with no valid action tag before the run
    /// gives up — one leaked prose reply is tolerated, two in a row means
    /// the model can't find its next move.
    private static let maximumConsecutiveInvalidComputerUseSteps = 2

    /// One action the computer-use loop can perform, parsed from the model's
    /// single-tag per-step reply. Coordinates are screenshot pixels
    /// (top-left origin), converted to AppKit globals before posting.
    enum ComputerUseAction {
        case click(x: Int, y: Int)
        case clickElement(index: Int)
        case typeText(text: String)
        case pressKey(keyName: String)
        case hotKey(keyNames: [String])
        case scroll(deltaX: Int, deltaY: Int)
        case done(summary: String)
    }

    /// Executes a [GUI:...] computer-use run: repeatedly captures the cursor
    /// screen, asks the brain for the next single action, executes it via
    /// synthetic CGEvents, and loops until the model replies GUI_DONE, a cap
    /// hits (12 steps / 2 minutes), two consecutive unparseable replies, or
    /// cancellation. Reuses the agent-run state (`isAgentRunActive`,
    /// `activeAgentRunProgressLines`) so the Stop button, "stop" commands,
    /// and panel status cover both run kinds. Returns the outcome line.
    func executeComputerUseRun(goal: String, source: ReplySource) async -> String {
        isAgentRunActive = true
        activeAgentRunProgressLines = []
        defer { isAgentRunActive = false }

        let computerUseSourceLabel = source == .voice ? "voice" : "typed"
        LazyAnalytics.trackComputerUseRunStarted(source: computerUseSourceLabel)
        LazyLatency.mark("computer-use-run-started")
        let computerUseRunStartDate = Date()
        print("🖥 Computer-use run started (\(computerUseSourceLabel)): \(goal)")

        var completedActionHistoryLines: [String] = []
        var consecutiveInvalidStepCount = 0
        var outcomeLine = "I couldn't figure out the next step."

        // Verification: the screen right before the last action, and the
        // history line it produced — compared against the next capture to
        // detect no-effect steps (A3).
        var captureBeforeLastAction: CompanionScreenCapture?
        var pendingVerificationHistoryIndex: Int?

        activeStepIndexedElements = []

        for stepNumber in 1...Self.maximumComputerUseStepCount {
            guard !Task.isCancelled else {
                outcomeLine = "I stopped the computer-use run — cancelled after \(stepNumber - 1) steps."
                LazyAnalytics.trackComputerUseRunAborted(reason: "cancelled")
                break
            }
            if Date().timeIntervalSince(computerUseRunStartDate) > Self.maximumComputerUseDurationInSeconds {
                outcomeLine = "I stopped the computer-use run — it timed out after \(stepNumber - 1) steps."
                LazyAnalytics.trackComputerUseRunAborted(reason: "timeout")
                print("🖥 Computer-use run timed out at step \(stepNumber)")
                break
            }

            // Fresh capture every step — the screen changes after each action.
            let cursorScreenCapture: CompanionScreenCapture
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let capturedCursorScreen = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    outcomeLine = "The computer-use run failed: no screen capture."
                    LazyAnalytics.trackComputerUseRunAborted(reason: "error")
                    break
                }
                cursorScreenCapture = capturedCursorScreen
            } catch {
                outcomeLine = "The computer-use run failed: \(error.localizedDescription)"
                LazyAnalytics.trackComputerUseRunAborted(reason: "error")
                break
            }
            LazyLatency.mark("computer-use-step-capture")

            // A3 — did the previous action visibly change the screen?
            // Raw-vs-raw downscale diff; a no-effect step gets the reason
            // burned into the history line the brain sees next step.
            if let pendingIndex = pendingVerificationHistoryIndex,
               let priorCapture = captureBeforeLastAction,
               pendingIndex < completedActionHistoryLines.count {
                let changedRatio = Self.screenDifferenceRatio(
                    from: priorCapture.imageData,
                    to: cursorScreenCapture.imageData
                )
                if changedRatio < 0.003 {
                    completedActionHistoryLines[pendingIndex]
                        += " — the screen did not visibly change after this step"
                    print("[verify] step \(pendingIndex + 1): UNCHANGED (\(String(format: "%.3f", changedRatio * 100))% pixels)")
                } else {
                    print("[verify] step \(pendingIndex + 1): changed \(String(format: "%.2f", changedRatio * 100))% pixels")
                }
            }
            pendingVerificationHistoryIndex = nil
            captureBeforeLastAction = nil

            // A1/A2 — AX grounding: number the frontmost app's pressable
            // elements that sit on this screen (reading order), burn amber
            // badges into the screenshot, and pass the badge legend along.
            let stepIndexedElements = AXElementIndexer.indexElements(capture: cursorScreenCapture)
            activeStepIndexedElements = stepIndexedElements
            let groundedScreenshotData = AXElementIndexer.overlayBadges(
                on: cursorScreenCapture.imageData,
                elements: stepIndexedElements,
                capture: cursorScreenCapture
            )
            let indexedElementLegendText = stepIndexedElements.isEmpty
                ? nil
                : AXElementIndexer.legendText(for: stepIndexedElements)

            let actionHistoryText = completedActionHistoryLines.isEmpty
                ? "none yet"
                : completedActionHistoryLines.joined(separator: "; ")

            let stepReplyText: String
            do {
                stepReplyText = try await openCodeChatClient.runComputerUseStep(
                    goal: goal,
                    actionHistoryText: actionHistoryText,
                    currentStepNumber: stepNumber,
                    maximumStepCount: Self.maximumComputerUseStepCount,
                    screenshotImageData: groundedScreenshotData,
                    screenshotPixelWidth: cursorScreenCapture.screenshotWidthInPixels,
                    screenshotPixelHeight: cursorScreenCapture.screenshotHeightInPixels,
                    indexedElementLegendText: indexedElementLegendText,
                    semanticModelChoice: effectiveSemanticModelChoice
                )
            } catch is CancellationError {
                outcomeLine = "I stopped the computer-use run — cancelled after \(stepNumber - 1) steps."
                LazyAnalytics.trackComputerUseRunAborted(reason: "cancelled")
                break
            } catch {
                outcomeLine = "The computer-use run failed: \(error.localizedDescription)"
                LazyAnalytics.trackComputerUseRunAborted(reason: "error")
                recordLastError("computer-use step failed — \(String(error.localizedDescription.prefix(160)))")
                print("🖥 Computer-use step \(stepNumber) request failed: \(error)")
                break
            }
            LazyLatency.mark("computer-use-step-brain")

            guard let computerUseAction = Self.parseComputerUseAction(from: stepReplyText) else {
                consecutiveInvalidStepCount += 1
                print("🖥 Computer-use step \(stepNumber) had no valid action tag: \(stepReplyText.prefix(120))")
                handleAgentRunProgressLine("→ step \(stepNumber): no valid action (\(stepReplyText.prefix(60)))", source: source)
                if consecutiveInvalidStepCount >= Self.maximumConsecutiveInvalidComputerUseSteps {
                    outcomeLine = "I couldn't figure out the next step."
                    LazyAnalytics.trackComputerUseRunAborted(reason: "invalid_steps")
                    break
                }
                continue
            }
            consecutiveInvalidStepCount = 0

            if case .done(let doneSummary) = computerUseAction {
                outcomeLine = doneSummary.isEmpty
                    ? "Done."
                    : "Done. \(doneSummary)"
                LazyAnalytics.trackComputerUseRunCompleted(
                    durationMilliseconds: Int(Date().timeIntervalSince(computerUseRunStartDate) * 1000),
                    stepCount: stepNumber - 1
                )
                LazyLatency.mark("computer-use-run-finished")
                print("🖥 Computer-use run finished at step \(stepNumber): \(outcomeLine)")
                break
            }

            let progressLineText = Self.describeComputerUseAction(computerUseAction, stepNumber: stepNumber)
            completedActionHistoryLines.append(progressLineText)
            handleAgentRunProgressLine("→ \(progressLineText)", source: source)

            performComputerUseAction(computerUseAction, on: cursorScreenCapture)
            LazyLatency.mark("computer-use-step-executed")

            // Arm A3 verification: compare this pre-action capture against
            // the next step's capture.
            captureBeforeLastAction = cursorScreenCapture
            pendingVerificationHistoryIndex = completedActionHistoryLines.count - 1

            // Last step reached without a GUI_DONE — report the cap.
            if stepNumber == Self.maximumComputerUseStepCount {
                outcomeLine = "I stopped the computer-use run — hit the step limit after \(Self.maximumComputerUseStepCount) steps."
                LazyAnalytics.trackComputerUseRunAborted(reason: "step_limit")
                print("🖥 Computer-use run hit the step limit")
                break
            }

            // Let the UI settle (focus changes, animations) before the next
            // screenshot so the model sees a stable screen.
            try? await Task.sleep(nanoseconds: Self.computerUseStepSettleDurationNanoseconds)
        }

        return outcomeLine
    }

    /// Parses the model's single-tag per-step reply into one action. Returns
    /// nil when no valid tag is present (prose-only replies, format drift).
    static func parseComputerUseAction(from stepReplyText: String) -> ComputerUseAction? {
        if let elementMatch = firstRegexMatch(pattern: #"\[GUI_CLICK_EL:\s*(\d+)\s*\]"#, in: stepReplyText, captureGroupCount: 1),
           let elementIndexText = rangeOfCaptureGroup(1, in: elementMatch, of: stepReplyText),
           let elementIndex = Int(stepReplyText[elementIndexText]), elementIndex >= 1 {
            return .clickElement(index: elementIndex)
        }
        if let clickMatch = firstRegexMatch(pattern: #"\[GUI_CLICK:\s*(\d+)\s*,\s*(\d+)\s*\]"#, in: stepReplyText, captureGroupCount: 2),
           let xText = rangeOfCaptureGroup(1, in: clickMatch, of: stepReplyText),
           let yText = rangeOfCaptureGroup(2, in: clickMatch, of: stepReplyText),
           let xCoordinate = Int(stepReplyText[xText]), let yCoordinate = Int(stepReplyText[yText]) {
            return .click(x: xCoordinate, y: yCoordinate)
        }
        if let typeMatch = firstRegexMatch(pattern: #"\[GUI_TYPE:([^\]]+)\]"#, in: stepReplyText, captureGroupCount: 1),
           let typeTextRange = rangeOfCaptureGroup(1, in: typeMatch, of: stepReplyText) {
            let typedText = String(stepReplyText[typeTextRange])
            return .typeText(text: typedText)
        }
        if let keyMatch = firstRegexMatch(pattern: #"\[GUI_KEY:\s*([a-z]+)\s*\]"#, in: stepReplyText, captureGroupCount: 1),
           let keyNameRange = rangeOfCaptureGroup(1, in: keyMatch, of: stepReplyText) {
            return .pressKey(keyName: String(stepReplyText[keyNameRange]))
        }
        if let hotKeyMatch = firstRegexMatch(pattern: #"\[GUI_HOTKEY:\s*([^\]]+)\]"#, in: stepReplyText, captureGroupCount: 1),
           let hotKeyNamesRange = rangeOfCaptureGroup(1, in: hotKeyMatch, of: stepReplyText) {
            let hotKeyNames = String(stepReplyText[hotKeyNamesRange])
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            guard !hotKeyNames.isEmpty else { return nil }
            return .hotKey(keyNames: hotKeyNames)
        }
        if let scrollMatch = firstRegexMatch(pattern: #"\[GUI_SCROLL:\s*(-?\d+)\s*,\s*(-?\d+)\s*\]"#, in: stepReplyText, captureGroupCount: 2),
           let deltaXText = rangeOfCaptureGroup(1, in: scrollMatch, of: stepReplyText),
           let deltaYText = rangeOfCaptureGroup(2, in: scrollMatch, of: stepReplyText),
           let deltaX = Int(stepReplyText[deltaXText]), let deltaY = Int(stepReplyText[deltaYText]) {
            return .scroll(deltaX: deltaX, deltaY: deltaY)
        }
        if let doneMatch = firstRegexMatch(pattern: #"\[GUI_DONE:([^\]]*)\]"#, in: stepReplyText, captureGroupCount: 1),
           let doneSummaryRange = rangeOfCaptureGroup(1, in: doneMatch, of: stepReplyText) {
            return .done(summary: String(stepReplyText[doneSummaryRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func firstRegexMatch(pattern: String, in text: String, captureGroupCount: Int) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func rangeOfCaptureGroup(_ groupIndex: Int, in match: NSTextCheckingResult, of text: String) -> Range<String.Index>? {
        guard let range = Range(match.range(at: groupIndex), in: text) else { return nil }
        return range
    }

    /// One console/history line per action, e.g. "step 3: click (412, 388)".
    private static func describeComputerUseAction(_ computerUseAction: ComputerUseAction, stepNumber: Int) -> String {
        switch computerUseAction {
        case .click(let x, let y):
            return "step \(stepNumber): click (\(x), \(y))"
        case .clickElement(let elementIndex):
            return "step \(stepNumber): press element \(elementIndex)"
        case .typeText(let text):
            return "step \(stepNumber): type \"\(text)\""
        case .pressKey(let keyName):
            return "step \(stepNumber): key \(keyName)"
        case .hotKey(let keyNames):
            return "step \(stepNumber): hotkey \(keyNames.joined(separator: "+"))"
        case .scroll(let deltaX, let deltaY):
            return "step \(stepNumber): scroll (\(deltaX), \(deltaY))"
        case .done:
            return "step \(stepNumber): done"
        }
    }

    /// Posts the synthetic events for one parsed action. Click coordinates
    /// use the same screenshot-pixel → AppKit-global conversion as POINT
    /// pointing; typing reuses the dictation keystroke machinery.
    private func performComputerUseAction(_ computerUseAction: ComputerUseAction, on screenCapture: CompanionScreenCapture) {
        switch computerUseAction {
        case .click(let x, let y):
            let globalClickLocation = computerUseGlobalLocation(
                screenshotPixelX: CGFloat(x),
                screenshotPixelY: CGFloat(y),
                screenCapture: screenCapture
            )
            postMouseClick(at: globalClickLocation)
            print("🖥 Computer-use click at screenshot (\(x), \(y)) → global (\(Int(globalClickLocation.x)), \(Int(globalClickLocation.y)))")
        case .clickElement(let elementIndex):
            guard let indexedElement = activeStepIndexedElements.first(where: { $0.index == elementIndex }) else {
                print("🖥 Computer-use element \(elementIndex) not in this step's index (badges may be stale)")
                return
            }
            let didPress = AXElementIndexer.performPress(indexedElement.element)
            print("🖥 Computer-use AXPress element \(elementIndex) (\(indexedElement.role) '\(indexedElement.title)') → \(didPress ? "ok" : "rejected")")
        case .typeText(let text):
            postComputerUseTypedText(text)
            print("🖥 Computer-use typed \(text.prefix(80))")
        case .pressKey(let keyName):
            postComputerUseKeyPress(keyName: keyName)
            print("🖥 Computer-use key \(keyName)")
        case .hotKey(let keyNames):
            postComputerUseHotKey(keyNames: keyNames)
            print("🖥 Computer-use hotkey \(keyNames.joined(separator: "+"))")
        case .scroll(let deltaX, let deltaY):
            // Prompt contract: positive dy scrolls down; CGEvent's wheel1 is
            // inverted (positive = content moves down / finger up), so flip.
            postComputerUseScroll(deltaX: deltaX, deltaY: deltaY)
            print("🖥 Computer-use scroll (\(deltaX), \(deltaY))")
        case .done:
            break
        }
    }

    // MARK: - A3 step verification (screen diff)

    /// Ratio (0…1) of pixels that changed between two raw step captures.
    /// Both are downscaled to a 320-px-wide luma strip first — big enough to
    /// catch dialogs/typing/nav, cheap enough per step.
    static func screenDifferenceRatio(from oldImageData: Data, to newImageData: Data) -> Double {
        guard let oldLuma = Self.lumaPixels(from: oldImageData, targetWidth: 320),
              let newLuma = Self.lumaPixels(from: newImageData, targetWidth: 320),
              !oldLuma.isEmpty, oldLuma.count == newLuma.count else {
            return 1.0
        }
        let changedCount = zip(oldLuma, newLuma).filter { old, new in
            abs(Int(old) - Int(new)) > 12
        }.count
        return Double(changedCount) / Double(oldLuma.count)
    }

    private static func lumaPixels(from imageData: Data, targetWidth: Int) -> [UInt8]? {
        guard let image = NSImage(data: imageData),
              image.size.width > 1, image.size.height > 1 else { return nil }
        let targetHeight = max(1, Int((image.size.height / image.size.width) * CGFloat(targetWidth)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: targetWidth * 3,
            bitsPerPixel: 24
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        NSGraphicsContext.restoreGraphicsState()

        guard let rawBytes = bitmap.bitmapData else { return nil }
        let byteCount = targetWidth * targetHeight * 3
        var luma = [UInt8]()
        luma.reserveCapacity(targetWidth * targetHeight)
        for offset in stride(from: 0, to: byteCount, by: 3) {
            let red = Int(rawBytes[offset])
            let green = Int(rawBytes[offset + 1])
            let blue = Int(rawBytes[offset + 2])
            luma.append(UInt8((red * 30 + green * 59 + blue * 11) / 100))
        }
        return luma
    }

    /// Screenshot pixel coords → AppKit global coords — the same scale/flip
    /// math element pointing uses (POINT tags).
    private func computerUseGlobalLocation(
        screenshotPixelX: CGFloat,
        screenshotPixelY: CGFloat,
        screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame

        let clampedX = max(0, min(screenshotPixelX, screenshotWidth))
        let clampedY = max(0, min(screenshotPixelY, screenshotHeight))

        // Screenshot pixels → display points → bottom-left-origin globals.
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    /// Moves the cursor to the location, then posts a left click
    /// (move → down → up) so the click lands where the model pointed.
    private func postMouseClick(at globalClickLocation: CGPoint) {
        let mouseEventSource = CGEventSource(stateID: .hidSystemState)
        let mouseMoveEvent = CGEvent(
            mouseEventSource: mouseEventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: globalClickLocation,
            mouseButton: .left
        )
        mouseMoveEvent?.post(tap: .cghidEventTap)
        let mouseDownEvent = CGEvent(
            mouseEventSource: mouseEventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: globalClickLocation,
            mouseButton: .left
        )
        mouseDownEvent?.post(tap: .cghidEventTap)
        let mouseUpEvent = CGEvent(
            mouseEventSource: mouseEventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: globalClickLocation,
            mouseButton: .left
        )
        mouseUpEvent?.post(tap: .cghidEventTap)
    }

    /// Types text at the current keyboard focus via the same unicode-string
    /// keystroke path dictation uses (Return/Tab by keycode, emoji-safe).
    private func postComputerUseTypedText(_ typedText: String) {
        let keyboardEventSource = CGEventSource(stateID: .hidSystemState)
        for typedCharacter in typedText {
            Self.postTypedCharacter(typedCharacter, keyboardEventSource: keyboardEventSource)
            Thread.sleep(forTimeInterval: 0.012)
        }
    }

    /// Key names the per-step prompt teaches → macOS virtual key codes.
    private static let computerUseKeyCodeByKeyNames: [String: CGKeyCode] = [
        "return": 36, "tab": 48, "escape": 53, "space": 49,
        "delete": 51, "forwarddelete": 117,
        "arrowup": 126, "arrowdown": 125, "arrowleft": 123, "arrowright": 124,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121
    ]

    /// Modifier names → macOS virtual key codes for hotkey combos.
    private static let computerUseModifierKeyCodes: [String: CGKeyCode] = [
        "cmd": 55, "command": 55, "shift": 56, "option": 58, "alt": 58, "control": 59, "ctrl": 59
    ]

    private func postComputerUseKeyPress(keyName: String) {
        guard let keyCode = Self.computerUseKeyCodeByKeyNames[keyName.lowercased()] else {
            print("⚠️ Computer-use key unknown: \(keyName)")
            return
        }
        let keyboardEventSource = CGEventSource(stateID: .hidSystemState)
        Self.postTypedKeyCode(keyCode, keyboardEventSource: keyboardEventSource)
    }

    /// Posts a modifier combo: each modifier down, the main key down/up,
    /// then modifiers up in reverse order. Modifier events are posted
    /// individually (the shared postTypedKeyCode helper always posts a
    /// down+up pair, which wouldn't hold a modifier across the main key).
    private func postComputerUseHotKey(keyNames: [String]) {
        guard let mainKeyName = keyNames.last,
              let mainKeyCode = Self.computerUseKeyCodeByKeyNames[mainKeyName]
                ?? Self.computerUseModifierKeyCodes[mainKeyName] else {
            print("⚠️ Computer-use hotkey has no valid main key: \(keyNames.joined(separator: "+"))")
            return
        }
        let modifierKeyCodes = keyNames.dropLast().compactMap { Self.computerUseModifierKeyCodes[$0] }
        let keyboardEventSource = CGEventSource(stateID: .hidSystemState)

        for modifierKeyCode in modifierKeyCodes {
            postComputerUseModifierKeyCode(modifierKeyCode, keyDown: true, keyboardEventSource: keyboardEventSource)
        }
        Self.postTypedKeyCode(mainKeyCode, keyboardEventSource: keyboardEventSource)
        for modifierKeyCode in modifierKeyCodes.reversed() {
            postComputerUseModifierKeyCode(modifierKeyCode, keyDown: false, keyboardEventSource: keyboardEventSource)
        }
    }

    private func postComputerUseModifierKeyCode(
        _ keyCode: CGKeyCode,
        keyDown: Bool,
        keyboardEventSource: CGEventSource?
    ) {
        let modifierKeyEvent = CGEvent(
            keyboardEventSource: keyboardEventSource,
            virtualKey: keyCode,
            keyDown: keyDown
        )
        modifierKeyEvent?.post(tap: .cghidEventTap)
    }

    private func postComputerUseScroll(deltaX: Int, deltaY: Int) {
        let scrollEventSource = CGEventSource(stateID: .hidSystemState)
        // wheel1 = vertical (negated so positive dy scrolls down per the
        // prompt contract); wheel2 = horizontal.
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: scrollEventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else { return }
        scrollEvent.post(tap: .cghidEventTap)
    }

}
