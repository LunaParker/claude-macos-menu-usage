//
//  Settings.swift
//  Menu Bar Usage for Claude
//
//  Preference keys with their defaults, launch-time preference migrations
//  and window ids.
//

import Foundation
import SwiftUI

/// A preference's UserDefaults key and the value it has until the user sets one.
nonisolated struct SettingKey<Value: Sendable>: Sendable {
    let name: String
    let defaultValue: Value
}

/// Every preference the app stores. `@AppStorage` and direct reads both take
/// these keys, so a default is written exactly once.
nonisolated enum SettingsKeys {
    static let hasCompletedOnboarding = SettingKey(name: "hasCompletedOnboarding", defaultValue: false)
    /// Which quota's percentage sits beside the menu bar gauge.
    static let menuBarMetric = SettingKey(name: "menuBarMetric", defaultValue: MenuBarMetric.off)
    /// The elapsed-window tick and on-pace verdict on each quota bar.
    static let showPaceOnBars = SettingKey(name: "showPaceOnBars", defaultValue: true)
    /// Seconds between background polls. `UsageStore` falls back to the default
    /// for anything outside 120–900 (`PollInterval`).
    static let pollIntervalSeconds = SettingKey(name: "pollIntervalSeconds", defaultValue: 300)

    static let notifyAt50Percent = SettingKey(name: "notifyAt50Percent", defaultValue: false)
    static let notifyAt75Percent = SettingKey(name: "notifyAt75Percent", defaultValue: false)
    static let notifyAt90Percent = SettingKey(name: "notifyAt90Percent", defaultValue: false)
    static let notifyOnReset = SettingKey(name: "notifyOnReset", defaultValue: false)
    /// Which quotas the thresholds above apply to.
    static let notifyForSession = SettingKey(name: "notifyForSession", defaultValue: true)
    static let notifyForWeekly = SettingKey(name: "notifyForWeekly", defaultValue: true)
    static let notifyForScopedWeekly = SettingKey(name: "notifyForScopedWeekly", defaultValue: true)

    /// Bundle id of the browser for web links; empty means the system default.
    static let preferredBrowserBundleID = SettingKey(name: "preferredBrowserBundleID", defaultValue: "")

    /// Master switch for the popover's status.claude.com row.
    static let serviceStatusEnabled = SettingKey(name: "serviceStatusEnabled", defaultValue: true)
    /// Hides the status row while every monitored service is operational.
    static let serviceStatusHideWhenOperational = SettingKey(name: "serviceStatusHideWhenOperational", defaultValue: false)
    /// Developer tab: render the status row from a fabricated outage.
    static let simulateStatusOutage = SettingKey(name: "simulateStatusOutage", defaultValue: false)
}

extension UserDefaults {
    nonisolated subscript<Value>(key: SettingKey<Value>) -> Value {
        object(forKey: key.name) as? Value ?? key.defaultValue
    }

    nonisolated subscript<Value: RawRepresentable>(key: SettingKey<Value>) -> Value where Value.RawValue == String {
        string(forKey: key.name).flatMap(Value.init(rawValue:)) ?? key.defaultValue
    }
}

extension AppStorage {
    init(_ key: SettingKey<Bool>, store: UserDefaults? = nil) where Value == Bool {
        self.init(wrappedValue: key.defaultValue, key.name, store: store)
    }

    init(_ key: SettingKey<Int>, store: UserDefaults? = nil) where Value == Int {
        self.init(wrappedValue: key.defaultValue, key.name, store: store)
    }

    init(_ key: SettingKey<String>, store: UserDefaults? = nil) where Value == String {
        self.init(wrappedValue: key.defaultValue, key.name, store: store)
    }

    init(_ key: SettingKey<Value>, store: UserDefaults? = nil) where Value: RawRepresentable, Value.RawValue == String {
        self.init(wrappedValue: key.defaultValue, key.name, store: store)
    }
}

/// Rewrites preferences that older builds stored differently. Runs first at
/// launch, before anything reads a preference.
nonisolated enum PreferenceMigrations {
    static func run(on defaults: UserDefaults) {
        // Onboarding was once scoped to the bundle path: hasCompletedOnboarding_<hash>.
        let scoped = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("hasCompletedOnboarding_") }
        if scoped.contains(where: { defaults.bool(forKey: $0) }) {
            defaults.set(true, forKey: SettingsKeys.hasCompletedOnboarding.name)
        }
        scoped.forEach(defaults.removeObject(forKey:))

        // The Sonnet bar and its setting were removed when Sonnet stopped being a separate quota.
        defaults.removeObject(forKey: "hideSonnetBarWhenZero")

        // The menu bar percentage was a session-only switch before the metric picker.
        if let showSession = defaults.object(forKey: "showSessionPercentInMenuBar") as? Bool {
            if showSession, defaults.string(forKey: SettingsKeys.menuBarMetric.name) == nil {
                defaults.set(MenuBarMetric.session.rawValue, forKey: SettingsKeys.menuBarMetric.name)
            }
            defaults.removeObject(forKey: "showSessionPercentInMenuBar")
        }

        // Alert state was a single session tracker before the weekly and model-scoped alerts.
        if let session = defaults.data(forKey: "sessionAlertTracker") {
            defaults.set(session, forKey: UsageAlerts.storageKey(for: .session))
            defaults.removeObject(forKey: "sessionAlertTracker")
        }
    }
}

/// The stable window id for the welcome/onboarding window opened at launch.
enum WindowIDs {
    static let onboarding = "onboarding"
    static let diagnosticLog = "diagnosticLog"
}
