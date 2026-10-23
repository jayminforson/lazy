//
//  NetworkStatusMonitor.swift
//  Lazy
//
//  M9 — cached network reachability for the offline-brain fast path. One
//  NWPathMonitor for the app's lifetime; `respond` reads `isOnline` as a
//  plain bool (zero per-turn cost — the monitor does all the waiting off
//  the critical path). A turn taken before the first callback fires reads
//  `true` and behaves exactly like today (cloud chain) — fail-toward-
//  existing-behavior by design.
//

import Foundation
import Network

final class NetworkStatusMonitor {
    static let shared = NetworkStatusMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.yourcompany.leanring-buddy.network-monitor")

    /// Last known reachability. The path handler hops to the main actor to
    /// write it; reads are synchronous from `respond` (also main actor).
    @MainActor private(set) var isOnline = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isOnline = online
            }
        }
        monitor.start(queue: queue)
    }
}
