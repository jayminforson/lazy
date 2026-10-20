//
//  CompanionManager+Actions.swift
//  Clicky
//
//  Action task parsing/execution and the instant local pre-route (volume, brightness, screenshot, playback, open/quit app).
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
    // MARK: - Action Task Parsing & Execution

    /// One executable action parsed from a [TASK:...] tag in the model's
    /// reply. Tasks run silently — nothing is spoken while the task executes —
    /// the app only speaks (voice) or appends (typed) the outcome line after.
    enum ActionTask {
        case openApp(appName: String)
        case quitApp(appName: String)
        case volumeUp
        case volumeDown
        case volumeMute
        case volumeUnmute
        case volumeSet(percent: Int)
        case brightnessUp
        case brightnessDown
        case brightnessSet(percent: Int)
        case screenshot
        case mediaPlay
        case mediaPause
        case mediaNext
        case mediaPrevious
        case setDarkMode(enabled: Bool?)
        case wifi(enabled: Bool?)
        case lockScreen
        case sleepDisplay
        case emptyTrash
        case quitAllApps
        case openURL(String)
    }

    /// Parses a [TASK:open Spotify]-style action tag anywhere in the model's
    /// reply (mirrors the [POINT:...] tag). Returns nil when no valid tag is
    /// present — those replies go through the normal conversational flow
    /// unchanged.
    static func parseActionTaskTag(from responseText: String) -> ActionTask? {
        let pattern = #"\[TASK:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagContentRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }

        let tagContent = String(responseText[tagContentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tagTokens = tagContent.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let actionName = tagTokens.first.map({ String($0).lowercased() }) else { return nil }
        let actionArgument = tagTokens.count > 1
            ? String(tagTokens[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        switch actionName {
        case "open":
            guard !actionArgument.isEmpty else { return nil }
            // Link / settings-pane form — routed straight to `open(1)`.
            if let urlText = Self.normalizedOpenURL(from: actionArgument) {
                return .openURL(urlText)
            }
            return .openApp(appName: actionArgument)
        case "quit", "close":
            guard !actionArgument.isEmpty else { return nil }
            return .quitApp(appName: actionArgument)
        case "volume":
            return parseVolumeActionArgument(actionArgument)
        case "brightness":
            return parseBrightnessActionArgument(actionArgument)
        case "screenshot":
            return .screenshot
        case "play", "resume":
            return .mediaPlay
        case "pause", "stop":
            return .mediaPause
        case "next":
            return .mediaNext
        case "prev", "previous":
            return .mediaPrevious
        case "darkmode", "dark":
            switch actionArgument.lowercased().trimmingCharacters(in: .whitespaces) {
            case "on", "enable", "enabled", "true", "turn on": return .setDarkMode(enabled: true)
            case "off", "disable", "disabled", "false", "turn off": return .setDarkMode(enabled: false)
            case "", "toggle", "switch": return .setDarkMode(enabled: nil)
            default: return nil
            }
        case "wifi":
            switch actionArgument.lowercased().trimmingCharacters(in: .whitespaces) {
            case "on", "enable", "enabled", "true", "turn on": return .wifi(enabled: true)
            case "off", "disable", "disabled", "false", "turn off": return .wifi(enabled: false)
            case "", "toggle", "switch": return .wifi(enabled: nil)
            default: return nil
            }
        case "lock", "lockscreen":
            return .lockScreen
        case "sleepdisplay", "displayoff", "sleep":
            return .sleepDisplay
        case "emptytrash", "emptybin":
            return .emptyTrash
        case "quitall", "quitallapps", "closeall":
            return .quitAllApps
        default:
            return nil
        }
    }

    /// Shape check for [TASK:open …] / pre-route arguments that should open
    /// as a URL instead of resolving as an app: known schemes pass through,
    /// bare domains get https:// prepended, anything else returns nil.
    static func normalizedOpenURL(from argumentText: String) -> String? {
        let trimmedText = argumentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }
        let loweredText = trimmedText.lowercased()
        for knownScheme in ["https://", "http://", "x-app:", "mailto:", "file:", "shortcuts://"] {
            if loweredText.hasPrefix(knownScheme) { return trimmedText }
        }
        if loweredText.contains("://") { return nil }
        let bareDomainPattern = #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:[0-9]+)?(/[^ ]*)?$"#
        guard trimmedText.range(of: bareDomainPattern, options: .regularExpression) != nil else { return nil }
        return "https://" + trimmedText
    }

    /// Strips every [TASK:...] tag from the reply so the remaining text can
    /// go through [POINT:...] parsing and display untagged.
    static func stripActionTaskTag(from responseText: String) -> String {
        let pattern = #"\s*\[TASK:[^\]]+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return responseText }
        return regex.stringByReplacingMatches(
            in: responseText,
            range: NSRange(responseText.startIndex..., in: responseText),
            withTemplate: ""
        )
    }

    /// Parses a [AGENT: ...] computer-use run tag from the model's reply —
    /// the one-line plan for multi-step file/shell work that the app then
    /// executes with the OpenCode agent's tools in a dedicated run.
    /// Returns nil when no tag is present.
    static func parseAgentRunTag(from responseText: String) -> String? {
        let pattern = #"\[AGENT:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagContentRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }
        let tagContent = String(responseText[tagContentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tagContent.isEmpty ? nil : tagContent
    }

    /// Strips every [AGENT:...] tag from the reply so the remaining plan
    /// text can be spoken / displayed and run through the normal tag
    /// pipeline ([DRAW]/[MEMORY]/[POINT] stripping).
    static func stripAgentRunTag(from responseText: String) -> String {
        let pattern = #"\s*\[AGENT:[^\]]+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return responseText }
        return regex.stringByReplacingMatches(
            in: responseText,
            range: NSRange(responseText.startIndex..., in: responseText),
            withTemplate: ""
        )
    }

    /// True when a voice/typed message is just a stop/cancel command and an
    /// agent run is currently executing — those cancel the run instead of
    /// going to the brain (the run IS the live task; the word needs no reply).
    static func isAgentRunStopCommand(_ messageText: String) -> Bool {
        let normalizedMessageText = messageText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedMessageText == "stop"
            || normalizedMessageText == "cancel"
            || normalizedMessageText == "stop that"
            || normalizedMessageText == "cancel that"
            || normalizedMessageText == "stop the run"
            || normalizedMessageText == "cancel the run"
    }

    // MARK: - Instant Local Action Pre-Route

    private static let instantVolumeUpPhrases: Set<String> = [
        "volume up", "turn the volume up", "turn up the volume", "turn volume up",
        "raise the volume", "increase the volume", "make it louder"
    ]
    private static let instantVolumeDownPhrases: Set<String> = [
        "volume down", "turn the volume down", "turn down the volume", "turn volume down",
        "lower the volume", "decrease the volume", "make it quieter"
    ]
    private static let instantVolumeMutePhrases: Set<String> = [
        "mute", "mute the sound", "mute the volume", "mute the audio", "mute the music", "sound off"
    ]
    private static let instantVolumeUnmutePhrases: Set<String> = [
        "unmute", "unmute the sound", "unmute the volume", "sound on"
    ]
    private static let instantBrightnessUpPhrases: Set<String> = [
        "brightness up", "turn the brightness up", "turn up the brightness",
        "raise the brightness", "increase the brightness", "make it brighter"
    ]
    private static let instantBrightnessDownPhrases: Set<String> = [
        "brightness down", "turn the brightness down", "turn down the brightness",
        "lower the brightness", "decrease the brightness", "make it darker"
    ]
    private static let instantScreenshotPhrases: Set<String> = [
        "take a screenshot", "screenshot", "capture my screen", "capture the screen", "snap a screenshot"
    ]
    private static let instantMediaPlayPhrases: Set<String> = [
        "play", "resume", "play music", "play the music", "play some music", "play the song",
        "play this song", "continue playing", "continue the music", "resume the music",
        "resume playing", "keep playing", "play it again",
        "start playing", "start the music", "start music", "start the song", "start the playlist"
    ]
    private static let instantMediaPausePhrases: Set<String> = [
        "pause", "pause the music", "pause the song", "pause playback", "pause it",
        "stop the music", "stop the song", "stop playing"
    ]
    private static let instantMediaNextPhrases: Set<String> = [
        "next", "next track", "next song", "skip", "skip track", "skip the track",
        "skip the song", "skip this song", "skip to the next track", "skip to the next song",
        "play the next track", "play the next song"
    ]
    private static let instantMediaPreviousPhrases: Set<String> = [
        "previous", "previous track", "previous song", "previous one",
        "go to the previous track", "go to the previous song", "play the previous track",
        "back a track", "last track", "go back a track"
    ]
    private static let instantDarkModeOnPhrases: Set<String> = [
        "dark mode", "turn on dark mode", "enable dark mode", "switch to dark mode",
        "switch to dark", "make it dark", "use dark mode", "turn dark mode on"
    ]
    private static let instantDarkModeOffPhrases: Set<String> = [
        "light mode", "turn off dark mode", "disable dark mode", "switch to light mode",
        "switch to light", "make it light", "use light mode", "turn dark mode off"
    ]
    private static let instantDarkModeTogglePhrases: Set<String> = [
        "toggle dark mode", "switch dark mode", "toggle theme", "switch themes",
        "toggle dark and light"
    ]
    private static let instantWifiOnPhrases: Set<String> = [
        "wifi on", "turn on wifi", "enable wifi", "turn wifi on",
        "switch wifi on", "get wifi back", "turn the wifi on"
    ]
    private static let instantWifiOffPhrases: Set<String> = [
        "wifi off", "turn off wifi", "disable wifi", "turn wifi off",
        "switch wifi off", "turn the wifi off"
    ]
    private static let instantWifiTogglePhrases: Set<String> = [
        "toggle wifi", "switch wifi"
    ]
    private static let instantLockPhrases: Set<String> = [
        "lock my screen", "lock the screen", "lock screen", "lock my mac",
        "lock my computer", "lock computer", "lock this mac"
    ]
    private static let instantSleepDisplayPhrases: Set<String> = [
        "sleep the display", "sleep display", "turn off the display", "turn off my display",
        "turn off my screen", "turn the screen off", "turn the display off"
    ]
    private static let instantEmptyTrashPhrases: Set<String> = [
        "empty the trash", "empty trash", "clear the trash", "empty my trash"
    ]
    private static let instantQuitAllPhrases: Set<String> = [
        "quit all apps", "close all apps", "quit everything", "close everything",
        "quit all applications", "close all applications"
    ]

    /// Strict whole-string classifier for instant local actions. Returns a
    /// concrete ActionTask only when the message (after normalization +
    /// filler stripping) is EXACTLY one known command — open/quit additionally
    /// require the app to resolve / be running. Anything else returns nil and
    /// falls through to the brain, so ambiguity never gets misrouted.
    static func parseInstantLocalAction(_ messageText: String) -> ActionTask? {
        let normalizedText = normalizedInstantActionMessage(messageText)
        guard !normalizedText.isEmpty else { return nil }

        if instantVolumeUpPhrases.contains(normalizedText) { return .volumeUp }
        if instantVolumeDownPhrases.contains(normalizedText) { return .volumeDown }
        if instantVolumeMutePhrases.contains(normalizedText) { return .volumeMute }
        if instantVolumeUnmutePhrases.contains(normalizedText) { return .volumeUnmute }
        if let volumePercent = instantPercentValue(in: normalizedText, keyword: "volume") {
            return .volumeSet(percent: volumePercent)
        }
        if instantBrightnessUpPhrases.contains(normalizedText) { return .brightnessUp }
        if instantBrightnessDownPhrases.contains(normalizedText) { return .brightnessDown }
        if let brightnessPercent = instantPercentValue(in: normalizedText, keyword: "brightness") {
            return .brightnessSet(percent: brightnessPercent)
        }
        if instantScreenshotPhrases.contains(normalizedText) { return .screenshot }
        if instantMediaPlayPhrases.contains(normalizedText) { return .mediaPlay }
        if instantMediaPausePhrases.contains(normalizedText) { return .mediaPause }
        if instantMediaNextPhrases.contains(normalizedText) { return .mediaNext }
        if instantMediaPreviousPhrases.contains(normalizedText) { return .mediaPrevious }
        if instantDarkModeOnPhrases.contains(normalizedText) { return .setDarkMode(enabled: true) }
        if instantDarkModeOffPhrases.contains(normalizedText) { return .setDarkMode(enabled: false) }
        if instantDarkModeTogglePhrases.contains(normalizedText) { return .setDarkMode(enabled: nil) }
        if instantWifiOnPhrases.contains(normalizedText) { return .wifi(enabled: true) }
        if instantWifiOffPhrases.contains(normalizedText) { return .wifi(enabled: false) }
        if instantWifiTogglePhrases.contains(normalizedText) { return .wifi(enabled: nil) }
        if instantLockPhrases.contains(normalizedText) { return .lockScreen }
        if instantSleepDisplayPhrases.contains(normalizedText) { return .sleepDisplay }
        if instantEmptyTrashPhrases.contains(normalizedText) { return .emptyTrash }
        if instantQuitAllPhrases.contains(normalizedText) { return .quitAllApps }

        for openVerb in ["open", "launch", "start"] {
            guard let nameCandidate = instantActionArgument(verb: openVerb, in: normalizedText) else { continue }
            let cleanedAppName = cleanedInstantActionName(nameCandidate)
            guard !cleanedAppName.isEmpty else { continue }
            // Link / settings-pane shape opens straight away, no app resolution.
            if let instantURLText = Self.normalizedOpenURL(from: cleanedAppName) {
                return .openURL(instantURLText)
            }
            guard !cleanedAppName.contains("/"),
                  !cleanedAppName.contains("~"),
                  Self.resolveApplicationURL(named: cleanedAppName) != nil else { continue }
            return .openApp(appName: cleanedAppName)
        }

        for quitVerb in ["quit", "close", "exit"] {
            guard let nameCandidate = instantActionArgument(verb: quitVerb, in: normalizedText) else { continue }
            let cleanedAppName = cleanedInstantActionName(nameCandidate)
            guard !cleanedAppName.isEmpty else { continue }
            let isApplicationRunning = NSWorkspace.shared.runningApplications.contains {
                $0.localizedName?.caseInsensitiveCompare(cleanedAppName) == .orderedSame
            }
            guard isApplicationRunning else { continue }
            return .quitApp(appName: cleanedAppName)
        }

        return nil
    }

    /// Lowercases, swaps clause punctuation for spaces, trims edge
    /// punctuation, collapses whitespace, and strips leading politeness
    /// fillers ("hey clicky", "please", "can you", …) so the matcher sees a
    /// bare command string.
    private static func normalizedInstantActionMessage(_ messageText: String) -> String {
        var workingText = messageText.lowercased()
        for separatorCharacter in [",", ";", "!", "?"] {
            workingText = workingText.replacingOccurrences(of: separatorCharacter, with: " ")
        }
        workingText = workingText.trimmingCharacters(in: CharacterSet(charactersIn: " .:\"'“”‘’…"))
        workingText = workingText.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let leadingFillerPhrases = [
            "hey lazy ", "hi lazy ", "lazy ",
            "hey clicky ", "hi clicky ", "clicky ", "hey ", "hi ",
            "please ", "could you ", "can you ", "would you ", "will you ",
            "i need you to ", "i want you to ", "i'd like you to ",
            "go ahead and ", "just ", "ok ", "okay ", "now ", "actually "
        ]
        var hasStrippedFiller = true
        while hasStrippedFiller {
            hasStrippedFiller = false
            for fillerPhrase in leadingFillerPhrases {
                if workingText.hasPrefix(fillerPhrase) {
                    workingText = String(workingText.dropFirst(fillerPhrase.count))
                        .trimmingCharacters(in: .whitespaces)
                    hasStrippedFiller = true
                }
            }
        }
        return workingText
    }

    /// Value for "volume"/"brightness set" forms: strict full-string shape
    /// ("volume 40", "set volume to 40", "turn the brightness to 70") with an
    /// 0-100 range check; nil for anything else.
    private static func instantPercentValue(in normalizedText: String, keyword: String) -> Int? {
        let pattern = "^(?:set |turn )?(?:the )?"
            + keyword
            + " (?:to |at |up to |down to )?(\\d{1,3})\\s?%?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: normalizedText,
                range: NSRange(normalizedText.startIndex..., in: normalizedText)
              ),
              let valueRange = Range(match.range(at: 1), in: normalizedText),
              let percentValue = Int(normalizedText[valueRange]),
              (0...100).contains(percentValue) else {
            return nil
        }
        return percentValue
    }

    /// Argument after an action verb, dropping leading articles
    /// ("open the xcode" → "xcode"); nil when the verb isn't a prefix or no
    /// argument follows.
    private static func instantActionArgument(verb: String, in normalizedText: String) -> String? {
        guard normalizedText.hasPrefix(verb + " ") else { return nil }
        var argumentText = String(normalizedText.dropFirst(verb.count + 1))
        var hasStrippedArticle = true
        while hasStrippedArticle {
            hasStrippedArticle = false
            for leadingArticle in ["the ", "my ", "a ", "an "] {
                if argumentText.hasPrefix(leadingArticle) {
                    argumentText = String(argumentText.dropFirst(leadingArticle.count))
                    hasStrippedArticle = true
                }
            }
        }
        argumentText = argumentText.trimmingCharacters(in: .whitespaces)
        return argumentText.isEmpty ? nil : argumentText
    }

    /// Drops conversational tails and ".app"-style suffixes from an app-name
    /// argument ("spotify for me please" → "spotify").
    private static func cleanedInstantActionName(_ rawName: String) -> String {
        var cleanedName = rawName.trimmingCharacters(in: .whitespaces)
        for trailingPhrase in [" for me please", " for me", " please", " real quick", " right now"] {
            if cleanedName.hasSuffix(trailingPhrase) {
                cleanedName = String(cleanedName.dropLast(trailingPhrase.count))
            }
        }
        cleanedName = cleanedName.trimmingCharacters(in: .whitespaces)
        for appSuffix in [" application", " app"] {
            if cleanedName.hasSuffix(appSuffix) {
                cleanedName = String(cleanedName.dropLast(appSuffix.count))
            }
        }
        return cleanedName.trimmingCharacters(in: .whitespaces)
    }

    /// Parses a [GUI: ...] computer-use tag from the model's reply — the
    /// one-line goal for clicking/typing through visible apps that the app
    /// then executes step by step. Returns nil when no tag is present.
    /// (The underscore variants like [GUI_CLICK:x,y] only appear in the
    /// per-step loop replies, never in this plan reply — the colon
    /// immediately after GUI keeps the patterns disjoint.)
    static func parseComputerUseTag(from responseText: String) -> String? {
        let pattern = #"\[GUI:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let tagContentRange = Range(match.range(at: 1), in: responseText) else {
            return nil
        }
        let tagContent = String(responseText[tagContentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tagContent.isEmpty ? nil : tagContent
    }

    /// Strips every [GUI:...] plan tag from the reply so the remaining plan
    /// text can be spoken / displayed and run through the normal tag
    /// pipeline stripping.
    static func stripComputerUseTag(from responseText: String) -> String {
        let pattern = #"\s*\[GUI:[^\]]+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return responseText }
        return regex.stringByReplacingMatches(
            in: responseText,
            range: NSRange(responseText.startIndex..., in: responseText),
            withTemplate: ""
        )
    }

    /// Maps the argument of a [TASK:volume ...] tag ("up", "set 40", "to 40")
    /// to a concrete volume action.
    private static func parseVolumeActionArgument(_ actionArgument: String) -> ActionTask? {
        switch actionArgument.lowercased().trimmingCharacters(in: .whitespaces) {
        case "up": return .volumeUp
        case "down": return .volumeDown
        case "mute": return .volumeMute
        case "unmute": return .volumeUnmute
        default:
            let digitsOnly = actionArgument.filter { $0.isNumber }
            guard !digitsOnly.isEmpty,
                  let volumePercent = Int(digitsOnly),
                  (0...100).contains(volumePercent) else {
                return nil
            }
            return .volumeSet(percent: volumePercent)
        }
    }

    /// Maps the argument of a [TASK:brightness ...] tag to a concrete
    /// brightness action.
    private static func parseBrightnessActionArgument(_ actionArgument: String) -> ActionTask? {
        switch actionArgument.lowercased().trimmingCharacters(in: .whitespaces) {
        case "up": return .brightnessUp
        case "down": return .brightnessDown
        default:
            let digitsOnly = actionArgument.filter { $0.isNumber }
            guard !digitsOnly.isEmpty,
                  let brightnessPercent = Int(digitsOnly),
                  (0...100).contains(brightnessPercent) else {
                return nil
            }
            return .brightnessSet(percent: brightnessPercent)
        }
    }

    /// Runs the parsed action silently and returns the outcome line: success
    /// → "Done <action>", failure → a short "Couldn't …" message. Called with
    /// the spinner already showing (.processing) — no speech until this returns.
    func executeActionTask(_ actionTask: ActionTask) async -> String {
        switch actionTask {
        case .openApp(let appName):
            guard let applicationURL = Self.resolveApplicationURL(named: appName) else {
                print("⚠️ Task open failed: no app named \"\(appName)\"")
                return "Couldn't open \(appName)"
            }
            do {
                try await NSWorkspace.shared.openApplication(
                    at: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                print("✅ Task: opened \(appName)")
                return "Done opening \(appName)"
            } catch {
                print("⚠️ Task open failed: \(error)")
                return "Couldn't open \(appName)"
            }

        case .quitApp(let appName):
            guard let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
                $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
            }) else {
                print("⚠️ Task quit failed: \"\(appName)\" isn't running")
                return "\(appName) isn't running"
            }
            if runningApplication.terminate() {
                print("✅ Task: quitting \(appName)")
                return "Done closing \(appName)"
            }
            print("⚠️ Task quit failed: \(appName) refused to terminate")
            return "Couldn't close \(appName)"

        case .volumeUp, .volumeDown, .volumeMute, .volumeUnmute, .volumeSet:
            return await executeVolumeAction(actionTask)

        case .brightnessUp:
            // Synthetic media-key events (accessibility is already granted).
            postSystemDefinedMediaKey(keyType: Self.nxKeyTypeBrightnessUp, keyDown: true)
            postSystemDefinedMediaKey(keyType: Self.nxKeyTypeBrightnessUp, keyDown: false)
            print("✅ Task: brightness up (media key)")
            return "Done raising the brightness"

        case .brightnessDown:
            postSystemDefinedMediaKey(keyType: Self.nxKeyTypeBrightnessDown, keyDown: true)
            postSystemDefinedMediaKey(keyType: Self.nxKeyTypeBrightnessDown, keyDown: false)
            print("✅ Task: brightness down (media key)")
            return "Done lowering the brightness"

        case .brightnessSet(let brightnessPercent):
            // Absolute brightness goes through IOKit's IODisplayConnect service
            // (CGDisplaySetBrightness no longer exists in recent SDKs) —
            // built-in display only; external monitors don't expose a
            // writable brightness parameter.
            let clampedBrightness = Float(min(max(brightnessPercent, 0), 100)) / 100
            if setBuiltInDisplayBrightness(clampedBrightness) {
                print("✅ Task: brightness set to \(brightnessPercent)")
                return "Done setting the brightness to \(brightnessPercent)"
            }
            print("⚠️ Task brightness set failed: no writable built-in display")
            return "Couldn't change the brightness"

        case .screenshot:
            return await executeScreenshotAction()

        case .mediaPlay, .mediaPause, .mediaNext, .mediaPrevious:
            return await executeMediaAction(actionTask)

        case .setDarkMode, .wifi, .lockScreen, .sleepDisplay, .emptyTrash, .quitAllApps, .openURL:
            return await executeSystemControlAction(actionTask)
        }
    }

    /// Runs a playback action against the music app that is currently
    /// playing or paused (Spotify preferred, then Music) — whichever of the
    /// two running candidates has a non-stopped player state; falls back to
    /// the first running candidate so a stopped app still starts.
    private func executeMediaAction(_ actionTask: ActionTask) async -> String {
        guard let mediaTargetName = await resolveMediaTargetAppName() else {
            print("⚠️ Task media failed: no music app running")
            return "Couldn't do that — no music app is running"
        }
        let appleScriptCommand: String
        let outcomeLine: String
        switch actionTask {
        case .mediaPlay:
            appleScriptCommand = "play"
            outcomeLine = "Done playing in \(mediaTargetName)"
        case .mediaPause:
            appleScriptCommand = "pause"
            outcomeLine = "Done pausing \(mediaTargetName)"
        case .mediaNext:
            appleScriptCommand = "next track"
            outcomeLine = "Done skipping to the next track"
        case .mediaPrevious:
            appleScriptCommand = "previous track"
            outcomeLine = "Done going to the previous track"
        default:
            return "Couldn't do that"
        }
        guard await runAppleScript("tell application \"\(mediaTargetName)\" to \(appleScriptCommand)") != nil else {
            print("⚠️ Task media failed: \(mediaTargetName) rejected \"\(appleScriptCommand)\"")
            return "Couldn't control \(mediaTargetName)"
        }
        print("✅ Task: \(mediaTargetName) \(appleScriptCommand)")
        return outcomeLine
    }

    /// Name of the music app playback should target: Spotify or Music —
    /// whichever running candidate reports playing/paused first (candidate
    /// order prefers Spotify), else the first running one, else nil.
    private func resolveMediaTargetAppName() async -> String? {
        let candidates = ["Spotify", "Music"]
        let runningNames = candidates.filter { candidate in
            NSWorkspace.shared.runningApplications.contains {
                $0.localizedName?.caseInsensitiveCompare(candidate) == .orderedSame
            }
        }
        guard !runningNames.isEmpty else { return nil }
        for runningName in runningNames {
            guard let playerState = await runAppleScript(
                "tell application \"\(runningName)\" to player state as text"
            ) else { continue }
            let normalizedState = playerState.lowercased()
            if normalizedState.contains("playing") || normalizedState.contains("paused") {
                return runningName
            }
        }
        return runningNames.first
    }

    /// All volume actions go through `osascript` so they're verifiable —
    /// up/down read the current level first, then step it by 6%.
    private func executeVolumeAction(_ actionTask: ActionTask) async -> String {
        switch actionTask {
        case .volumeUp:
            guard let currentVolumeString = await runAppleScript("output volume of (get volume settings)"),
                  let currentVolumePercent = Int(currentVolumeString) else {
                return "Couldn't change the volume"
            }
            let steppedVolumePercent = min(currentVolumePercent + 6, 100)
            guard await runAppleScript("set volume output volume \(steppedVolumePercent)") != nil else {
                return "Couldn't change the volume"
            }
            print("✅ Task: volume \(currentVolumePercent) → \(steppedVolumePercent)")
            return "Done raising the volume"

        case .volumeDown:
            guard let currentVolumeString = await runAppleScript("output volume of (get volume settings)"),
                  let currentVolumePercent = Int(currentVolumeString) else {
                return "Couldn't change the volume"
            }
            let steppedVolumePercent = max(currentVolumePercent - 6, 0)
            guard await runAppleScript("set volume output volume \(steppedVolumePercent)") != nil else {
                return "Couldn't change the volume"
            }
            print("✅ Task: volume \(currentVolumePercent) → \(steppedVolumePercent)")
            return "Done lowering the volume"

        case .volumeMute:
            guard await runAppleScript("set volume with output muted") != nil else {
                return "Couldn't change the volume"
            }
            print("✅ Task: volume muted")
            return "Done muting the sound"

        case .volumeUnmute:
            guard await runAppleScript("set volume without output muted") != nil else {
                return "Couldn't change the volume"
            }
            print("✅ Task: volume unmuted")
            return "Done unmuting the sound"

        case .volumeSet(let volumePercent):
            guard await runAppleScript("set volume output volume \(volumePercent)") != nil else {
                return "Couldn't change the volume"
            }
            print("✅ Task: volume set to \(volumePercent)")
            return "Done setting the volume to \(volumePercent)"

        default:
            // Only volume cases are ever passed in from executeActionTask.
            return "Couldn't change the volume"
        }
    }

    /// Saves the cursor screen's screenshot to the Desktop and returns the
    /// outcome line. Reuses the shared ScreenCaptureKit capture utility.
    private func executeScreenshotAction() async -> String {
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let screenshotCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first else {
                print("⚠️ Task screenshot failed: no screens captured")
                return "Couldn't take a screenshot"
            }
            let screenshotDateFormatter = DateFormatter()
            screenshotDateFormatter.dateFormat = "yyyy-MM-dd HHmmss"
            let desktopDirectoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
            let screenshotFileURL = desktopDirectoryURL.appendingPathComponent(
                "Screenshot \(screenshotDateFormatter.string(from: Date())).jpg"
            )
            try screenshotCapture.imageData.write(to: screenshotFileURL)
            print("✅ Task: screenshot saved to \(screenshotFileURL.path)")
            return "Done taking a screenshot"
        } catch {
            print("⚠️ Task screenshot failed: \(error)")
            return "Couldn't take a screenshot"
        }
    }

    /// Writes the brightness parameter on the first display exposing a
    /// writable IODisplayConnect brightness service (the built-in panel).
    /// Returns false when no display accepts the write (e.g. external-only).
    private func setBuiltInDisplayBrightness(_ brightness: Float) -> Bool {
        var displayIterator: io_iterator_t = 0
        let matchingServicesResult = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &displayIterator
        )
        guard matchingServicesResult == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(displayIterator) }

        var displayService = IOIteratorNext(displayIterator)
        while displayService != 0 {
            let writeResult = IODisplaySetFloatParameter(displayService, 0, kIODisplayBrightnessKey as CFString, brightness)
            IOObjectRelease(displayService)
            if writeResult == KERN_SUCCESS {
                return true
            }
            displayService = IOIteratorNext(displayIterator)
        }
        return false
    }

    /// Resolves an app name ("spotify", "Google Chrome") to its .app bundle
    /// URL by scanning the standard application directories — case-insensitive
    /// exact match first, then prefix match so "chrome" finds
    /// "Google Chrome.app".
    private static func resolveApplicationURL(named appName: String) -> URL? {
        let cleanedAppName = appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
        guard !cleanedAppName.isEmpty else { return nil }

        let applicationSearchDirectories = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSString(string: "~/Applications").expandingTildeInPath
        ]

        for directoryPath in applicationSearchDirectories {
            guard let directoryContents = try? FileManager.default.contentsOfDirectory(atPath: directoryPath) else {
                continue
            }
            let expectedAppName = cleanedAppName + ".app"
            if let exactMatch = directoryContents.first(where: {
                $0.caseInsensitiveCompare(expectedAppName) == .orderedSame
            }) {
                return URL(fileURLWithPath: directoryPath).appendingPathComponent(exactMatch)
            }
            let cleanedAppNameLowercased = cleanedAppName.lowercased()
            if let prefixMatch = directoryContents.first(where: {
                $0.lowercased().hasSuffix(".app") && $0.lowercased().hasPrefix(cleanedAppNameLowercased)
            }) {
                return URL(fileURLWithPath: directoryPath).appendingPathComponent(prefixMatch)
            }
        }
        return nil
    }

    /// Runs a one-line AppleScript via /usr/bin/osascript off the main actor
    /// (the process blocks until the script exits) and returns trimmed stdout,
    /// or nil when the script failed. Internal (not private) so
    /// SystemControlActions.swift can share it across files.
    func runAppleScript(_ appleScriptSource: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScriptSource]
            let standardOutputPipe = Pipe()
            process.standardOutput = standardOutputPipe
            do {
                try process.run()
            } catch {
                print("⚠️ osascript failed to launch: \(error)")
                return nil
            }
            let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                print("⚠️ osascript exited \(process.terminationStatus) for: \(appleScriptSource)")
                return nil
            }
            return String(data: standardOutputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    // NX_KEYTYPE_* values from IOKit's ev_keymap.h — the codes the system
    // uses for F-row media keys.
    private static let nxKeyTypeBrightnessUp: Int32 = 2
    private static let nxKeyTypeBrightnessDown: Int32 = 3

    /// Posts a synthetic system-defined media-key event (subtype 8, "aux
    /// control button") — the same events the brightness keys emit. Requires
    /// accessibility, which the app already has.
    private func postSystemDefinedMediaKey(keyType: Int32, keyDown: Bool) {
        // data1 layout: bits 16–23 = key type, bits 8–15 = 0x0A (down) or
        // 0x0B (up), low byte = 0x10 (key-state marker).
        let keyStateFlags = keyDown ? 0x0A : 0x0B
        let eventPayload = (Int(keyType) << 16) | (keyStateFlags << 8) | 0x10
        let systemEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: eventPayload,
            data2: -1
        )
        systemEvent?.cgEvent?.post(tap: .cghidEventTap)
    }

}
