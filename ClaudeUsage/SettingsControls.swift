//
//  SettingsControls.swift
//  Menu Bar Usage for Claude
//
//  Controls shared by the Settings window and the setup pages, so the two
//  can't drift apart.
//

import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

extension Binding<MenuBarMetric> {
    /// For the menu bar pickers: shows the choice the menu bar actually displays
    /// for these quotas, and stores a pick as is.
    func resolved(for snapshot: UsageSnapshot?) -> Binding<MenuBarMetric> {
        Binding(get: { wrappedValue.resolved(for: snapshot) }, set: { wrappedValue = $0 })
    }
}

/// The refresh interval as a slider over `PollInterval.stops`. Reschedules
/// polling on change, wherever it's shown.
struct PollIntervalSlider: View {
    @AppStorage(SettingsKeys.pollIntervalSeconds) private var seconds: Int
    @Environment(UsageStore.self) private var usage

    var body: some View {
        let label = PollInterval.label(seconds: PollInterval.stops[index])
        VStack(alignment: .leading, spacing: 8) {
            Text("Refresh every \(label)")
                .monospacedDigit()
            Slider(
                value: indexBinding,
                in: 0...Double(PollInterval.stops.count - 1),
                step: 1,
                label: { Text("Refresh interval") },
                minimumValueLabel: { Text("Fresher").font(.caption).foregroundStyle(.secondary) },
                maximumValueLabel: { Text("Lighter").font(.caption).foregroundStyle(.secondary) },
                tick: { value in
                    SliderTick(value) { Text("\(PollInterval.stops[Int(value)] / 60)") }
                }
            )
            .labelsHidden()
            .accessibilityLabel("Refresh interval")
            .accessibilityValue(label)
            Text("Usage is fetched in the background at this pace, and opening the popover fetches too and restarts the countdown. Anthropic rate-limits checks more often than every 5 minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: seconds) { _, _ in
            // Takes effect now rather than when the booked poll comes due (up to 15 minutes).
            usage.reschedulePolling()
        }
    }

    private var index: Int { PollInterval.stopIndex(nearestTo: seconds) }

    private var indexBinding: Binding<Double> {
        Binding(
            get: { Double(index) },
            set: { seconds = PollInterval.stops[Int($0.rounded())] }
        )
    }
}

/// Launch at login through `SMAppService`. The system is the source of truth,
/// since the user can change it in System Settings → General → Login Items.
struct LaunchAtLoginToggle: View {
    @State private var isOn = false
    /// Why the last change didn't take, shown under the toggle.
    @State private var message: String?

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { setEnabled($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Launch at login")
                Text("Start Menu Bar Usage for Claude automatically when you log in to your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            isOn = SMAppService.mainApp.status == .enabled
        }
    }

    private func setEnabled(_ enabled: Bool) {
        message = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "Couldn’t update login item: \(error.localizedDescription)"
        }
        // Registration can succeed and still wait for the user's approval.
        let status = SMAppService.mainApp.status
        isOn = status == .enabled
        switch status {
        case .requiresApproval:
            message = "Approval needed. Open System Settings → General → Login Items & Extensions and enable Menu Bar Usage for Claude."
        case .notFound:
            message = "macOS can’t find the app bundle. Move Menu Bar Usage for Claude into /Applications and try again."
        default:
            break
        }
    }
}

/// Whether one status.claude.com component is monitored.
struct MonitoredServiceToggle: View {
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

/// Shown while notifications aren't allowed: how to allow them.
struct NotificationAuthorizationBanner: View {
    @Environment(NotificationManager.self) private var notifications

    var body: some View {
        let status = notifications.authorizationStatus
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(status == .notDetermined
                     ? "Notifications have not been enabled yet."
                     : "Notifications are turned off for this app.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            Text(status == .notDetermined
                 ? "Enable notifications to receive usage alerts. You can also just switch an alert on — macOS will ask for permission automatically."
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
