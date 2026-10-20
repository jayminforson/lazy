//
//  BundledSkills.swift
//  Clicky
//
//  M4 B2 — the 38 bundled MIT reference skills (25 hermes root + 11
//  integrations + 2 bundled; © Nous Research 2025, blender-toolkit via
//  dev-gom marketplace — see NOTICE.md). Data lives in the GENERATED
//  BundledSkills+Hermes / +Work files (do not hand-edit those).
//
//  How skills reach the brain (locked design — 353KB total can never ride
//  along on every request):
//    1. catalog (name + one-liner, ~4KB) is always part of the system prompt
//    2. full body is injected into the request ONLY when the user's message
//       locally matches the skill (name mention or ≥2 description keywords)
//    3. every skill is also written to Application Support/skills/ so the
//       user can read the raw markdown in Finder
//

import Foundation

enum BundledSkills {

    // MARK: - Entry

    /// One bundled skill: catalog metadata + full markdown body.
    struct Entry: Identifiable {
        let name: String
        let description: String
        let body: String
        var id: String { name }
    }

    // MARK: - Caps

    /// Matched skills injected into one request (top scores win).
    static let maximumMatchedSkillCount = 2
    /// Per-skill body cap for injection — keeps free-tier requests sane.
    static let maximumInjectedBodyUTF8Bytes = 16_384
    /// Description keywords shorter than this are too generic to match on.
    static let minimumKeywordLength = 6
    /// Score a direct name mention gets (= an automatic match on its own).
    private static let nameMatchScore = 3

    // MARK: - Catalog

    /// All bundled skills: 25 hermes root + 11 integrations + 2 bundled.
    static var all: [Entry] { bundledHermesEntries + bundledWorkEntries }

    /// The always-on catalog block for the system prompt (name + one-liner).
    static func catalogBlock() -> String {
        let catalogLines = all
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
        return """
        bundled skills catalog (built into the app; © Nous Research, MIT):
        \(catalogLines)
        """
    }

    // MARK: - Local matching + injection

    /// Local, free match for injection: a word-boundary name mention (score
    /// 3) or keyword overlap with the description (1 each, 6+ letters).
    /// Keeps skills whose score ≥ 2 (a name alone, or two real keywords),
    /// top 2 by score. Pure string work — no brain call, no network.
    static func matchingEntries(forMessage message: String) -> [Entry] {
        let loweredMessage = message.lowercased()
        var scoredEntries: [(score: Int, entry: Entry)] = []

        for entry in all {
            var score = 0
            let escapedName = NSRegularExpression.escapedPattern(for: entry.name)
            if let nameRegex = try? NSRegularExpression(pattern: "\\b\(escapedName)\\b"),
               nameRegex.firstMatch(
                   in: loweredMessage,
                   range: NSRange(loweredMessage.startIndex..., in: loweredMessage)
               ) != nil {
                score += nameMatchScore
            }

            let keywordTokens = Set(
                entry.description
                    .lowercased()
                    .split(whereSeparator: { !$0.isLetter })
                    .map(String.init)
                    .filter { $0.count >= minimumKeywordLength }
            )
            for keyword in keywordTokens where loweredMessage.contains(keyword) {
                score += 1
            }

            if score >= 2 {
                scoredEntries.append((score, entry))
            }
        }

        return scoredEntries
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.entry.name < rhs.entry.name
            }
            .prefix(maximumMatchedSkillCount)
            .map { $0.entry }
    }

    /// The "skill reference (name):" sections appended to the brain prompt
    /// for matched skills (bodies capped). nil = nothing to inject.
    static func injectionBlock(for entries: [Entry]) -> String? {
        guard !entries.isEmpty else { return nil }
        let sections = entries.map { entry -> String in
            var bodyText = entry.body
            if bodyText.utf8.count > maximumInjectedBodyUTF8Bytes {
                let truncatedBytes = Data(bodyText.utf8.prefix(maximumInjectedBodyUTF8Bytes))
                bodyText = String(decoding: truncatedBytes, as: UTF8.self)
                    + "\n…(skill reference truncated at \(maximumInjectedBodyUTF8Bytes / 1024)KB)"
            }
            return "skill reference (\(entry.name)):\n\(bodyText)"
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - On-disk install

    /// Writes each skill to Application Support/skills/<name>.md the first
    /// time it's missing — source of truth stays the embedded strings; the
    /// files are for browsing/editing by hand (a later restart does NOT
    /// overwrite user edits, only fills gaps).
    static func installBundledSkillFilesIfNeeded() {
        guard let skillsDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("com.yourcompany.leanring-buddy", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
        } catch {
            print("📚 Bundled skills: could not create \(skillsDirectory.path) — \(error.localizedDescription)")
            return
        }

        var installedFileCount = 0
        for entry in all {
            let skillFileURL = skillsDirectory.appendingPathComponent("\(entry.name).md")
            guard !FileManager.default.fileExists(atPath: skillFileURL.path) else { continue }
            do {
                try entry.body.write(to: skillFileURL, atomically: true, encoding: .utf8)
                installedFileCount += 1
            } catch {
                print("📚 Bundled skills: could not write \(entry.name).md — \(error.localizedDescription)")
            }
        }
        if installedFileCount > 0 {
            print("📚 Bundled skills: installed \(installedFileCount) skill file(s) to \(skillsDirectory.path)")
        }
    }
}
