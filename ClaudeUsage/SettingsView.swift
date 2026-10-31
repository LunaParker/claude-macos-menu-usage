//
//  SettingsView.swift
//  Menu Bar Usage for Claude
//
//  Contents of the app's Settings (Preferences) window, presented by the
//  cog button in the popover header via `openSettings`. Uses a TabView
//  with three tabs: "General" for user-facing preferences, "Notifications"
//  for usage-threshold alert opt-ins, and "Developer" for the fetch
//  diagnostic counters.
//

import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            NotificationsSettingsView()
                .tabItem {
                    Label("Notifications", systemImage: "bell.badge")
                }

            DeveloperSettingsView()
                .tabItem {
                    Label("Developer", systemImage: "hammer")
                }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(UsageStore.self) private var usage

    @AppStorage(SettingsKeys.menuBarMetric)
    private var menuBarMetric: MenuBarMetric

    @AppStorage(SettingsKeys.showPaceOnBars)
    private var showPaceOnBars: Bool

    @AppStorage(SettingsKeys.preferredBrowserBundleID)
    private var preferredBrowserBundleID: String

    // Service status preferences
    @AppStorage(SettingsKeys.serviceStatusEnabled)
    private var serviceStatusEnabled: Bool

    @AppStorage(SettingsKeys.serviceStatusHideWhenOperational)
    private var serviceStatusHideWhenOperational: Bool

    @State private var browsers: [BrowserHelper.BrowserInfo] = []

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The last good data, even if stale, says which quotas the account has.
        let known = usage.snapshot
        Form {
            Section {
                LaunchAtLoginToggle()
            } header: {
                Text("General")
            }

            Section {
                Picker(selection: $menuBarMetric.resolved(for: known)) {
                    ForEach(MenuBarMetric.options(for: known), id: \.self) { metric in
                        Text(metric.title(for: known)).tag(metric)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in menu bar")
                        Text("A percentage next to the gauge icon. While any quota is used up, the time until it resets is shown instead, whatever you pick here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Menu Bar")
            }

            Section {
                Toggle(isOn: $showPaceOnBars) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show pace on usage bars")
                        Text("Mark how much of each window has passed, and say whether you're on pace or when you'd reach 100% at your current rate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Popover")
            }

            Section {
                Toggle(isOn: $serviceStatusEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Claude service status")
                        Text("Polls status.claude.com when the popover opens to surface incidents affecting the services you select. No background polling — only on popover open, throttled to one fetch every five minutes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $serviceStatusHideWhenOperational) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only show when degraded")
                        Text("Hide the status row whenever every monitored service is operational.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!serviceStatusEnabled)
            } header: {
                Text("Service Status")
            }

            Section {
                ForEach(KnownComponent.allCases) { component in
                    MonitoredServiceToggle(component: component)
                }
            } header: {
                Text("Services to Monitor")
            } footer: {
                Text("claude.ai and Claude Code are monitored by default. Tick others to include their status in the popover row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!serviceStatusEnabled)

            Section {
                PollIntervalSlider()
            } header: {
                Text("Polling")
            }

            Section {
                Picker(selection: $preferredBrowserBundleID) {
                    Text("System Default").tag("")
                    ForEach(browsers) { browser in
                        Text(browser.name).tag(browser.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open links in")
                        Text("Which browser to use when opening Claude web links from the popover and notifications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Browser")
            }

            Section {
                Button("Run Setup Again…") {
                    openWindow(id: WindowIDs.onboarding)
                    NSApp.activate()
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Walks through what the menu bar shows, usage alerts, service status and how often to refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            browsers = BrowserHelper.installedBrowsers()
        }
    }
}

// MARK: - Notifications

private struct NotificationsSettingsView: View {
    @Environment(NotificationManager.self) private var notifications

    @AppStorage(SettingsKeys.notifyAt50Percent) private var notifyAt50: Bool
    @AppStorage(SettingsKeys.notifyAt75Percent) private var notifyAt75: Bool
    @AppStorage(SettingsKeys.notifyAt90Percent) private var notifyAt90: Bool
    @AppStorage(SettingsKeys.notifyOnReset) private var notifyOnReset: Bool

    @AppStorage(SettingsKeys.notifyForSession) private var notifyForSession: Bool
    @AppStorage(SettingsKeys.notifyForWeekly) private var notifyForWeekly: Bool
    @AppStorage(SettingsKeys.notifyForScopedWeekly) private var notifyForScopedWeekly: Bool

    var body: some View {
        Form {
            if notifications.authorizationStatus != .authorized {
                Section {
                    NotificationAuthorizationBanner()
                }
            }

            Section {
                alertToggle($notifyAt50, "50% usage", "Notify when a watched quota reaches 50%.")
                alertToggle($notifyAt75, "75% usage", "Notify when a watched quota reaches 75%.")
                alertToggle($notifyAt90, "90% usage", "Notify when a watched quota reaches 90%.")
                alertToggle($notifyOnReset, "Usage reset", "Notify when a watched quota resets after reaching 100%.")
            } header: {
                Text("Usage Alerts")
            } footer: {
                Text("Each threshold fires at most once per window for each quota. A reading that passes several thresholds at once sends one alert, for the highest. The reset notification requires that usage reached 100% before the window expired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                alertToggle(
                    $notifyForSession,
                    "Current session",
                    "The 5-hour session window. Verified Ultra accounts don't have one.",
                    requestsAuthorization: false
                )
                alertToggle($notifyForWeekly, "Weekly limit", "The 7-day limit across all models.", requestsAuthorization: false)
                alertToggle(
                    $notifyForScopedWeekly,
                    "Model weekly limit",
                    "The model-specific weekly quota, currently Fable on Max 5x and Ultra plans. Only applies when your plan has one.",
                    requestsAuthorization: false
                )
            } header: {
                Text("Quotas to Watch")
            }
        }
        .formStyle(.grouped)
        .task {
            await notifications.refreshAuthorizationStatus()
        }
    }

    /// The threshold toggles ask for notification permission when first switched on;
    /// the quota switches only choose what the thresholds apply to.
    private func alertToggle(
        _ binding: Binding<Bool>,
        _ title: String,
        _ caption: String,
        requestsAuthorization: Bool = true
    ) -> some View {
        Toggle(isOn: requestsAuthorization ? toggleWithAuthRequest(binding) : binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// When the user enables a toggle and notification authorization
    /// hasn't been determined yet, automatically request it so the
    /// system prompt appears without a separate button press.
    private func toggleWithAuthRequest(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                if newValue {
                    notifications.requestAuthorizationIfNeeded()
                }
            }
        )
    }
}

// MARK: - Developer

private struct DeveloperSettingsView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(NotificationManager.self) private var notifications
    @Environment(\.openWindow) private var openWindow

    /// Confirmation state for the destructive factory-reset button.
    @State private var showingResetConfirmation: Bool = false

    @AppStorage(SettingsKeys.simulateStatusOutage)
    private var simulateStatusOutage: Bool

    /// Pretty-printed when it parses, raw otherwise.
    private func copyLastResponse() {
        guard let data = usage.lastResponseBody else { return }
        let text: String
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: pretty, encoding: .utf8) {
            text = string
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Network requests") {
                    Text("\(usage.networkRequestCount)")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }

                LabeledContent("Last attempt") {
                    attemptLabel
                }

                LabeledContent("Last success") {
                    successLabel
                }

                LabeledContent("Tracking since") {
                    Text(usage.diagnosticsStartedAt, style: .relative)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Average rate") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(averageRateLabel(now: context.date))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Fetch Diagnostics")
            } footer: {
                Text("Counts only requests that actually reach the network. Calls skipped by the debounce, rate-limit cooldown, or re-entrancy guard are not included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Current state") {
                    stateLabel
                }
                LabeledContent("Rate-limit cooldown") {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        rateLimitLabel(now: context.date)
                    }
                }
                LabeledContent("Token refresh") {
                    Text(authPhaseDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                LabeledContent("Claude CLI") {
                    Text(UserDefaults.standard.string(forKey: ClaudeCLILocator.cachedPathKey) ?? "Not located yet")
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
            } header: {
                Text("Store State")
            }

            Section {
                LabeledContent("Method") {
                    authMethodLabel
                }
            } header: {
                Text("Authentication")
            } footer: {
                authMethodFooter
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Button("Reset Counters", role: .destructive) {
                        usage.resetDiagnostics()
                    }
                    Spacer()
                    Button("Copy Last Response") {
                        copyLastResponse()
                    }
                    .disabled(usage.lastResponseBody == nil)
                    Button("Force Refresh") {
                        Task { await usage.refresh() }
                    }
                    .disabled(usage.isRefreshing)
                }
            } footer: {
                Text("Resetting the counters also resets the \u{201c}Tracking since\u{201d} timer so you can benchmark the fetch rate from a fresh baseline. Copy Last Response puts the latest raw JSON from the usage endpoint on the clipboard. Force Refresh bypasses the debounce but not the rate-limit cooldown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Send Test Notification") {
                    Task { await notifications.sendTestNotification() }
                }
                .disabled(
                    notifications.authorizationStatus != .authorized
                    && notifications.authorizationStatus != .provisional
                )
            } header: {
                Text("Notifications")
            } footer: {
                Text("Delivers a test notification to verify that macOS notifications are working for this app. The button is disabled when notification permission hasn't been granted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $simulateStatusOutage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulate outage of claude.ai and Claude Code")
                        Text("Renders the popover's service status row with a fabricated major outage so you can preview the degraded look. No network calls are made; the simulation overrides every other status setting while it's on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Status Simulation")
            }

            Section {
                Button("Open Diagnostic Log") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: WindowIDs.diagnosticLog)
                }
            } header: {
                Text("Diagnostic Log")
            } footer: {
                Text("Opens a window showing timestamped log entries for Keychain reads, API requests, and background credential refresh events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset All Settings and Restart…", role: .destructive) {
                    showingResetConfirmation = true
                }
            } header: {
                Text("Factory Reset")
            } footer: {
                Text("Clears every preference (onboarding, launch at login, poll interval, menu bar percentage, diagnostic counters) and any in-memory state such as the rate-limit cooldown. Your Claude Code credentials in the Keychain are **not** touched — those belong to the `claude` CLI. The app will relaunch automatically when the reset finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset all settings and restart?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset and Restart", role: .destructive) {
                AppReset.performFactoryResetAndRestart()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears every preference, unregisters the app from Login Items, and relaunches. You'll see the welcome window again on next launch.")
        }
    }

    // MARK: Derived labels

    @ViewBuilder
    private var attemptLabel: some View {
        if let date = usage.lastNetworkAttemptAt {
            Text(date, style: .relative)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("Never")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var successLabel: some View {
        if let date = usage.lastUpdated {
            Text(date, style: .relative)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("Never")
                .foregroundStyle(.secondary)
        }
    }

    private func averageRateLabel(now: Date) -> String {
        let elapsed = now.timeIntervalSince(usage.diagnosticsStartedAt)
        guard elapsed >= 1, usage.networkRequestCount > 0 else { return "—" }
        let perMinute = Double(usage.networkRequestCount) / (elapsed / 60.0)
        return String(format: "%.2f req/min", perMinute)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch usage.presentation {
        case .loading:
            Text("Loading…").foregroundStyle(.secondary)
        case .usage(_, nil):
            Label("Loaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        case .usage(_, .some(let notice)):
            Label("Stale: \(String(describing: notice))", systemImage: "clock.badge.exclamationmark")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
                .lineLimit(2)
        case .problem(let failure):
            Label(String(describing: failure), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var authMethodLabel: some View {
        switch usage.keychainReadMethod {
        case .securityCLI:
            Label("/usr/bin/security", systemImage: "checkmark.shield.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        case .secItemCopyMatching:
            Label("SecItemCopyMatching", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        case .credentialsFile:
            Label("~/.claude/.credentials.json", systemImage: "doc.text.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        case nil:
            Text("Not yet determined")
                .foregroundStyle(.secondary)
        }
    }

    private var authMethodFooter: Text {
        switch usage.keychainReadMethod {
        case .securityCLI:
            Text("You're using the preferred authentication method. Credentials are read silently via /usr/bin/security without triggering a macOS Keychain access prompt.")
        case .secItemCopyMatching:
            Text("You're using the fallback authentication method (SecItemCopyMatching). You may be prompted to re-authenticate via a macOS Keychain dialog approximately every 8 hours when Claude Code refreshes your token.")
        case .credentialsFile:
            Text("Claude Code is keeping its credentials in ~/.claude/.credentials.json because its last Keychain write failed. It moves them back to the Keychain on its next successful write, usually the next token refresh.")
        case nil:
            Text("The authentication method will be shown after the first successful credential read.")
        }
    }

    private var authPhaseDescription: String {
        switch usage.auth {
        case .ok:
            "Idle"
        case .refreshing(let attempt, let pid, let strategy):
            "Attempt \(attempt) running (PID \(pid), \(strategy.logDescription))"
        case .checking(let attempt, _):
            "Checking attempt \(attempt)"
        case .waiting(let failed, let until):
            "\(failed) failed; next attempt \(until.formatted(date: .omitted, time: .shortened))"
        }
    }

    @ViewBuilder
    private func rateLimitLabel(now: Date) -> some View {
        if let until = usage.rateLimitedUntil, until > now {
            let remaining = Int(until.timeIntervalSince(now))
            Label("Active — clears in \(remaining)s", systemImage: "hourglass")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
                .monospacedDigit()
        } else {
            Label("Clear", systemImage: "checkmark.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        }
    }
}

#Preview {
    SettingsView()
}
