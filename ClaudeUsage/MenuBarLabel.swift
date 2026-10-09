//
//  MenuBarLabel.swift
//  Menu Bar Usage for Claude
//
//  The gauge icon and optional percentage shown in the menu bar.
//

import AppKit
import SwiftUI

/// The icon (plus optional text percentage) rendered directly into the menu bar.
struct MenuBarLabel: View {
    let usage: UsageStore

    @AppStorage(SettingsKeys.showSessionPercentInMenuBar)
    private var showSessionPercent: Bool

    @AppStorage(SettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding: Bool

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
            guard !LaunchContext.isUnitTestHost else { return }
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
