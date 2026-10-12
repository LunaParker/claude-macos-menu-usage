//
//  SetupChoicesTests.swift
//  ClaudeUsageTests
//
//  The pure choices behind the setup pages and the Settings slider: the
//  refresh stops, the three-way service-status choice, the alert presets
//  and the page sequence.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("PollInterval")
struct PollIntervalTests {

    @Test("the slider stops at 2, 3, 4, 5, 10 and 15 minutes")
    func stops() {
        #expect(PollInterval.stops == [120, 180, 240, 300, 600, 900])
    }

    @Test("a stored value sits on the nearest stop", arguments: [
        (120, 0), (100, 0), (170, 1), (300, 3), (420, 3), (500, 4), (900, 5), (2_000, 5),
    ])
    func nearestStop(seconds: Int, index: Int) {
        #expect(PollInterval.stopIndex(nearestTo: seconds) == index)
    }

    @Test("labels read in minutes", arguments: [(120, "2 minutes"), (300, "5 minutes"), (900, "15 minutes")])
    func labels(seconds: Int, label: String) {
        #expect(PollInterval.label(seconds: seconds) == label)
    }

    @Test("the store honours 2 to 15 minutes and falls back to 5 outside it", arguments: [
        (120, 120), (150, 150), (600, 600), (900, 900), (60, 300), (1_200, 300), (0, 300),
    ])
    func effectiveInterval(stored: Int, effective: Int) {
        #expect(PollInterval.effectiveSeconds(stored: stored) == effective)
    }

    @Test("the store polls at a 15-minute setting")
    func storeUsesLongInterval() {
        let harness = StoreHarness()
        harness.defaults.set(900, forKey: SettingsKeys.pollIntervalSeconds.name)

        #expect(harness.makeStore().pollInterval == .seconds(900))
    }
}

@Suite("ServiceStatusMode")
struct ServiceStatusModeTests {

    @Test("reads the two switches as one choice", arguments: [
        (true, false, ServiceStatusMode.always), (true, true, .degradedOnly), (false, false, .never), (false, true, .never),
    ])
    func readsSwitches(enabled: Bool, hide: Bool, mode: ServiceStatusMode) {
        #expect(ServiceStatusMode(enabled: enabled, hideWhenOperational: hide) == mode)
    }

    @Test("writes the choice back; Never leaves the degraded-only switch as it was")
    func writesSwitches() {
        var enabled = false
        var hide = true

        ServiceStatusMode.always.apply(enabled: &enabled, hideWhenOperational: &hide)
        #expect((enabled, hide) == (true, false))

        ServiceStatusMode.degradedOnly.apply(enabled: &enabled, hideWhenOperational: &hide)
        #expect((enabled, hide) == (true, true))

        ServiceStatusMode.never.apply(enabled: &enabled, hideWhenOperational: &hide)
        #expect((enabled, hide) == (false, true))
    }
}

@Suite("AlertPreset")
struct AlertPresetTests {

    @Test("reads the three threshold switches", arguments: [
        (false, false, false, AlertPreset.none), (false, false, true, .at90), (false, true, true, .at75And90),
        (true, true, true, .all), (true, false, true, .custom), (false, true, false, .custom), (true, false, false, .custom),
    ])
    func readsThresholds(at50: Bool, at75: Bool, at90: Bool, preset: AlertPreset) {
        #expect(AlertPreset(at50: at50, at75: at75, at90: at90) == preset)
    }

    @Test("writes a preset's thresholds; Custom changes nothing")
    func writesThresholds() {
        var at50 = true, at75 = false, at90 = true

        AlertPreset.custom.apply(at50: &at50, at75: &at75, at90: &at90)
        #expect((at50, at75, at90) == (true, false, true))

        AlertPreset.at75And90.apply(at50: &at50, at75: &at75, at90: &at90)
        #expect((at50, at75, at90) == (false, true, true))

        AlertPreset.none.apply(at50: &at50, at75: &at75, at90: &at90)
        #expect((at50, at75, at90) == (false, false, false))
    }

    @Test("Custom is offered only when the current switches match no preset")
    func choices() {
        #expect(AlertPreset.choices(current: .at90) == [.none, .at90, .at75And90, .all])
        #expect(AlertPreset.choices(current: .custom) == [.none, .at90, .at75And90, .all, .custom])
    }
}

@Suite("SetupStep")
struct SetupStepTests {

    @Test("a first run starts at the welcome page; a re-run skips it")
    func firstStep() {
        #expect(SetupStep.first(hasCompletedOnboarding: false) == .welcome)
        #expect(SetupStep.first(hasCompletedOnboarding: true) == .menuBar)
    }

    @Test("the pages run in order, and Back never returns to the welcome page")
    func sequence() {
        #expect(SetupStep.welcome.next == .menuBar)
        #expect(SetupStep.menuBar.next == .alerts)
        #expect(SetupStep.alerts.next == .serviceStatus)
        #expect(SetupStep.serviceStatus.next == .refresh)
        #expect(SetupStep.refresh.next == nil)

        #expect(SetupStep.welcome.previous == nil)
        #expect(SetupStep.menuBar.previous == nil)
        #expect(SetupStep.alerts.previous == .menuBar)
        #expect(SetupStep.refresh.previous == .serviceStatus)
    }

    @Test("progress counts the setup pages only")
    func progress() {
        #expect(SetupStep.welcome.progress == nil)
        #expect(SetupStep.menuBar.progress?.index == 1)
        #expect(SetupStep.refresh.progress?.index == 4)
        #expect(SetupStep.refresh.progress?.count == 4)
    }
}
