//
//  UsageIntents.swift
//  Menu Bar Usage for Claude
//
//  The app's Shortcuts actions: read the current usage, or refresh and read.
//  Both go through `UsageStore.currentUsage(refreshFirst:)`.
//

import AppIntents
import Foundation

/// What the actions hand to Shortcuts; "Get Details" exposes the properties.
struct ClaudeUsageEntity: TransientAppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Claude Usage")

    @Property(title: "Session Percent") var sessionPercent: Int
    @Property(title: "Session Resets At") var sessionResetsAt: Date?
    @Property(title: "Weekly Percent") var weeklyPercent: Int
    @Property(title: "Weekly Resets At") var weeklyResetsAt: Date?
    @Property(title: "Model Name") var modelName: String?
    @Property(title: "Model Percent") var modelPercent: Int?
    @Property(title: "Model Resets At") var modelResetsAt: Date?
    @Property(title: "Extra Usage Used") var extraUsageUsed: Double?
    @Property(title: "Extra Usage Remaining") var extraUsageRemaining: Double?
    @Property(title: "Updated At") var updatedAt: Date

    init() {}

    init(snapshot: UsageSnapshot) {
        sessionPercent = Self.percent(snapshot.session.fraction)
        sessionResetsAt = snapshot.session.resetsAt
        weeklyPercent = Self.percent(snapshot.weekly.fraction)
        weeklyResetsAt = snapshot.weekly.resetsAt
        modelName = snapshot.scopedWeekly?.title
        modelPercent = snapshot.scopedWeekly.map { Self.percent($0.fraction) }
        modelResetsAt = snapshot.scopedWeekly?.resetsAt
        extraUsageUsed = snapshot.extraUsage?.used
        extraUsageRemaining = snapshot.extraUsage?.remaining
        updatedAt = snapshot.fetchedAt
    }

    var displayRepresentation: DisplayRepresentation {
        var title = "Session \(sessionPercent)% · Weekly \(weeklyPercent)%"
        if let modelName, let modelPercent {
            title += " · \(modelName) \(modelPercent)%"
        }
        return DisplayRepresentation(title: "\(title)")
    }

    /// What Siri says: each quota and when it resets.
    static func summary(
        of snapshot: UsageSnapshot,
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let names: [UsageSnapshot.Bar.Kind: String] = [.session: "Session", .weekly: "Weekly"]
        return snapshot.bars.map { bar in
            var sentence = "\(names[bar.id] ?? bar.title) \(percent(bar.fraction))%"
            if let resetsAt = bar.resetsAt,
               let phrase = ResetWording.phrase(for: resetsAt, now: now, locale: locale, timeZone: timeZone) {
                sentence += ", resets \(phrase)"
            }
            return sentence + "."
        }.joined(separator: " ")
    }

    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}

struct GetClaudeUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Claude Usage"
    static let description = IntentDescription("The current session, weekly and model usage, with when each resets.")

    @Dependency private var usage: UsageStore

    @MainActor
    func perform() async throws -> some ReturnsValue<ClaudeUsageEntity> & ProvidesDialog {
        let snapshot = try await usage.currentUsage(refreshFirst: false)
        return .result(
            value: ClaudeUsageEntity(snapshot: snapshot),
            dialog: IntentDialog("\(ClaudeUsageEntity.summary(of: snapshot, now: Date()))")
        )
    }
}

struct RefreshClaudeUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Claude Usage"
    static let description = IntentDescription("Fetches usage from Claude now, then returns it.")

    @Dependency private var usage: UsageStore

    @MainActor
    func perform() async throws -> some ReturnsValue<ClaudeUsageEntity> & ProvidesDialog {
        let snapshot = try await usage.currentUsage(refreshFirst: true)
        return .result(
            value: ClaudeUsageEntity(snapshot: snapshot),
            dialog: IntentDialog("\(ClaudeUsageEntity.summary(of: snapshot, now: Date()))")
        )
    }
}

/// Spotlight and Siri phrases, available without building a shortcut.
struct ClaudeUsageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetClaudeUsageIntent(),
            phrases: [
                "Check my Claude usage in \(.applicationName)",
                "How much Claude usage do I have left in \(.applicationName)",
            ],
            shortTitle: "Check Claude Usage",
            systemImageName: "gauge.with.dots.needle.33percent"
        )
        AppShortcut(
            intent: RefreshClaudeUsageIntent(),
            phrases: ["Refresh my Claude usage in \(.applicationName)"],
            shortTitle: "Refresh Claude Usage",
            systemImageName: "arrow.clockwise"
        )
    }
}

nonisolated extension UsageRequestError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSetUp:
            "Finish setting up Menu Bar Usage for Claude first."
        case .unavailable(let failure):
            // `detail` is Markdown for the popover; Shortcuts shows it as plain text.
            "\(failure.title). \(failure.detail.replacingOccurrences(of: "`", with: ""))"
        case .noData:
            "No usage data yet."
        }
    }
}
