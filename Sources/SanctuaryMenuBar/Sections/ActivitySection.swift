// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SanctuaryCore
import SwiftUI

struct ActivitySection: View {
    let entries: [ActivityEntry]
    let auditLogPath: String

    init(entries: [ActivityEntry], auditLogPath: String = SanctuaryPaths.auditLogPath()) {
        self.entries = entries
        self.auditLogPath = auditLogPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("ACTIVITY (last hour)")
            ForEach(Array(entries.prefix(5)), id: \.rowID) { entry in
                ActivityRow(entry: entry)
            }
            Button(action: openFullLog) {
                Text("View full log →")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                    .frame(maxWidth: .infinity, minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.contentPadding)
            }
            .buttonStyle(.plain)
        }
    }

    private func openFullLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: auditLogPath))
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: entry.isDenial ? "xmark.shield.fill" : "exclamationmark.triangle")
                    .foregroundStyle(entry.isDenial ? DesignTokens.Colors.label : DesignTokens.Colors.secondaryLabel)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(entry.relativeTimeText)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                Spacer(minLength: 0)
            }
            Text(entry.summaryText)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.label)
                .lineLimit(1)
                .truncationMode(.tail)
            if !entry.attributionText.isEmpty {
                Text(entry.attributionText)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.contentPadding)
        .accessibilityElement(children: .combine)
    }
}

private extension ActivityEntry {
    var rowID: String {
        "\(timestamp.timeIntervalSince1970)-\(summaryText)-\(attributionText)"
    }
}

struct ActivitySection_Previews: PreviewProvider {
    static var previews: some View {
        ActivitySection(entries: [
            ActivityEntry(
                timestamp: Date(),
                relativeTimeText: "just now",
                summaryText: "Codex tried to read MetaMask",
                attributionText: "Detected · definite",
                isDenial: false
            ),
            ActivityEntry(
                timestamp: Date(),
                relativeTimeText: "2 minutes ago",
                summaryText: "Codex tried to attach to Brave",
                attributionText: "Blocked",
                isDenial: true
            )
        ])
        .padding()
        .previewDisplayName("Activity Section")
    }
}
