//
//  AppLifecycle.swift
//  Menu Bar Usage for Claude
//
//  Launch-time helpers: test-host detection, single-instance
//  enforcement and the factory reset.
//

import AppKit
import ServiceManagement

/// The unit tests run inside the app, so its launch code runs first. A test
/// host launch must not quit other instances, open windows or start polling.
enum LaunchContext {
    static let isUnitTestHost = isUnitTestHost(environment: ProcessInfo.processInfo.environment)

    nonisolated static func isUnitTestHost(environment: [String: String]) -> Bool {
        ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
            .contains { environment[$0] != nil }
    }
}

/// Enforces at-most-one-instance semantics for the app. Menu bar apps with
/// LSUIElement can end up with multiple live instances a few different ways:
///
///   • Factory reset uses `open -n` which explicitly bypasses LaunchServices'
///     "activate existing instance" behaviour.
///   • A rebuild from Xcode produces a fresh bundle in DerivedData whose path
///     differs from any previously-installed copy in `/Applications`.
///   • Double-clicking the `.app` while an older dev build is still alive.
///
/// Without a guard, the user ends up with two gauge icons in the menu bar,
/// two background poll loops competing for the same rate-limit bucket, and
/// two sets of state. We detect this at launch by querying
/// `NSRunningApplication` for every process with our bundle identifier that
/// isn't us, politely ask them to quit, and wait briefly for them to exit.
/// Falls back to `forceTerminate()` for anything that hasn't responded within
/// a three-second grace period.
enum SingleInstance {
    @MainActor
    static func enforceUniqueness() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier

        // Filter out ourselves. Anything left is a duplicate.
        func peers() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }
        }

        let initialPeers = peers()
        guard !initialPeers.isEmpty else { return }

        // Polite terminate first so the old instance runs its normal
        // `applicationShouldTerminate` / cleanup path (stopping poll
        // tasks, unregistering notifications, etc.).
        for app in initialPeers {
            app.terminate()
        }

        // Spin-wait on the main thread for up to ~3 seconds for the
        // duplicates to actually disappear. Polls in 100 ms increments
        // so the common case (factory-reset restart, where the old
        // instance is already mid-terminate) returns in a few hundred
        // milliseconds rather than waiting the full budget.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if peers().isEmpty { return }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Anything still alive after the grace period gets force-killed.
        // This is the "the old instance is frozen" fallback — the
        // alternative is to give up and let two instances coexist, which
        // is the exact problem we're trying to avoid.
        for app in peers() {
            app.forceTerminate()
        }
    }
}

/// Factory-reset helper invoked from the Developer tab. Wipes every piece
/// of state the app has persisted outside of the Keychain (which belongs
/// to Claude Code, not us), unregisters from Login Items, and relaunches.
enum AppReset {
    /// Performs the reset and restarts the app. Safe to call from the main
    /// actor — the relaunch itself is kicked off on a background queue so
    /// the main thread can continue long enough to dismiss any confirmation
    /// sheet cleanly before termination.
    @MainActor
    static func performFactoryResetAndRestart() {
        // 1. Clear every key this app has ever written to UserDefaults,
        //    including bundle-path-scoped onboarding flags from older
        //    builds, the poll interval, the menu bar percentage toggle,
        //    and anything else we might add later.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }

        // 2. Unregister from Login Items. `try?` because the only failure
        //    modes are "wasn't registered in the first place" or "already
        //    unregistered", both of which are fine outcomes for a reset.
        try? SMAppService.mainApp.unregister()

        // 3. Relaunch via `/usr/bin/open -n <self>` and then terminate.
        //    `open` talks to LaunchServices to schedule the new launch,
        //    which happens independently of our own process exiting —
        //    so even if we terminate before `open` finishes, the new
        //    instance still comes up.
        let bundleURL = Bundle.main.bundleURL
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
            task.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
