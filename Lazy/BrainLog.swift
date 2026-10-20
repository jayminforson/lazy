//
//  BrainLog.swift
//  Clicky
//
//  M4.5d — persistent, size-capped diagnostic log for the brain chain.
//  Xcode's console dies with Xcode (the 2026-10-20 freeze lost every print
//  the moment the app was force-quit), so the only evidence that survives a
//  hang is whatever reached disk. Chain events, search-engine outcomes, the
//  turn deadline, stall reports and error chips all land here.
//
//  Rules: never throws, never blocks the caller (async serial queue), never
//  logs credentials (the two API keys never pass through this file). A
//  diagnostic must not be able to take a turn down.
//

import Foundation

enum BrainLog {

    nonisolated private static let queue = DispatchQueue(label: "clicky.brainlog", qos: .utility)

    /// Rotate at ~1 MB, keeping the tail: the last megabyte is what a
    /// post-mortem needs; the first half is disposable noise.
    nonisolated private static let maxBytes: UInt64 = 1_000_000

    nonisolated static var logURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.yourcompany.leanring-buddy", isDirectory: true)
            .appendingPathComponent("brain.log")
    }

    /// Appends one timestamped line ("2026-10-20 17:45:03.123 message").
    /// Safe from any thread (the stamp is computed on the caller, the file
    /// work runs on the private queue).
    nonisolated static func line(_ message: String) {
        let entry = "\(timestamp()) \(message)\n"
        let url = logURL
        queue.async {
            writeEntry(entry, to: url)
        }
    }

    /// C-side timestamp — strftime instead of DateFormatter so nothing here
    /// touches actor-isolated or non-Sendable state (this runs from the
    /// stall reporter's thread and, in the worst case, a signal path).
    nonisolated private static func timestamp() -> String {
        var calendarTime = time(nil)
        var localTime = tm()
        localtime_r(&calendarTime, &localTime)
        var buffer = [CChar](repeating: 0, count: 32)
        strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &localTime)
        let epoch = Date().timeIntervalSince1970
        let millis = Int((epoch - epoch.rounded(.down)) * 1000)
        return "\(String(cString: buffer)).\(String(format: "%03d", millis))"
    }

    nonisolated private static func writeEntry(_ entry: String, to url: URL) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size > maxBytes {
            if let data = try? Data(contentsOf: url), data.count > 4096 {
                try? Data(data.suffix(data.count / 2)).write(to: url, options: .atomic)
            } else {
                try? Data().write(to: url, options: .atomic)
            }
        }
        // FileHandle(forWritingTo:) FAILS when the file doesn't exist yet —
        // create it explicitly, or the very first lines (the ones a launch
        // post-mortem needs most) would be silently dropped.
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        }
    }
}
