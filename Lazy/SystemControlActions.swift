//
//  SystemControlActions.swift
//  Clicky
//
//  M5.1 — system-level ActionTask executors (dark mode, Wi-Fi, lock screen,
//  display sleep, empty trash, quit-all, open URL): headless shell /
//  AppleScript calls so these land instantly with no brain round trip.
//

import Foundation

extension CompanionManager {

    /// Runs a system-control ActionTask and returns its outcome line
    /// ("Done …" / "Couldn't …"), mirroring executeActionTask's contract.
    func executeSystemControlAction(_ actionTask: ActionTask) async -> String {
        switch actionTask {
        case .setDarkMode(let requestedDarkMode):
            return await executeDarkModeAction(enabled: requestedDarkMode)

        case .wifi(let requestedWifiEnabled):
            return await executeWifiAction(enabled: requestedWifiEnabled)

        case .lockScreen:
            // Ctrl+Cmd+Q is the system Lock Screen shortcut.
            guard await runAppleScript("tell application \"System Events\" to keystroke \"q\" using {command down, control down}") != nil else {
                print("⚠️ Task lock failed")
                return "Couldn't lock the screen"
            }
            print("✅ Task: locked the screen")
            return "Done locking the screen"

        case .sleepDisplay:
            guard await Self.runCommand("/usr/bin/pmset", arguments: ["displaysleepnow"]) != nil else {
                print("⚠️ Task display sleep failed")
                return "Couldn't turn off the display"
            }
            print("✅ Task: display sleeping")
            return "Done turning off the display"

        case .emptyTrash:
            guard await Self.runCommand(
                "/usr/bin/osascript",
                arguments: ["-e", "tell application \"Finder\" to empty trash"],
                timeoutSeconds: 20
            ) != nil else {
                print("⚠️ Task empty trash failed")
                return "Couldn't empty the Trash"
            }
            print("✅ Task: emptied the Trash")
            return "Done emptying the Trash"

        case .quitAllApps:
            // Gentle quit (not killall): apps with unsaved documents show
            // their own save dialog, best-effort within the timeout. Clicky
            // is an LSUIElement (background only) so it never quits itself.
            let quitAllScript = """
            tell application "System Events"
                set appNames to name of every process whose background only is false and name is not "Finder" and name is not "loginwindow"
            end tell
            repeat with appName in appNames
                try
                    tell application (appName as text) to quit
                end try
            end repeat
            """
            _ = await Self.runCommand(
                "/usr/bin/osascript",
                arguments: ["-e", quitAllScript],
                timeoutSeconds: 20
            )
            print("✅ Task: quit all visible apps (best effort)")
            return "Done closing your apps"

        case .openURL(let urlString):
            guard let normalizedURLText = Self.normalizedOpenURL(from: urlString) else {
                print("⚠️ Task open URL failed: not a URL: \(urlString)")
                return "Couldn't open that link"
            }
            guard await Self.runCommand("/usr/bin/open", arguments: [normalizedURLText]) != nil else {
                print("⚠️ Task open URL failed: \(normalizedURLText)")
                return "Couldn't open that link"
            }
            print("✅ Task: opened \(normalizedURLText)")
            return "Done opening it"

        default:
            return "Couldn't do that"
        }
    }

    // MARK: - Dark mode

    private func executeDarkModeAction(enabled requestedDarkMode: Bool?) async -> String {
        var shouldEnableDarkMode = requestedDarkMode
        if shouldEnableDarkMode == nil {
            guard let currentModeText = await runAppleScript(
                "tell application \"System Events\" to tell appearance preferences to get dark mode"
            ) else {
                print("⚠️ Task dark mode failed: couldn't read appearance")
                return "Couldn't change the appearance"
            }
            let isCurrentlyDark = currentModeText.lowercased().contains("true")
            shouldEnableDarkMode = !isCurrentlyDark
        }
        let darkModeValue = shouldEnableDarkMode! ? "true" : "false"
        guard await runAppleScript(
            "tell application \"System Events\" to tell appearance preferences to set dark mode to \(darkModeValue)"
        ) != nil else {
            print("⚠️ Task dark mode failed: set rejected")
            return "Couldn't change the appearance"
        }
        print("✅ Task: dark mode \(darkModeValue)")
        return shouldEnableDarkMode! ? "Done turning on dark mode" : "Done turning off dark mode"
    }

