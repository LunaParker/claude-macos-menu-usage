//
//  MenuBarUsageForClaudeApp.swift
//  Menu Bar Usage for Claude
//
//  Created by Luna Parker on 4/11/2026.
//

import SwiftUI

@main
struct MenuBarUsageForClaudeApp: App {
    @State private var usage = UsageStore()
    @State private var status = StatusStore()

    init() {
        // Runs on the main thread before any scenes are constructed, so
        // by the time the MenuBarExtra is rendered we're guaranteed to
        // be the only instance of ourselves in the menu bar.
        guard !LaunchContext.isUnitTestHost else { return }
        SingleInstance.enforceUniqueness()
        PreferenceMigrations.run(on: .standard)

        // Older builds cached responses, bearer token included, on disk.
        LegacyURLCache.removeForThisApp()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePopoverView()
                .environment(usage)
                .environment(status)
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
                .environment(status)
        }

        Window("Diagnostic Log", id: WindowIDs.diagnosticLog) {
            DiagnosticLogView()
                .environment(DiagnosticLog.shared)
        }
        .windowResizability(.contentMinSize)
    }
}
