//
//  SetupChoices.swift
//  Menu Bar Usage for Claude
//
//  The pure choices behind the setup pages and the Settings slider: the
//  refresh stops, the three-way service-status choice, the alert presets
//  and the order of the setup pages.
//

import Foundation

/// The refresh slider's stops and the range the store honours.
nonisolated enum PollInterval {
    /// 5, 10 and 15 minutes: 3 drew 429s (Oct 2026), and 15 keeps the menu bar
    /// inside its 30-minute staleness limit.
    static let stops = [300, 600, 900]
    static let range = 300...900

    /// A stored value outside the range (an old or hand-edited preference) falls back to the default.
    static func effectiveSeconds(stored: Int) -> Int {
        range.contains(stored) ? stored : SettingsKeys.pollIntervalSeconds.defaultValue
    }

    static func stopIndex(nearestTo seconds: Int) -> Int {
        stops.indices.min { abs(stops[$0] - seconds) < abs(stops[$1] - seconds) } ?? 0
    }

    static func label(seconds: Int) -> String {
        let minutes = max(1, seconds / 60)
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

/// The popover's status.claude.com row as one choice over its two switches.
nonisolated enum ServiceStatusMode: Hashable, CaseIterable, Sendable {
    case always
    case degradedOnly
    case never

    init(enabled: Bool, hideWhenOperational: Bool) {
        if !enabled {
            self = .never
        } else {
            self = hideWhenOperational ? .degradedOnly : .always
        }
    }

    /// Never only switches the row off, so the degraded-only choice survives a round trip.
    func apply(enabled: inout Bool, hideWhenOperational: inout Bool) {
        switch self {
        case .always:
            enabled = true
            hideWhenOperational = false
        case .degradedOnly:
            enabled = true
            hideWhenOperational = true
        case .never:
            enabled = false
        }
    }

    var title: String {
        switch self {
        case .always: "Always"
        case .degradedOnly: "Only when something’s wrong"
        case .never: "Never"
        }
    }
}

/// The usage-alert thresholds as the handful of combinations setup offers.
nonisolated enum AlertPreset: Hashable, Sendable {
    case none
    case at90
    case at75And90
    case all
    /// The switches match no preset (set in Settings); shown so setup doesn't silently change them.
    case custom

    init(at50: Bool, at75: Bool, at90: Bool) {
        switch (at50, at75, at90) {
        case (false, false, false): self = .none
        case (false, false, true): self = .at90
        case (false, true, true): self = .at75And90
        case (true, true, true): self = .all
        default: self = .custom
        }
    }

    func apply(at50: inout Bool, at75: inout Bool, at90: inout Bool) {
        switch self {
        case .none: (at50, at75, at90) = (false, false, false)
        case .at90: (at50, at75, at90) = (false, false, true)
        case .at75And90: (at50, at75, at90) = (false, true, true)
        case .all: (at50, at75, at90) = (true, true, true)
        case .custom: break
        }
    }

    static func choices(current: AlertPreset) -> [AlertPreset] {
        let presets: [AlertPreset] = [.none, .at90, .at75And90, .all]
        return current == .custom ? presets + [.custom] : presets
    }

    var title: String {
        switch self {
        case .none: "No alerts"
        case .at90: "At 90%"
        case .at75And90: "At 75% and 90%"
        case .all: "At 50%, 75% and 90%"
        case .custom: "Custom (as set in Settings)"
        }
    }
}

/// The pages of the setup window. Welcome is the consent step; the rest are optional.
nonisolated enum SetupStep: Int, CaseIterable, Hashable, Sendable {
    case welcome
    case menuBar
    case alerts
    case serviceStatus
    case refresh

    /// A re-run from Settings skips the welcome page: consent was given the first time.
    static func first(hasCompletedOnboarding: Bool) -> SetupStep {
        hasCompletedOnboarding ? .menuBar : .welcome
    }

    var next: SetupStep? {
        SetupStep(rawValue: rawValue + 1)
    }

    /// Never back to the welcome page, whose Continue already started polling.
    var previous: SetupStep? {
        rawValue <= SetupStep.menuBar.rawValue ? nil : SetupStep(rawValue: rawValue - 1)
    }

    /// "Step 2 of 4"; the welcome page isn't counted.
    var progress: (index: Int, count: Int)? {
        self == .welcome ? nil : (rawValue, SetupStep.allCases.count - 1)
    }
}
