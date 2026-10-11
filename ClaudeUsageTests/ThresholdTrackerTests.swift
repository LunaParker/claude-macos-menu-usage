//
//  ThresholdTrackerTests.swift
//  ClaudeUsageTests
//
//  ThresholdTracker decides which alerts are due for one quota's window.
//  Each threshold fires at most once per window, one reading sends at most
//  one alert, a launch or a new window never bursts stale alerts, and
//  crossings wait for permission and for the user to enable them.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ThresholdTracker")
struct ThresholdTrackerTests {

    private let window = Date(timeIntervalSince1970: 1_800_000_000)
    private let all: Set<Int> = [50, 75, 90]

    @Test("an enabled threshold fires once per window")
    func firesOnce() {
        var tracker = ThresholdTracker()

        #expect(evaluate(&tracker, 0.40) == [])
        #expect(evaluate(&tracker, 0.55) == [.crossed(percent: 50)])
        #expect(evaluate(&tracker, 0.60) == [])
    }

    @Test("the first evaluation fires only the highest threshold already passed")
    func noBurstOnLaunch() {
        var tracker = ThresholdTracker()

        #expect(evaluate(&tracker, 0.80) == [.crossed(percent: 75)])
        #expect(evaluate(&tracker, 0.92) == [.crossed(percent: 90)])
    }

    @Test("several thresholds passed in one reading fire only the highest")
    func oneReadingOneAlert() {
        var tracker = ThresholdTracker()
        _ = evaluate(&tracker, 0.10)

        #expect(evaluate(&tracker, 0.92) == [.crossed(percent: 90)])
        #expect(evaluate(&tracker, 0.93) == [])
    }

    @Test("a disabled threshold stays pending until the user enables it")
    func waitsForEnable() {
        var tracker = ThresholdTracker()
        _ = evaluate(&tracker, 0.10)

        #expect(evaluate(&tracker, 0.55, enabled: []) == [])
        #expect(evaluate(&tracker, 0.55, enabled: [50]) == [.crossed(percent: 50)])
    }

    @Test("without notification permission a crossing stays pending")
    func waitsForPermission() {
        var tracker = ThresholdTracker()
        _ = evaluate(&tracker, 0.10)

        #expect(evaluate(&tracker, 0.55, canDeliver: false) == [])
        #expect(evaluate(&tracker, 0.55) == [.crossed(percent: 50)])
    }

    @Test("a new session window re-arms the thresholds")
    func newWindowRearms() {
        var tracker = ThresholdTracker()
        _ = evaluate(&tracker, 0.10)
        #expect(evaluate(&tracker, 0.55) == [.crossed(percent: 50)])

        let next = window.addingTimeInterval(5 * 3600)
        #expect(evaluate(&tracker, 0.10, resetsAt: next) == [])
        #expect(evaluate(&tracker, 0.55, resetsAt: next) == [.crossed(percent: 50)])
    }

    @Test("sub-second jitter in resets_at is not a new window")
    func jitterIsSameWindow() {
        var tracker = ThresholdTracker()
        _ = evaluate(&tracker, 0.10)
        #expect(evaluate(&tracker, 0.55) == [.crossed(percent: 50)])

        #expect(evaluate(&tracker, 0.56, resetsAt: window.addingTimeInterval(0.7)) == [])
    }

    @Test("a window that reached 100% raises the reset alert when it rotates")
    func resetAfterCapacity() {
        var tracker = ThresholdTracker()
        _ = evaluate(&tracker, 1.0)

        #expect(evaluate(&tracker, 0.0, resetsAt: window.addingTimeInterval(5 * 3600)) == [.windowReset])
    }

    @Test("no reset alert when the window never reached 100%, or when the user turned it off")
    func noResetWithoutCapacityOrSetting() {
        var below = ThresholdTracker()
        _ = evaluate(&below, 0.95)
        #expect(evaluate(&below, 0.0, resetsAt: window.addingTimeInterval(5 * 3600)) == [])

        var off = ThresholdTracker()
        _ = evaluate(&off, 1.0)
        #expect(evaluate(&off, 0.0, resetsAt: window.addingTimeInterval(5 * 3600), resetAlert: false) == [])
    }

    private func evaluate(
        _ tracker: inout ThresholdTracker,
        _ fraction: Double,
        resetsAt: Date? = nil,
        enabled: Set<Int>? = nil,
        resetAlert: Bool = true,
        canDeliver: Bool = true
    ) -> [ThresholdTracker.Event] {
        tracker.evaluate(
            fraction: fraction,
            resetsAt: resetsAt ?? window,
            enabled: enabled ?? all,
            resetAlertEnabled: resetAlert,
            canDeliver: canDeliver
        )
    }
}
