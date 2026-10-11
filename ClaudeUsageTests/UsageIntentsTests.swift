//
//  UsageIntentsTests.swift
//  ClaudeUsageTests
//
//  The Shortcuts value built from a snapshot, and the sentence Siri says.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ClaudeUsageEntity")
struct ClaudeUsageEntityTests {

    @Test("carries every quota, the model limit and extra usage when present")
    func fullSnapshot() {
        var snapshot = UsageSnapshot.snapshot(session: 0.55, weekly: 0.3, fable: 0.8)
        snapshot.extraUsage = UsageSnapshot.ExtraUsageSummary(fraction: 0.25, percentLabel: "25%", used: 5, monthlyLimit: 20)

        let entity = ClaudeUsageEntity(snapshot: snapshot)

        #expect(entity.sessionPercent == 55)
        #expect(entity.sessionResetsAt == TestSnapshots.sessionWindow)
        #expect(entity.weeklyPercent == 30)
        #expect(entity.weeklyResetsAt == TestSnapshots.weeklyWindow)
        #expect(entity.modelName == "Fable")
        #expect(entity.modelPercent == 80)
        #expect(entity.modelResetsAt == TestSnapshots.weeklyWindow)
        #expect(entity.extraUsageUsed == 5)
        #expect(entity.extraUsageRemaining == 15)
        #expect(entity.updatedAt == TestSnapshots.now)
    }

    @Test("leaves the model limit and extra usage empty when the plan has neither")
    func minimalSnapshot() {
        let entity = ClaudeUsageEntity(snapshot: .snapshot(session: 0.55, weekly: 0.3))

        #expect(entity.modelName == nil)
        #expect(entity.modelPercent == nil)
        #expect(entity.modelResetsAt == nil)
        #expect(entity.extraUsageUsed == nil)
        #expect(entity.extraUsageRemaining == nil)
    }

    @Test("the spoken summary names each quota and when it resets")
    func spokenSummary() {
        let locale = Locale(identifier: "en_US")
        let timeZone = TimeZone(identifier: "America/Toronto")!

        let full = UsageSnapshot.snapshot(session: 0.55, weekly: 0.3, fable: 0.8)
        #expect(ClaudeUsageEntity.summary(of: full, now: TestSnapshots.now, locale: locale, timeZone: timeZone)
                == "Session 55%, resets at 6:00\u{202F}AM. Weekly 30%, resets Monday at 3:00\u{202F}AM. Fable 80%, resets Monday at 3:00\u{202F}AM.")

        let plain = UsageSnapshot.snapshot(session: 0.55, sessionResetsAt: nil, weekly: 0.3)
        #expect(ClaudeUsageEntity.summary(of: plain, now: TestSnapshots.now, locale: locale, timeZone: timeZone)
                == "Session 55%. Weekly 30%, resets Monday at 3:00\u{202F}AM.")

        let tomorrow = UsageSnapshot.snapshot(session: 0.55, sessionResetsAt: TestSnapshots.now.addingTimeInterval(23 * 3600), weekly: 0.3)
        #expect(ClaudeUsageEntity.summary(of: tomorrow, now: TestSnapshots.now, locale: locale, timeZone: timeZone)
                == "Session 55%, resets tomorrow at 2:00\u{202F}AM. Weekly 30%, resets Monday at 3:00\u{202F}AM.")
    }

    @Test("the Shortcuts error text is plain, with no Markdown")
    func errorTextIsPlain() {
        let text = String(localized: UsageRequestError.unavailable(.signInExpired(nextAttempt: nil)).localizedStringResource)

        #expect(text.hasPrefix("Claude Code needs you to sign in again. "))
        #expect(!text.contains("`"))
    }
}
