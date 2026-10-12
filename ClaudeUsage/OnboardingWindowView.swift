//
//  OnboardingWindowView.swift
//  Menu Bar Usage for Claude
//
//  The setup window. The welcome page explains what the app does before it
//  touches the Keychain; its Continue sets `SettingsKeys.hasCompletedOnboarding`
//  and starts polling, then the optional setup pages follow. "Run Setup
//  Again…" in Settings reopens the window at the first setup page.
//

import AppKit
import SwiftUI

struct OnboardingWindowView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage(SettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding: Bool

    /// Nil until the first move; until then the start page follows the onboarding flag.
    @State private var step: SetupStep?

    var body: some View {
        let current = step ?? SetupStep.first(hasCompletedOnboarding: hasCompletedOnboarding)
        VStack(spacing: 0) {
            page(current)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            footer(current)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
        }
        .frame(width: 580, height: 600)
    }

    @ViewBuilder
    private func page(_ step: SetupStep) -> some View {
        switch step {
        case .welcome: WelcomePage()
        case .menuBar: MenuBarSetupPage()
        case .alerts: AlertsSetupPage()
        case .serviceStatus: ServiceStatusSetupPage()
        case .refresh: RefreshSetupPage()
        }
    }

    private func footer(_ current: SetupStep) -> some View {
        HStack(spacing: 12) {
            if current == .welcome {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            } else if let previous = current.previous {
                Button("Back") {
                    step = previous
                }
            }

            if let progress = current.progress {
                Text("Step \(progress.index) of \(progress.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if current != .welcome, current.next != nil {
                Button("Skip Setup") {
                    finish()
                }
            }

            Button {
                advance(from: current)
            } label: {
                Text(primaryTitle(current))
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        // One size and shape for every footer button; macOS draws large buttons as capsules.
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private func primaryTitle(_ step: SetupStep) -> String {
        switch step {
        case .welcome: "Continue"
        case .refresh: "Done"
        default: "Next"
        }
    }

    private func advance(from current: SetupStep) {
        switch current {
        case .welcome:
            // Consent: flip the flag and start polling, whose first refresh reads the Keychain.
            hasCompletedOnboarding = true
            usage.startPolling()
            step = .menuBar
        default:
            if let next = current.next {
                step = next
            } else {
                finish()
            }
        }
    }

    private func finish() {
        dismissWindow(id: WindowIDs.onboarding)
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            hero

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                OnboardingWindowRow(
                    icon: "chart.bar.xaxis",
                    title: "Your quota bars, just like Claude Desktop",
                    detail: "Current session, weekly limit, and — on Max plans — your weekly Fable allowance."
                )

                OnboardingWindowRow(
                    icon: "key.horizontal",
                    title: "Uses your existing Claude Code login",
                    detail: "Menu Bar Usage for Claude reads the OAuth token that the `claude` CLI already stored in your macOS login keychain. No extra sign-in required."
                )

                OnboardingWindowRow(
                    icon: "lock.shield",
                    title: "Your token stays on your Mac",
                    detail: "It’s only sent to Anthropic’s own usage endpoint. Nothing is uploaded anywhere else."
                )
            }

            keychainCallout
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Menu Bar Usage for Claude")
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your Claude Code quotas, one click away in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keychainCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)
                Text("What happens when you click Continue")
                    .font(.subheadline.weight(.semibold))
            }
            Text("The app will read your Claude Code credentials from the login keychain and start fetching your usage data in the background. Then a few quick questions set it up the way you like; you can skip them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Row

private struct OnboardingWindowRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 26, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
