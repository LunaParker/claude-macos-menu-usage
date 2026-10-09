//
//  DiagnosticLogView.swift
//  Menu Bar Usage for Claude
//
//  The Diagnostic Log window.
//

import SwiftUI

struct DiagnosticLogView: View {
    @Environment(DiagnosticLog.self) private var log
    @State private var filterCategory: DiagnosticLog.Entry.Category?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Category", selection: $filterCategory) {
                Text("All").tag(nil as DiagnosticLog.Entry.Category?)
                ForEach(DiagnosticLog.Entry.Category.allCases, id: \.self) { cat in
                    Text(cat.rawValue).tag(cat as DiagnosticLog.Entry.Category?)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Spacer()

            Text("\(filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button("Clear Window") { log.clear() }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Empties this window. The log file keeps every entry.")

            Button("Reveal Log File") { log.revealInFinder() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)

                    Text(entry.category.rawValue)
                        .font(.caption.bold())
                        .foregroundStyle(categoryColor(entry.category))
                        .frame(width: 60, alignment: .leading)

                    Text(entry.message)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .id(entry.id)
            }
            // Not entries.count: it stays at the cap once the list is full.
            .onChange(of: log.entries.last?.id) { _, _ in
                if let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredEntries: [DiagnosticLog.Entry] {
        guard let cat = filterCategory else { return log.entries }
        return log.entries.filter { $0.category == cat }
    }

    private func categoryColor(_ cat: DiagnosticLog.Entry.Category) -> Color {
        switch cat {
        case .keychain: .orange
        case .api: .blue
        case .refresh: .purple
        case .status: .teal
        }
    }
}
