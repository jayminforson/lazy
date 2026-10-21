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
//  M4.5e (the "freezes until I close Xcode" report) added three things:
//  ① stdout/stderr go O_NONBLOCK at start — print() writing into a full
//     Xcode console pipe used to park the MAIN thread with no timeout and
//     no escape short of quitting Xcode; now it just drops a line
//     (brain.log is the evidence channel that matters);
//  ② the stall dump writes to the pre-opened brain.log fd FIRST, stderr
//     second — a wedged stderr write inside the handler used to eat the
//     evidence before it hit disk; the handler itself is now also
//     allocation-free (pre-allocated frame buffer, StaticString banner),
//     so it can't die on a locked allocator either;
//  ③ the watchdog keeps a rolling gap trail (worst beat gap per 5 s
//     window) so the sub-3 s blocks that never trip a STALL report still
//     leave a timing trail in brain.log.
//

import Foundation
import Darwin

enum MainThreadStallReporter {

    // Signal/thread-shared state — plain memory shared across threads and
    // the signal handler, deliberately OUTSIDE the actor system
    // (nonisolated(unsafe): accesses are hand-serialized by design).
    nonisolated(unsafe) private static var mainThread: pthread_t?
    nonisolated(unsafe) fileprivate static var logFileDescriptor: Int32 = -1
    // Backtrace storage, allocated ONCE in start() before the handler is
    // installed — the signal handler must never allocate (a stall while
    // the main thread holds an allocator lock would deadlock the handler
    // before its first byte reached disk, i.e. exactly the evidence we
    // need). Reentrancy: SIGUSR2 stays blocked while its handler runs
    // (no SA_NODEFER) and the watchdog reports one episode at a time, so
    // main is the only reader/writer of this buffer.
    nonisolated(unsafe) fileprivate static var frameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
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
        // Pre-allocate the handler's backtrace buffer (M4.5e ② hardening:
        // allocation-free signal handler — see frameBuffer above).
        frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
        // Console backpressure protection (M4.5e ①): from here on no
        // print()/write() to the Xcode console can block any thread.
        makeConsoleWritesNonBlocking()
        installSignalHandler()
        lastBeatUptime = ProcessInfo.processInfo.systemUptime
        startWatchdogThread()
        BrainLog.line("stall reporter: active — main-thread stack dump after \(Int(stallThresholdSeconds))s unresponsiveness")
        BrainLog.line("console non-blocking: stdout/stderr O_NONBLOCK — print() can no longer wedge the main thread")
    }

    /// M4.5e ① — mark the console descriptors non-blocking. print() goes to
    /// stdout; Xcode captures stdout+stderr in a pipe whose reader is
    /// Xcode's UI process. When that console stops draining (long sessions,
    /// thousands of lines), the pipe fills and every write(2) on it parks
    /// the calling thread — and in this app the caller is almost always the
    /// main thread, which is exactly the beachball that "never stops until
    /// I close Xcode" (closing Xcode kills the pipe reader, the write fails,
    /// the thread wakes). With O_NONBLOCK a full pipe fails immediately
    /// (EAGAIN) instead of sleeping forever; the accepted cost is that under
    /// sustained pressure console lines can be dropped or truncated —
    /// brain.log goes to a real file and is unaffected. Child processes
    /// inherit these flags, but the ones that need reliable output already
    /// get their own pipes (runCommand), and /dev/null (Finder launch)
    /// ignores O_NONBLOCK entirely.
    nonisolated private static func makeConsoleWritesNonBlocking() {
        for fd in [STDOUT_FILENO, STDERR_FILENO] {
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
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
        // M4.5e ③ gap trail. The gap below normally equals this loop's
        // 1.0 s sleep (the beat is stamped when the previous ping ran), so
        // any gap past 1.25 s means the main thread sat on a ping for
        // ~250 ms — the sub-3 s blocks that by design never trip a STALL
        // report yet ARE the sticky-note/notch-poll beachballs. Rolling
        // worst gap per 5 s window: one brain.log line per window only when
        // something was actually slow, so a clean run writes nothing and a
        // blocky run names itself with a number.
        let trailThreshold: TimeInterval = 1.25  // 1.0 s cadence + 0.25 s slack
        let trailWindow: TimeInterval = 5.0
        var windowStart = ProcessInfo.processInfo.systemUptime
        var windowWorstGap: TimeInterval = 0

        while true {
            Thread.sleep(forTimeInterval: 1.0)
            // Ping: on a healthy main thread this block runs within
            // milliseconds and re-stamps the beat.
            DispatchQueue.main.async { noteBeatOnMainThread() }
            let gap = ProcessInfo.processInfo.systemUptime - lastBeatUptime
            if gap > trailThreshold && gap > windowWorstGap {
                windowWorstGap = gap
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - windowStart >= trailWindow {
                if windowWorstGap > 0 {
                    let worst = String(format: "%.2f", windowWorstGap)
                    let blocked = String(format: "%.2f", windowWorstGap - 1.0)
                    BrainLog.line("⏳ gap trail: worst beat gap \(worst)s in the last 5s — ~\(blocked)s of main-thread block (healthy ≈ 1.00s)")
                }
                windowStart = now
                windowWorstGap = 0
            }
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
/// backtrace_symbols_fd / write are), and NOTHING in here allocates: the
/// log fd and the backtrace buffer were pre-created at start, and the
/// banner is a StaticString (static storage) — the previous
/// `Array("…".utf8)` + `[UnsafeMutableRawPointer?]` version heap-allocated
/// twice, which would deadlock this handler if the stall happened while
/// the main thread held an allocator lock — the dump would never reach
/// disk, which is the one thing this handler exists to prevent.
nonisolated private func handleStallSignal(_ signal: Int32) {
    let banner: StaticString = "🛑 MAIN THREAD STALLED — stack at the stall point:\n"
    let bannerBytes = banner.utf8Start
    let bannerLength = banner.utf8CodeUnitCount
    guard let frames = MainThreadStallReporter.frameBuffer else {
        // start() never ran (impossible in practice — the handler is only
        // installed there) — still announce, just without frames.
        write(STDERR_FILENO, bannerBytes, bannerLength)
        return
    }
    let frameCount = backtrace(frames, 64)
    // brain.log FIRST (M4.5e ②): this handler runs on the main thread's own
    // stack, so an interruptible write to a wedged stderr pipe would block
    // INSIDE the handler forever (SA_RESTART resumes it) and the dump would
    // never reach disk — the evidence died with the console. Pre-opened log
    // fd = a real file, writes complete; stderr goes second (and is
    // non-blocking since M4.5e ①, so it can't hang here either).
    let fd = MainThreadStallReporter.logFileDescriptor
    if fd >= 0 {
        write(fd, bannerBytes, bannerLength)
        backtrace_symbols_fd(frames, frameCount, fd)
    }
    write(STDERR_FILENO, bannerBytes, bannerLength)
    backtrace_symbols_fd(frames, frameCount, STDERR_FILENO)
}
