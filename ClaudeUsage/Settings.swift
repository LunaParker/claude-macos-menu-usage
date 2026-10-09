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
    static let showSessionPercentInMenuBar = SettingKey(name: "showSessionPercentInMenuBar", defaultValue: false)
    /// Seconds between background polls. `UsageStore` falls back to the default
    /// for anything outside 120–300.
    static let pollIntervalSeconds = SettingKey(name: "pollIntervalSeconds", defaultValue: 300)

    static let notifyAt50Percent = SettingKey(name: "notifyAt50Percent", defaultValue: false)
    static let notifyAt75Percent = SettingKey(name: "notifyAt75Percent", defaultValue: false)
    static let notifyAt90Percent = SettingKey(name: "notifyAt90Percent", defaultValue: false)
    static let notifyOnReset = SettingKey(name: "notifyOnReset", defaultValue: false)

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
}

/// Rewrites preferences that older builds stored differently. Runs at launch,
/// before any view reads a preference.
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
    }
}

/// The stable window id for the welcome/onboarding window opened at launch.
enum WindowIDs {
    static let onboarding = "onboarding"
    static let diagnosticLog = "diagnosticLog"
}
