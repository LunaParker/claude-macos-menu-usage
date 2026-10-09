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

import Combine
import ServiceManagement
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
    @AppStorage(SettingsKeys.showSessionPercentInMenuBar)
    private var showSessionPercent: Bool

    @AppStorage(SettingsKeys.pollIntervalSeconds)
    private var pollIntervalSeconds: Int

    @AppStorage(SettingsKeys.preferredBrowserBundleID)
    private var preferredBrowserBundleID: String

    // Service status preferences
    @AppStorage(SettingsKeys.serviceStatusEnabled)
    private var serviceStatusEnabled: Bool

    @AppStorage(SettingsKeys.serviceStatusHideWhenOperational)
    private var serviceStatusHideWhenOperational: Bool

    @Environment(UsageStore.self) private var usage

    @State private var browsers: [BrowserHelper.BrowserInfo] = []

    /// Mirrors `SMAppService.mainApp.status == .enabled`. Initialised from
    /// the live status on first appearance rather than stored locally —
    /// the system is the source of truth because the user can flip this
    /// themselves in System Settings → General → Login Items.
    @State private var launchAtLogin: Bool = false

    /// Populated when `register()` / `unregister()` throws, or when the
    /// system reports `.requiresApproval` after a register attempt. Shown
    /// as a caption under the toggle so the user understands what to do.
    @State private var launchAtLoginMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                        Text("Automatically start Menu Bar Usage for Claude when you log in to your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let launchAtLoginMessage {
                            Text(launchAtLoginMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("General")
            }

            Section {
                Toggle(isOn: $showSessionPercent) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show session usage in menu bar")
                        Text("Display the current session percentage next to the gauge icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Menu Bar")
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
                Picker(selection: $pollIntervalSeconds) {
                    Text("2 minutes").tag(120)
                    Text("3 minutes").tag(180)
                    Text("4 minutes").tag(240)
                    Text("5 minutes").tag(300)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Refresh every")
                        Text("How often Menu Bar Usage for Claude polls Claude’s usage endpoint in the background. Shorter intervals show fresher data but are more likely to be rate-limited.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .pickerStyle(.menu)
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
        }
        .formStyle(.grouped)
        .onAppear {
            browsers = BrowserHelper.installedBrowsers()
            refreshLaunchAtLoginStatus()
        }
        .onChange(of: pollIntervalSeconds) { _, _ in
            // Cancel the current sleep and start a new one at the new
            // cadence so the change takes effect right away instead of
            // after the existing sleep finishes (up to 5 minutes later).
            usage.reschedulePolling()
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { setLaunchAtLogin($0) }
        )
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginMessage = "Couldn’t update login item: \(error.localizedDescription)"
        }

        // Re-read the live status instead of trusting the toggle value —
        // if registration succeeded but the user hasn't approved login
        // items yet, the system will report `.requiresApproval`.
        let status = SMAppService.mainApp.status
        launchAtLogin = (status == .enabled)

        switch status {
        case .requiresApproval:
            launchAtLoginMessage = "Approval needed. Open System Settings → General → Login Items & Extensions and enable Menu Bar Usage for Claude."
        case .notFound:
            launchAtLoginMessage = "macOS can’t find the app bundle. Move Menu Bar Usage for Claude into /Applications and try again."
        default:
            break
        }
    }
}

private struct MonitoredServiceToggle: View {
    let component: KnownComponent
    @AppStorage private var isOn: Bool

    init(component: KnownComponent) {
        self.component = component
        _isOn = AppStorage(component.setting)
    }

    var body: some View {
        Toggle(component.displayName, isOn: $isOn)
    }
}

// MARK: - Notifications

private struct NotificationsSettingsView: View {
    @Environment(NotificationManager.self) private var notifications

    @AppStorage(SettingsKeys.notifyAt50Percent) private var notifyAt50: Bool
    @AppStorage(SettingsKeys.notifyAt75Percent) private var notifyAt75: Bool
    @AppStorage(SettingsKeys.notifyAt90Percent) private var notifyAt90: Bool
    @AppStorage(SettingsKeys.notifyOnReset) private var notifyOnReset: Bool

    var body: some View {
        Form {
            if notifications.authorizationStatus != .authorized {
                Section {
                    authorizationBanner
                }
            }

            Section {
                Toggle(isOn: toggleWithAuthRequest($notifyAt50)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("50% usage")
                        Text("Notify when current session usage reaches 50%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: toggleWithAuthRequest($notifyAt75)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("75% usage")
                        Text("Notify when current session usage reaches 75%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: toggleWithAuthRequest($notifyAt90)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("90% usage")
                        Text("Notify when current session usage reaches 90%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: toggleWithAuthRequest($notifyOnReset)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Usage reset")
                        Text("Notify when your session usage resets after reaching 100%.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Session Usage Alerts")
            } footer: {
                Text("Each threshold fires at most once per session window. The reset notification requires that usage reached 100% before the window expired.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await notifications.refreshAuthorizationStatus()
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
                if newValue && notifications.authorizationStatus == .notDetermined {
                    Task { await notifications.requestAuthorization() }
                }
            }
        )
    }

    @ViewBuilder
    private var authorizationBanner: some View {
        let status = notifications.authorizationStatus
        VStack(alignment: .leading, spacing: 8) {
            Label {
                if status == .notDetermined {
                    Text("Notifications have not been enabled yet.")
                } else {
                    Text("Notifications are disabled for this app.")
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(status == .notDetermined
                 ? "Enable notifications to receive usage alerts. You can also just flip a toggle below — macOS will ask for permission automatically."
                 : "Notifications were previously denied. You can re-enable them in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if status == .notDetermined {
                Button("Enable Notifications") {
                    Task { await notifications.requestAuthorization() }
                }
            } else if status == .denied {
                Button("Open Notification Settings…") {
                    notifications.openNotificationSettings()
                }
            }
        }
    }
}

// MARK: - Developer

private struct DeveloperSettingsView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(NotificationManager.self) private var notifications
    @Environment(\.openWindow) private var openWindow

    /// Drives relative-date labels to re-render once a second while the
    /// tab is visible so "Updated 14 sec ago" stays accurate without the
    /// user having to click away and back.
    @State private var tickerDate: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Confirmation state for the destructive factory-reset button.
    @State private var showingResetConfirmation: Bool = false

    @AppStorage(SettingsKeys.simulateStatusOutage)
    private var simulateStatusOutage: Bool

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
                    Text(averageRateLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
                    rateLimitLabel
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
                    Button("Force Refresh") {
                        Task { await usage.refresh() }
                    }
                    .disabled(usage.isRefreshing)
                }
            } footer: {
                Text("Resetting the counters also resets the \u{201c}Tracking since\u{201d} timer so you can benchmark the fetch rate from a fresh baseline. Force Refresh bypasses the debounce but not the rate-limit cooldown.")
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
        .onReceive(ticker) { now in
            tickerDate = now
        }
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

    private var averageRateLabel: String {
        let elapsed = tickerDate.timeIntervalSince(usage.diagnosticsStartedAt)
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
    private var rateLimitLabel: some View {
        if let until = usage.rateLimitedUntil, until > tickerDate {
            let remaining = Int(until.timeIntervalSince(tickerDate))
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
