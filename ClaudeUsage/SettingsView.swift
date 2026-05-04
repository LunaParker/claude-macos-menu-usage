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
    private var showSessionPercent: Bool = false

    @AppStorage(SettingsKeys.hideSonnetBarWhenZero)
    private var hideSonnetBarWhenZero: Bool = false

    @AppStorage(SettingsKeys.pollIntervalSeconds)
    private var pollIntervalSeconds: Int = defaultPollIntervalSeconds

    @AppStorage(SettingsKeys.preferredBrowserBundleID)
    private var preferredBrowserBundleID: String = ""

    // Service status preferences
    @AppStorage(SettingsKeys.serviceStatusEnabled)
    private var serviceStatusEnabled: Bool = true

    @AppStorage(SettingsKeys.serviceStatusHideWhenOperational)
    private var serviceStatusHideWhenOperational: Bool = false

    @AppStorage(SettingsKeys.monitorClaudeAI)
    private var monitorClaudeAI: Bool = true

    @AppStorage(SettingsKeys.monitorClaudeCode)
    private var monitorClaudeCode: Bool = true

    @AppStorage(SettingsKeys.monitorClaudeAPI)
    private var monitorClaudeAPI: Bool = false

    @AppStorage(SettingsKeys.monitorClaudeConsole)
    private var monitorClaudeConsole: Bool = false

    @AppStorage(SettingsKeys.monitorClaudeCowork)
    private var monitorClaudeCowork: Bool = false

    @AppStorage(SettingsKeys.monitorClaudeForGov)
    private var monitorClaudeForGov: Bool = false

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
                Toggle(isOn: $hideSonnetBarWhenZero) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide Sonnet bar at 0%")
                        Text("Omit the weekly Sonnet bar from the popover when its usage rounds to 0%. Only applies to Max subscribers.")
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
                Toggle(KnownComponent.claudeAI.displayName,       isOn: $monitorClaudeAI)
                Toggle(KnownComponent.claudeCode.displayName,     isOn: $monitorClaudeCode)
                Toggle(KnownComponent.claudeAPI.displayName,      isOn: $monitorClaudeAPI)
                Toggle(KnownComponent.claudeConsole.displayName,  isOn: $monitorClaudeConsole)
                Toggle(KnownComponent.claudeCowork.displayName,   isOn: $monitorClaudeCowork)
                Toggle(KnownComponent.claudeForGov.displayName,   isOn: $monitorClaudeForGov)
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

// MARK: - Notifications

private struct NotificationsSettingsView: View {
    @Environment(UsageStore.self) private var usage

    @AppStorage(SettingsKeys.notifyAt50Percent) private var notifyAt50 = false
    @AppStorage(SettingsKeys.notifyAt75Percent) private var notifyAt75 = false
    @AppStorage(SettingsKeys.notifyAt90Percent) private var notifyAt90 = false
    @AppStorage(SettingsKeys.notifyOnReset) private var notifyOnReset = false

    var body: some View {
        Form {
            if usage.notificationManager.authorizationStatus != .authorized {
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
            await usage.notificationManager.refreshAuthorizationStatus()
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
                if newValue && usage.notificationManager.authorizationStatus == .notDetermined {
                    Task { await usage.notificationManager.requestAuthorization() }
                }
            }
        )
    }

    @ViewBuilder
    private var authorizationBanner: some View {
        let status = usage.notificationManager.authorizationStatus
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
                    Task { await usage.notificationManager.requestAuthorization() }
                }
            } else if status == .denied {
                Button("Open Notification Settings…") {
                    usage.notificationManager.openNotificationSettings()
                }
            }
        }
    }
}

// MARK: - Developer

private struct DeveloperSettingsView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(\.openWindow) private var openWindow

    /// Drives relative-date labels to re-render once a second while the
    /// tab is visible so "Updated 14 sec ago" stays accurate without the
    /// user having to click away and back.
    @State private var tickerDate: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Confirmation state for the destructive factory-reset button.
    @State private var showingResetConfirmation: Bool = false

    @AppStorage(SettingsKeys.simulateStatusOutage)
    private var simulateStatusOutage: Bool = false

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
                    Task { await usage.notificationManager.sendTestNotification() }
                }
                .disabled(
                    usage.notificationManager.authorizationStatus != .authorized
                    && usage.notificationManager.authorizationStatus != .provisional
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
        switch usage.state {
        case .idle:
            Text("Idle").foregroundStyle(.secondary)
        case .loading:
            Text("Loading…").foregroundStyle(.secondary)
        case .loaded:
            Label("Loaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.green)
        case .missingCredentials:
            Label("Missing credentials", systemImage: "key.slash")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.orange)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
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
        case nil:
            Text("The authentication method will be shown after the first successful credential read.")
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

// MARK: - Diagnostic Log Window

struct DiagnosticLogView: View {
    @Environment(DiagnosticLog.self) private var log
    @State private var filterCategory: DiagnosticLog.Entry.Category?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Category", selection: $filterCategory) {
                Text("All").tag(nil as DiagnosticLog.Entry.Category?)
                ForEach(DiagnosticLog.Entry.Category.allCases, id: \.self) { cat in
                    Text(cat.rawValue).tag(cat as DiagnosticLog.Entry.Category?)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Spacer()

            Text("\(filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button("Clear") { log.clear() }
                .buttonStyle(.borderless)
                .font(.caption)

            Button("Reveal Log File") { log.revealInFinder() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)

                    Text(entry.category.rawValue)
                        .font(.caption.bold())
                        .foregroundStyle(categoryColor(entry.category))
                        .frame(width: 60, alignment: .leading)

                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            .onChange(of: log.entries.count) { _, _ in
                if let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredEntries: [DiagnosticLog.Entry] {
        guard let cat = filterCategory else { return log.entries }
        return log.entries.filter { $0.category == cat }
    }

    private func categoryColor(_ cat: DiagnosticLog.Entry.Category) -> Color {
        switch cat {
        case .keychain: .orange
        case .api: .blue
        case .refresh: .purple
        case .status: .teal
        }
    }
}

#Preview {
    SettingsView()
}