    // MARK: - Wi-Fi

    private func executeWifiAction(enabled requestedWifiEnabled: Bool?) async -> String {
        guard let wifiDevice = await Self.wifiHardwareDeviceName() else {
            print("⚠️ Task wifi failed: no Wi-Fi hardware port found")
            return "Couldn't find the Wi-Fi hardware"
        }
        var shouldEnableWifi = requestedWifiEnabled
        if shouldEnableWifi == nil {
            guard let powerText = await Self.runCommand(
                "/usr/sbin/networksetup",
                arguments: ["-getairportpower", wifiDevice]
            ) else {
                print("⚠️ Task wifi failed: couldn't read power for \(wifiDevice)")
                return "Couldn't change Wi-Fi"
            }
            // Output: "Wi-Fi Power (en0): On" — "Off" does not contain "on".
            shouldEnableWifi = !powerText.lowercased().contains("on")
        }
        let powerArgument = shouldEnableWifi! ? "on" : "off"
        guard await Self.runCommand(
            "/usr/sbin/networksetup",
            arguments: ["-setairportpower", wifiDevice, powerArgument]
        ) != nil else {
            print("⚠️ Task wifi failed: setairportpower \(wifiDevice) \(powerArgument)")
            return "Couldn't change Wi-Fi"
        }
        print("✅ Task: wifi \(powerArgument) (\(wifiDevice))")
        return shouldEnableWifi! ? "Done turning Wi-Fi on" : "Done turning Wi-Fi off"
    }

    /// Finds the hardware port device (e.g. en0) backing Wi-Fi from
    /// `networksetup -listallhardwareports`.
    private static func wifiHardwareDeviceName() async -> String? {
        guard let hardwarePortListing = await runCommand(
            "/usr/sbin/networksetup",
            arguments: ["-listallhardwareports"]
        ) else { return nil }
        var listingLines = hardwarePortListing.components(separatedBy: "\n")
        while let headerIndex = listingLines.firstIndex(where: {
            $0.contains("Wi-Fi") || $0.contains("AirPort")
        }) {
            guard headerIndex + 1 < listingLines.count else { return nil }
            let deviceLine = listingLines[headerIndex + 1]
            if deviceLine.hasPrefix("Device:") {
                let deviceName = deviceLine
                    .replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !deviceName.isEmpty { return deviceName }
            }
            listingLines.removeFirst(headerIndex + 1)
        }
        return nil
    }

    // MARK: - Shell runner

    /// Runs a system tool off the main actor and returns trimmed stdout, or
    /// nil when the process fails to launch, exits non-zero, or exceeds
    /// `timeoutSeconds` (then killed — a hung child, e.g. AppleScript waiting
    /// on a dialog, can't wedge the run).
    static func runCommand(
        _ executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 30
    ) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let standardOutputPipe = Pipe()
            process.standardOutput = standardOutputPipe
            process.standardError = FileHandle.nullDevice
            // Drain stdout on its own task so readDataToEndOfFile can't block
            // past the deadline while the child hangs without closing stdout.
            let readerTask = Task.detached(priority: .userInitiated) { () -> Data in
                standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            do {
                try process.run()
            } catch {
                print("⚠️ runCommand failed to launch \(executablePath): \(error)")
                _ = await readerTask.value
                return nil
            }
            // Poll-wait with a deadline (Process has no waitUntilExit(timeout:)).
            let waitDeadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning && Date() < waitDeadline {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                let terminateDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < terminateDeadline {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                _ = await readerTask.value
                print("⚠️ runCommand timed out after \(timeoutSeconds)s: \(executablePath)")
                return nil
            }
            process.waitUntilExit()
            let standardOutputData = await readerTask.value
            guard process.terminationStatus == 0 else {
                print("⚠️ runCommand exited \(process.terminationStatus): \(executablePath) \(arguments.joined(separator: " "))")
                return nil
            }
            return String(data: standardOutputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
