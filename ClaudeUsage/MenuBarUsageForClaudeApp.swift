//
//  MenuBarUsageForClaudeApp.swift
//  Menu Bar Usage for Claude
//
//  Created by Luna Parker on 4/11/2026.
//

import AppKit
import CryptoKit
import ServiceManagement
import SwiftUI

/// Keys used with `@AppStorage` throughout the app. Kept here so the call
/// sites in `MenuBarLabel`, the popover, and the settings pane all agree.
enum SettingsKeys {
    /// The onboarding flag is scoped to the running bundle's path. The
    /// macOS Keychain access-control list is tied to the exact binary
    /// path, so when Xcode rebuilds into a new DerivedData location (or
    /// the user moves the .app to /Applications), the next run will get
    /// a fresh Keychain prompt. Tying onboarding to the same path makes
    /// the welcome window re-appear at that moment, which is what the
    /// user sees as "why am I suddenly being asked for my keychain?"
    static let hasCompletedOnboarding: String = {
        let path = Bundle.main.bundlePath
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "hasCompletedOnboarding_\(hex)"
    }()
    static let showSessionPercentInMenuBar = "showSessionPercentInMenuBar"
    /// Polling interval in seconds. Validated by `UsageStore` against the
    /// allowed range (120–300) — anything outside falls back to the default.
    static let pollIntervalSeconds = "pollIntervalSeconds"
}

/// The stable window id for the welcome/onboarding window opened at launch.
enum WindowIDs {
    static let onboarding = "onboarding"
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
            try? task.run()
            task.waitUntilExit()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

/// Default background poll interval, also used as the fallback when the
/// user-chosen value is missing or out of range. Kept as a top-level
/// constant so the store and the settings pane agree.
let defaultPollIntervalSeconds: Int = 300

@main
struct MenuBarUsageForClaudeApp: App {
    @State private var usage = UsageStore()

    init() {
        // Runs on the main thread before any scenes are constructed, so
        // by the time the MenuBarExtra is rendered we're guaranteed to
        // be the only instance of ourselves in the menu bar.
        SingleInstance.enforceUniqueness()
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView()
                .environment(usage)
        } label: {
            MenuBarLabel(usage: usage)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Menu Bar Usage for Claude", id: WindowIDs.onboarding) {
            OnboardingWindowView()
                .environment(usage)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(usage)
        }
    }
}

/// The icon (plus optional text percentage) rendered directly into the menu bar.
private struct MenuBarLabel: View {
    let usage: UsageStore

    @AppStorage(SettingsKeys.showSessionPercentInMenuBar)
    private var showSessionPercent: Bool = false

    @AppStorage(SettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding: Bool = false

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The label in `MenuBarExtra` is rendered in the menu bar's own
        // appearance context — the monochrome SF Symbol + a plain Text lets
        // the system tint both for light/dark menu bars automatically.
        HStack(spacing: 3) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.monochrome)
            if showSessionPercent, let label = sessionPercentLabel {
                Text(label)
                    .monospacedDigit()
            } else if shouldShowSessionWarning {
                // Only surface the exclamation mark when the user has
                // opted out of the numeric percentage — if they're already
                // looking at "94%" in the menu bar, a warning icon would
                // be redundant. Suppressed at 100% too: at that point the
                // filled gauge icon is itself the signal and an
                // exclamation would just be visual noise.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .accessibilityLabel(accessibilityLabelText)
        // The menu bar label is the only view guaranteed to be present for
        // the entire app lifetime, so we piggy-back on its `.task` to
        // branch the launch flow. Critically, we do NOT start polling (and
        // therefore don't touch the Keychain) until the user has seen the
        // onboarding window and clicked Continue.
        .task {
            if hasCompletedOnboarding {
                usage.startPolling()
            } else {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: WindowIDs.onboarding)
            }
        }
    }

    private var symbolName: String {
        // SF Symbol "gauge.with.dots.needle.Npercent" variants ship on macOS 14+.
        switch usage.state {
        case .loaded(let snapshot):
            let peak = snapshot.peakUtilization
            if peak >= 0.9 { return "gauge.with.dots.needle.100percent" }
            if peak >= 0.66 { return "gauge.with.dots.needle.67percent" }
            if peak >= 0.33 { return "gauge.with.dots.needle.33percent" }
            return "gauge.with.dots.needle.0percent"
        default:
            return "gauge.with.dots.needle.bottom.50percent"
        }
    }

    /// The formatted session-bar percentage, or `nil` if we don't have a
    /// snapshot yet (in which case we just render the icon alone).
    private var sessionPercentLabel: String? {
        if case .loaded(let snapshot) = usage.state {
            return snapshot.session.percentLabel
        }
        return nil
    }

    /// True when the session quota has crossed the warning threshold
    /// (≥ 90%) but hasn't been fully exhausted (< 100%). Used to decide
    /// whether to render the exclamation mark in place of the numeric
    /// percentage. Returns false if we don't have a snapshot yet.
    private var shouldShowSessionWarning: Bool {
        guard case .loaded(let snapshot) = usage.state else { return false }
        let fraction = snapshot.session.fraction
        return fraction >= 0.9 && fraction < 1.0
    }

    private var accessibilityLabelText: String {
        if let label = sessionPercentLabel {
            return "Menu Bar Usage for Claude, current session \(label)"
        }
        if shouldShowSessionWarning {
            return "Menu Bar Usage for Claude, current session above 90%"
        }
        return "Menu Bar Usage for Claude"
    }
}
