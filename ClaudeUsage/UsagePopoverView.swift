//
//  UsagePopoverView.swift
//  Menu Bar Usage for Claude
//
//  The window-style popover presented from the menu bar. Mirrors the
//  progress bars shown by Claude Desktop: Current Session, Weekly Limit,
//  and — when the API reports one — a model-scoped weekly bar (currently
//  Fable, Max plans only).
//

import AppKit
import Combine
import SwiftUI

struct UsagePopoverView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(\.openWindow) private var openWindow

    /// First-run flag. Until this flips, we don't touch the Keychain, and
    /// the popover only shows a short "complete setup" placeholder. The
    /// real welcome flow lives in `OnboardingWindowView`, presented as a
    /// separate window at launch.
    @AppStorage(SettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding: Bool

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                MainContentView()
            } else {
                SetupRequiredView {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: WindowIDs.onboarding)
                }
            }
        }
        .frame(width: 320)
    }
}

// MARK: - Pre-onboarding placeholder

/// Shown in the popover when the user hasn't completed onboarding yet.
/// The real welcome flow is a separate window; this is just a short nudge
/// in case they click the menu bar icon before going through it.
private struct SetupRequiredView: View {
    let onOpenSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Menu Bar Usage for Claude")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("Finish setup to see your usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("The welcome window explains what’s about to happen and asks you to allow keychain access.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .keyboardShortcut("q")

                Spacer()

                Button {
                    onOpenSetup()
                } label: {
                    Text("Open setup")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

// MARK: - Main content (post-onboarding)

/// The regular popover contents: header, quota bars, footer.
/// Lives in its own view so that its `.task` fires the moment the user
/// completes onboarding — which is what triggers the very first Keychain read.
private struct MainContentView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(StatusStore.self) private var status
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            content

            ServiceStatusRow()

            Divider()

            footer
        }
        .padding(18)
        .task {
            // Fetch on open (debounced); the background poll carries on regardless.
            usage.refreshNow()
            // Fetch the service status only when its TTL has elapsed —
            // status.claude.com rarely changes and we don't want to hit
            // it on every popover open.
            await status.refreshIfStale()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Menu Bar Usage for Claude")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer()
            if usage.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    usage.manualRetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
            Button {
                // Dismiss the MenuBarExtra panel first so it doesn't
                // sit on top of the Settings window. The panel is the
                // only NSPanel this app owns.
                for case let panel as NSPanel in NSApp.windows {
                    panel.close()
                }
                // Bring the app forward so the Settings window isn't buried
                // behind whatever was focused when the popover dismissed.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch usage.presentation {
        case .loading:
            loadingView
        case .usage(let snapshot, _):
            loadedView(snapshot)
        case .problem(.signedOut):
            MissingCredentialsView()
        case .problem(.rateLimited(let until)):
            RateLimitedView(clearAt: until)
        case .problem(let failure):
            ErrorView(failure: failure, isRefreshInProgress: usage.isRefreshingCredentials) {
                usage.manualRetry()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading usage…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private func loadedView(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            QuotaBarView(bar: snapshot.session)
            QuotaBarView(bar: snapshot.weekly)
            if let scoped = snapshot.scopedWeekly {
                QuotaBarView(bar: scoped)
            }
            if let extra = snapshot.extraUsage {
                ExtraUsageCard(summary: extra)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            footerRow
            // Bars kept through a failure are stale; say why, or nothing looks wrong.
            if case .usage(_, .some(let notice)) = usage.presentation {
                switch notice {
                case .rateLimited(let until):
                    CooldownFooterLine(clearAt: until)
                default:
                    NoticeFooterLine(failure: notice)
                }
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if case .usage = usage.presentation, let lastUpdated = usage.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    // Dismiss the popover before opening the browser so
                    // it doesn't sit on top of the window that appears.
                    for case let panel as NSPanel in NSApp.windows {
                        panel.close()
                    }
                    BrowserHelper.open(url)
                }
            } label: {
                HStack(spacing: 3) {
                    Text("Manage")
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.trailing, 4)
            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .keyboardShortcut("q")
        }
    }
}

// MARK: - Bar

/// A single Claude usage bar. Uses a native capsule progress indicator so it
/// plays well with macOS 26 Liquid Glass and dark-mode tinting.
struct QuotaBarView: View {
    let bar: UsageSnapshot.Bar

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(bar.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(bar.percentLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(.quaternary)

                    // Fill
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: fillGradient,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, proxy.size.width * bar.fraction))
                }
            }
            .frame(height: 8)

            if let resetsAt = bar.resetsAt {
                Text(resetLabel(for: resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bar.title) \(bar.percentLabel)")
    }

    private var fillGradient: [Color] {
        switch bar.fraction {
        case ..<0.5:
            return [.green, .mint]
        case 0.5..<0.9:
            return [.yellow, .orange]
        default:
            // ≥90% — solid red across the whole bar so the warning state
            // reads unambiguously regardless of how much of the capsule
            // is currently filled.
            return [.red, .red]
        }
    }

    private func resetLabel(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Resets \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}

// MARK: - Extra Usage card

/// Renders the paid-overflow bar under the quota bars. Only shown
/// when the user has enabled Extra Usage in their claude.ai account and
/// the API returned populated numbers.
///
/// Visually distinct from the quota bars (purple/indigo gradient, card
/// background) so it's obvious this is paid usage, not free quota.
private struct ExtraUsageCard: View {
    let summary: UsageSnapshot.ExtraUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("Extra Usage")
                        .font(.subheadline.weight(.medium))
                } icon: {
                    Image(systemName: "creditcard.fill")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                .labelStyle(.titleAndIcon)

                Spacer()

                Text(summary.percentLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.purple, .indigo],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, proxy.size.width * summary.fraction))
                }
            }
            .frame(height: 8)

