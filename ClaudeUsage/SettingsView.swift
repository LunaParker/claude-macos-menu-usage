//
//  SettingsView.swift
//  Menu Bar Usage for Claude
//
//  Contents of the app's Settings (Preferences) window, presented by the
//  cog button in the popover header via `openSettings`. Uses a TabView
//  with two tabs: "General" for user-facing preferences, "Developer" for
//  the fetch diagnostic counters.
//

import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
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

    @AppStorage(SettingsKeys.pollIntervalSeconds)
    private var pollIntervalSeconds: Int = defaultPollIntervalSeconds

    @Environment(UsageStore.self) private var usage

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
        }
        .formStyle(.grouped)
        .onAppear {
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

// MARK: - Developer

private struct DeveloperSettingsView: View {
    @Environment(UsageStore.self) private var usage

    /// Drives relative-date labels to re-render once a second while the
    /// tab is visible so "Updated 14 sec ago" stays accurate without the
    /// user having to click away and back.
    @State private var tickerDate: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Confirmation state for the destructive factory-reset button.
    @State private var showingResetConfirmation: Bool = false

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
                Text("Resetting the counters also resets the “Tracking since” timer so you can benchmark the fetch rate from a fresh baseline. Force Refresh bypasses the debounce but not the rate-limit cooldown.")
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
