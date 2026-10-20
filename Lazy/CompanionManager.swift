//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import IOKit
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Which input modality produced the current request. Voice replies are
/// spoken via TTS only — never displayed on screen, never logged in the
/// chat box. Typed replies are silent, stream into the chat window, and
/// are the only turns logged in the transcript.
enum ReplySource {
    case voice
    case typed
    /// Proactive suggestion batch (morning notch) — announcement only:
    /// transcript + badge, never a voice reply.
    case scheduled
}

/// What a push-to-talk press does with its final transcript: send it to the
/// AI brain as a voice command, or type it at the cursor in the frontmost
/// app (dictation).
enum TranscriptSubmissionBehavior {
    case runAsCommand
    case insertAsDictation
}

/// One hand-drawn annotation the overlay renders on screen, parsed from a
/// [DRAW:...] tag. All points are AppKit-global (bottom-left origin);
/// `displayFrame` says which screen owns it (per-screen conversion happens
/// in the overlay).
struct ScreenAnnotation: Identifiable, Equatable {
    enum ShapeKind: Equatable {
        case circle
        case arrow
        case underline
        case freehandPath
    }

    let id: UUID
    let shapeKind: ShapeKind
    /// AppKit-global points: circle = [boxStart, boxEnd], arrow/underline =
    /// [start, end], freehandPath = the polyline.
    let points: [CGPoint]
    let displayFrame: CGRect
    /// Stable seed for the hand-drawn wobble so jitter never shimmers
    /// between renders of the same annotation.
    let wobbleSeed: UInt64
}

/// Status shown by the notch pill's dot: green while the mic is listening,
/// yellow while a reply is being generated/spoken (voice or typed), blue
/// when idle.
enum NotchPillStatus {
    case idle
    case listening
    case working
}

/// Small helper for the `[latency]` debug logs: call `beginInteraction()` at
/// key-down, then `mark()` at each pipeline milestone. Prints milliseconds
/// since the interaction start and since the previous mark, so the Xcode
/// console shows exactly where voice-response time is going.
@MainActor
enum LazyLatency {
    private static var interactionStartedAt: TimeInterval?
    private static var lastMarkedAt: TimeInterval?
    private static var didMarkFirstTTSPaudio = false

    static func beginInteraction() {
        interactionStartedAt = ProcessInfo.processInfo.systemUptime
        lastMarkedAt = interactionStartedAt
        didMarkFirstTTSPaudio = false
        print("[latency] ————— new interaction —————")
        BrainLog.line("latency: ————— new interaction —————")
    }

    static func mark(_ label: String) {
        guard let startedAt = interactionStartedAt else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let totalMilliseconds = Int((now - startedAt) * 1000)
        let deltaMilliseconds = Int((now - (lastMarkedAt ?? startedAt)) * 1000)
        print("[latency] \(label): +\(totalMilliseconds)ms total, +\(deltaMilliseconds)ms since previous")
        BrainLog.line("latency: \(label): +\(totalMilliseconds)ms total, +\(deltaMilliseconds)ms since previous")
        lastMarkedAt = now
    }

    /// First audible TTS moment of the interaction (ElevenLabs first chunk
    /// or system-voice startSpeaking) — fires once per interaction no matter
    /// how many sentences queue up afterwards.
    static func markFirstTTSPaudio() {
        guard interactionStartedAt != nil, !didMarkFirstTTSPaudio else { return }
        didMarkFirstTTSPaudio = true
        mark("tts-first-audio")
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// Hand-drawn [DRAW:...] annotations currently on screen, in AppKit
    /// global coords. Empty = nothing drawn. Cleared ~7s after being set
    /// (the overlay draws, holds ~6s, then fades) or on push-to-talk interrupt.
    @Published var activeScreenAnnotations: [ScreenAnnotation] = []
    private var screenAnnotationsClearTask: Task<Void, Never>?

    /// True while a multi-step [AGENT:...] computer-use run is executing —
    /// drives the panel's "Agent working…" status and the chat window's
    /// Stop button.
    @Published var isAgentRunActive: Bool = false

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Voice replies are audio-only — no on-screen text — so the cursor-following
    // reply bubble is never shown anymore; only defensive hideOverlay() resets
    // below remain (the manager is kept in case display is ever re-enabled).
    private let companionResponseOverlayManager = CompanionResponseOverlayManager()

    /// The chat window (typed messages + scrollable transcript + streaming
    /// assistant bubble). Lazily created so the window only exists on first use.
    /// Opened via the notch sheet's expand button.
    private lazy var chatWindowController = ChatWindowController(companionManager: self)

    /// HeyClicky-style notch chat: pill at the top-center screen edge that
    /// toggles a chat sheet springing down from the top. The main entry
    /// point for typed chat (plus the ctrl+cmd+a hotkey).
    private lazy var notchChatManager = NotchChatManager(companionManager: self)

    // MARK: - M6 Mail

    /// Mail stack owner (M6.1): Gmail/Outlook OAuth, the sync loop, the
    /// local SQLite store. Home → Settings → Mail drives it; M6.2–M6.4 hang
    /// classification, the sticky board, and drafts off this.
    let mailManager = MailManager()

    /// M6.3: the sticky board — a tilted handwritten note pasted on the
    /// desktop (todos + reminders + mail cards).
    private(set) lazy var stickyBoardManager = StickyBoardManager(mailManager: mailManager)

    /// On-screen walkthrough card — shows while a [GUIDE:] walkthrough is
    /// active and the notch sheet is closed (B1 amended: user decision).
    private lazy var guideStepOverlay = GuideStepOverlayManager(
        companionManager: self,
        notchChatManager: notchChatManager
    )

    /// App-delegate wiring: the notch sheet header's house button opens the
    /// Home dashboard. Called once at launch, before the sheet first opens.
    func setNotchChatHomeHandler(_ handler: @escaping () -> Void) {
        notchChatManager.onOpenHome = handler
    }

    /// House button: leaving chat for Home — close the sheet first so it
    /// can't float over the dashboard.
    func closeNotchChatSheet() {
        notchChatManager.closeSheet()
    }

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://clicky-proxy.clicky-proxy-nana.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: Self.fallbackWorkerModelID(forSemanticModelChoice: selectedModel))
    }()

    /// Primary chat brain: talks to the local OpenCode server, which calls
    /// free vision models (space-bunny-free / step-5-preview-free) with the
    /// user's own OpenCode credentials. The worker-based claudeAPI above is
    /// only used when this bridge is unavailable.
    let openCodeChatClient = OpenCodeChatClient()

    /// Primary brain transport #1: Gemini free tier called directly (skipped
    /// entirely when no API key is configured). The local OpenCode bridge
    /// above stays attempt #2 and the worker claudeAPI attempt #3.
    private let geminiBrainTransport = GeminiBrainTransport()

    lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        let client = ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
        client.onQueueFailure = { [weak self] error in
            self?.noteTTSSynthesisFailure(error)
        }
        return client
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    // MARK: - Chat Window State (typed messages)

    /// One message in the chat window transcript. Voice turns are logged here
    /// too, so the window shows the full conversation regardless of modality.
    struct ChatMessage: Identifiable, Codable {
        let id: UUID
        let role: ChatMessageRole
        let text: String
        let sentAt: Date
    }

    enum ChatMessageRole: String, Codable {
        case user
        case assistant
    }

    /// A file the user picked in the chat input to include with the next
    /// typed message. Only metadata lives here — the file's data is read at
    /// submit time so chips stay cheap.
    struct ChatFileAttachment: Identifiable, Equatable {
        let id: UUID
        let displayName: String
        let fileURL: URL
        let isImage: Bool

