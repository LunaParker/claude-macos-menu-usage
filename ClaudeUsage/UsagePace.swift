//
//  UsagePace.swift
//  Menu Bar Usage for Claude
//
//  How far through its window a quota is, and whether usage is running
//  ahead of it. Pure: a bar and the clock in, a tick position and a verdict
//  out. The window starts 5 h (session) or 7 d (weekly) before `resetsAt`,
//  which is all the endpoint gives.
//

import Foundation

nonisolated struct UsagePace: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case onPace
        /// When usage reaches 100% at a straight-line rate from the window's start.
        case full(at: Date)
    }

    /// Share of the window that has passed, 0…1.
    let elapsed: Double
    /// Nil while the window is too young to extrapolate, or once the bar is full.
    let verdict: Verdict?

    /// 15 minutes of a session, about 8 hours of a week: before that the ratio is noise.
    static let minimumElapsed = 0.05

    init?(bar: UsageSnapshot.Bar, now: Date) {
        guard let resetsAt = bar.resetsAt, resetsAt > now else { return nil }
        let length = bar.id.windowLength
        let start = resetsAt.addingTimeInterval(-length)
        let elapsedSeconds = now.timeIntervalSince(start)
        guard elapsedSeconds >= 0 else { return nil }

        elapsed = min(elapsedSeconds / length, 1)
        if elapsed < Self.minimumElapsed || bar.fraction >= 1 {
            verdict = nil
        } else if bar.fraction <= elapsed {
            verdict = .onPace
        } else {
            verdict = .full(at: start.addingTimeInterval(elapsedSeconds / bar.fraction))
        }
    }
}

nonisolated extension UsageSnapshot.Bar.Kind {
    var windowLength: TimeInterval {
        switch self {
        case .session: 5 * 3600
        case .weekly, .scopedWeekly: 7 * 86_400
        }
    }
}

nonisolated extension UsagePace.Verdict {
    /// The caption under a bar: short, since it shares the line with the reset countdown.
    func label(
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        switch self {
        case .onPace:
            return "On pace"
        case .full(let date):
            let style = Date.FormatStyle(locale: locale, timeZone: timeZone)
            let time = date.formatted(style.hour().minute())
            if ResetWording.daysAhead(of: date, from: now, timeZone: timeZone) == 0 {
                return "100% by \(time)"
            }
            return "100% by \(date.formatted(style.weekday(.abbreviated))) \(time)"
        }
    }
}
