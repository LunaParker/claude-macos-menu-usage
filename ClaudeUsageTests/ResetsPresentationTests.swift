//
//  ResetsPresentationTests.swift
//  ClaudeUsageTests
//
//  What the popover shows for limit resets: nothing, one row, or the card
//  under a bar at 100%, and the words each uses.
//

import Foundation
import Testing
@testable import ClaudeUsage

@Suite("ResetsPresentation")
struct ResetsPresentationTests {
    typealias F = ResetFixtures

    private func make(_ resets: LimitResets?, _ snapshot: UsageSnapshot, _ visibility: ResetVisibility = .always) -> ResetsPresentation {
        ResetsPresentation.make(resets: resets, snapshot: snapshot, visibility: visibility, now: F.now, locale: F.locale, timeZone: F.timeZone)
    }

    @Test("several kinds of reset: the count and the next to expire")
    func rowSeveral() {
        let shown = make(F.all, F.snapshot(weekly: 0.43, fable: 0.02))
        #expect(shown == .row(.init(title: "3 limit resets available", detail: "Next to expire: weekly reset, Dec 10", isSimulated: false)))
    }

    @Test("one kind of reset names it, with the year when it isn't this one")
    func rowOneKind() {
        let weekly = make(LimitResets(grants: [F.weekly]), F.snapshot(weekly: 0.43, fable: 0.02))
        #expect(weekly == .row(.init(title: "1 limit reset available", detail: "Weekly reset, expires Dec 10", isSimulated: false)))

        let fable = make(LimitResets(grants: [F.fableA, F.fableB]), F.snapshot(weekly: 0.43, fable: 0.02))
        #expect(fable == .row(.init(title: "2 limit resets available", detail: "Fable resets, expire Mar 9, 2027", isSimulated: false)))
    }

    @Test("From 75% shows only the weekly reset while Fable is low")
    func rowFiltered() {
        let shown = make(F.all, F.snapshot(weekly: 0.78, fable: 0.12), .nearLimit)
        #expect(shown == .row(.init(title: "1 limit reset available", detail: "Weekly reset, expires Dec 10", isSimulated: false)))
    }

    @Test("the weekly limit at 100% gets the card, with the other resets as a footnote")
    func cardWeekly() {
        let shown = make(F.all, F.snapshot(weekly: 1, fable: 0.38))
        #expect(shown == .card(.init(
            bar: .weekly,
            title: "A reset can clear your weekly limit",
            body: "Your weekly reset clears your weekly and Fable limits now, instead of in 2 days. It expires Dec 10.",
            footnote: "2 Fable resets also available, expiring Mar 9, 2027.",
            isSimulated: false
        )))
    }

    @Test("in a filtered mode, resets for bars below the threshold leave the footnote out")
    func cardFiltered() {
        let shown = make(F.all, F.snapshot(weekly: 1, fable: 0.38), .atLimit)
        guard case .card(let card) = shown else {
            Issue.record("expected a card, got \(shown)")
            return
        }
        #expect(card.footnote == nil)
    }

    @Test("Fable at 100% suggests a Fable reset before the broader weekly one")
    func cardFable() {
        let shown = make(F.all, F.snapshot(weekly: 0.6, fable: 1))
        #expect(shown == .card(.init(
            bar: .scopedWeekly,
            title: "A reset can clear your Fable limit",
            body: "One of your 2 Fable resets clears your Fable limit now, instead of in 2 days. They expire Mar 9, 2027.",
            footnote: "1 weekly reset also available, expiring Dec 10.",
            isSimulated: false
        )))
    }

    @Test("a bar at 100% that no surfaced reset clears keeps the row")
    func fullBarWithoutReset() {
        let fableOnly = LimitResets(grants: [F.fableA])
        let shown = make(fableOnly, F.snapshot(weekly: 1, fable: 0.2))
        #expect(shown == .row(.init(title: "1 limit reset available", detail: "Fable reset, expires Mar 9, 2027", isSimulated: false)))
    }

    @Test("nothing to show is hidden", arguments: [ResetVisibility.always, .never])
    func hidden(visibility: ResetVisibility) {
        #expect(make(LimitResets(grants: []), F.snapshot(weekly: 1, fable: 1), visibility) == .hidden)
        #expect(make(nil, F.snapshot(weekly: 1, fable: 1), visibility) == .hidden)
        if visibility == .never {
            #expect(make(F.all, F.snapshot(weekly: 1, fable: 1), visibility) == .hidden)
        }
    }

    @Test("the simulated reset is marked")
    func simulatedMark() {
        let resets = LimitResets.displayed(nil, simulate: true, now: F.now, timeZone: F.timeZone)
        let shown = make(resets, F.snapshot(weekly: 0.4, fable: nil))
        #expect(shown == .row(.init(title: "1 limit reset available", detail: "Weekly reset, expires Nov 21", isSimulated: true)))
    }

    @Test("the session's card says current session")
    func sessionCard() {
        let session = LimitResets(grants: [LimitResets.Grant(id: "s", count: 1, expiresAt: nil, clears: [.session])])
        let snapshot = F.snapshot(weekly: 0.2, fable: nil, session: 1)
        guard case .card(let card) = make(session, snapshot) else {
            Issue.record("expected a card")
            return
        }
        #expect(card.title == "A reset can clear your current session")
        #expect(card.body == "Your session reset clears your current session now, instead of in 1 hour.")
    }
}
