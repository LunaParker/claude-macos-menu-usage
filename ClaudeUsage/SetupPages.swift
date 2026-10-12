//
//  SetupPages.swift
//  Menu Bar Usage for Claude
//
//  The optional pages after the welcome page: what the menu bar shows,
//  usage alerts, service status, and refresh and startup. Every choice
//  applies as it's made, like in Settings.
//

import SwiftUI
import UserNotifications

// MARK: - Page frame

/// A setup page: a question, a line of explanation, then its controls.
struct SetupPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A caption-sized heading over a group of controls.
private struct SetupGroupLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
    }
}

// MARK: - Menu bar

struct MenuBarSetupPage: View {
    @Environment(UsageStore.self) private var usage
    @AppStorage(SettingsKeys.menuBarMetric) private var metric: MenuBarMetric
    @AppStorage(SettingsKeys.showPaceOnBars) private var showPace: Bool

    var body: some View {
        let now = Date()
        let live = usage.presentation.menuBarSnapshot(now: now)
        let snapshot = live ?? SetupPreview.sample(now: now)
        SetupPage(
            title: "What should the menu bar show?",
            subtitle: "A percentage beside the gauge. While a quota is used up, the menu bar counts down to its reset instead."
        ) {
            HStack(alignment: .top, spacing: 28) {
                Picker("Show in menu bar", selection: $metric) {
                    ForEach(options(live: live), id: \.self) { option in
                        Text(title(for: option, live: live)).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    MenuBarItemView(content: MenuBarContent(snapshot: snapshot, metric: metric, now: now))
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text(live == nil ? "Preview with sample data" : "Preview with your current usage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(minWidth: 200)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            }

            Divider()

            Toggle(isOn: $showPace) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show pace on usage bars")
                    Text("A tick marks how much of each window has passed, and the caption says whether you’re on pace.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)

            QuotaBarView(bar: snapshot.weekly)
                .padding(14)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// The model option only when the plan has that limit (or before data arrives),
    /// and always when it's the current choice.
    private func options(live: UsageSnapshot?) -> [MenuBarMetric] {
        MenuBarMetric.allCases.filter { option in
            option != .scopedWeekly || live == nil || live?.scopedWeekly != nil || metric == .scopedWeekly
        }
    }

    private func title(for option: MenuBarMetric, live: UsageSnapshot?) -> String {
        switch option {
        case .off: "Just the gauge"
        case .scopedWeekly: live?.scopedWeekly.map { "\($0.title) weekly limit" } ?? option.title
        default: option.title
        }
    }
}

// MARK: - Alerts

struct AlertsSetupPage: View {
    @Environment(UsageStore.self) private var usage
    @Environment(NotificationManager.self) private var notifications

    @AppStorage(SettingsKeys.notifyAt50Percent) private var notifyAt50: Bool
    @AppStorage(SettingsKeys.notifyAt75Percent) private var notifyAt75: Bool
    @AppStorage(SettingsKeys.notifyAt90Percent) private var notifyAt90: Bool
    @AppStorage(SettingsKeys.notifyOnReset) private var notifyOnReset: Bool
    @AppStorage(SettingsKeys.notifyForSession) private var notifyForSession: Bool
    @AppStorage(SettingsKeys.notifyForWeekly) private var notifyForWeekly: Bool
    @AppStorage(SettingsKeys.notifyForScopedWeekly) private var notifyForScopedWeekly: Bool

    var body: some View {
        let preset = AlertPreset(at50: notifyAt50, at75: notifyAt75, at90: notifyAt90)
        let live = usage.presentation.menuBarSnapshot(now: Date())
        SetupPage(
            title: "Want a heads-up before you hit a limit?",
            subtitle: "Get a notification as a quota fills up. Each alert fires once per window, so you won’t be pestered."
        ) {
            if notifications.authorizationStatus == .denied {
                NotificationAuthorizationBanner()
                    .padding(14)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                SetupGroupLabel(text: "Notify me")
                Picker("Notify me", selection: presetBinding) {
                    ForEach(AlertPreset.choices(current: preset), id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Toggle("Also tell me when a used-up quota resets", isOn: resetBinding)
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                SetupGroupLabel(text: "For")
                Toggle("Current session", isOn: $notifyForSession)
                Toggle("Weekly limit", isOn: $notifyForWeekly)
                if live == nil || live?.scopedWeekly != nil {
                    Toggle(live?.scopedWeekly.map { "\($0.title) weekly limit" } ?? "Model weekly limit (Max plans)", isOn: $notifyForScopedWeekly)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(preset == .none && !notifyOnReset)
        }
        .task {
            await notifications.refreshAuthorizationStatus()
        }
    }

    private var presetBinding: Binding<AlertPreset> {
        Binding(
            get: { AlertPreset(at50: notifyAt50, at75: notifyAt75, at90: notifyAt90) },
            set: { preset in
                preset.apply(at50: &notifyAt50, at75: &notifyAt75, at90: &notifyAt90)
                if preset != .none {
                    notifications.requestAuthorizationIfNeeded()
                }
            }
        )
    }

    private var resetBinding: Binding<Bool> {
        Binding(
            get: { notifyOnReset },
            set: { isOn in
                notifyOnReset = isOn
                if isOn {
                    notifications.requestAuthorizationIfNeeded()
                }
            }
        )
    }
}

// MARK: - Service status

struct ServiceStatusSetupPage: View {
    @AppStorage(SettingsKeys.serviceStatusEnabled) private var enabled: Bool
    @AppStorage(SettingsKeys.serviceStatusHideWhenOperational) private var hideWhenOperational: Bool

    var body: some View {
        let mode = ServiceStatusMode(enabled: enabled, hideWhenOperational: hideWhenOperational)
        SetupPage(
            title: "Show Claude’s service status?",
            subtitle: "The popover can show a row from status.claude.com. It’s fetched only when you open the popover, at most every five minutes."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                SetupGroupLabel(text: "Show the status row")
                Picker("Show the status row", selection: modeBinding) {
                    ForEach(ServiceStatusMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                SetupGroupLabel(text: "Services to watch")
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(KnownComponent.allCases) { component in
                        MonitoredServiceToggle(component: component)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .disabled(mode == .never)
        }
    }

    private var modeBinding: Binding<ServiceStatusMode> {
        Binding(
            get: { ServiceStatusMode(enabled: enabled, hideWhenOperational: hideWhenOperational) },
            set: { $0.apply(enabled: &enabled, hideWhenOperational: &hideWhenOperational) }
        )
    }
}

// MARK: - Refresh and startup

struct RefreshSetupPage: View {
    var body: some View {
        SetupPage(
            title: "How often should it check?",
            subtitle: "Drag to choose how often your usage is fetched in the background."
        ) {
            PollIntervalSlider()
                .padding(14)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))

            Divider()

            LaunchAtLoginToggle()
                .toggleStyle(.switch)

            Text("You can change any of this later in Settings (⌘,).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sample data

/// What the previews show before the first fetch has come back.
enum SetupPreview {
    static func sample(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            session: bar(.session, "Current Session", 0.34, now.addingTimeInterval(2.5 * 3600)),
            weekly: bar(.weekly, "Weekly Limit", 0.48, now.addingTimeInterval(3 * 86_400)),
            scopedWeekly: bar(.scopedWeekly, "Fable", 0.41, now.addingTimeInterval(3 * 86_400)),
            extraUsage: nil,
            fetchedAt: now
        )
    }

    private static func bar(_ kind: UsageSnapshot.Bar.Kind, _ title: String, _ fraction: Double, _ resetsAt: Date) -> UsageSnapshot.Bar {
        UsageSnapshot.Bar(id: kind, title: title, fraction: fraction, percentLabel: "\(Int((fraction * 100).rounded()))%", resetsAt: resetsAt)
    }
}
