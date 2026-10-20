//
//  MainThreadStallReporter.swift
//  Clicky
//
//  M4.5d — the beachball names itself. The 2026-10-20 freeze ("blue
//  indicator stuck, cursor beachball, voice question never answered")
//  produced zero evidence: Xcode's console died with the force-quit and
//  nothing on disk said what the main thread was blocked in. This closes
//  that gap.
//
//  How it works: a background thread pings the main actor once a second
//  (a DispatchQueue.main.async block that stamps the last beat). When a
//  ping goes unanswered for >3 s, the watchdog signals the MAIN thread
//  with SIGUSR2 — the handler runs ON the blocked thread's own stack and
//  dumps it (backtrace + backtrace_symbols_fd, both async-signal-safe,
//  straight to stderr AND brain.log). SA_RESTART so the blocked call
//  resumes untouched. One report per stall episode: the report re-arms
//  only after the main thread beats again, so a 60 s stall costs one
//  dump, not sixty. If the main thread is blocked in an uninterruptible
//  Mach wait the signal is deferred until it wakes — still the exact
//  stack that was stuck, just delivered post-mortem.
//

import Foundation
import Darwin

enum MainThreadStallReporter {

    // Signal/thread-shared state — plain memory shared across threads and
    // the signal handler, deliberately OUTSIDE the actor system
    // (nonisolated(unsafe): accesses are hand-serialized by design).
    nonisolated(unsafe) private static var mainThread: pthread_t?
    nonisolated(unsafe) fileprivate static var logFileDescriptor: Int32 = -1
    nonisolated(unsafe) private static var lastBeatUptime: TimeInterval = 0
    nonisolated(unsafe) private static var hasReportedStall = false
    nonisolated(unsafe) private static var isStarted = false

    nonisolated private static let stallThresholdSeconds: TimeInterval = 3

    /// Call once at launch, from the main thread.
    static func start() {
        guard !isStarted else { return }
        isStarted = true
        mainThread = pthread_self()
        // Pre-open the log so the signal handler never allocates or opens
        // anything — it may run while the main thread holds allocator locks.
        logFileDescriptor = open(BrainLog.logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        installSignalHandler()
        lastBeatUptime = ProcessInfo.processInfo.systemUptime
        startWatchdogThread()
        BrainLog.line("stall reporter: active — main-thread stack dump after \(Int(stallThresholdSeconds))s unresponsiveness")
    }

    /// Nonisolated so the Thread's block converts cleanly (a MainActor
    /// closure where @Sendable is expected is exactly the warning we add
    /// zero of).
    nonisolated private static func startWatchdogThread() {
        let watchdog = Thread { watchdogLoop() }
        watchdog.name = "clicky.stall-reporter"
        watchdog.qualityOfService = .utility
        watchdog.start()
    }

    // MARK: - Watchdog (background thread)

    nonisolated private static func watchdogLoop() {
        while true {
            Thread.sleep(forTimeInterval: 1.0)
            // Ping: on a healthy main thread this block runs within
            // milliseconds and re-stamps the beat.
            DispatchQueue.main.async { noteBeatOnMainThread() }
            let gap = ProcessInfo.processInfo.systemUptime - lastBeatUptime
            if gap > stallThresholdSeconds {
                if !hasReportedStall {
                    hasReportedStall = true
                    let seconds = String(format: "%.1f", gap)
                    BrainLog.line("🛑 STALL: main thread unanswered for \(seconds)s — dumping its stack (also on stderr)")
                    print("🛑 STALL: main thread unanswered for \(seconds)s — main-thread stack dump follows")
                    signalMainThreadForDump()
                }
            } else if hasReportedStall {
                hasReportedStall = false  // recovered — re-arm for the next episode
            }
        }
    }

    nonisolated private static func noteBeatOnMainThread() {
        lastBeatUptime = ProcessInfo.processInfo.systemUptime
    }

    nonisolated private static func signalMainThreadForDump() {
        guard let thread = mainThread else { return }
        pthread_kill(thread, SIGUSR2)
    }

    // MARK: - Signal handler (runs on the main thread's own stack)

    nonisolated private static func installSignalHandler() {
        var action = sigaction()
        // A FILE-SCOPE global func reference — the only shape that converts
        // to @convention(c). Both other shapes were rejected by Sema (the
        // diagnostics DO reach -typecheck; earlier "typecheck can't see it"
        // reasoning was wrong and cost a build cycle):
        //   closure literal   { _ in dump() }  → "cannot be formed from a
        //       closure that captures context" (the literal inherits the
        //       enclosing isolation)
        //   static-method ref handleStallSignal → "can only be formed from
        //       a reference to a 'func' or a literal closure" (a member
        //       reference is not a bare func reference)
        // A global nonisolated func is context-free by construction.
        action.__sigaction_u.__sa_handler = handleStallSignal
        action.sa_flags = SA_RESTART  // the blocked call must resume untouched
        sigaction(SIGUSR2, &action, nil)
    }
}

// MARK: - Signal target (file scope: must be a bare 'func' for @convention(c))

/// Runs ON the stalled main thread — every frame above its wait point IS
/// the blocking call. Async-signal-safe calls only (backtrace /
/// backtrace_symbols_fd / write are; the log fd was pre-opened at start so
/// nothing is allocated or opened here).
nonisolated private func handleStallSignal(_ signal: Int32) {
    let banner = Array("🛑 MAIN THREAD STALLED — stack at the stall point:\n".utf8)
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let frameCount = backtrace(&frames, 64)
    write(STDERR_FILENO, banner, banner.count)
    backtrace_symbols_fd(&frames, frameCount, STDERR_FILENO)
    let fd = MainThreadStallReporter.logFileDescriptor
    if fd >= 0 {
        write(fd, banner, banner.count)
        backtrace_symbols_fd(&frames, frameCount, fd)
    }
}