            Text(balanceText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Extra Usage \(summary.percentLabel) used. \(balanceText).")
    }

    /// "5,327 used · 8,673 remaining" — raw credit numbers with no
    /// currency symbol, because `/api/oauth/usage` doesn't return the
    /// currency. Users who want the dollar value can tap Manage.
    private var balanceText: String {
        let used = Self.creditFormatter.string(from: NSNumber(value: summary.used)) ?? "\(Int(summary.used))"
        let remaining = Self.creditFormatter.string(from: NSNumber(value: summary.remaining)) ?? "\(Int(summary.remaining))"
        return "\(used) used · \(remaining) remaining"
    }

    private static let creditFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}

// MARK: - Error states

private struct MissingCredentialsView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Claude Code not authenticated")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Menu Bar Usage for Claude couldn’t find your Claude Code OAuth credentials, either in the macOS Keychain (**Claude Code-credentials**) or in **~/.claude/.credentials.json**.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Install Claude Code if you haven’t:")
                        .font(.caption)
                } icon: {
                    Image(systemName: "1.circle.fill")
                        .foregroundStyle(.tint)
                }
                Text("npm install -g @anthropic-ai/claude-code")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))

                Label {
                    Text("Sign in to your Claude account:")
                        .font(.caption)
                } icon: {
                    Image(systemName: "2.circle.fill")
                        .foregroundStyle(.tint)
                }
                Text("claude  →  /login")
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
            }

            Button {
                if let url = URL(string: "https://docs.claude.com/en/docs/claude-code/overview") {
                    BrowserHelper.open(url)
                }
            } label: {
                Label("Claude Code setup docs", systemImage: "arrow.up.forward.app")
                    .font(.caption)
            }
            .buttonStyle(.link)
        }
    }
}

