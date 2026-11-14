//
//  LimitResets.swift
//  Menu Bar Usage for Claude
//
//  The limit resets the account holds, which bars each one clears, which ones
//  the "Show limit resets" setting surfaces, and how the popover words them.
//

import Foundation

// MARK: - Model

nonisolated struct LimitResets: Equatable, Sendable {
    struct Grant: Equatable, Sendable, Identifiable {
        let id: String
        /// Resets left in this grant.
        let count: Int
        let expiresAt: Date?
        let clears: Set<UsageSnapshot.Bar.Kind>
        var isSimulated = false
    }

    var grants: [Grant]

    init(grants: [Grant]) {
        self.grants = grants
    }

    /// Keeps the resets that can be used now: some left, started, unexpired, not
    /// paused or cooling down, and clearing at least one limit the app knows.
    init(block: LimitResetsBlock, now: Date) {
        grants = block.grants.compactMap { grant in
            let clears = Set((grant.clears ?? []).compactMap(Self.barKind(forLimitKey:)))
            guard let count = grant.resetsLeft, count > 0, !clears.isEmpty,
                  grant.paused != true, grant.usableNow != false
            else { return nil }
            if let starts = grant.startsAt, starts > now { return nil }
            if let ends = grant.endsAt, ends <= now { return nil }
            return Grant(id: grant.id, count: count, expiresAt: grant.endsAt, clears: clears)
        }
    }

    /// Claude Code's own mapping of the limit keys in `clears`.
    static func barKind(forLimitKey key: String) -> UsageSnapshot.Bar.Kind? {
        switch key {
        case "five_hour": .session
        case "seven_day": .weekly
        case "seven_day_overage_included": .scopedWeekly
        default: nil
        }
    }

    /// The resets to show: the fetched ones, plus the Developer tab's fake weekly reset.
    static func displayed(
        _ network: LimitResets?,
        simulate: Bool,
        now: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> LimitResets? {
        guard simulate else { return network }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Anchored to the day so its expiry, and the alerts keyed on it, hold still.
        let expiry = calendar.date(byAdding: .day, value: 8, to: calendar.startOfDay(for: now))
        let fake = Grant(id: "simulated-weekly-reset", count: 1, expiresAt: expiry, clears: [.weekly], isSimulated: true)
        return LimitResets(grants: (network?.grants ?? []) + [fake])
    }

    /// The resets a visibility choice shows: all of them, or those clearing a bar
    /// at or above its threshold. Only bars the snapshot has count.
    func surfaced(in snapshot: UsageSnapshot, visibility: ResetVisibility, now: Date) -> [Grant] {
        guard let threshold = visibility.threshold else { return [] }
        let current = grants.filter { $0.expiresAt.map { $0 > now } ?? true }
        guard visibility != .always else { return current }
        let qualifying = Set(snapshot.bars.filter { $0.fraction >= threshold }.map(\.id))
        return current.filter { !$0.clears.isDisjoint(with: qualifying) }
    }
}

// MARK: - Groups

nonisolated extension LimitResets {
    /// Grants that clear the same limits, shown together: two one-reset Fable grants read as "2 Fable resets".
    struct Group: Equatable, Sendable {
        let clears: Set<UsageSnapshot.Bar.Kind>
        let count: Int
        let firstExpiry: Date?
        let sameExpiry: Bool
        let isSimulated: Bool
    }

    /// Soonest to expire first; resets without an expiry last.
    static func groups(_ grants: [Grant]) -> [Group] {
        var order: [Set<UsageSnapshot.Bar.Kind>] = []
        var members: [Set<UsageSnapshot.Bar.Kind>: [Grant]] = [:]
        for grant in grants {
            if members[grant.clears] == nil { order.append(grant.clears) }
            members[grant.clears, default: []].append(grant)
        }
        let groups = order.map { clears -> Group in
            let grants = members[clears] ?? []
            let expiries = grants.compactMap(\.expiresAt)
            return Group(
                clears: clears,
                count: grants.reduce(0) { $0 + $1.count },
                firstExpiry: expiries.min(),
                sameExpiry: Set(expiries).count <= 1 && expiries.count == grants.count,
                isSimulated: grants.contains(where: \.isSimulated)
            )
        }
        return groups.enumerated().sorted { a, b in
            switch (a.element.firstExpiry, b.element.firstExpiry) {
            case let (x?, y?) where x != y: x < y
            case (.some, nil): true
            case (nil, .some): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The most targeted group that clears `kind`, so a Fable reset is suggested
    /// before a weekly one that would also clear Fable; then the soonest to expire.
    static func bestGroup(clearing kind: UsageSnapshot.Bar.Kind, among groups: [Group]) -> Group? {
        groups.filter { $0.clears.contains(kind) }.min { a, b in
            if a.clears.count != b.clears.count { return a.clears.count < b.clears.count }
            return (a.firstExpiry ?? .distantFuture) < (b.firstExpiry ?? .distantFuture)
        }
    }
}

// MARK: - Visibility setting

/// General → Popover → Show limit resets.
nonisolated enum ResetVisibility: String, CaseIterable, Sendable {
    case always
    case nearLimit
    case atLimit
    case never

    var title: String {
        switch self {
        case .always: "Always"
        case .nearLimit: "From 75% used"
        case .atLimit: "At the limit"
        case .never: "Never"
        }
    }

    var caption: String {
        let using = "You use a reset on claude.ai; this app only shows them."
        switch self {
        case .always: return "Every reset Anthropic has given you and when it expires. \(using)"
        case .nearLimit: return "A reset appears once a limit it clears is 75% used. \(using)"
        case .atLimit: return "A reset appears only while a limit it clears is used up. \(using)"
        case .never: return "The popover never shows resets. Reset notifications have their own switches on the Notifications tab."
        }
    }

    /// The bar fraction a reset's limit must reach; nil shows nothing.
    var threshold: Double? {
        switch self {
        case .always: 0
        case .nearLimit: 0.75
        case .atLimit: 1
        case .never: nil
        }
    }
}

// MARK: - Popover presentation

nonisolated enum ResetsPresentation: Equatable, Sendable {
    case hidden
    /// One line under the bars.
    case row(Row)
    /// A card under a bar at 100% that a surfaced reset clears.
    case card(Card)

    struct Row: Equatable, Sendable {
        let title: String
        let detail: String
        let isSimulated: Bool
    }

    struct Card: Equatable, Sendable {
        let bar: UsageSnapshot.Bar.Kind
        let title: String
        let body: String
        let footnote: String?
        let isSimulated: Bool
    }

    static func make(
        resets: LimitResets?,
        snapshot: UsageSnapshot,
        visibility: ResetVisibility,
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> ResetsPresentation {
        guard let resets else { return .hidden }
        let surfaced = resets.surfaced(in: snapshot, visibility: visibility, now: now)
        guard !surfaced.isEmpty else { return .hidden }
        let words = ResetWords(scopedTitle: snapshot.scopedWeekly?.title, now: now, locale: locale, timeZone: timeZone)
        let groups = LimitResets.groups(surfaced)

        for bar in snapshot.bars where bar.fraction >= 1 {
            guard let best = LimitResets.bestGroup(clearing: bar.id, among: groups) else { continue }
            let others = groups.filter { $0 != best }
            return .card(Card(
                bar: bar.id,
                title: "A reset can clear your \(words.limitPhrase(for: bar.id))",
                body: words.cardBody(best, bar: bar),
                footnote: others.isEmpty ? nil : others.map(words.alsoAvailable).joined(separator: " "),
                isSimulated: surfaced.contains(where: \.isSimulated)
            ))
        }

        let total = surfaced.reduce(0) { $0 + $1.count }
        return .row(Row(
            title: "\(total) limit reset\(total == 1 ? "" : "s") available",
            detail: words.rowDetail(groups),
            isSimulated: surfaced.contains(where: \.isSimulated)
        ))
    }
}

// MARK: - Wording

/// Names and dates for resets, shared by the popover and the notifications.
nonisolated struct ResetWords {
    let scopedTitle: String?
    let now: Date
    let locale: Locale
    let timeZone: TimeZone

    /// "weekly reset", "Fable reset", "session reset".
    func noun(for clears: Set<UsageSnapshot.Bar.Kind>) -> String {
        if clears.contains(.weekly) { return "weekly reset" }
        if clears.contains(.scopedWeekly) { return "\(scopedTitle ?? "model") reset" }
        if clears.contains(.session) { return "session reset" }
        return "limit reset"
    }

    func noun(for clears: Set<UsageSnapshot.Bar.Kind>, count: Int) -> String {
        noun(for: clears) + (count == 1 ? "" : "s")
    }

    /// "weekly limit", "Fable limit", "current session".
    func limitPhrase(for kind: UsageSnapshot.Bar.Kind) -> String {
        switch kind {
        case .session: "current session"
        case .weekly: "weekly limit"
        case .scopedWeekly: "\(scopedTitle ?? "model") limit"
        }
    }

    /// "your weekly and Fable limits", "your current session".
    func targets(_ clears: Set<UsageSnapshot.Bar.Kind>) -> String {
        let kinds = UsageSnapshot.Bar.Kind.allCases.filter(clears.contains)
        if kinds == [.session] { return "your current session" }
        let names = kinds.map { kind in
            switch kind {
            case .session: "session"
            case .weekly: "weekly"
            case .scopedWeekly: scopedTitle ?? "model"
            }
        }
        return "your \(Self.list(names)) limit\(names.count == 1 ? "" : "s")"
    }

    /// "Dec 10" this year, "Mar 9, 2027" otherwise.
    func shortDate(_ date: Date) -> String {
        let style = Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? style : style.year())
    }

    /// "March 9, 2027".
    func longDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).month(.wide).day().year())
    }

    func rowDetail(_ groups: [LimitResets.Group]) -> String {
        guard let next = groups.first else { return "" }
        let nouns = Set(groups.map { noun(for: $0.clears) })
        if nouns.count == 1 {
            let count = groups.reduce(0) { $0 + $1.count }
            let name = Self.capitalizedFirst(noun(for: next.clears, count: count))
            guard let expiry = next.firstExpiry else { return name }
            return "\(name), expire\(count == 1 ? "s" : "") \(shortDate(expiry))"
        }
        guard let expiry = next.firstExpiry else { return Self.capitalizedFirst(noun(for: next.clears)) }
        return "Next to expire: \(noun(for: next.clears)), \(shortDate(expiry))"
    }

    func cardBody(_ group: LimitResets.Group, bar: UsageSnapshot.Bar) -> String {
        let subject = group.count == 1
            ? "Your \(noun(for: group.clears))"
            : "One of your \(group.count) \(noun(for: group.clears, count: group.count))"
        var body = "\(subject) clears \(targets(group.clears)) now"
        if let resetsAt = bar.resetsAt, resetsAt > now {
            body += ", instead of \(relative(resetsAt))"
        }
        body += "."
        if let expiry = group.firstExpiry {
            let verb = group.count == 1 ? "It expires" : group.sameExpiry ? "They expire" : "The first expires"
            body += " \(verb) \(shortDate(expiry))."
        }
        return body
    }

    func alsoAvailable(_ group: LimitResets.Group) -> String {
        var sentence = "\(group.count) \(noun(for: group.clears, count: group.count)) also available"
        if let expiry = group.firstExpiry {
            sentence += ", expiring \(shortDate(expiry))"
        }
        return sentence + "."
    }

    /// "in 2 days".
    func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - Refresh policy

/// When the resets request is due: hourly, or once five minutes have passed
/// after the usage changed in a way a used or newly usable reset would explain.
nonisolated enum ResetsRefreshPolicy {
    static let interval: TimeInterval = 3600
    static let afterChange: TimeInterval = 300

    static func isDue(lastAttempt: Date?, previous: UsageSnapshot?, current: UsageSnapshot, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        if elapsed >= interval { return true }
        return elapsed >= afterChange && limitsChanged(from: previous, to: current)
    }

    /// A bar dropped, its window moved, or it just reached 100% (some resets only work at a limit).
    static func limitsChanged(from previous: UsageSnapshot?, to current: UsageSnapshot) -> Bool {
        guard let previous else { return false }
        return current.bars.contains { bar in
            guard let old = previous.bars.first(where: { $0.id == bar.id }) else { return false }
            return bar.fraction < old.fraction
                || !ThresholdTracker.isSameResetTime(old.resetsAt, bar.resetsAt)
                || (bar.fraction >= 1 && old.fraction < 1)
        }
    }
}
