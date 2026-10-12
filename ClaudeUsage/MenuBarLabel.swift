//
//  MenuBarLabel.swift
//  Menu Bar Usage for Claude
//
//  The gauge icon and, beside it, whatever MenuBarContent decides: a
//  percentage, a warning or a reset countdown.
//

import AppKit
import SwiftUI

/// The icon (plus optional text) rendered directly into the menu bar.
struct MenuBarLabel: View {
    let usage: UsageStore

    @AppStorage(SettingsKeys.menuBarMetric)
    private var metric: MenuBarMetric

    @AppStorage(SettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding: Bool

    @Environment(\.openWindow) private var openWindow

    /// Advanced each minute so a reset countdown ticks and stale data drops out.
    /// Not a TimelineView: inside a MenuBarExtra label that spins the host's
    /// update loop at full CPU.
    @State private var now = Date()

    var body: some View {
        let content = MenuBarContent(
            snapshot: usage.presentation.menuBarSnapshot(now: now),
            metric: metric,
            now: now
        )
        MenuBarItemView(content: content)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
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
}

/// The gauge and whatever sits beside it. The menu bar label and the setup
/// window's preview both draw this, so the preview is exactly what appears.
struct MenuBarItemView: View {
    let content: MenuBarContent

    var body: some View {
        // In the menu bar this renders in the bar's own appearance context: the
        // monochrome symbol and plain Text are tinted for light or dark bars.
        HStack(spacing: 3) {
            Image(systemName: content.symbolName)
                .symbolRenderingMode(.monochrome)
            if let text = content.text {
                Text(text)
                    .monospacedDigit()
            }
            if content.showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .accessibilityLabel(content.accessibilityLabel)
    }
}
