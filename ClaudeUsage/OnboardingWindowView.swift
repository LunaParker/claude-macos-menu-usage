//
//  OnboardingWindowView.swift
//  Menu Bar Usage for Claude
//
//  The first-run welcome window. Shown before the app starts polling
//  so the user understands what the app does before it begins fetching
//  usage data.
//
//  This window is tied to `SettingsKeys.hasCompletedOnboarding`, whose
//  value is scoped to the running bundle path — so rebuilding the app
//  (which moves it to a new DerivedData path) or relocating the .app
//  naturally re-shows this window.
//

import AppKit
import SwiftUI

struct OnboardingWindowView: View {
    @Environment(UsageStore.self) private var usage
    @Environment(\.dismissWindow) private var dismissWindow

    @AppStorage(SettingsKeys.hasCompletedOnboarding)
    private var hasCompletedOnboarding: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            hero

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                OnboardingWindowRow(
                    icon: "chart.bar.xaxis",
                    title: "Three bars, just like Claude Desktop",
                    detail: "Current session, weekly limit, and — for Max plans — your weekly Sonnet allowance."
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

            Spacer(minLength: 4)

            HStack {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")

                Spacer()

                Button {
                    continueTapped()
                } label: {
                    Text("Continue")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Subviews

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
            Text("The app will read your Claude Code credentials from the login keychain and start fetching your usage data in the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Actions

    private func continueTapped() {
        // Flip the onboarding flag *and* kick off polling in the same
        // user action. `startPolling()` will in turn call `refresh()`,
        // which reads the Keychain for the first time.
        hasCompletedOnboarding = true
        usage.startPolling()
        dismissWindow(id: WindowIDs.onboarding)
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
