//
//  LazyPersona.swift
//  Clicky
//
//  Clickys personas: named companions whose prompt addendum, quip, and
//  accent change how Clicky sounds and reads in Home. The active persona
//  persists in UserDefaults and is injected into the companion prompt.
//  Art is drawn (initial disc) — nothing shipped from the reference DMG.
//

import Foundation

struct LazyPersona: Identifiable, Codable, Equatable, Hashable {
    /// Stable id; also the defaults value for the active persona.
    let id: String
    let name: String
    /// One-line flavor card copy (original, reference-inspired style).
    let quip: String
    /// Appended to the companion system prompt — defines voice/behavior.
    let promptAddendum: String
    /// Accent hex used for the Home selection ring and hero tint.
    let accentHex: String

    // MARK: M7.1 — per-persona voice identity

    /// macOS voice identifier for a PINNED persona voice on the AVSpeech
    /// fallback path; nil = the original NSSpeechSynthesizer built-in
    /// default (Lazy — the pre-M7.1 Clicky voice, restored at M7.2 after
    /// the AVSpeech default proved audibly different). A missing identifier
    /// degrades gracefully: default voice + the persona's rate.
    let systemVoiceIdentifier: String?
    /// Speaking-rate delta around AVSpeech's 0.5 default (final rate =
    /// 0.5 + delta × 0.5, clamped 0.1–1.0; 0.0 = neutral).
    let systemVoiceRate: Float
    /// ElevenLabs delivery shaping (stability / similarity_boost) sent with
    /// every synthesis — the proxy owns the voice itself, so personality
    /// rides on delivery, not timbre.
    let elevenLabsStability: Double
    let elevenLabsSimilarity: Double

    /// Initial shown on the persona disc (drawn avatar placeholder).
    var initial: String {
        String(name.prefix(1)).uppercased()
    }

    static let defaultID = "clicky"
    /// M7.1 — stable id constants for behavior gates (Pip's fast-tier lock,
    /// Juno's broad search, Sable's confirm-before-runs).
    static let pipID = "pip"
    static let sableID = "sable"
    static let junoID = "juno"

    static let builtIns: [LazyPersona] = [
        LazyPersona(
            id: "clicky",
            name: "Lazy",
            quip: "Lives in your notch. Answers with voice.",
            promptAddendum: """
            You are Lazy, the default companion: quick, warm, and to the point. give the fewest words that fully answer, then stop. friendly, never stiff; a light touch of humor is fine. when something is unclear, ask one short question instead of guessing.
            """,
            accentHex: "#3B82F6",
            // The default persona keeps EXACT pre-M7.1 behavior: machine
            // default system voice, neutral rate, today's ElevenLabs shaping.
            systemVoiceIdentifier: nil,
            systemVoiceRate: 0.0,
            elevenLabsStability: 0.5,
            elevenLabsSimilarity: 0.75
        ),
        LazyPersona(
            id: "pip",
            name: "Pip",
            quip: "One-line answers. Zero dithering.",
            promptAddendum: """
            You are Pip: fast, bright, and to the point. lead with the answer in a single line — no preamble, never repeat the question back. add detail only when asked, and keep even that to one or two lines. never pad, never hedge.
            """,
            accentHex: "#F59E0B",
            // Installed compact voices probed on this machine (M7.1): no
            // Alex/Fred/Victoria on modern macOS — en-US ships Samantha only.
            systemVoiceIdentifier: "com.apple.voice.compact.en-AU.Karen",
            systemVoiceRate: 0.45,
            // Lower stability = livelier, more varied delivery.
            elevenLabsStability: 0.35,
            elevenLabsSimilarity: 0.8
        ),
        LazyPersona(
            id: "sable",
            name: "Sable",
            quip: "Checks twice. Speaks once.",
            promptAddendum: """
            You are Sable: calm, careful, and unhurried. when an answer carries a risk, an assumption, or a catch, name it in ONE short line before answering — then answer plainly. no padding, no hedging beyond that single line. careful is not the same as slow.
            """,
            accentHex: "#34D399",
            systemVoiceIdentifier: "com.apple.voice.compact.en-GB.Daniel",
            systemVoiceRate: -0.15,
            // Higher stability = steadier, more measured delivery.
            elevenLabsStability: 0.62,
            elevenLabsSimilarity: 0.75
        ),
        LazyPersona(
            id: "juno",
            name: "Juno",
            quip: "Cites sources. Admits unknowns.",
            promptAddendum: """
            You are Juno: a curious researcher. prefer verifiable facts — when you cite one, say where it came from; when you can't verify something, say so plainly instead of guessing. short is fine, but never trade accuracy for brevity.
            """,
            accentHex: "#A78BFA",
            systemVoiceIdentifier: "com.apple.voice.compact.en-IE.Moira",
            systemVoiceRate: 0.0,
            elevenLabsStability: 0.55,
            elevenLabsSimilarity: 0.8
        )
    ]

    static func persona(id: String) -> LazyPersona {
        builtIns.first(where: { $0.id == id }) ?? builtIns[0]
    }

    /// The prompt block the active persona contributes.
    func promptBlock() -> String {
        """
        ## Who you are
        \(promptAddendum) Speak as this persona in every reply.
        """
    }
}
