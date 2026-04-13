//
//  UsagePopoverView.swift
//  Menu Bar Usage for Claude
//
//  The window-style popover presented from the menu bar. Mirrors the three
//  progress bars shown by Claude Desktop: Current Session, Weekly Limit,
//  and (for Max users) a Sonnet-specific weekly bar.
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
    private var hasCompletedOnboarding: Bool = false

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

/// The regular popover contents: header, three bars, footer.
/// Lives in its own view so that its `.task` fires the moment the user
/// completes onboarding — which is what triggers the very first Keychain read.
private struct MainContentView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            content

            Divider()

            footer
        }
        .padding(18)
        .task {
            // Opening the popover forces an immediate refetch + resets the
            // 60-second cycle so the user always sees fresh numbers the
            // moment they click the menu bar icon. Polling itself keeps
            // running in the background regardless of popover state.
            usage.refreshNow()
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
                    Task { await usage.refresh() }
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
        switch usage.state {
        case .idle, .loading:
            loadingView
        case .loaded(let snapshot):
            loadedView(snapshot)
        case .missingCredentials:
            MissingCredentialsView()
        case .error(let message):
            // If the error was caused by a 429 and the cooldown is still
            // active, render the live-countdown view instead of the
            // static error text so the user sees an accurate remaining
            // time that updates every second.
            if let until = usage.rateLimitedUntil, until > Date() {
                RateLimitedView(clearAt: until)
            } else {
                ErrorView(message: message) {
                    Task { await usage.refresh() }
                }
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
            if let sonnet = snapshot.sonnet {
                QuotaBarView(bar: sonnet)
            }
            if let extra = snapshot.extraUsage {
                ExtraUsageCard(summary: extra)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if case .loaded = usage.state, let lastUpdated = usage.lastUpdated {
                Text("Updated \(lastUpdated, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
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

/// Renders the paid-overflow bar under the three quota bars. Only shown
/// when the user has enabled Extra Usage in their claude.ai account and
/// the API returned populated numbers.
///
/// Visually distinct from the quota bars (purple/indigo gradient, card
/// background) so it's obvious this is paid usage, not free quota.
private struct ExtraUsageCard: View {
    let summary: UsageSnapshot.ExtraUsageSummary
    @Environment(\.openURL) private var openURL

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

            HStack(alignment: .firstTextBaseline) {
                Text(balanceText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Manage")
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption2)
                }
                .buttonStyle(.link)
            }
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
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.slash")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Claude Code not authenticated")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Menu Bar Usage for Claude reads your Claude Code OAuth credentials from the macOS Keychain, but it couldn’t find an entry for **Claude Code-credentials**.")
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
                    openURL(url)
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
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Couldn’t fetch usage")
                    .font(.subheadline.weight(.semibold))
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
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
        return "Claude’s usage endpoint is temporarily rate-limiting us. Retrying in \(Self.format(remaining))."
    }

    /// Formats a duration as `"Mm SSs"` or `"SSs"` depending on magnitude.
    /// Rounds up so the countdown never flashes "0s" before actually clearing.
    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(1, Int(seconds.rounded(.up)))
        let minutes = total / 60
        let secs = total % 60
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        }
        return "\(secs)s"
    }
}
