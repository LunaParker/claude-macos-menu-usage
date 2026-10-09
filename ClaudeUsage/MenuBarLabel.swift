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

    /// The usage to show: kept through a transient failure, dropped once it's too old.
    private var snapshot: UsageSnapshot? {
        usage.presentation.menuBarSnapshot(now: Date())
    }

    private var symbolName: String {
        guard let snapshot else { return "gauge.with.dots.needle.bottom.50percent" }
        let peak = snapshot.peakUtilization
        if peak >= 0.9 { return "gauge.with.dots.needle.100percent" }
        if peak >= 0.66 { return "gauge.with.dots.needle.67percent" }
        if peak >= 0.33 { return "gauge.with.dots.needle.33percent" }
        return "gauge.with.dots.needle.0percent"
    }

    private var sessionPercentLabel: String? {
        snapshot?.session.percentLabel
    }

    /// Session at 90% or more but below 100%, where the full gauge says it all.
    private var shouldShowSessionWarning: Bool {
        guard let snapshot else { return false }
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
