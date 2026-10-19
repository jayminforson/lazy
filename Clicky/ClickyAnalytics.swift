//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//

import Foundation
import PostHog

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {
        let config = PostHogConfig(
            apiKey: "phc_xcQPygmhTMzzYh8wNW92CCwoXmnzqyChAixh8zgpqC3C",
            host: "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture("app_opened", properties: [
            "app_version": version
        ])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        PostHogSDK.shared.capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        PostHogSDK.shared.capture("onboarding_replayed")
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        PostHogSDK.shared.capture("onboarding_video_completed")
    }

    /// The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {
        PostHogSDK.shared.capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        PostHogSDK.shared.capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        PostHogSDK.shared.capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        PostHogSDK.shared.capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        PostHogSDK.shared.capture("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    static func trackUserMessageSent(transcript: String) {
        PostHogSDK.shared.capture("user_message_sent", properties: [
            "transcript": transcript,
            "character_count": transcript.count
        ])
    }

    /// Claude responded and the response is being spoken via TTS.
    static func trackAIResponseReceived(response: String) {
        PostHogSDK.shared.capture("ai_response_received", properties: [
            "response": response,
            "character_count": response.count
        ])
    }

    /// Claude's response included a [POINT:x,y:label] coordinate tag,
    /// so the buddy is flying to point at a UI element.
    static func trackElementPointed(elementLabel: String?) {
        PostHogSDK.shared.capture("element_pointed", properties: [
            "element_label": elementLabel ?? "unknown"
        ])
    }

    // MARK: - Chat Window

    /// User opened the notch chat sheet (pill tap or ctrl+cmd+a).
    static func trackNotchChatOpened() {
        PostHogSDK.shared.capture("notch_chat_opened")
    }

    // MARK: - Agent Runs (computer-use)

    /// A [AGENT:...] computer-use run started (file/shell work via the
    /// OpenCode agent's tools in a dedicated session).
    static func trackAgentRunStarted(source: String) {
        PostHogSDK.shared.capture("agent_run_started", properties: [
            "source": source
        ])
    }

    /// An agent run finished within its caps and produced an outcome.
    static func trackAgentRunCompleted(durationMilliseconds: Int, toolCallCount: Int) {
        PostHogSDK.shared.capture("agent_run_completed", properties: [
            "duration_ms": durationMilliseconds,
            "tool_call_count": toolCallCount
        ])
    }

    /// An agent run stopped before completing: cancelled by the user,
    /// hit a cap (timeout/tool limit), or failed with an error.
    static func trackAgentRunAborted(reason: String) {
        PostHogSDK.shared.capture("agent_run_aborted", properties: [
            "reason": reason
        ])
    }

    // MARK: - Computer-Use Runs (GUI click/type agent)

    /// A [GUI:...] computer-use run started (clicking/typing through
    /// visible apps step by step).
    static func trackComputerUseRunStarted(source: String) {
        PostHogSDK.shared.capture("computer_use_run_started", properties: [
            "source": source
        ])
    }

    /// A computer-use run reached GUI_DONE within its caps.
    static func trackComputerUseRunCompleted(durationMilliseconds: Int, stepCount: Int) {
        PostHogSDK.shared.capture("computer_use_run_completed", properties: [
            "duration_ms": durationMilliseconds,
            "step_count": stepCount
        ])
    }

    /// A computer-use run stopped before GUI_DONE: cancelled, timed out,
    /// hit the step limit, produced consecutive invalid replies, or failed.
    static func trackComputerUseRunAborted(reason: String) {
        PostHogSDK.shared.capture("computer_use_run_aborted", properties: [
            "reason": reason
        ])
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        PostHogSDK.shared.capture("response_error", properties: [
            "error": error
        ])
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        PostHogSDK.shared.capture("tts_error", properties: [
            "error": error
        ])
    }

    // MARK: - Proactivity (M3)

    /// A scheduled suggestion batch reached the user (morning notch badge).
    static func trackSuggestionDelivered(count: Int) {
        PostHogSDK.shared.capture("suggestion_delivered", properties: [
            "count": count
        ])
    }
}
