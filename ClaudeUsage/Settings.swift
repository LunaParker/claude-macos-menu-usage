//
//  Settings.swift
//  Menu Bar Usage for Claude
//
//  Preference keys, window ids and the default poll interval.
//

import CryptoKit
import Foundation

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

    // Notification preferences
    static let notifyAt50Percent = "notifyAt50Percent"
    static let notifyAt75Percent = "notifyAt75Percent"
    static let notifyAt90Percent = "notifyAt90Percent"
    static let notifyOnReset = "notifyOnReset"

    /// Bundle identifier of the user's preferred browser for opening web
    /// links (e.g. "com.brave.Browser"). Empty string = system default.
    static let preferredBrowserBundleID = "preferredBrowserBundleID"

    // Service status (status.claude.com)
    /// Master toggle for the popover's service-status row. When false,
    /// `StatusStore` performs no fetches and the row is hidden.
    static let serviceStatusEnabled = "serviceStatusEnabled"
    /// When true, the status row is hidden whenever every monitored
    /// component is operational. Doesn't affect fetching — we still need
    /// to fetch in order to know whether anything is degraded.
    static let serviceStatusHideWhenOperational = "serviceStatusHideWhenOperational"
    /// Per-component monitoring opt-ins. Defaults defined on
    /// `KnownComponent.defaultEnabled`; only `claude.ai` and `Claude Code`
    /// are on out of the box.
    static let monitorClaudeAI         = "monitorClaudeAI"
    static let monitorClaudeCode       = "monitorClaudeCode"
    static let monitorClaudeAPI        = "monitorClaudeAPI"
    static let monitorClaudeConsole    = "monitorClaudeConsole"
    static let monitorClaudeCowork     = "monitorClaudeCowork"
    static let monitorClaudeForGov     = "monitorClaudeForGov"
    /// Developer affordance — when true, the popover renders the status
    /// row using a fabricated outage snapshot so the user can preview the
    /// degraded look without waiting for a real incident.
    static let simulateStatusOutage    = "simulateStatusOutage"
}

/// The stable window id for the welcome/onboarding window opened at launch.
enum WindowIDs {
    static let onboarding = "onboarding"
    static let diagnosticLog = "diagnosticLog"
}

/// Default background poll interval, also used as the fallback when the
/// user-chosen value is missing or out of range. Kept as a top-level
/// constant so the store and the settings pane agree.
let defaultPollIntervalSeconds: Int = 300