        init(fileURL: URL) {
            self.id = UUID()
            self.displayName = fileURL.lastPathComponent
            self.fileURL = fileURL
            // Cheap chip-icon heuristic from the extension — the real
            // type detection (image decode vs UTF-8) happens at submit.
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]
            self.isImage = imageExtensions.contains(fileURL.pathExtension.lowercased())
        }
    }

    /// A user-defined personal skill: a named, reusable prompt. Invoked in
    /// chat as "/name" (expanded before submit) or by voice ("run my name").
    struct UserSkill: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var promptText: String
    }

    /// Persisted transcript shown in the chat window. Loaded at startup so
    /// history survives app restarts.
    @Published private(set) var chatMessages: [ChatMessage] = []

    /// True while a typed reply is streaming — drives the typing indicator
    /// and the live-updating assistant bubble in the chat window.
    @Published var chatIsResponding = false

    /// Live assistant reply text for the in-flight typed response. Cleared
    /// when the final reply message replaces it in chatMessages.
    @Published var chatStreamingReplyText: String = ""

    // MARK: - M3 Proactivity State

    /// Sensing + once/day suggestion batch (rules, DND probe, routines).
    let proactiveEngine = ProactiveSuggestionEngine()

    /// Live mirror of `proactiveEngine.unreadCount` so the notch pill badge
    /// re-renders with the manager (views observe the manager, not the engine).
    @Published var unreadSuggestionCount = 0

    /// Active Clickys persona — drives the prompt addendum and Home hero.
    @Published var activePersonaID: String = CompanionManager.loadActivePersonaID()

    private var unreadCountCancellable: AnyCancellable?

    static let activePersonaDefaultsKey = "clickyActivePersona"

    static func loadActivePersonaID() -> String {
        UserDefaults.standard.string(forKey: activePersonaDefaultsKey) ?? LazyPersona.defaultID
    }

    var activePersona: LazyPersona {
        LazyPersona.persona(id: activePersonaID)
    }

    func setActivePersona(id: String) {
        guard LazyPersona.builtIns.contains(where: { $0.id == id }) else { return }
        activePersonaID = id
        UserDefaults.standard.set(id, forKey: Self.activePersonaDefaultsKey)
        print("🎭 Persona: \(id)")
    }

    private static let persistedChatMessagesKey = "clickyChatMessages"
    private static let maximumPersistedChatMessageCount = 100

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?

    /// Screenshot capture started at key-up, overlapping transcript
    /// finalization. Consumed by the response task; stale results (>30s old)
    /// are re-captured instead of being sent to the model.
    private var screenshotCaptureTask: Task<(captures: [CompanionScreenCapture], capturedAt: Date), Error>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var chatToggleCancellables = Set<AnyCancellable>()
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Captured when a keyboard-shortcut session starts so flipping the
    /// panel's dictation toggle mid-recording can't misroute the transcript
    /// that's about to land.
    private var activeKeyboardShortcutSubmissionBehavior: TranscriptSubmissionBehavior = .runAsCommand
    /// The most recent dictation-insertion task; cancelled if a new dictated
    /// transcript lands before the previous one finished posting keystrokes.
    private var activeDictationInsertionTask: Task<Void, Never>?
    /// The last text dictation typed at the cursor — used only to decide
    /// whether the next dictated utterance needs a separating leading space
    /// (posted keystrokes can't read the cursor's neighborhood, so we
    /// remember our own last insertion instead).
    private var lastDictatedTextInsertedAtCursor: String?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True while all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Live status for the notch pill's dot. Derived from the published
    /// voiceState + chatIsResponding so the pill re-renders on every change
    /// without extra observation plumbing.
    var notchPillStatus: NotchPillStatus {
        if voiceState == .listening {
            return .listening
        }
        if voiceState == .processing || voiceState == .responding || chatIsResponding {
            return .working
        }
        return .idle
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The selected brain as a semantic choice ("fast" or "smart"),
    /// persisted to UserDefaults. Older builds stored Claude model IDs
    /// (claude-sonnet-4-6 / claude-opus-4-6); those are migrated here so
    /// existing installs keep their Sonnet→fast / Opus→smart preference.
    @Published var selectedModel: String = CompanionManager.migrateStoredSemanticModelChoice()

    private static func migrateStoredSemanticModelChoice() -> String {
        let storedChoice = UserDefaults.standard.string(forKey: "selectedClaudeModel")
        let migratedChoice: String
        switch storedChoice {
        case "claude-opus-4-6":
            migratedChoice = "smart"
        case "fast", "smart":
            migratedChoice = storedChoice ?? "fast"
        default:
            migratedChoice = "fast"
        }
        UserDefaults.standard.set(migratedChoice, forKey: "selectedClaudeModel")
        return migratedChoice
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = Self.fallbackWorkerModelID(forSemanticModelChoice: model)
    }

    /// Model ID sent to the Cloudflare worker chat route (the fallback brain).
    /// The worker currently overrides this with its own FREE_CHAT_MODEL, but a
    /// sensible ID keeps the fallback path correct if that override is removed.
    private static func fallbackWorkerModelID(forSemanticModelChoice semanticModelChoice: String) -> String {
        semanticModelChoice == "smart"
            ? "google/gemma-4-26b-a4b-it:free"
            : "dots-studio/dots-3-note-preview:free"
    }

    /// User preference for whether the push-to-talk shortcut should behave
    /// as dictation (transcript typed at the cursor) instead of running
    /// voice commands through the brain. The dedicated fn+control shortcut
    /// always dictates regardless of this toggle. Persisted to UserDefaults.
    @Published var isDictationModeEnabled: Bool = UserDefaults.standard.bool(forKey: "isDictationModeEnabled")

    func setDictationModeEnabled(_ enabled: Bool) {
        isDictationModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isDictationModeEnabled")
    }

    /// Facts the user explicitly asked Clicky to remember (via [REMEMBER:...]
    /// tags in replies). Injected into every system prompt as the "things you
    /// know about the user" section. Persisted to UserDefaults.
    @Published private(set) var rememberedFacts: [String] = UserDefaults.standard.stringArray(
        forKey: CompanionManager.rememberedFactsUserDefaultsKey
    ) ?? []

    /// Personal skills the user saved (named reusable prompts). Persisted to
    /// UserDefaults; listed in the system prompt and expanded from "/name"
    /// drafts in chat.
    @Published private(set) var userSkills: [UserSkill] = {
        guard let encodedSkills = UserDefaults.standard.data(forKey: CompanionManager.userSkillsUserDefaultsKey),
              let decodedSkills = try? JSONDecoder().decode([UserSkill].self, from: encodedSkills) else {
            return []
        }
        return decodedSkills
    }()

    /// Last failure Clicky surfaced to the user (classified, human-readable),
    /// persisted so the panel can show it after a restart.
    @Published var lastErrorText: String? = UserDefaults.standard.string(
        forKey: CompanionManager.lastErrorUserDefaultsKey
    )

    /// When that last failure happened (epoch seconds stored in UserDefaults).
    @Published var lastErrorDate: Date? = {
        let epoch = UserDefaults.standard.double(forKey: CompanionManager.lastErrorTimestampUserDefaultsKey)
        return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
    }()

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        // M4.5d: the beachball names itself (main-thread stack dump after 3s
        // unresponsive) + the brain chain logs to disk — Xcode's console dies
        // with Xcode, so a hang must leave evidence behind (brain.log).
        MainThreadStallReporter.start()
        BrainLog.line("— Clicky launched —")

        refreshAllPermissions()
        print("🔑 Lazy start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // On-screen walkthrough card — observe guide/sheet state once.
        guideStepOverlay.startObserving()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // Warm the local OpenCode bridge (health + session checks) so the
        // first voice interaction doesn't pay for cold preflight round trips.
        openCodeChatClient.warmUp()

        // Restore the chat window transcript from the previous run.
        loadPersistedChatMessages()

        // B2: fill any missing bundled skill files in Application Support
        // (first launch writes all 38; later launches only fill gaps, so
        // hand edits are never overwritten).
        BundledSkills.installBundledSkillFilesIfNeeded()

        // M3: proactive engine — batch deliveries append a scheduled
        // transcript entry; unread count mirrors onto this manager for the
        // notch pill badge.
        proactiveEngine.onDeliverBatch = { [weak self] cards in
            self?.deliverScheduledSuggestions(cards, source: .scheduled)
        }
        proactiveEngine.start()
        unreadCountCancellable = proactiveEngine.$unreadCount.sink { [weak self] count in
            self?.unreadSuggestionCount = count
        }

        // M6.1: mail sync — restores any connected account and starts the
        // 90 s poll; no-op until the user connects a mailbox in Settings.
        mailManager.start()

        // M6.3: sticky board — reminder flashes come from the scheduler
        // (owned by mailManager), the board is the UI surface.
        mailManager.reminderScheduler.onFired = { [weak self] id, _ in
            self?.stickyBoardManager.flash(itemID: "reminder:\(id)")
        }
        stickyBoardManager.start()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        LazyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        LazyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Lazy: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Lazy: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    /// Immediately removes all on-screen drawings (push-to-talk interrupt) and
    /// cancels their scheduled clear. Kept separate from
    /// `clearDetectedElementLocation()` because pointing finishes on its own
    /// timeline (buddy flies back) while drawings must vanish instantly.
    private func clearScreenAnnotations() {
        screenAnnotationsClearTask?.cancel()
        screenAnnotationsClearTask = nil
        if !activeScreenAnnotations.isEmpty {
            activeScreenAnnotations = []
        }
    }

    /// Clears the current on-screen annotations after the overlay has had
    /// time to draw them on, hold ~6s, and fade. Cancelled when a new batch
    /// arrives or an interaction interrupts.
    private func scheduleScreenAnnotationsClear() {
        screenAnnotationsClearTask?.cancel()
        screenAnnotationsClearTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            activeScreenAnnotations = []
        }
    }

    func stop() {
        proactiveEngine.stop()
        mailManager.stop()
        stickyBoardManager.stop()
        unreadCountCancellable?.cancel()
        unreadCountCancellable = nil
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        companionResponseOverlayManager.hideOverlay()
        transientHideTask?.cancel()
        screenAnnotationsClearTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            LazyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            LazyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            LazyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            LazyAnalytics.trackAllPermissionsGranted()
        }

        updateNotchChatPillVisibility()
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    LazyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    if self.voiceState != .listening {
                        LazyLatency.mark("listening-ui-shown")
                    }
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }

        globalPushToTalkShortcutMonitor
            .chatTogglePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.toggleNotchChat()
            }
            .store(in: &chatToggleCancellables)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed(let shortcutOption):
            // The dedicated dictation shortcut always inserts; the command
            // shortcut (ctrl+option) inserts only while the panel's
            // "Dictation mode" toggle is on.
            let submissionBehavior: TranscriptSubmissionBehavior = shortcutOption == BuddyPushToTalkShortcut.dictationShortcutOption
                || isDictationModeEnabled
                ? .insertAsDictation
                : .runAsCommand
            handleKeyboardShortcutPressed(submissionBehavior: submissionBehavior)
        case .released:
            handleKeyboardShortcutReleased()
        }
    }

    private func handleKeyboardShortcutPressed(submissionBehavior: TranscriptSubmissionBehavior) {
        activeKeyboardShortcutSubmissionBehavior = submissionBehavior

        // Dictation never hits the brain, so there's no latency chain to
        // measure and no bridge to warm.
        if submissionBehavior == .runAsCommand {
            LazyLatency.beginInteraction()
        }

        // Don't register push-to-talk while the onboarding video is playing
        guard !showOnboardingVideo else { return }

        // Cancel any pending transient hide so the overlay stays visible
        transientHideTask?.cancel()
        transientHideTask = nil

        // If the cursor is hidden, bring it back transiently for this interaction
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Dismiss the menu bar panel so it doesn't cover the screen
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Cancel any in-progress response and TTS from a previous utterance
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        companionResponseOverlayManager.hideOverlay()
        // A typed chat response may be streaming — abort it so the chat
        // window doesn't keep a stale in-flight bubble. The cancelled
        // task skips its own state reset (guarded by `!Task.isCancelled`).
        if chatIsResponding {
            chatIsResponding = false
            chatStreamingReplyText = ""
        }
        clearDetectedElementLocation()
        clearScreenAnnotations()
        // The cancelled response task skips its own state reset (guarded by
        // `!Task.isCancelled`), so clear .responding here. Otherwise the
        // voice-state sink ignores the new .listening update and the mic
        // sign never appears for this utterance.
        if voiceState == .responding {
            voiceState = .idle
        }

        // Dismiss the onboarding prompt if it's showing
        if showOnboardingPrompt {
            withAnimation(.easeOut(duration: 0.3)) {
                onboardingPromptOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showOnboardingPrompt = false
                self.onboardingPromptText = ""
            }
        }


        LazyAnalytics.trackPushToTalkStarted()

        // A previous session may still be preparing or finalizing (both can
        // take seconds) — abort it so this press starts immediately instead
        // of being silently dropped.
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        buddyDictationManager.interruptForNewKeyboardShortcutPress()

        // Re-warm the bridge preflight so the reply path starts hot.
        if submissionBehavior == .runAsCommand {
            openCodeChatClient.warmUp()
        }

        pendingKeyboardShortcutStartTask = Task {
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts are hidden (waveform-only UI)
                },
                submitDraftText: { [weak self] finalTranscript in
                    guard let self else { return }

                    if submissionBehavior == .insertAsDictation {
                        self.typeDictatedTextAtCursor(finalTranscript)
                        return
                    }

                    LazyLatency.mark("transcript-submitted")
                    self.lastTranscript = finalTranscript
                    print("🗣️ Companion received transcript: \(finalTranscript)")
                    LazyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                    self.respond(to: finalTranscript, source: .voice)
                }
            )
        }
    }

    private func handleKeyboardShortcutReleased() {
        // Cancel the pending start task in case the user released the shortcut
        // before the async startPushToTalk had a chance to begin recording.
        // Without this, a quick press-and-release drops the release event and
        // leaves the waveform overlay stuck on screen indefinitely.
        LazyAnalytics.trackPushToTalkReleased()

        let submissionBehavior = activeKeyboardShortcutSubmissionBehavior
        if submissionBehavior == .runAsCommand {
            LazyLatency.mark("key-up")
        }

        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        // Start the screenshot now so it overlaps AssemblyAI's turn-end
        // wait — the response task consumes it when the transcript lands.
        // Dictation never reaches the brain, so it skips the capture entirely.
        if submissionBehavior == .runAsCommand {
            beginScreenshotCaptureNow()
        }
    }

    // MARK: - AI Response Pipeline

    /// Starts capturing all screens immediately at key-up so the capture
    /// overlaps AssemblyAI's turn-end wait instead of running after it.
    private func beginScreenshotCaptureNow() {
        if let screenshotCaptureTask, !screenshotCaptureTask.isCancelled {
            return
        }
        screenshotCaptureTask = Task {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            LazyLatency.mark("screenshot-ready")
            return (captures, Date())
        }
    }

    /// Returns a screenshot for the current response, consuming the capture
    /// started at key-up when it's still fresh. Falls back to a direct capture
    /// for flows that didn't start one (e.g. the microphone button) or when the
    /// pre-started capture failed.
    private func takeScreenshotForResponse() async throws -> [CompanionScreenCapture] {
        if let screenshotCaptureTask {
            self.screenshotCaptureTask = nil
            do {
                let (captures, capturedAt) = try await screenshotCaptureTask.value
                if Date().timeIntervalSince(capturedAt) < 30 {
                    return captures
                }
                print("⚠️ Screenshot from key-up was stale (\(Int(Date().timeIntervalSince(capturedAt)))s) — re-capturing")
            } catch {
                print("⚠️ Pre-started screenshot failed (\(error)) — capturing directly")
            }
        }
        let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        LazyLatency.mark("screenshot-ready")
        return captures
    }

    /// Called for each sentence the model finishes writing (streamed from the
    /// bridge's /event SSE). Queues it for TTS so speech starts while the rest
    /// of the reply is still generating. Sentences containing "[" are held
    /// back — that's the [POINT:...] tag, which must not be spoken.
    private func handleEarlyReplySentence(_ sentence: String) {
        guard !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !sentence.contains("[") else { return }
        if voiceState == .processing {
            LazyLatency.mark("brain-first-sentence")
        }
        guard !replyNeedsSystemVoiceFallback, !isElevenLabsVoiceDisabledToday else { return }
        elevenLabsTTSClient.enqueueSentence(sentence)
        voiceState = .responding
    }

    /// Compact recap of the last few exchanges for a freshly rotated OpenCode
    /// session (the client rotates at `sessionRotationMessageThreshold`, when
    /// server-side prefill would otherwise grow unbounded). Sent once, right
    /// after rotation, so follow-ups keep context without re-prefilling
    /// Builds the seed text for a freshly rotated OpenCode session, which has
    /// no server-side memory yet. Prefers the server-written summary from the
    /// last rotation (covers the whole rotated-out session), then the most
    /// recent in-memory exchanges; on app relaunch (empty `conversationHistory`
    /// and no summary) falls back to the persisted typed transcript.
    private func conversationSeedForNewSession() -> String? {
        var seedSections: [String] = []

        // The server-side summary captured at the last rotation is the
        // richest continuity source — it condenses the entire old session.
        if let persistedSessionSummary = openCodeChatClient.persistedSessionSummary,
           !persistedSessionSummary.isEmpty {
            seedSections.append("Summary of an earlier conversation:\n\(persistedSessionSummary)")
        }

        if !conversationHistory.isEmpty {
            let recentExchanges = conversationHistory.suffix(2).map { entry in
                "User: \(entry.userTranscript.prefix(300))\nLazy: \(entry.assistantResponse.prefix(300))"
            }.joined(separator: "\n\n")
            seedSections.append("Most recent exchanges:\n\(recentExchanges)")
        } else if seedSections.isEmpty {
            let recentChatMessages = chatMessages.suffix(6)
            guard !recentChatMessages.isEmpty else { return nil }
            let recentTranscript = recentChatMessages.map { message in
                let speaker = message.role == .user ? "User" : "Lazy"
                return "\(speaker): \(message.text.prefix(300))"
            }.joined(separator: "\n\n")
            seedSections.append("Recent messages:\n\(recentTranscript)")
        }

        return seedSections.joined(separator: "\n\n")
    }

    /// Captures a screenshot, sends it along with the user's message to the
    /// brain, and delivers the reply according to the input modality:
    /// - voice: sentences stream into TTS while generation continues; the
    ///   reply is spoken only — never displayed, never logged in the chat box.
    /// - typed: text streams into the chat window's live assistant bubble;
    ///   no TTS. Pointing works in both modalities. A [POINT:x,y:label] tag
    ///   in the reply triggers the buddy's flight to that element on screen,
    ///   and [DRAW:...] tags publish hand-drawn annotations the overlay
    ///   renders. A [TASK:...] tag runs an action silently and only the
    ///   outcome line ("Done opening Spotify") is spoken / appended.
    private func respond(
        to userMessageText: String,
        source: ReplySource,
        fileAttachments: [ChatFileAttachment] = []
    ) {
        let speakReply = source == .voice

        // Fresh interaction — clear the per-reply system-voice fallback so a
        // failure from the previous reply doesn't bleed into this one (the
        // day-level quota lock, if any, is checked separately).
        replyNeedsSystemVoiceFallback = false

        // Voice interactions start the [latency] clock at key-down; typed
        // messages have no key-down, so start it here — otherwise every
        // mark for a typed reply silently no-ops and the console shows
        // nothing to diagnose.
        if source == .typed {
            LazyLatency.beginInteraction()
        }

        // "stop" / "cancel" while an agent run is executing cancels the
        // run itself instead of going to the brain — the run is the live
        // task, and the word on its own needs no reply.
        if isAgentRunActive, Self.isAgentRunStopCommand(userMessageText) {
            cancelActiveAgentRun()
            if source == .typed {
                appendChatMessage(role: .assistant, text: "Stopped the agent run.")
            } else {
                currentResponseTask = Task {
                    voiceState = .processing
                    if replyNeedsSystemVoiceFallback || isElevenLabsVoiceDisabledToday {
                        speakViaSystemVoice("stopped.")
                    } else {
                        do {
                            try await elevenLabsTTSClient.speakText("stopped.")
                        } catch {
                            noteTTSSynthesisFailure(error)
                            LazyAnalytics.trackTTSError(error: error.localizedDescription)
                            print("⚠️ ElevenLabs TTS error: \(error)")
                            speakViaSystemVoice("stopped.")
                        }
                    }
                    voiceState = .idle
                }
            }
            return
        }

        // Interrupt any in-progress response so only one reply is ever in
        // flight. The cancelled task skips its own cleanup (guarded by
        // `!Task.isCancelled`), so reset shared state here.
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        companionResponseOverlayManager.hideOverlay()
        if source == .typed {
            chatIsResponding = false
            chatStreamingReplyText = ""
            // Don't leave the cursor stuck in spinner/responding — the
            // cancelled voice task won't reset it itself.
            if voiceState == .responding || voiceState == .processing {
                voiceState = .idle
            }
        }

        currentResponseTask = Task {
            if speakReply {
                // Stay in processing (spinner) state — voice gets no on-screen
                // reply text, so the spinner is the only feedback until the
                // reply is spoken.
                voiceState = .processing
            } else {
                chatIsResponding = true
                chatStreamingReplyText = ""
            }
            // Audio commands are never logged in the chat box — the transcript
            // is for typed conversations only.
            if source == .typed {
                appendChatMessage(role: .user, text: userMessageText)
            }

            // M5.3 — risky-action confirmation: a strict yes/no answers the
            // open parked ask right here (no brain call); anything else
            // supersedes the ask and flows on normally. First of the local
            // intents so a pending ask can't be starved by them.
            if let parkedConfirmation = pendingRiskConfirmation {
                if let confirmationAnswer = RiskGate.answer(matching: userMessageText) {
                    pendingRiskConfirmation = nil
                    riskConfirmationTimeoutTask?.cancel()
                    riskConfirmationTimeoutTask = nil
                    let confirmationOutcomeLine: String
                    if confirmationAnswer == .no {
                        print("🛑 Risk confirmation: no — skipping the parked action")
                        confirmationOutcomeLine = "Okay — I didn't do it."
                        // A declined draft reply is discarded so no stale
                        // send card lingers (Lazy's discard path + audit).
                        if case .draftSend(let declinedDraftID, _, _, _, _) = parkedConfirmation {
                            mailManager.discardDraft(declinedDraftID)
                        }
                    } else {
                        confirmationOutcomeLine = await executeParkedRiskConfirmation(
                            parkedConfirmation,
                            speakReply: speakReply
                        )
                        guard !Task.isCancelled else { return }
                    }
                    conversationHistory.append((
                        userTranscript: userMessageText,
                        assistantResponse: confirmationOutcomeLine
                    ))
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }
                    LazyAnalytics.trackAIResponseReceived(response: confirmationOutcomeLine)
                    if speakReply {
                        await speakOutcomeLine(confirmationOutcomeLine)
                        if !Task.isCancelled {
                            voiceState = .idle
                            scheduleTransientHideIfNeeded()
                        }
                    } else {
                        chatStreamingReplyText = ""
                        chatIsResponding = false
                        appendChatMessage(role: .assistant, text: confirmationOutcomeLine)
                    }
                    return
                }
                // Not an answer — the open ask is superseded by whatever the
                // user actually said (the normal pipeline owns this message).
                print("🛑 Risk confirmation: superseded by a new message")
                pendingRiskConfirmation = nil
                riskConfirmationTimeoutTask?.cancel()
                riskConfirmationTimeoutTask = nil
            }

            // Suggestion pause/resume — local intent (locked M3 rule), no
            // brain call: "ignore breaks until 3pm" hushes every batch until
            // then; resume phrases clear it early. Strict phrases only —
            // anything else falls through to the normal pipeline.
            if let suggestionIntent = proactiveEngine.suggestionIntent(matching: userMessageText) {
                let outcomeLine: String
                switch suggestionIntent {
                case .pauseUntil(let date):
                    proactiveEngine.pauseSuggestions(until: date)
                    outcomeLine = "Quiet until \(date.formatted(date: .omitted, time: .shortened))."
                case .resume:
                    proactiveEngine.resumeSuggestions()
                    outcomeLine = "Suggestions are back on."
                }
                print("🔕 Local suggestion intent: \(suggestionIntent)")
                if speakReply {
                    await speakOutcomeLine(outcomeLine)
                } else {
                    chatStreamingReplyText = ""
                    chatIsResponding = false
                    appendChatMessage(role: .assistant, text: outcomeLine)
                }
                if !Task.isCancelled && speakReply {
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
                return
            }

            // Walkthrough guide advance/finish — local, no brain, only while
            // a [GUIDE:...] walkthrough is active. "next" speaks/appends the
            // following step; "done" clears the card. Anything else falls
            // through to the normal pipeline unchanged.
            if !activeGuideSteps.isEmpty,
               let guideIntent = Self.guideIntent(matching: userMessageText),
               let guideOutcomeLine = deliverGuideIntent(guideIntent, speakReply: speakReply) {
                if speakReply {
                    await speakOutcomeLine(guideOutcomeLine)
                } else {
                    chatStreamingReplyText = ""
                    chatIsResponding = false
                    appendChatMessage(role: .assistant, text: guideOutcomeLine)
                }
                if !Task.isCancelled && speakReply {
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
                return
            }

            // M6.4 — mail intents: "check my email" digest + "reply to X"
            // (Gemini fast draft → approval card + M5.3 yes/no). Strict
            // phrases; the reply NEVER sends on its own — it parks the
            // ask first (PTT-safe), exactly like the empty-trash gate.
            if fileAttachments.isEmpty, Self.isMailDigestIntent(userMessageText) {
                let digestLine = mailManager.mailDigestLine()
                if speakReply {
                    await speakOutcomeLine(digestLine)
                    if !Task.isCancelled {
                        voiceState = .idle
                        scheduleTransientHideIfNeeded()
                    }
                } else {
                    chatStreamingReplyText = ""
                    chatIsResponding = false
                    appendChatMessage(role: .assistant, text: digestLine)
                }
                return
            }
            if fileAttachments.isEmpty, let replyRequest = Self.mailReplyRequest(userMessageText) {
                if speakReply {
                    voiceState = .processing
                }
                let replyOutcome = await mailManager.createReplyDraft(
                    matching: replyRequest.query,
                    instruction: replyRequest.instruction
                )
                guard !Task.isCancelled else { return }
                switch replyOutcome {
                case .failed(let failureLine):
                    if speakReply {
                        await speakOutcomeLine(failureLine)
                        if !Task.isCancelled {
                            voiceState = .idle
                            scheduleTransientHideIfNeeded()
                        }
                    } else {
                        chatStreamingReplyText = ""
                        chatIsResponding = false
                        appendChatMessage(role: .assistant, text: failureLine)
                    }
                case .parked(let draft):
                    print("🛑 Mail draft parked: \(draft.subject.prefix(50)) → \(draft.toAddresses.joined(separator: ", "))")
                    let question = "Here's the reply to \(draft.toName): \(draft.body). Should I send it?"
                    await parkRiskConfirmation(
                        .draftSend(
                            draftID: draft.id,
                            recipientName: draft.toName,
                            previewBody: draft.body,
                            userMessageText: userMessageText,
                            source: source
                        ),
                        question: question,
                        typedPlanText: nil,
                        speakReply: speakReply
                    )
                }
                return
            }

            // M6.3 — sticky-board capture: "remind me to…" / "add todo…" /
            // "note: …" / "open|hide the board" — strict local prefixes, no
            // brain; anything else falls through unchanged.
            if fileAttachments.isEmpty,
               let captureOutcome = deliverBoardCaptureIntent(userMessageText) {
                if speakReply {
                    await speakOutcomeLine(captureOutcome)
                } else {
                    chatStreamingReplyText = ""
                    chatIsResponding = false
                    appendChatMessage(role: .assistant, text: captureOutcome)
                }
                if !Task.isCancelled && speakReply {
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
                return
            }

            // Instant local actions: strict whole-string matches (open/quit a
            // resolvable app, volume, brightness, screenshot, playback) run
            // right here — no screenshot, no brain call, sub-half-second
            // outcome. Anything that doesn't match cleanly falls through to
            // the normal brain pipeline unchanged.
            if fileAttachments.isEmpty,
               let instantActionTask = Self.parseInstantLocalAction(userMessageText) {
                // M5.3 — a risky instant action parks for yes/no instead of
                // running (emptying the Trash is permanent).
                if RiskGate.isRiskyActionTask(instantActionTask) {
                    await parkRiskConfirmation(
                        .instantTask(instantActionTask, userMessageText: userMessageText, source: source),
                        question: RiskGate.confirmationQuestion(forActionTask: instantActionTask),
                        typedPlanText: nil,
                        speakReply: speakReply
                    )
                    return
                }
                print("⚡ Instant local action: \(instantActionTask)")
                let outcomeLine = await executeActionTask(instantActionTask)
                LazyLatency.mark("task-executed")
                guard !Task.isCancelled else { return }

                conversationHistory.append((
                    userTranscript: userMessageText,
                    assistantResponse: outcomeLine
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                LazyAnalytics.trackAIResponseReceived(response: outcomeLine)

                if speakReply {
                    await speakOutcomeLine(outcomeLine)
                } else {
                    chatStreamingReplyText = ""
                    chatIsResponding = false
                    appendChatMessage(role: .assistant, text: outcomeLine)
                }

                if !Task.isCancelled && speakReply {
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                }
                return
            }

            // Marks [latency] brain-first-delta once per reply — the moment
            // the first visible word arrives (bridge /event delta or worker
            // fallback chunk), which is the number that matters for perceived
            // speed. Shared by both paths so it can only fire once.
            var hasMarkedFirstBrainDelta = false
            // True once the local bridge failed and the worker fallback was
            // attempted — lets the final catch say "brain AND backup" instead
            // of blaming only the last error.
            var didFailOverToWorker = false

            do {
                // Consume the screenshot started at key-up (voice), or
                // capture fresh now (typed) so screen context is current.
                let screenCaptures = try await takeScreenshotForResponse()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so the coordinate space matches the image the model sees. We
                // scale from screenshot pixels to display points ourselves.
                var labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Files the user attached in chat (typed only) or referenced
                // by full path in the message (either modality) ride along
                // with the request — images join the picture list, text is
                // framed into the prompt below.
                var fileContextSections: [String] = []
                var includedFileURLs: Set<URL> = []

                for fileAttachment in fileAttachments {
                    guard !includedFileURLs.contains(fileAttachment.fileURL) else { continue }
                    guard let loadedFileAttachment = loadFileAttachment(from: fileAttachment.fileURL) else { continue }
                    includedFileURLs.insert(fileAttachment.fileURL)
                    incorporate(
                        loadedFileAttachment,
                        into: &labeledImages,
                        fileContextSections: &fileContextSections
                    )
                }

                for referencedFilePath in Self.referencedFilePaths(in: userMessageText) {
                    let referencedFileURL = URL(fileURLWithPath: referencedFilePath)
                    guard !includedFileURLs.contains(referencedFileURL) else { continue }
                    guard let loadedFileAttachment = loadFileAttachment(from: referencedFileURL) else { continue }
                    includedFileURLs.insert(referencedFileURL)
                    incorporate(
                        loadedFileAttachment,
                        into: &labeledImages,
                        fileContextSections: &fileContextSections
                    )
                }

                let enrichedUserPrompt: String
                if fileContextSections.isEmpty {
                    enrichedUserPrompt = userMessageText
                } else {
                    enrichedUserPrompt = fileContextSections.joined(separator: "\n\n")
                        + "\n\n" + userMessageText
                }

                // B2 — bundled-skill injection: purely local match against
                // the 38 bundled skills; matched bodies ride along AFTER the
                // user's message (the catalog itself lives in the system
                // prompt). No match = zero extra bytes.
                var brainUserPrompt = enrichedUserPrompt
                let matchedBundledSkills = BundledSkills.matchingEntries(forMessage: userMessageText)
                if let skillInjectionBlock = BundledSkills.injectionBlock(for: matchedBundledSkills) {
                    print("📚 Bundled skills: injecting \(matchedBundledSkills.map(\.name).joined(separator: ", "))")
                    brainUserPrompt += "\n\n" + skillInjectionBlock
                }

                // M6.4 — mail awareness: one compact block of recent mail so
                // the brain can answer mail questions ("did the professor
                // write?") without a separate tool. Zero bytes when no
                // mailbox is connected or nothing recent exists.
                if let mailAwareness = mailManager.mailAwarenessBlock() {
                    brainUserPrompt += "\n\n" + mailAwareness
                }

                // B1 nudge — walkthrough-shaped asks get an explicit on-turn
                // reminder so the model can't skip the [GUIDE:] tags (the
                // protocol lives in the system prompt; free models drift).
                if Self.isWalkthroughPhrasing(userMessageText) {
                    brainUserPrompt += "\n\nThis is a step-by-step walkthrough request — per the walkthrough tutoring instructions, append one [GUIDE:step] tag per step at the end of your reply."
                }

                // Freshness nudge (M4) — free models drift from the search-
                // hook instruction; time-sensitive phrasing gets a format-free
                // reminder. Gemini link only: the marker format lives solely
                // in that transport's prompt, so serve/worker fallbacks can
                // never leak a raw marker into speech. Skipped when the
                // transport already searched proactively (M4.5b) — the hook
                // instruction is suppressed on those turns, so pointing at it
                // would only confuse the model.
                if geminiBrainTransport.isConfigured,
                   Self.needsCurrentInformation(userMessageText),
                   !Self.warrantsProactiveSearch(userMessageText) {
                    brainUserPrompt += "\n\nThis may need current information — if the answer could have changed recently, use your web search hook from your instructions first."
                }

                // Brain chain (locked): Gemini free direct first (history kept
                // locally inside the transport, whole attempt skipped with no
                // key), then the local OpenCode server (memory server-side in
                // its session), then the worker — every link streams text so
                // TTS (voice) or the chat bubble (typed) can start before
                // generation finishes.
                var fullResponseText = ""
                var alreadySpokenReplyPrefix = ""

                if geminiBrainTransport.isConfigured {
                    do {
                        let streamedReply = try await geminiBrainTransport.analyzeScreenshots(
                            images: labeledImages,
                            systemPrompt: companionSystemPrompt,
                            semanticModelChoice: selectedModel,
                            userPrompt: brainUserPrompt,
                            conversationSeed: conversationSeedForNewSession(),
                            // M4.5b: the raw utterance, not brainUserPrompt — that
                            // one carries the skills/nudge/awareness blocks and
                            // would make a noisy search query.
                            searchQueryHint: userMessageText,
                            onSentenceReady: speakReply ? { [weak self] sentence in
                                self?.handleEarlyReplySentence(sentence)
                            } : nil,
                            onDelta: { [weak self] displayText in
                                if !hasMarkedFirstBrainDelta {
                                    hasMarkedFirstBrainDelta = true
                                    LazyLatency.mark("brain-first-delta")
                                }
                                self?.handleStreamedReplyDisplayUpdate(displayText, source: source)
                            }
                        )
                        fullResponseText = streamedReply.fullReplyText
                        alreadySpokenReplyPrefix = streamedReply.alreadySpokenReplyPrefix
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        // Drop any sentences the failed attempt already queued
                        // so the next chain link isn't spoken on top of them.
                        elevenLabsTTSClient.stopPlayback()
                        print("⚠️ Gemini direct brain failed, falling back to local bridge: \(error)")
                        BrainLog.line("chain: Gemini direct failed (\(error)) — falling back to local serve (slower link)")
                        LazyAnalytics.trackResponseError(error: "gemini: \(error.localizedDescription)")
                    }
                }

                if fullResponseText.isEmpty {
                    do {
                        let streamedReply = try await openCodeChatClient.analyzeScreenshots(
                            images: labeledImages,
                            systemPrompt: companionSystemPrompt,
                            semanticModelChoice: selectedModel,
                            userPrompt: brainUserPrompt,
                            // Only consumed when the client just rotated to a
                            // fresh session (it has no server-side memory then).
                            conversationSeed: conversationSeedForNewSession(),
                            // Sentence-level early speech only applies to voice —
                            // typed replies are silent and stream via onDelta.
                            onSentenceReady: speakReply ? { [weak self] sentence in
                                self?.handleEarlyReplySentence(sentence)
                            } : nil,
                            onDelta: { [weak self] displayText in
                                if !hasMarkedFirstBrainDelta {
                                    hasMarkedFirstBrainDelta = true
                                    LazyLatency.mark("brain-first-delta")
                                }
                                self?.handleStreamedReplyDisplayUpdate(displayText, source: source)
                            }
                        )
                        fullResponseText = streamedReply.fullReplyText
                        alreadySpokenReplyPrefix = streamedReply.alreadySpokenReplyPrefix
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        // Drop any sentences the streaming path already queued so
                        // the fallback reply isn't spoken on top of them.
                        elevenLabsTTSClient.stopPlayback()
                        // If the local bridge is down (server stopped, model
                        // unavailable), fall back to the Cloudflare worker chat
                        // route so interactions still get an answer.
                        print("⚠️ OpenCode bridge failed, falling back to worker chat: \(error)")
                        BrainLog.line("chain: local serve failed (\(error)) — falling back to Cloudflare worker")
                        LazyAnalytics.trackResponseError(error: "bridge: \(error.localizedDescription)")
                        didFailOverToWorker = true

                        let historyForAPI = conversationHistory.map { entry in
                            (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                        }
                        let (fallbackResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                            images: labeledImages,
                            systemPrompt: companionSystemPrompt,
                            conversationHistory: historyForAPI,
                            userPrompt: brainUserPrompt,
                            onTextChunk: { [weak self] accumulatedFallbackReplyText in
                                if !hasMarkedFirstBrainDelta {
                                    hasMarkedFirstBrainDelta = true
                                    LazyLatency.mark("brain-first-delta")
                                }
                                self?.handleStreamedReplyDisplayUpdate(
                                    Self.displayTextWithoutPointTag(accumulatedFallbackReplyText),
                                    source: source
                                )
                            }
                        )
                        fullResponseText = fallbackResponseText
                    }
                }

                LazyLatency.mark("brain-reply")

                guard !Task.isCancelled else { return }

                // Parse a [TASK:...] action tag first. When present the reply
                // is an executable task: run it with no speech, and only the
                // outcome line ("Done opening Spotify") gets spoken (voice) or
                // appended (typed).
                let actionTask = Self.parseActionTaskTag(from: fullResponseText)
                // [AGENT:...] shell/file runs and [GUI:...] computer-use runs
                // are only considered when the reply isn't already an
                // instant [TASK:...] — the three are mutually exclusive by
                // prompt rule.
                let agentRunGoal = actionTask == nil ? Self.parseAgentRunTag(from: fullResponseText) : nil
                let computerUseGoal = (actionTask == nil && agentRunGoal == nil)
                    ? Self.parseComputerUseTag(from: fullResponseText)
                    : nil
                let textWithoutActionTag = Self.stripActionTaskTag(from: fullResponseText)
                let textWithoutAgentTag = Self.stripAgentRunTag(from: textWithoutActionTag)
                let textWithoutComputerUseTag = Self.stripComputerUseTag(from: textWithoutAgentTag)
                // GUIDE slots between computer-use and DRAW in the locked
                // protocol order — capture steps before stripping, and only
                // for plain replies (task/agent/GUI runs never tutor).
                let guideSteps = (actionTask == nil && agentRunGoal == nil && computerUseGoal == nil)
                    ? Self.parseGuideSteps(from: textWithoutComputerUseTag, screenCaptures: screenCaptures)
                    : []
                // Drill diagnostics: walkthrough phrasing + no steps parsed =
                // the model ignored the protocol — say so instead of failing
                // silently next time a drill runs.
                if guideSteps.isEmpty && Self.isWalkthroughPhrasing(userMessageText) {
                    if actionTask != nil {
                        print("🗺 Guide: walkthrough phrasing but reply carried [TASK:] — no walkthrough")
                    } else if agentRunGoal == nil && computerUseGoal == nil {
                        print("🗺 Guide: no [GUIDE:] tags in reply (model returned plain prose)")
                    }
                }
                let textWithoutGuideTags = Self.stripGuideTags(from: textWithoutComputerUseTag)
                let textWithoutDrawingTags = Self.stripScreenAnnotationTags(from: textWithoutGuideTags)
                let textWithoutMemoryTags = Self.stripMemoryTags(from: textWithoutDrawingTags)

                // Parse the [POINT:...] tag from the remaining response text
                let parseResult = Self.parsePointingCoordinates(from: textWithoutMemoryTags)
                var spokenText = parseResult.spokenText

                // M5.3 — risk gate: a risky task or run goal parks for a
                // spoken/typed yes-no instead of executing. The streamed plan
                // speech is dropped — the question replaces it. Plain replies
                // / GUIDE / DRAW never reach this point with a risky action.
                if let actionTask, RiskGate.isRiskyActionTask(actionTask) {
                    elevenLabsTTSClient.stopPlayback()
                    await parkRiskConfirmation(
                        .instantTask(actionTask, userMessageText: userMessageText, source: source),
                        question: RiskGate.confirmationQuestion(forActionTask: actionTask),
                        typedPlanText: nil,
                        speakReply: speakReply
                    )
                    return
                }
                if let runGoal = agentRunGoal ?? computerUseGoal, RiskGate.isRiskyRunGoal(runGoal) {
                    elevenLabsTTSClient.stopPlayback()
                    let riskGatePlanText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                    await parkRiskConfirmation(
                        .run(
                            goal: runGoal,
                            isUIStyleGoal: agentRunGoal == nil && computerUseGoal != nil,
                            planText: riskGatePlanText,
                            userMessageText: userMessageText,
                            source: source
                        ),
                        question: RiskGate.confirmationQuestion(forRunGoal: runGoal),
                        typedPlanText: riskGatePlanText,
                        speakReply: speakReply
                    )
                    return
                }

                if let actionTask {
                    // Tasks stay silent until they finish — drop any sentences
                    // the streaming path already queued (covers models that leak
                    // prose before the tag; tag-only replies never queue any).
                    elevenLabsTTSClient.stopPlayback()
                    spokenText = await executeActionTask(actionTask)
                    LazyLatency.mark("task-executed")
                    // The task ran detached from cancellation — if a new
                    // interaction interrupted this one mid-task, drop the
                    // outcome instead of speaking/appending it late.
                    guard !Task.isCancelled else { return }
                } else if let runGoal = agentRunGoal ?? computerUseGoal {
                    // M5.2 — [AGENT:] (file/shell work) and [GUI:] (UI
                    // clicking/typing) both execute through the unified tool
                    // loop; UI-style goals keep the legacy per-step loop as
                    // their keyless/direct-failure fallback inside
                    // executeAgentRun. The pre-tag plan text already streamed
                    // (spoken for voice, live bubble for typed) — now run the
                    // work and deliver the outcome afterwards.
                    let agentRunPlanText = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                    currentAgentRunPlanText = agentRunPlanText
                    if speakReply {
                        // M5.4 — voice doesn't speak run plans: drop any plan
                        // sentences the streamer already queued (the prompt
                        // enforces few-word plans, so little/no audio leaked);
                        // typed chat keeps the plan line in its transcript.
                        elevenLabsTTSClient.stopPlayback()
                        // Spinner for the duration of the run.
                        voiceState = .processing
                    }
                    let isUIStyleGoal = agentRunGoal == nil && computerUseGoal != nil
                    let agentRunOutcome = await executeAgentRun(
                        goal: runGoal,
                        source: source,
                        prefersComputerUseFallback: isUIStyleGoal
                    )
                    // The run detached from cancellation — if a new
                    // interaction interrupted it mid-run, drop the outcome
                    // instead of speaking/appending it late.
                    guard !Task.isCancelled else { return }

                    let agentRunOutcomeLine = Self.agentRunOutcomeLine(agentRunOutcome)

                    // Voice: the plan was already spoken — speak only the
                    // outcome. Typed: one transcript entry carrying plan +
                    // outcome (step lines stay out of the transcript).
                    if speakReply {
                        spokenText = agentRunOutcomeLine
                    } else {
                        var agentRunReplySections: [String] = []
                        if !agentRunPlanText.isEmpty {
                            agentRunReplySections.append(agentRunPlanText)
                        }
                        agentRunReplySections.append(agentRunOutcomeLine)
                        spokenText = agentRunReplySections.joined(separator: "\n\n")
                    }
                } else {
                    // [DRAW:...] tags become hand-drawn annotations the overlay
                    // renders on the matching screen. Tasks never draw.
                    applyScreenAnnotationTags(from: fullResponseText, screenCaptures: screenCaptures)

                    // [GUIDE:...] steps become an active walkthrough: card
                    // drives off the state, voice speaks only step 1, typed
                    // transcript carries the full numbered list.
                    if !guideSteps.isEmpty {
                        activeGuideSteps = guideSteps
                        activeGuideStepIndex = 0
                        flashGuideStepTarget(at: 0)
                        let firstStepLine = "Step 1: \(guideSteps[0].text)"
                        if speakReply {
                            spokenText += "\n\n\(firstStepLine)"
                        } else {
                            let numberedStepLines = guideSteps
                                .enumerated()
                                .map { "Step \($0.offset + 1): \($0.element.text)" }
                                .joined(separator: "\n")
                            spokenText += "\n\n\(numberedStepLines)"
                        }
                        print("🗺 Guide: walkthrough started (\(guideSteps.count) step(s))")
                    }

                    // [REMEMBER:...] / [MEMORY_CLEAR] tags update the durable
                    // user-facts store. Tasks never carry memory tags.
                    if Self.responseContainsMemoryClear(from: fullResponseText) {
                        clearRememberedFacts()
                    }
                    if let factToRemember = Self.parseRememberedFact(from: fullResponseText) {
                        rememberFact(factToRemember)
                    }
                }

                // Handle element pointing if coordinates were returned.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                // Task replies never point.
                let hasPointCoordinate = parseResult.coordinate != nil
                if actionTask == nil && agentRunGoal == nil && computerUseGoal == nil && hasPointCoordinate && speakReply {
                    voiceState = .idle
                }

                // Pick the screen capture matching the response's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if actionTask == nil,
                   agentRunGoal == nil,
                   computerUseGoal == nil,
                   let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    LazyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else if actionTask == nil && agentRunGoal == nil && computerUseGoal == nil {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: userMessageText,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                LazyAnalytics.trackAIResponseReceived(response: spokenText)

                if speakReply {
                    if actionTask != nil || agentRunGoal != nil || computerUseGoal != nil {
                        // Task, agent-run, and computer-use replies speak
                        // ONLY the outcome line, with no early-speech prefix
                        // bookkeeping — tasks dropped their queued sentences
                        // before executing; agent/computer-use runs already
                        // spoke the pre-tag plan via the streamer, so the
                        // outcome is new text.
                        await speakOutcomeLine(spokenText)
                    } else if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Play the response via TTS. Keep the spinner (processing state)
                        // until the audio actually starts playing, then switch to responding.

                        // Remove the sentences the streaming path already queued for
                        // speech so they aren't spoken a second time.
                        let unspokenReplyText: String
                        if alreadySpokenReplyPrefix.isEmpty || spokenText.hasPrefix(alreadySpokenReplyPrefix) {
                            unspokenReplyText = String(spokenText.dropFirst(alreadySpokenReplyPrefix.count))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            // Rare: streamed delta text didn't match the final reply.
                            print("⚠️ Early-spoken prefix mismatch — speaking full reply")
                            unspokenReplyText = spokenText
                        }

                        if !unspokenReplyText.isEmpty {
                            if replyNeedsSystemVoiceFallback || isElevenLabsVoiceDisabledToday {
                                // ElevenLabs already failed (or is locked out for
                                // the day) — drop the queue and speak the FULL
                                // reply, including any prefix the streamer counted
                                // as spoken but never made it to audio.
                                elevenLabsTTSClient.stopPlayback()
                                speakViaSystemVoice(spokenText)
                                LazyLatency.mark("tts-audio-started")
                            } else if alreadySpokenReplyPrefix.isEmpty {
                                // No streaming sentences arrived (SSE unavailable) —
                                // speak the whole reply in one shot, as before.
                                do {
                                    try await elevenLabsTTSClient.speakText(unspokenReplyText)
                                    LazyLatency.mark("tts-audio-started")
                                    // speakText returns after player.play() — audio is now playing
                                    voiceState = .responding
                                } catch {
                                    noteTTSSynthesisFailure(error)
                                    let failureReason = Self.classifyResponseError(error)
                                    LazyAnalytics.trackTTSError(error: "[voice] \(failureReason) | \(error.localizedDescription)")
                                    print("⚠️ ElevenLabs TTS error: \(error)")
                                    speakRealTextWithSystemVoice(reason: failureReason, detail: error.localizedDescription, text: unspokenReplyText)
                                }
                            } else {
                                // Early sentences are already queued — append the
                                // remainder; the queue plays it after they finish.
                                elevenLabsTTSClient.enqueueSentence(unspokenReplyText)
                                LazyLatency.mark("tts-remainder-queued")
                                voiceState = .responding
                            }
                        }
                    }
                } else {
                    // Typed: the final reply replaces the live streaming bubble.
                    chatStreamingReplyText = ""
                    chatIsResponding = false
                    appendChatMessage(role: .assistant, text: spokenText)
                }
            } catch is CancellationError {
                // User spoke again or typed a new message — response was interrupted
            } catch {
                let failureReason = Self.classifyResponseError(error)
                let classifiedReason = didFailOverToWorker
                    ? "my brain and my backup both failed — \(failureReason)"
                    : failureReason
                LazyAnalytics.trackResponseError(error: "[response] \(classifiedReason) | \(error.localizedDescription)")
                print("⚠️ Companion response error: \(error)")
                if speakReply {
                    speakFailureFallback(reason: classifiedReason, detail: error.localizedDescription)
                } else {
                    recordLastError("\(classifiedReason) — \(String(error.localizedDescription.prefix(160)))")
                    chatStreamingReplyText = ""
                    chatIsResponding = false
                    appendChatMessage(role: .assistant, text: "⚠️ \(error.localizedDescription)")
                }
            }

            if !Task.isCancelled && speakReply {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Notch Chat Window

    /// Toggles the notch chat sheet. Guarded by the same onboarding +
    /// permissions gate that shows the pill, so the ctrl+cmd+a hotkey can't
    /// open a broken sheet.
    func toggleNotchChat() {
        let isNotchChatAvailable = hasCompletedOnboarding && allPermissionsGranted && !showOnboardingVideo
        guard isNotchChatAvailable else {
            return
        }
        notchChatManager.toggle()
    }

    /// Pops the notch sheet's transcript into the resizable floating window
    /// (the sheet stays open — HeyClicky's expand flow).
    func expandNotchChatToWindow() {
        chatWindowController.showChatWindow()
    }

    /// Keeps the notch pill in sync with onboarding/permission state.
    /// Called from the permission poller (every 1.5s) and directly when
    /// the onboarding video starts/ends so the pill hides immediately.
    private func updateNotchChatPillVisibility() {
        let shouldShowPill = hasCompletedOnboarding && allPermissionsGranted && !showOnboardingVideo
        notchChatManager.setPillVisible(shouldShowPill)
    }

    /// Entry point for typed messages from the chat window's input field.
    func submitTypedMessage(_ messageText: String, fileAttachments: [ChatFileAttachment] = []) {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessageText.isEmpty else { return }
        lastTranscript = trimmedMessageText
        print("⌨️ Companion received typed message: \(trimmedMessageText)")
        if !fileAttachments.isEmpty {
            print("⌨️ Companion typed message carries \(fileAttachments.count) attachment(s)")
        }
        LazyAnalytics.trackUserMessageSent(transcript: trimmedMessageText)
        respond(to: trimmedMessageText, source: .typed, fileAttachments: fileAttachments)
    }

    private func appendChatMessage(role: ChatMessageRole, text: String) {
        chatMessages.append(ChatMessage(id: UUID(), role: role, text: text, sentAt: Date()))
        if chatMessages.count > Self.maximumPersistedChatMessageCount {
            chatMessages.removeFirst(chatMessages.count - Self.maximumPersistedChatMessageCount)
        }
        persistChatMessages()
    }

    private func persistChatMessages() {
        guard let encodedMessages = try? JSONEncoder().encode(chatMessages) else { return }
        UserDefaults.standard.set(encodedMessages, forKey: Self.persistedChatMessagesKey)
    }

    private func loadPersistedChatMessages() {
        guard let encodedMessages = UserDefaults.standard.data(forKey: Self.persistedChatMessagesKey),
              let decodedMessages = try? JSONDecoder().decode([ChatMessage].self, from: encodedMessages) else {
            return
        }
        chatMessages = decodedMessages
    }

    // MARK: - Scheduled Suggestion Delivery (M3)

    /// A morning-batch delivery (ReplySource.scheduled): announcement only —
    /// transcript entry + notch badge, never voice. The badge count mirrors
    /// through `unreadSuggestionCount`; opening the sheet or Home →
    /// Suggestions marks everything read.
    private func deliverScheduledSuggestions(_ cards: [LazySuggestion], source: ReplySource) {
        guard source == .scheduled else { return }
        let text = Self.scheduledAnnouncementText(for: cards)
        appendChatMessage(role: .assistant, text: text)
        LazyAnalytics.trackSuggestionDelivered(count: cards.count)
        print("📅 Scheduled suggestion batch (\(cards.count)) → badge \(proactiveEngine.unreadCount)")
    }

    private static func scheduledAnnouncementText(for cards: [LazySuggestion]) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 5..<12: greeting = "Good morning"
        case 12..<18: greeting = "Good afternoon"
        default: greeting = "Good evening"
        }
        let head = "\(greeting) — \(cards.count) thing\(cards.count == 1 ? "" : "s") waiting:"
        let bullets = cards.map { "• \($0.title) — \($0.body)" }
        return ([head] + bullets).joined(separator: "\n")
    }

    // MARK: - Streaming Reply Display

    /// Routes streamed reply text to the chat window's live assistant bubble
    /// for typed replies. Voice replies are audio-only — their streamed text
    /// is deliberately never displayed on screen.
    private func handleStreamedReplyDisplayUpdate(_ displayText: String, source: ReplySource) {
        guard source == .typed else { return }
        let trimmedDisplayText = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayText.isEmpty else { return }
        chatStreamingReplyText = trimmedDisplayText
    }

    /// Reply text with any trailing [POINT:...] tag removed — keeps streamed
    /// fallback text display-safe while deltas are still arriving.
    private static func displayTextWithoutPointTag(_ text: String) -> String {
        if let pointTagStartIndex = text.firstIndex(of: "[") {
            return String(text[..<pointTagStartIndex])
        }
        return text
    }

    /// If the cursor is in transient mode (user toggled "Show Lazy" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for on-screen drawings to finish their hold + fade
            // (annotations are cleared ~7s after being published)
            while !activeScreenAnnotations.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Voice Fallback State (stored here; delivered by +Speak.swift)

    /// True when a synthesis failure already forced this reply onto the
    /// system voice — set by the queue-failure callback and the single-shot
    /// catch paths, reset at the start of every interaction.
    var replyNeedsSystemVoiceFallback = false

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Agent Run State (stored here; executed by +Runs.swift)

    /// One-line plan of the agent run currently executing — the text that
    /// streamed before the [AGENT:...] tag. Reused as the header of the
    /// typed chat run console and the final transcript entry.
    var currentAgentRunPlanText = ""

    /// Step log of the current agent run, one line per tool call — shown
    /// live in the typed chat bubble and appended to the final transcript
    /// entry with the outcome.
    var activeAgentRunProgressLines: [String] = []

    // MARK: - GUI Run State (stored here; executed by +Runs.swift)

    /// Indexed AX elements backing the CURRENT computer-use step's badged
    /// screenshot — [GUI_CLICK_EL:n] resolves against this. Refreshed every
    /// step before the brain reply arrives; also refreshed by the unified
    /// loop's screenshot tool (M5) for click_element.
    var activeStepIndexedElements: [IndexedAXElement] = []

    /// The badged cursor-screen capture backing the CURRENT unified-loop
    /// screenshot (M5) — ui click coordinates convert against it. Set by
    /// the screenshot tool, cleared at run start.
    var activeStepScreenshotCapture: CompanionScreenCapture?

    // MARK: - M5.3 Risk Confirmation State

    /// A risky action parked while its spoken/typed yes-or-no question is
    /// open. The park happens BEFORE the question is spoken, so a PTT
    /// re-press (which cancels the in-flight speaking task) can't lose the
    /// ask — the released utterance just answers it.
    enum PendingRiskConfirmation {
        case instantTask(ActionTask, userMessageText: String, source: ReplySource)
        case run(goal: String, isUIStyleGoal: Bool, planText: String, userMessageText: String, source: ReplySource)
        case draftSend(draftID: Int64, recipientName: String, previewBody: String, userMessageText: String, source: ReplySource)

        var source: ReplySource {
            switch self {
            case .instantTask(_, _, let replySource):
                return replySource
            case .run(_, _, _, _, let replySource):
                return replySource
            case .draftSend(_, _, _, _, let replySource):
                return replySource
            }
        }
    }

    /// The open confirmation ask; nil = nothing waiting.
    var pendingRiskConfirmation: PendingRiskConfirmation?

    /// 45 s auto-cancel timer for the open ask (cancelled when the ask is
    /// answered, superseded, or replaced by a fresh one).
    var riskConfirmationTimeoutTask: Task<Void, Never>?

    // MARK: - Guide State (walkthrough tutoring)

    /// One spoken/displayed step of an active [GUIDE:...] walkthrough.
    /// Target already converted to AppKit globals at parse time (with the
    /// reply's screen capture) so flashing later needs no re-capture.
    struct GuideStep {
        let text: String
        let targetGlobalPoint: CGPoint?
        let targetDisplayFrame: CGRect?
    }

    /// Steps of the active walkthrough — drives the sheet's checklist card
    /// and the local "next"/"done" pre-route. Replaced wholesale by the
    /// next GUIDE reply; empty = no walkthrough active.
    @Published var activeGuideSteps: [GuideStep] = []

    /// Index of the step currently highlighted/last spoken.
    @Published var activeGuideStepIndex: Int = 0

    // MARK: - Drawing Tag Parsing & Conversion

    /// A [DRAW:...] tag parsed from the reply, still in screenshot pixel
    /// space — converted to AppKit global coords later, once the target
    /// screen's capture (scale + frame) is known.
    private struct RawScreenAnnotation {
        let shapeKind: ScreenAnnotation.ShapeKind
        let points: [CGPoint]
        let screenNumber: Int?
    }

    /// Parses up to 3 [DRAW:kind x,y ... :screenN] tags from the reply.
    /// Malformed or degenerate tags are skipped; unknown kinds are ignored
    /// here (and stripped from display text by `stripScreenAnnotationTags`).
    private static func parseScreenAnnotationTags(from responseText: String) -> [RawScreenAnnotation] {
        let pattern = #"\[DRAW:(circle|arrow|underline|path)\s+([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullTextRange = NSRange(responseText.startIndex..., in: responseText)
        let tagMatches = regex.matches(in: responseText, range: fullTextRange)

        var rawAnnotations: [RawScreenAnnotation] = []
        for tagMatch in tagMatches.prefix(3) {
            guard let shapeNameRange = Range(tagMatch.range(at: 1), in: responseText),
                  let argumentRange = Range(tagMatch.range(at: 2), in: responseText) else {
                continue
            }
            let shapeName = String(responseText[shapeNameRange])
            var argumentText = String(responseText[argumentRange]).trimmingCharacters(in: .whitespaces)

            // Optional :screenN suffix, same convention as [POINT:...].
            var screenNumber: Int? = nil
            if let screenSuffixRange = argumentText.range(of: #":screen(\d+)$"#, options: .regularExpression) {
                let screenDigits = String(argumentText[screenSuffixRange]).filter { $0.isNumber }
                screenNumber = Int(screenDigits)
                argumentText = String(argumentText[..<screenSuffixRange.lowerBound])
            }

            var points: [CGPoint] = []
            for coordinateToken in argumentText.split(whereSeparator: { $0.isWhitespace }) {
                let coordinateComponents = coordinateToken.split(separator: ",")
                guard coordinateComponents.count == 2,
                      let pointX = Double(coordinateComponents[0]),
                      let pointY = Double(coordinateComponents[1]) else {
                    continue
                }
                points.append(CGPoint(x: pointX, y: pointY))
            }

            let shapeKind: ScreenAnnotation.ShapeKind
            let annotationPoints: [CGPoint]
            switch shapeName {
            case "circle":
                guard points.count >= 2, points[0] != points[1] else { continue }
                shapeKind = .circle
                annotationPoints = [points[0], points[1]]
            case "arrow":
                guard points.count >= 2, points[0] != points[1] else { continue }
                shapeKind = .arrow
                annotationPoints = [points[0], points[1]]
            case "underline":
                guard points.count >= 2, points[0] != points[1] else { continue }
                shapeKind = .underline
                annotationPoints = [points[0], points[1]]
            case "path":
                guard points.count >= 2 else { continue }
                shapeKind = .freehandPath
                annotationPoints = Array(points.prefix(60))
            default:
                continue
            }

            rawAnnotations.append(RawScreenAnnotation(
                shapeKind: shapeKind,
                points: annotationPoints,
                screenNumber: screenNumber
            ))
        }
        return rawAnnotations
    }

    /// Strips every [DRAW:...] tag so the remaining text goes through
    /// [POINT:...] parsing and display untagged.
    private static func stripScreenAnnotationTags(from responseText: String) -> String {
        let pattern = #"\s*\[DRAW:[^\]]+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return responseText }
        return regex.stringByReplacingMatches(
            in: responseText,
            range: NSRange(responseText.startIndex..., in: responseText),
            withTemplate: ""
        )
    }

    /// Converts screenshot-pixel points to AppKit global coordinates using
    /// the target screen's capture (scale pixel → point space, flip Y,
    /// offset by the display's global frame) — the same math as [POINT:...]
    /// but for an arbitrary list of points.
    private static func convertScreenshotPointsToGlobalCoordinates(
        _ points: [CGPoint],
        using screenCapture: CompanionScreenCapture
    ) -> [CGPoint] {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame
        return points.map { point in
            let clampedX = max(0, min(point.x, screenshotWidth))
            let clampedY = max(0, min(point.y, screenshotHeight))
            let displayLocalX = clampedX * (displayWidth / screenshotWidth)
            let displayLocalY = clampedY * (displayHeight / screenshotHeight)
            let appKitY = displayHeight - displayLocalY
            return CGPoint(
                x: displayLocalX + displayFrame.origin.x,
                y: appKitY + displayFrame.origin.y
            )
        }
    }

    /// Parses every [DRAW:...] tag in the reply, converts each tag's
    /// screenshot-pixel coordinates to AppKit global coords for its target
    /// screen, publishes the batch, and schedules its auto-clear. A reply
    /// without drawing tags leaves any existing drawings on their own timer.
    private func applyScreenAnnotationTags(from responseText: String, screenCaptures: [CompanionScreenCapture]) {
        let rawAnnotations = Self.parseScreenAnnotationTags(from: responseText)
        guard !rawAnnotations.isEmpty else { return }

        let convertedAnnotations: [ScreenAnnotation] = rawAnnotations.compactMap { rawAnnotation in
            let targetScreenCapture: CompanionScreenCapture? = {
                if let screenNumber = rawAnnotation.screenNumber,
                   screenNumber >= 1 && screenNumber <= screenCaptures.count {
                    return screenCaptures[screenNumber - 1]
                }
                return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
            }()
            guard let targetScreenCapture else { return nil }

            let globalPoints = Self.convertScreenshotPointsToGlobalCoordinates(
                rawAnnotation.points,
                using: targetScreenCapture
            )
            let annotationIdentifier = UUID()
            return ScreenAnnotation(
                id: annotationIdentifier,
                shapeKind: rawAnnotation.shapeKind,
                points: globalPoints,
                displayFrame: targetScreenCapture.displayFrame,
                wobbleSeed: UInt64(bitPattern: Int64(annotationIdentifier.hashValue))
            )
        }
        guard !convertedAnnotations.isEmpty else { return }

        activeScreenAnnotations = convertedAnnotations
        scheduleScreenAnnotationsClear()
        print("✏️ Screen annotations: \(convertedAnnotations.count) tag(s) published to overlay")
    }

    // MARK: - Guide (walkthrough) parsing & runtime

    /// Max steps one [GUIDE:...] reply may carry — longer walkthroughs get
    /// truncated at parse time (prompt caps at 6; this bounds a stray tag).
    private static let maximumGuideStepCount = 6

    /// Parses every [GUIDE:step] tag in order. An optional @x,y suffix
    /// (screenshot pixels) is converted to AppKit globals immediately using
    /// the reply's cursor-screen capture, so step activation later needs no
    /// re-capture. Malformed/empty steps are skipped.
    static func parseGuideSteps(
        from responseText: String,
        screenCaptures: [CompanionScreenCapture]
    ) -> [GuideStep] {
        let pattern = #"\[GUIDE:\s*([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let tagMatches = regex.matches(
            in: responseText,
            range: NSRange(responseText.startIndex..., in: responseText)
        )
        guard !tagMatches.isEmpty else { return [] }
        guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen })
                ?? screenCaptures.first else { return [] }

        var parsedSteps: [GuideStep] = []
        for tagMatch in tagMatches {
            guard parsedSteps.count < maximumGuideStepCount,
                  let stepTextRange = Range(tagMatch.range(at: 1), in: responseText) else { break }
            var stepText = String(responseText[stepTextRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            var targetGlobalPoint: CGPoint? = nil
            var targetDisplayFrame: CGRect? = nil
            if let targetSuffixRange = stepText.range(of: #"@\s*(\d+)\s*,\s*(\d+)\s*$"#, options: .regularExpression) {
                let targetSuffix = String(stepText[targetSuffixRange])
                let coordinateDigits = targetSuffix.filter { $0.isNumber || $0 == "," }
                let coordinateParts = coordinateDigits.split(separator: ",")
                if coordinateParts.count == 2,
                   let pixelX = Double(coordinateParts[0]),
                   let pixelY = Double(coordinateParts[1]),
                   let convertedPoint = Self.convertScreenshotPointsToGlobalCoordinates(
                       [CGPoint(x: pixelX, y: pixelY)],
                       using: cursorScreenCapture
                   ).first,
                   // B1 revised: out-of-bounds guesses (the model inventing
                   // coords for steps with nothing on screen to point at)
                   // drop the target instead of circling a random spot.
                   cursorScreenCapture.displayFrame.contains(convertedPoint) {
                    targetGlobalPoint = convertedPoint
                    targetDisplayFrame = cursorScreenCapture.displayFrame
                }
                stepText = String(stepText[..<targetSuffixRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }

            guard !stepText.isEmpty else { continue }
            parsedSteps.append(GuideStep(
                text: stepText,
                targetGlobalPoint: targetGlobalPoint,
                targetDisplayFrame: targetDisplayFrame
            ))
        }
        return parsedSteps
    }

    /// Strips every [GUIDE:...] tag so spoken/typed text stays clean.
    private static func stripGuideTags(from responseText: String) -> String {
        let pattern = #"\s*\[GUIDE:[^\]]+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return responseText }
        return regex.stringByReplacingMatches(
            in: responseText,
            range: NSRange(responseText.startIndex..., in: responseText),
            withTemplate: ""
        )
    }

    /// Local intent for an ACTIVE walkthrough: advance or finish. Strict
    /// whole-string phrases only — anything else is normal chat (with a
    /// guide running, "next step" of a DIFFERENT request falls to the brain).
    enum GuideIntent {
        case advance
        case finish
    }

    static func guideIntent(matching userMessageText: String) -> GuideIntent? {
        let normalizedText = userMessageText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        switch normalizedText {
        case "next", "next step", "keep going", "continue", "go on", "onward":
            return .advance
        case "done", "finish", "finished", "stop", "stop guiding", "stop the walkthrough",
             "end walkthrough", "end guide", "that's enough", "thats enough":
            return .finish
        default:
            return nil
        }
    }

    /// Delivers one guide step or the finish confirmation — shared by the
    /// voice/typed "next"/"done" pre-route and the card's buttons (buttons
    /// pass speakReply=false and skip the transcript append).
    // MARK: - M5.3 Risk Confirmation (park + deliver + execute)

    /// Parks a risky action and delivers its yes/no question: state first
    /// (a PTT re-press that cancels the speaking task can't lose the ask),
    /// then the 45 s auto-cancel timer, conversation history, and the
    /// question itself. Caller returns immediately after.
    private func parkRiskConfirmation(
        _ pendingConfirmation: PendingRiskConfirmation,
        question: String,
        typedPlanText: String?,
        speakReply: Bool
    ) async {
        pendingRiskConfirmation = pendingConfirmation
        riskConfirmationTimeoutTask?.cancel()
        let timeoutSource = pendingConfirmation.source
        riskConfirmationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.pendingRiskConfirmation != nil else { return }
            print("🛑 Risk confirmation: no answer in 45s — cleared")
            self.pendingRiskConfirmation = nil
            self.riskConfirmationTimeoutTask = nil
            if timeoutSource == .voice {
                await self.speakOutcomeLine("I didn't hear back, so I left it alone.")
            }
        }

        let originalUserMessage: String
        switch pendingConfirmation {
        case .instantTask(_, let userMessageText, _):
            originalUserMessage = userMessageText
        case .run(_, _, _, let userMessageText, _):
            originalUserMessage = userMessageText
        case .draftSend(_, _, _, let userMessageText, _):
            originalUserMessage = userMessageText
        }
        conversationHistory.append((
            userTranscript: originalUserMessage,
            assistantResponse: question
        ))
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }
        print("🛑 Risk gate: waiting for yes/no — \(question)")

        if speakReply {
            await speakOutcomeLine(question)
            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        } else {
            chatStreamingReplyText = ""
            chatIsResponding = false
            var questionTranscriptText = question
            if let typedPlanText, !typedPlanText.isEmpty {
                questionTranscriptText = typedPlanText + "\n\n" + question
            }
            appendChatMessage(role: .assistant, text: questionTranscriptText)
        }
    }

    /// Runs a user-confirmed parked action and returns the line to deliver:
    /// voice gets the outcome only; a confirmed run in typed chat carries
    /// plan + outcome (the locked plan+outcome transcript rule).
    private func executeParkedRiskConfirmation(
        _ pendingConfirmation: PendingRiskConfirmation,
        speakReply: Bool
    ) async -> String {
        switch pendingConfirmation {
        case .instantTask(let actionTask, _, _):
            print("🛑 Risk confirmation: yes — running \(actionTask)")
            let outcomeLine = await executeActionTask(actionTask)
            LazyLatency.mark("task-executed")
            return outcomeLine
        case .draftSend(let draftID, let recipientName, _, _, _):
            // The approval already happened (the yes); the draft service
            // re-verifies the body hash before anything leaves the machine.
            print("🛑 Risk confirmation: yes — sending draft \(draftID) to \(recipientName)")
            if speakReply {
                voiceState = .processing
            }
            return await mailManager.sendDraft(draftID)
        case .run(let goal, let isUIStyleGoal, let planText, _, let parkedSource):
            print("🛑 Risk confirmation: yes — running goal: \(goal)")
            if speakReply {
                voiceState = .processing
            }
            let runOutcome = await executeAgentRun(
                goal: goal,
                source: parkedSource,
                prefersComputerUseFallback: isUIStyleGoal
            )
            let outcomeLine = Self.agentRunOutcomeLine(runOutcome)
            if speakReply {
                return outcomeLine
            }
            let trimmedPlanText = planText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPlanText.isEmpty ? outcomeLine : trimmedPlanText + "\n\n" + outcomeLine
        }
    }

    func deliverGuideIntent(_ intent: GuideIntent, speakReply: Bool) -> String? {
        switch intent {
        case .advance:
            guard !activeGuideSteps.isEmpty else { return nil }
            if activeGuideStepIndex + 1 < activeGuideSteps.count {
                activeGuideStepIndex += 1
                flashGuideStepTarget(at: activeGuideStepIndex)
                print("🗺 Guide: step \(activeGuideStepIndex + 1)/\(activeGuideSteps.count)")
                return "Step \(activeGuideStepIndex + 1): \(activeGuideSteps[activeGuideStepIndex].text)"
            }
            return "That was the last step — say \"done\" to finish the walkthrough."
        case .finish:
            guard !activeGuideSteps.isEmpty else { return nil }
            activeGuideSteps = []
            activeGuideStepIndex = 0
            screenAnnotationsClearTask?.cancel()
            screenAnnotationsClearTask = nil
            activeScreenAnnotations = []
            print("🗺 Guide: walkthrough finished")
            return "Walkthrough finished."
        }
    }

    /// Card-tap entry point: runs the intent, then speaks the outcome line
    /// the way the voice "next"/"done" pre-route does (quota-lock → system
    /// voice fallback lives inside speakOutcomeLine). Spoken only — the
    /// transcript stays untouched, matching a voice walkthrough beat.
    /// M6.4 — "check my email" family (strict whole-phrase, no brain).
    static func isMailDigestIntent(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "check my email" || normalized == "check my mail"
            || normalized == "any new mail" || normalized == "any new email"
            || normalized == "what's in my inbox" || normalized == "read my email"
    }

    /// M6.4 — "reply to X [saying …]": the query is the sender-name /
    /// subject fragment the store LIKEs against; an optional "saying …"
    /// tail is the drafting instruction.
    static func mailReplyRequest(_ text: String) -> (query: String, instruction: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("reply to ") else { return nil }
        var rest = String(trimmed.dropFirst("reply to ".count))
        var instruction = ""
        if let range = rest.range(of: " saying ", options: .caseInsensitive) {
            instruction = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            rest = String(rest[..<range.lowerBound])
        }
        let query = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        guard query.count >= 2 else { return nil }
        return (query, instruction)
    }

    /// M6.3 — sticky-board capture intents (strict whole-phrase prefixes).
    /// Returns the outcome line to speak/append; nil = not a capture
    /// phrase (falls through to the brain unchanged).
    private func deliverBoardCaptureIntent(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        if normalized.hasPrefix("remind me to ") {
            let task = String(trimmed.dropFirst("remind me to ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            let due = NaturalDueParser.parse(task)
            mailManager.addReminderItem(title: task, dueAt: due)
            stickyBoardManager.show()
            if let due {
                return "Done — I'll remind you to \(task) at \(due.formatted(date: .omitted, time: .shortened))."
            }
            return "Done — I'll remind you to \(task) in a minute."
        }

        if normalized.hasPrefix("add todo ") || normalized.hasPrefix("add a todo ") {
            let prefix = normalized.hasPrefix("add a todo ") ? "add a todo " : "add todo "
            let task = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            stickyBoardManager.addItem(text: task)
            stickyBoardManager.show()
            return "Added to the board: \(task)."
        }

        if normalized.hasPrefix("note: ") {
            let task = String(trimmed.dropFirst("note: ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            mailManager.addTodoItem(title: task)
            stickyBoardManager.show()
            return "Noted — \(task)."
        }

        if normalized == "open the board" || normalized == "show the board" || normalized == "show my board" {
            stickyBoardManager.show()
            return "Here's the board."
        }
        if normalized == "hide the board" || normalized == "close the board" {
            stickyBoardManager.hide()
            return "Board hidden."
        }
        return nil
    }

    func deliverGuideIntentAndSpeak(_ intent: GuideIntent) {
        guard let guideOutcomeLine = deliverGuideIntent(intent, speakReply: true) else { return }
        Task { await speakOutcomeLine(guideOutcomeLine) }
    }

    /// Flashes a hand-drawn circle around the current step's target, using
    /// the same annotation renderer as [DRAW:...]. Skips when the step has
    /// no target or the reply already published DRAW annotations.
    func flashGuideStepTarget(at stepIndex: Int) {
        guard stepIndex >= 0, stepIndex < activeGuideSteps.count,
              let targetPoint = activeGuideSteps[stepIndex].targetGlobalPoint,
              let targetDisplayFrame = activeGuideSteps[stepIndex].targetDisplayFrame,
              activeScreenAnnotations.isEmpty else { return }
        let boxSize: CGFloat = 96
        let annotationIdentifier = UUID()
        activeScreenAnnotations = [ScreenAnnotation(
            id: annotationIdentifier,
            shapeKind: .circle,
            points: [
                CGPoint(x: targetPoint.x - boxSize / 2, y: targetPoint.y - boxSize / 2),
                CGPoint(x: targetPoint.x + boxSize / 2, y: targetPoint.y + boxSize / 2)
            ],
            displayFrame: targetDisplayFrame,
            wobbleSeed: UInt64(bitPattern: Int64(annotationIdentifier.hashValue))
        )]
        scheduleScreenAnnotationsClear()
    }

    // MARK: - Memory Tag Parsing & Facts

    private static let rememberedFactsUserDefaultsKey = "clickyRememberedFacts"
    static let lastErrorUserDefaultsKey = "clickyLastError"
    static let lastErrorTimestampUserDefaultsKey = "clickyLastErrorAt"
    static let ttsQuotaExhaustedDateUserDefaultsKey = "clickyTTSQuotaExhaustedDate"
    private static let maximumRememberedFactCount = 24
    private static let maximumRememberedFactCharacterCount = 200

    /// Stores a fact the user asked Clicky to remember ([REMEMBER:...] tag).
    /// Exact duplicates (case-insensitive) replace the old entry instead of
    /// piling up.
    private func rememberFact(_ rememberedFact: String) {
        let trimmedFact = String(rememberedFact.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maximumRememberedFactCharacterCount))
        guard !trimmedFact.isEmpty else { return }

        var updatedFacts = rememberedFacts.filter {
            $0.localizedCaseInsensitiveCompare(trimmedFact) != .orderedSame
        }
        updatedFacts.append(trimmedFact)
        if updatedFacts.count > Self.maximumRememberedFactCount {
            updatedFacts.removeFirst(updatedFacts.count - Self.maximumRememberedFactCount)
        }

        rememberedFacts = updatedFacts
        UserDefaults.standard.set(updatedFacts, forKey: Self.rememberedFactsUserDefaultsKey)
        print("🧠 Remembered facts: stored \"\(trimmedFact)\" (\(updatedFacts.count) total)")
    }

    /// Wipes all remembered facts ([MEMORY_CLEAR] tag).
    private func clearRememberedFacts() {
        rememberedFacts = []
        UserDefaults.standard.removeObject(forKey: Self.rememberedFactsUserDefaultsKey)
        print("🧠 Remembered facts cleared")
    }

    // MARK: - Personal Skills

    private static let userSkillsUserDefaultsKey = "clickyUserSkills"
    private static let maximumUserSkillCount = 20
    private static let maximumUserSkillNameCharacterCount = 24
    private static let maximumUserSkillPromptCharacterCount = 1_000

    /// Adds (or replaces by name) a personal skill. Returns false when the
    /// name or prompt doesn't meet the validation rules.
    @discardableResult
    func addUserSkill(named rawName: String, promptText rawPromptText: String) -> Bool {
        let normalizedSkillName = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trimmedPromptText = rawPromptText.trimmingCharacters(in: .whitespacesAndNewlines)

        let skillNameIsValid = !normalizedSkillName.isEmpty
            && normalizedSkillName.count <= Self.maximumUserSkillNameCharacterCount
            && normalizedSkillName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        let skillPromptIsValid = !trimmedPromptText.isEmpty

        guard skillNameIsValid, skillPromptIsValid else { return false }

        var updatedSkills = userSkills.filter { $0.name != normalizedSkillName }
        updatedSkills.append(UserSkill(
            id: UUID(),
            name: normalizedSkillName,
            promptText: String(trimmedPromptText.prefix(Self.maximumUserSkillPromptCharacterCount))
        ))
        updatedSkills.sort { $0.name < $1.name }
        if updatedSkills.count > Self.maximumUserSkillCount {
            updatedSkills.removeFirst(updatedSkills.count - Self.maximumUserSkillCount)
        }

        userSkills = updatedSkills
        persistUserSkills()
        print("✨ User skills: saved \"\(normalizedSkillName)\" (\(updatedSkills.count) total)")
        return true
    }

    func removeUserSkill(id skillID: UUID) {
        userSkills.removeAll { $0.id == skillID }
        persistUserSkills()
        print("✨ User skills: removed skill \(skillID.uuidString.prefix(8))")
    }

    /// Expands a "/name extra words" draft to the skill's prompt (plus the
    /// trailing words). Returns nil when the draft isn't a skill invocation
    /// or no skill matches the name.
    func expandedSkillDraftText(from draftText: String) -> String? {
        guard draftText.hasPrefix("/") else { return nil }

        let invocationBody = String(draftText.dropFirst())
        if let spaceIndex = invocationBody.firstIndex(of: " ") {
            let skillName = invocationBody[..<spaceIndex].lowercased()
            let trailingWords = invocationBody[spaceIndex...].trimmingCharacters(in: .whitespaces)
            guard let matchedSkill = userSkills.first(where: { $0.name == skillName }) else { return nil }
            return trailingWords.isEmpty
                ? matchedSkill.promptText
                : "\(matchedSkill.promptText) \(trailingWords)"
        }

        let skillName = invocationBody.lowercased()
        return userSkills.first { $0.name == skillName }?.promptText
    }

    private func persistUserSkills() {
        guard let encodedSkills = try? JSONEncoder().encode(userSkills) else { return }
        UserDefaults.standard.set(encodedSkills, forKey: Self.userSkillsUserDefaultsKey)
    }

    // MARK: - Attached & Referenced Files

    private static let maximumRequestFileAttachmentCount = 5
    private static let maximumImageAttachmentByteCount = 8 * 1024 * 1024
    private static let maximumTextAttachmentByteCount = 200 * 1024
    private static let maximumTextAttachmentCharacterCount = 80_000

    /// One file successfully read for a brain request.
    private struct LoadedFileAttachment {
        let displayName: String
        /// Re-encoded JPEG data — joins the request's image list.
        let imageData: Data?
        /// UTF-8 contents — injected as a framed text section.
        let textContents: String?
    }

    /// Reads one file for a brain request: decodable images (jpeg/png/heic/…)
    /// become JPEG data the bridge's proven screenshot path carries, and
    /// UTF-8 text becomes an inline section. Returns nil for anything
    /// unreadable, too large, or neither image nor text.
    private func loadFileAttachment(from fileURL: URL) -> LoadedFileAttachment? {
        let fileManager = FileManager.default
        guard let fileAttributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              (fileAttributes[.type] as? FileAttributeType) == .typeRegular,
              let fileSizeInBytes = fileAttributes[.size] as? Int,
              fileSizeInBytes > 0,
              fileSizeInBytes <= Self.maximumImageAttachmentByteCount else {
            return nil
        }

        guard let fileData = try? Data(contentsOf: fileURL) else { return nil }

        if let decodedImage = NSBitmapImageRep(data: fileData),
           let jpegData = decodedImage.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            return LoadedFileAttachment(
                displayName: fileURL.lastPathComponent,
                imageData: jpegData,
                textContents: nil
            )
        }

        if fileSizeInBytes <= Self.maximumTextAttachmentByteCount,
           let textContents = String(data: fileData, encoding: .utf8),
           !textContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LoadedFileAttachment(
                displayName: fileURL.lastPathComponent,
                imageData: nil,
                textContents: String(textContents.prefix(Self.maximumTextAttachmentCharacterCount))
            )
        }

        print("📎 Skipping \(fileURL.lastPathComponent): not a supported image or text file (or too large)")
        return nil
    }

    /// Folds a loaded attachment into the request payload: images join the
    /// screenshot list as their own labeled entries; text becomes a framed
    /// context section prepended to the user prompt.
    private func incorporate(
        _ loadedFileAttachment: LoadedFileAttachment,
        into labeledImages: inout [(data: Data, label: String)],
        fileContextSections: inout [String]
    ) {
        if let imageData = loadedFileAttachment.imageData {
            labeledImages.append((
                data: imageData,
                label: "Attached image file: \(loadedFileAttachment.displayName)"
            ))
            print("📎 Attached image: \(loadedFileAttachment.displayName) (\(imageData.count / 1024) KB)")
            return
        }

        if let textContents = loadedFileAttachment.textContents {
            fileContextSections.append("""
            The user attached or referenced a file named \(loadedFileAttachment.displayName):

            --- begin file \(loadedFileAttachment.displayName) ---
            \(textContents)
            --- end file \(loadedFileAttachment.displayName) ---
            """)
            print("📎 Attached text file: \(loadedFileAttachment.displayName) (\(textContents.count) chars)")
        }
    }

    /// Absolute or home-relative file paths mentioned in a transcript (voice
    /// or typed). The /Users/, /tmp/, /var/, ~/ prefixes keep casual numbers
    /// ("version 2.0") from matching; directories and unreadable paths are
    /// filtered out later by `loadFileAttachment`.
    static func referencedFilePaths(in transcriptText: String) -> [String] {
        guard let pathRegex = try? NSRegularExpression(
            pattern: #"(?:^|[\s"'(])((?:/Users/|/tmp/|/var/|~/)[^\s"'()<>,;:]+)"#
        ) else { return [] }

        let transcriptRange = NSRange(transcriptText.startIndex..., in: transcriptText)
        var referencedPaths: [String] = []
        pathRegex.enumerateMatches(in: transcriptText, range: transcriptRange) { match, _, _ in
            guard let match, let pathRange = Range(match.range(at: 1), in: transcriptText) else { return }
            let referencedPath = String(transcriptText[pathRange])
            guard !referencedPaths.contains(referencedPath) else { return }
            referencedPaths.append(referencedPath)
        }

        if referencedPaths.count > Self.maximumRequestFileAttachmentCount {
            referencedPaths = Array(referencedPaths.prefix(Self.maximumRequestFileAttachmentCount))
        }

        return referencedPaths.map { referencedPath in
            (referencedPath as NSString).expandingTildeInPath
        }
    }

    /// The fact inside a [REMEMBER: ...] tag, or nil when the reply has none.
    static func parseRememberedFact(from responseText: String) -> String? {
        guard let tagRegex = try? NSRegularExpression(pattern: #"\[REMEMBER: ([^\]]+)\]"#) else { return nil }
        let responseRange = NSRange(responseText.startIndex..., in: responseText)
        guard let match = tagRegex.firstMatch(in: responseText, range: responseRange),
              let factRange = Range(match.range(at: 1), in: responseText) else { return nil }
        return String(responseText[factRange])
    }

    /// Whether the reply asks to wipe all remembered facts ([MEMORY_CLEAR]).
    static func responseContainsMemoryClear(from responseText: String) -> Bool {
        responseText.contains("[MEMORY_CLEAR]")
    }

    /// Removes [REMEMBER: ...] and [MEMORY_CLEAR] tags so they're never
    /// spoken, displayed, or stored in conversation history.
    static func stripMemoryTags(from responseText: String) -> String {
        var strippedText = responseText
        if let tagRegex = try? NSRegularExpression(pattern: #"\s*\[REMEMBER: [^\]]+\]"#) {
            strippedText = tagRegex.stringByReplacingMatches(
                in: strippedText,
                range: NSRange(strippedText.startIndex..., in: strippedText),
                withTemplate: ""
            )
        }
        if let tagRegex = try? NSRegularExpression(pattern: #"\s*\[MEMORY_CLEAR\]"#) {
            strippedText = tagRegex.stringByReplacingMatches(
                in: strippedText,
                range: NSRange(strippedText.startIndex..., in: strippedText),
                withTemplate: ""
            )
        }
        return strippedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dictation Text Insertion

    /// Posts the dictated transcript as synthetic keyboard events into
    /// whatever app is frontmost right now (the clicky panels never take
    /// focus, so that's the user's app — or the notch chat input if it's
    /// focused). Accessibility trust is already required for the global
    /// push-to-talk event tap, so posting keystrokes needs no new permission.
    func typeDictatedTextAtCursor(_ dictatedText: String) {
        let trimmedDictatedText = dictatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDictatedText.isEmpty else { return }

        print("⌨️ Companion dictation inserting at cursor: \(trimmedDictatedText)")

        var textToInsert = trimmedDictatedText
        if let lastDictatedTextInsertedAtCursor,
           let previousInsertedLastCharacter = lastDictatedTextInsertedAtCursor.last,
           previousInsertedLastCharacter.isLetter || previousInsertedLastCharacter.isNumber,
           let dictatedFirstCharacter = textToInsert.first,
           !Self.dictationInsertionNoSpaceBeforeCharacters.contains(dictatedFirstCharacter) {
            // Our previous dictation ended mid-word and this one doesn't start
            // with closing punctuation — insert a word-separating space, since
            // two utterances into the same field would otherwise butt together.
            textToInsert = " " + textToInsert
        }

        activeDictationInsertionTask?.cancel()

        // Recorded before the keystrokes land — the spacing rule only needs
        // "the last text we started inserting", and touching state from the
        // detached posting task would need a cross-actor hop for no benefit.
        lastDictatedTextInsertedAtCursor = textToInsert

        let textCharacters = Array(textToInsert)
        let dictationInsertionTask = Task.detached(priority: .userInitiated) {
            let keyboardEventSource = CGEventSource(stateID: .hidSystemState)

            for textCharacter in textCharacters {
                if Task.isCancelled { return }
                Self.postTypedCharacter(textCharacter, keyboardEventSource: keyboardEventSource)
                try? await Task.sleep(for: .microseconds(600))
            }
        }
        activeDictationInsertionTask = dictationInsertionTask
    }

    /// Closing punctuation and quotes that must not get a space before them
    /// when a new dictated utterance follows a word-ending one.
    private static let dictationInsertionNoSpaceBeforeCharacters: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\u{201D}"
    ]

    nonisolated static func postTypedCharacter(
        _ typedCharacter: Character,
        keyboardEventSource: CGEventSource?
    ) {
        // Return and Tab are posted by keycode instead of unicode — a
        // unicode "\n"/"\t" event isn't honored by every field (terminals
        // especially), while the real key codes behave everywhere.
        if typedCharacter == "\n" {
            postTypedKeyCode(36, keyboardEventSource: keyboardEventSource) // Return
            return
        }

        if typedCharacter == "\t" {
            postTypedKeyCode(48, keyboardEventSource: keyboardEventSource) // Tab
            return
        }

        // A Character's UTF-16 view covers multi-scalar glyphs (emoji, flags)
        // in a single key event.
        let utf16CodeUnits = Array(typedCharacter.utf16)

        let keyDownEvent = CGEvent(
            keyboardEventSource: keyboardEventSource,
            virtualKey: 0,
            keyDown: true
        )
        utf16CodeUnits.withUnsafeBufferPointer { utf16CodeUnitBuffer in
            keyDownEvent?.keyboardSetUnicodeString(
                stringLength: utf16CodeUnitBuffer.count,
                unicodeString: utf16CodeUnitBuffer.baseAddress
            )
        }
        keyDownEvent?.post(tap: .cghidEventTap)

        let keyUpEvent = CGEvent(
            keyboardEventSource: keyboardEventSource,
            virtualKey: 0,
            keyDown: false
        )
        utf16CodeUnits.withUnsafeBufferPointer { utf16CodeUnitBuffer in
            keyUpEvent?.keyboardSetUnicodeString(
                stringLength: utf16CodeUnitBuffer.count,
                unicodeString: utf16CodeUnitBuffer.baseAddress
            )
        }
        keyUpEvent?.post(tap: .cghidEventTap)
    }

    nonisolated static func postTypedKeyCode(
        _ keyCode: CGKeyCode,
        keyboardEventSource: CGEventSource?
    ) {
        let keyDownEvent = CGEvent(
            keyboardEventSource: keyboardEventSource,
            virtualKey: keyCode,
            keyDown: true
        )
        keyDownEvent?.post(tap: .cghidEventTap)

        let keyUpEvent = CGEvent(
            keyboardEventSource: keyboardEventSource,
            virtualKey: keyCode,
            keyDown: false
        )
        keyUpEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        updateNotchChatPillVisibility()

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            LazyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            LazyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        updateNotchChatPillVisibility()
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