private struct ErrorView: View {
    let failure: UsageFailure
    var isRefreshInProgress: Bool = false
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(failure.title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(markdown: failure.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isRefreshInProgress {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing\u{2026}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

/// One footer line saying why the bars on screen may be stale.
private struct NoticeFooterLine: View {
    let failure: UsageFailure

    var body: some View {
        // The symbol is part of the text run so it sits on the caption's baseline.
        Text("\(Text(Image(systemName: "exclamationmark.circle")).foregroundStyle(.orange)) \(Text(failure.notice).foregroundStyle(.secondary))")
            .font(.caption2)
            .lineLimit(1)
    }
}

/// User-facing copy for each failure. `.signedOut` and `.rateLimited` have views of their own.
private extension UsageFailure {
    var title: String {
        switch self {
        case .signedOut: "Claude Code not authenticated"
        case .credentialsUnreadable: "Couldn’t read your Claude Code credentials"
        case .refreshingSignIn: "Refreshing Claude Code’s sign-in"
        case .signInExpired: "Claude Code needs you to sign in again"
        case .claudeNotFound: "Couldn’t find the claude command"
        case .rateLimited: "Rate-limited by Claude"
        case .offline: "Couldn’t reach Claude"
        case .server(let status): "Claude’s usage endpoint returned HTTP \(status)"
        case .unexpectedResponse: "Couldn’t read Claude’s usage response"
        }
    }

    /// Markdown.
    var detail: String {
        switch self {
        case .signedOut:
            "No credentials in the Keychain or `~/.claude/.credentials.json`."
        case .credentialsUnreadable(let reason):
            reason
        case .refreshingSignIn:
            "The token expired, so Claude Code is refreshing it in the background. This usually takes a few seconds."
        case .signInExpired:
            "The background token refresh didn’t work. Run `claude` in Terminal and type `/login`, then try again."
        case .claudeNotFound:
            "The background token refresh needs Claude Code. Install it, or make sure `claude` is on your login shell’s PATH, then try again."
        case .rateLimited:
            "Claude’s usage endpoint is rate-limiting this app."
        case .offline(let reason):
            reason
        case .server:
            "This is usually temporary. The app will try again shortly."
        case .unexpectedResponse:
            "The endpoint may have changed. The app will keep trying."
        }
    }

    var notice: String {
        switch self {
        case .refreshingSignIn: "Refreshing Claude Code’s sign-in…"
        case .offline: "Couldn’t reach Claude · retrying soon"
        case .server(let status): "Usage endpoint returned HTTP \(status) · retrying soon"
        case .unexpectedResponse: "Couldn’t read the usage response · retrying soon"
        default: title
        }
    }
}

private extension Text {
    init(markdown: String) {
        self.init((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
    }
}

// MARK: - Rate-limited view

/// Shown instead of `ErrorView` when the store is in an `.error` state that
/// was caused by a 429. Drives a live countdown from the current
/// `rateLimitedUntil` timestamp so the user sees an accurate remaining
/// time instead of a static string that was stale the moment it was set.
private struct RateLimitedView: View {
    let clearAt: Date

    /// Re-published every second to force the countdown text to refresh.
    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.orange)
                Text("Rate-limited by Claude")
                    .font(.subheadline.weight(.semibold))
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .monospacedDigit()
        }
        .onReceive(ticker) { now = $0 }
    }

    private var description: String {
        let remaining = clearAt.timeIntervalSince(now)
        if remaining <= 0 {
            return "The cooldown has cleared. The next scheduled poll will fetch fresh data."
        }
        return "Claude’s usage endpoint is temporarily rate-limiting us. Retrying in \(RateLimitCountdown.format(remaining))."
    }
}

/// Pure formatting shared by `RateLimitedView` and `CooldownFooterLine`,
/// kept free of SwiftUI so it can be unit-tested.
enum RateLimitCountdown {
    /// Formats a duration as `"Mm SSs"` or `"SSs"` depending on magnitude.
    /// Rounds up so the countdown never flashes "0s" before actually clearing.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded(.up)))
        let minutes = total / 60
        let secs = total % 60
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        }
        return "\(secs)s"
    }

    /// The footer line for an active cooldown, or `nil` once it has
    /// cleared (the next scheduled poll fetches fresh data on its own, so
    /// there is nothing left to say).
    static func footerText(clearAt: Date, now: Date) -> String? {
        let remaining = clearAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return "Rate-limited by Claude · retrying in \(format(remaining))"
    }
}

/// One-line live countdown shown under the footer while a 429 cooldown
/// is active and a snapshot is still on screen. Ticks every second and
/// renders nothing once the cooldown has cleared.
private struct CooldownFooterLine: View {
    let clearAt: Date

