//
//  ToolGate.swift
//  Clicky
//
//  M4 A4 — named tool policies for the opencode bridge. Chat replies and
//  computer-use steps never see mutating tools; explicit [AGENT:...] runs
//  get the full set, logged once per run as the turn's approval line so
//  the console shows exactly what the model is allowed to call.
//

import Foundation

enum ToolGate {

    /// Policy for normal chat replies (and any non-agent message): mutating
    /// tools disabled — bash/write/edit belong to explicit [AGENT:] runs
    /// only. Read-only tools (read/grep/glob/list) stay available so the
    /// model can still inspect files it already knows about.
    static let chatDisabledTools: [String: Bool] = [
        "bash": false,
        "write": false,
        "edit": false
    ]

    /// Tools an agent run may call this turn — matches the serve default
    /// tool set; caps (30 calls / 300 s since M5) are enforced separately
    /// by the run loop.
    static let agentApprovedToolNames: [String] = [
        "bash", "read", "write", "edit", "grep", "glob", "list"
    ]

    /// M5 unified loop set — file/shell tools plus the UI tools that run
    /// through the CompanionManager main-actor handler.
    static let unifiedRunApprovedToolNames: [String] = [
        "bash", "read", "write", "edit", "osascript", "screenshot", "ui", "wait"
    ]

    /// One console line printed at agent-run start — the per-turn approval
    /// record ("approved for this turn").
    static var agentTurnApprovalLogLine: String {
        "🛡 ToolGate: approved for this turn: " + agentApprovedToolNames.joined(separator: ", ")
    }

    /// Approval record when the direct unified loop can run (Gemini key
    /// present) — printed instead of the serve-set line.
    static var unifiedTurnApprovalLogLine: String {
        "🛡 ToolGate: approved for this turn (unified): " + unifiedRunApprovedToolNames.joined(separator: ", ")
    }
}
