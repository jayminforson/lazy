//
//  CompanionManager+Speak.swift
//  Clicky
//
//  Truthful failure delivery: error classification, the last-error chip, ElevenLabs quota/failure handling, and system-voice speaking paths.
//  Split from CompanionManager.swift — same type, other file.
//

import AVFoundation
import Combine
import Foundation
import IOKit
import PostHog
import ScreenCaptureKit
import SwiftUI

extension CompanionManager {
    // MARK: - Truthful Failure Delivery

    /// Why a reply failed, in words Clicky can honestly say out loud. Used
    /// for the system-voice fallback, the panel's last-error chip, and the
    /// PostHog error class tag — never a canned joke that masks the cause.
    static func classifyResponseError(_ error: Error) -> String {
        let nsError = error as NSError
        let text = nsError.localizedDescription
        let lower = text.lowercased()
        if nsError.domain == "ElevenLabsTTS" {
            return "my voice service failed, so I'm using my system voice."
        }
        if lower.contains("free tier") || lower.contains("rate limit")
            || lower.contains("too many requests") || lower.contains("http 429") {
            return "my free brain is rate-limited right now — try again in a minute."
        }
        if lower.contains("http 500") || lower.contains("http 502") || lower.contains("http 503")
            || lower.contains("http 504") || lower.contains("service unavailable")
            || lower.contains("upstream") || lower.contains("timed out") || lower.contains("timeout")
            || lower.contains("internal server error") {
            return "my brain provider is having trouble — try again shortly."
        }
        if lower.contains("connection") || lower.contains("network") || lower.contains("not connected")
            || lower.contains("did not start") || lower.contains("server did not") || lower.contains("offline") {
            return "I can't reach my local brain — is the opencode server running?"
        }
        return "something went wrong: \(String(text.prefix(140)))"
    }

    /// Persists the last failure so the panel can show it after a restart —
    /// next time, no console archaeology needed to name the broken leg.
    func recordLastError(_ message: String) {
        let stamp = Date()
        UserDefaults.standard.set(message, forKey: CompanionManager.lastErrorUserDefaultsKey)
        UserDefaults.standard.set(stamp.timeIntervalSince1970, forKey: CompanionManager.lastErrorTimestampUserDefaultsKey)
        lastErrorText = message
        lastErrorDate = stamp
    }


    /// The day ElevenLabs quota died. While it equals today, every voice
    /// reply skips ElevenLabs entirely (system voice); a stored date from a
    /// previous day means the free quota may have reset, so ElevenLabs is
    /// retried once and re-locks on the next 4xx quota error.
    var isElevenLabsVoiceDisabledToday: Bool {
        guard let storedStamp = UserDefaults.standard.string(
            forKey: CompanionManager.ttsQuotaExhaustedDateUserDefaultsKey
        ) else { return false }
        return storedStamp == Self.dayStampFormatter.string(from: Date())
    }

    private static let dayStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Called for every non-transient ElevenLabs synthesis failure (queue
    /// callback and single-shot catches). Marks the current reply for
    /// system-voice speech; on a real quota error it also locks voice to the
    /// system voice for the rest of the day and records the chip once.
    func noteTTSSynthesisFailure(_ error: Error) {
        replyNeedsSystemVoiceFallback = true
        let nsError = error as NSError
        let lowerDescription = nsError.localizedDescription.lowercased()
        let isQuotaFailure = nsError.domain == "ElevenLabsTTS"
            && (nsError.code == 401 || nsError.code == 403
                || lowerDescription.contains("quota") || lowerDescription.contains("exceed"))
        guard isQuotaFailure else { return }
        let todayStamp = Self.dayStampFormatter.string(from: Date())
        guard UserDefaults.standard.string(
            forKey: CompanionManager.ttsQuotaExhaustedDateUserDefaultsKey
        ) != todayStamp else { return }
        UserDefaults.standard.set(todayStamp, forKey: CompanionManager.ttsQuotaExhaustedDateUserDefaultsKey)
        recordLastError("my voice service failed, so I'm using my system voice. — \(nsError.localizedDescription.prefix(160))")
        LazyAnalytics.trackTTSError(error: "[tts-quota] \(nsError.localizedDescription)")
        print("🔇 ElevenLabs quota exhausted — system voice for the rest of today")
    }

    /// Speaks an honest failure line via the macOS system voice — works
    /// even when ElevenLabs itself is the thing that failed.
    func speakFailureFallback(reason: String, detail: String) {
        recordLastError("\(reason) — \(String(detail.prefix(160)))")
        speakViaSystemVoice(reason)
    }

    /// When ElevenLabs fails on a reply whose real text we still have,
    /// speak THAT through the system voice instead of hiding it behind a
    /// canned line — the user always hears what actually happened.
    func speakRealTextWithSystemVoice(reason: String, detail: String, text: String) {
        recordLastError("\(reason) — \(String(detail.prefix(160)))")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Phase 0 (locked): NO failure preamble in front of real content —
        // the reason only lands in the last-error chip. Only when somehow
        // no text exists is the honest reason all there is to say.
        speakViaSystemVoice(trimmed.isEmpty ? reason : trimmed)
    }

    /// One-shot system-voice playback (NSSpeechSynthesizer self-retains
    /// for the utterance). Kept in a single function so the macOS 14
    /// deprecation warnings stay at their baseline count.
    func speakViaSystemVoice(_ utterance: String) {
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        LazyLatency.markFirstTTSPaudio()
        voiceState = .responding
    }

    /// Speaks a task/agent/GUI/pre-route OUTCOME line for voice: system
    /// voice when ElevenLabs failed or is locked out for the day, ElevenLabs
    /// otherwise, with the system-voice real-content fallback on error
    /// (Phase 0: reason → chip only, content → audio).
    func speakOutcomeLine(_ outcomeLine: String) async {
        guard !outcomeLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if replyNeedsSystemVoiceFallback || isElevenLabsVoiceDisabledToday {
            speakViaSystemVoice(outcomeLine)
            LazyLatency.mark("task-audio-started")
            return
        }
        do {
            try await elevenLabsTTSClient.speakText(outcomeLine)
            LazyLatency.mark("task-audio-started")
            voiceState = .responding
        } catch {
            noteTTSSynthesisFailure(error)
            let failureReason = Self.classifyResponseError(error)
            LazyAnalytics.trackTTSError(error: "[voice] \(failureReason) | \(error.localizedDescription)")
            print("⚠️ ElevenLabs TTS error: \(error)")
            speakRealTextWithSystemVoice(reason: failureReason, detail: error.localizedDescription, text: outcomeLine)
        }
    }

}
