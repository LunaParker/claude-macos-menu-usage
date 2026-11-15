//
//  ResetsRefreshPolicyTests.swift
//  ClaudeUsageTests
//
//  When the resets request goes out: hourly, or sooner after the usage itself
//  changes (a reset used on claude.ai drops a bar), never within five minutes.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ResetsRefreshPolicy")
struct ResetsRefreshPolicyTests {
    typealias F = ResetFixtures

    private let window = F.now.addingTimeInterval(3 * 86_400)

    private func due(after seconds: TimeInterval, from previous: UsageSnapshot?, to current: UsageSnapshot) -> Bool {
        ResetsRefreshPolicy.isDue(lastAttempt: F.now, previous: previous, current: current, now: F.now.addingTimeInterval(seconds))
    }

    @Test("due when the resets were never checked")
    func neverChecked() {
        #expect(ResetsRefreshPolicy.isDue(lastAttempt: nil, previous: nil, current: F.snapshot(weekly: 0.4, fable: 0.1), now: F.now))
    }

    @Test("hourly while nothing changes")
    func hourly() {
        let same = F.snapshot(weekly: 0.4, fable: 0.1, resetsAt: window)
        #expect(!due(after: 59 * 60, from: same, to: same))
        #expect(due(after: 60 * 60, from: same, to: same))
    }

    @Test("usage rising is not a change")
    func risingUsage() {
        let before = F.snapshot(weekly: 0.4, fable: 0.1, resetsAt: window)
        let after = F.snapshot(weekly: 0.5, fable: 0.2, resetsAt: window)
        #expect(!due(after: 10 * 60, from: before, to: after))
    }

    @Test("a dropped bar, a moved window or a bar newly at 100% is due after five minutes, not before")
    func changes() {
        let before = F.snapshot(weekly: 0.9, fable: 0.3, resetsAt: window)
        let dropped = F.snapshot(weekly: 0.1, fable: 0.3, resetsAt: window)
        let moved = F.snapshot(weekly: 0.9, fable: 0.3, resetsAt: window.addingTimeInterval(7 * 86_400))
        let full = F.snapshot(weekly: 1, fable: 0.3, resetsAt: window)
        let jittered = F.snapshot(weekly: 0.9, fable: 0.3, resetsAt: window.addingTimeInterval(0.7))

        for after in [dropped, moved, full] {
            #expect(!due(after: 4 * 60, from: before, to: after))
            #expect(due(after: 5 * 60, from: before, to: after))
        }
        #expect(!due(after: 10 * 60, from: before, to: jittered))
    }

    @Test("a bar that appears is not a change")
    func newBar() {
        let before = F.snapshot(weekly: 0.4, fable: nil, resetsAt: window)
        let after = F.snapshot(weekly: 0.4, fable: 0.1, resetsAt: window)
        #expect(!due(after: 10 * 60, from: before, to: after))
    }
}
