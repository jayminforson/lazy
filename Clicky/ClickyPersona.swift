//
//  ClickyPersona.swift
//  Clicky
//
//  Clickys personas: named companions whose prompt addendum, quip, and
//  accent change how Clicky sounds and reads in Home. The active persona
//  persists in UserDefaults and is injected into the companion prompt.
//  Art is drawn (initial disc) — nothing shipped from the reference DMG.
//

import Foundation

struct ClickyPersona: Identifiable, Codable, Equatable, Hashable {
    /// Stable id; also the defaults value for the active persona.
    let id: String
    let name: String
    /// One-line flavor card copy (original, reference-inspired style).
    let quip: String
    /// Appended to the companion system prompt — defines voice/behavior.
    let promptAddendum: String
    /// Accent hex used for the Home selection ring and hero tint.
    let accentHex: String

    /// Initial shown on the persona disc (drawn avatar placeholder).
    var initial: String {
        String(name.prefix(1)).uppercased()
    }

    static let defaultID = "clicky"

    static let builtIns: [ClickyPersona] = [
        ClickyPersona(
            id: "clicky",
            name: "Lazy",
            quip: "Lives in your notch. Answers with voice.",
            promptAddendum: "You are Lazy, the default companion: quick, warm, and to the point. Give the fewest words that fully answer.",
            accentHex: "#3B82F6"
        ),
        ClickyPersona(
            id: "pip",
            name: "Pip",
            quip: "One-line answers. Zero dithering.",
            promptAddendum: "You are Pip: fast and chatty. Lead with the answer in a single line; add detail only when asked.",
            accentHex: "#F59E0B"
        ),
        ClickyPersona(
            id: "sable",
            name: "Sable",
            quip: "Checks twice. Speaks once.",
            promptAddendum: "You are Sable: calm and careful. Note assumptions and risks briefly, then answer plainly.",
            accentHex: "#34D399"
        ),
        ClickyPersona(
            id: "juno",
            name: "Juno",
            quip: "Cites sources. Admits unknowns.",
            promptAddendum: "You are Juno: a curious researcher. Prefer verifiable facts and say plainly when you are unsure.",
            accentHex: "#A78BFA"
        )
    ]

    static func persona(id: String) -> ClickyPersona {
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
