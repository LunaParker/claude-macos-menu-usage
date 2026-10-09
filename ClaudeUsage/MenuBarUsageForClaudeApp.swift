//
//  MenuBarUsageForClaudeApp.swift
//  Menu Bar Usage for Claude
//
//  Created by Luna Parker on 4/11/2026.
//

import SwiftUI

@main
struct MenuBarUsageForClaudeApp: App {
    @State private var notifications: NotificationManager
    @State private var usage: UsageStore
    @State private var status = StatusStore()

    init() {
        let notifications = NotificationManager()
        let usage = UsageStore(dependencies: .live(notifier: notifications))
        // The notification goes through the store, which re-reads the Keychain afterwards.
        notifications.reauthenticateHandler = { [weak usage] in usage?.manualRetry() }
        _notifications = State(initialValue: notifications)
        _usage = State(initialValue: usage)

        // Runs before any scene is built, so by the time the MenuBarExtra is
        // rendered this is the only instance in the menu bar.
        guard !LaunchContext.isUnitTestHost else { return }
        SingleInstance.enforceUniqueness()
        PreferenceMigrations.run(on: .standard)

        // Older builds cached responses, bearer token included, on disk.
        LegacyURLCache.removeForThisApp()
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        notifications.registerAsDelegate()
        Task { await notifications.refreshAuthorizationStatus() }
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
                .environment(notifications)
        }

        Window("Diagnostic Log", id: WindowIDs.diagnosticLog) {
            DiagnosticLogView()
                .environment(DiagnosticLog.shared)
        }
        .windowResizability(.contentMinSize)
    }
}