    @State private var now: Date = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let text = RateLimitCountdown.footerText(clearAt: clearAt, now: now) {
                // The symbol is interpolated into the text run rather than
                // placed in an HStack so it is laid out as a glyph on the
                // same line: an HStack centres the image's own box, which
                // sits visibly lower than the caption text.
                Text("\(Text(Image(systemName: "hourglass")).foregroundStyle(.orange)) \(Text(text).foregroundStyle(.secondary))")
                    .font(.caption2)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .onReceive(ticker) { now = $0 }
    }
}

// MARK: - Service status row

/// SwiftUI styling for `StatusSeverity`, kept here so the data layer
/// (`StatusStore.swift`) doesn't need to import SwiftUI.
private extension StatusSeverity {
    var symbolName: String {
        switch self {
        case .operational: return "checkmark.circle.fill"
        case .maintenance: return "wrench.adjustable.fill"
        case .minor:       return "exclamationmark.circle.fill"
        case .major:       return "exclamationmark.triangle.fill"
        case .critical:    return "exclamationmark.octagon.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .operational: return .green
        case .maintenance: return .blue
        case .minor:       return .yellow
        case .major:       return .orange
        case .critical:    return .red
        }
    }
}

/// Compact row beneath the quota bars summarising the current state of
/// status.claude.com for the components the user has opted to monitor.
///
/// Visibility (decided per-render):
/// - simulation flag on → always render the simulated payload
/// - master toggle off → hidden
/// - state isn't `.loaded` → hidden (we don't render skeletons or
///   surface fetch errors here; status is auxiliary)
/// - "hide when operational" on AND nothing degraded → hidden
private struct ServiceStatusRow: View {
    @Environment(StatusStore.self) private var status

    @AppStorage(SettingsKeys.serviceStatusEnabled)
    private var enabled: Bool

    @AppStorage(SettingsKeys.serviceStatusHideWhenOperational)
    private var hideWhenOperational: Bool

    @AppStorage(SettingsKeys.simulateStatusOutage)
    private var simulateOutage: Bool

    var body: some View {
        if let payload = effectivePayload {
            content(payload)
        }
    }

    /// Resolves which snapshot the row should render (real or simulated)
    /// and whether to render at all. Nil means "hide entirely".
    private var effectivePayload: (snapshot: StatusSnapshot, simulated: Bool)? {
        if simulateOutage {
            return (Self.simulatedSnapshot, true)
        }
        guard enabled else { return nil }
        guard let snapshot = status.snapshot else { return nil }
        if hideWhenOperational && snapshot.displaySeverity == .operational {
            return nil
        }
        return (snapshot, false)
    }

    @ViewBuilder
    private func content(_ payload: (snapshot: StatusSnapshot, simulated: Bool)) -> some View {
        let snapshot = payload.snapshot
        let severity = snapshot.displaySeverity

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severity.symbolName)
                .font(.subheadline)
                .foregroundStyle(severity.tintColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(headlineText(for: snapshot))
                    .font(.subheadline.weight(.medium))

                ForEach(snapshot.affectedComponents) { component in
                    Text("\(component.name): \(component.severity.componentLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !snapshot.relevantIncidents.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.relevantIncidents) { incident in
                            incidentRow(incident)
                        }
                    }
                    .padding(.top, 2)
                }

                if payload.simulated {
                    Text("Simulated — disable in Settings → Developer")
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func incidentRow(_ incident: StatusSnapshot.Incident) -> some View {
        if let url = incident.url {
            Button {
                // Match the popover's other web-link buttons: dismiss
                // first so the browser window doesn't end up behind a
                // floating popover panel.
                for case let panel as NSPanel in NSApp.windows {
                    panel.close()
                }
                BrowserHelper.open(url)
            } label: {
                HStack(spacing: 3) {
                    Text(incident.name)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } else {
            Text(incident.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func headlineText(for snapshot: StatusSnapshot) -> String {
        if snapshot.displaySeverity == .operational {
            return "All monitored services operational"
        }
        return snapshot.pageDescription
    }

    /// The fabricated snapshot rendered when
    /// `SettingsKeys.simulateStatusOutage` is on. Marks claude.ai and
    /// Claude Code as a major outage and attaches one fabricated
    /// incident link to status.claude.com.
    private static let simulatedSnapshot = StatusSnapshot(
        displaySeverity: .critical,
        pageDescription: "Major Service Outage",
        affectedComponents: [
            StatusSnapshot.AffectedComponent(
                id: KnownComponent.claudeAI.rawValue,
                name: KnownComponent.claudeAI.displayName,
                severity: .critical
            ),
            StatusSnapshot.AffectedComponent(
                id: KnownComponent.claudeCode.rawValue,
                name: KnownComponent.claudeCode.displayName,
                severity: .critical
            )
        ],
        relevantIncidents: [
            StatusSnapshot.Incident(
                id: "simulated-incident",
                name: "Simulated outage (preview)",
                url: URL(string: "https://status.claude.com")
            )
        ],
        fetchedAt: Date()
    )
}
