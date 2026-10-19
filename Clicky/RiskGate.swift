//
//  RiskGate.swift
//  Clicky
//
//  M5.3 — risky-action gate (locked user decision: "confirm risky only").
//  Sending messages, deleting beyond the Trash, and purchases pause for a
//  spoken/typed yes-or-no before anything executes; every other action
//  still runs instantly (M5's "say it, done instantly" stays intact for
//  non-risky work). Pure classification — parking/delivery live in
//  CompanionManager.
//

import Foundation

/// The user's answer to a confirmation question.
enum RiskConfirmationAnswer {
    case yes
    case no
}

enum RiskGate {

    // Word-boundary cues over run goals. Kept deliberately broad: a false
    // positive costs one spoken "yes", a miss costs real data. (Moving TO
    // the Trash is reversible and not gated; emptying it is, and lives in
    // isRiskyActionTask instead.)
    private static let sendCuePattern = #"\b(send|sending|email|e-mail|mail|message|dm|tweet|post|publish|submit|upload|forward|reply|share|airdrop|dispatch|deliver)\b"#
    private static let deleteCuePattern = #"\b(delete|deleting|remove|removing|erase|erasing|purge|shred|wipe|format|uninstall|empty|forever|permanently)\b|\brm\s"#
    private static let purchaseCuePattern = #"\b(buy|buying|purchase|purchasing|order|ordering|checkout|subscribe|subscription|payment|pay|rent|donate|bid)\b"#

    /// Risky instant tasks — the parsed ActionTask itself is the ground
    /// truth (no keyword guessing on this path).
    static func isRiskyActionTask(_ actionTask: CompanionManager.ActionTask) -> Bool {
        switch actionTask {
        case .emptyTrash:
            // Emptying the Trash is permanent — beyond-trash deletion.
            return true
        default:
            return false
        }
    }

    /// Risky [AGENT:] / [GUI:] run goals, classified on the goal text.
    static func isRiskyRunGoal(_ runGoal: String) -> Bool {
        let lowercasedGoal = runGoal.lowercased()
        for cuePattern in [sendCuePattern, deleteCuePattern, purchaseCuePattern] {
            if lowercasedGoal.range(of: cuePattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    static func confirmationQuestion(forActionTask actionTask: CompanionManager.ActionTask) -> String {
        switch actionTask {
        case .emptyTrash:
            return "That empties the Trash for good. Should I go ahead?"
        default:
            return "That's a permanent change. Should I go ahead?"
        }
    }

    static func confirmationQuestion(forRunGoal runGoal: String) -> String {
        "That means: \(runGoal). Should I go ahead?"
    }

    // Strict whole-string answers, mirroring the guide-intent matcher's
    // plain-phrase style. Anything else is NOT an answer (a pending ask is
    // superseded by whatever the user actually said).
    private static let yesAnswerPhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "yah", "sure", "yes please", "yeah please",
        "do it", "go ahead", "go for it", "proceed", "confirm", "confirmed",
        "ok", "okay", "sounds good", "please do", "affirmative", "that's right",
        "correct", "definitely", "of course", "y"
    ]
    private static let noAnswerPhrases: Set<String> = [
        "no", "nope", "nah", "no thanks", "no thank you", "don't", "do not",
        "cancel", "stop", "abort", "never mind", "nevermind", "skip",
        "don't do it", "dont do it", "leave it", "negative", "not now", "n"
    ]

    static func answer(matching messageText: String) -> RiskConfirmationAnswer? {
        let normalizedText = messageText
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        if yesAnswerPhrases.contains(normalizedText) { return .yes }
        if noAnswerPhrases.contains(normalizedText) { return .no }
        return nil
    }
}
