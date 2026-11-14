//
//  LimitResetViews.swift
//  Menu Bar Usage for Claude
//
//  The popover's limit reset row and at-limit card. Both only link to
//  claude.ai, where resets are used; the app never claims one.
//

import SwiftUI

private let usageSettingsURL = URL(string: "https://claude.ai/settings/usage")!

/// One line under the bars: how many resets, and the next to expire.
struct LimitResetRow: View {
    let row: ResetsPresentation.Row

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.medium))
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.isSimulated {
                    SimulatedResetNote()
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            Button {
                MenuBarPanel.open(usageSettingsURL)
            } label: {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
            .help("See your limit resets on claude.ai")
            .accessibilityLabel("See your limit resets on claude.ai")
        }
    }
}

/// Under a bar at 100%: which reset could clear it, and a link to use it on claude.ai.
struct LimitResetCard: View {
    let card: ResetsPresentation.Card

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            .labelStyle(.titleAndIcon)

            Text(card.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                MenuBarPanel.open(usageSettingsURL)
            } label: {
                HStack(spacing: 4) {
                    Text("Use it on claude.ai")
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let footnote = card.footnote {
                Divider()
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if card.isSimulated {
                SimulatedResetNote()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SimulatedResetNote: View {
    var body: some View {
        Text("Simulated. Turn it off in Settings › Developer.")
            .font(.caption2)
            .italic()
            .foregroundStyle(.orange)
            .padding(.top, 2)
    }
}
