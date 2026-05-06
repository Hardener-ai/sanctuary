// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct SecurityOverviewSection: View {
    let snapshot: SecurityOverviewSnapshot
    let onProtectResource: (SecurityOverviewResource) -> Void
    let onOpenAudit: () -> Void
    let onRescan: () -> Void

    init(
        snapshot: SecurityOverviewSnapshot,
        onProtectResource: @escaping (SecurityOverviewResource) -> Void = { _ in },
        onOpenAudit: @escaping () -> Void = {},
        onRescan: @escaping () -> Void = {}
    ) {
        self.snapshot = snapshot
        self.onProtectResource = onProtectResource
        self.onOpenAudit = onOpenAudit
        self.onRescan = onRescan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(visibleCategories) { category in
                SecurityOverviewCategoryRow(
                    category: category,
                    hasActiveTamper: snapshot.hasActiveTamper,
                    onProtectResource: onProtectResource,
                    onOpenAudit: onOpenAudit
                )
            }
            missingCoverage
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DesignTokens.Spacing.grid) {
                SectionHeader("SECURITY OVERVIEW")
                Spacer(minLength: 0)
                Button(action: onRescan) {
                    Image(systemName: "arrow.clockwise")
                        .font(DesignTokens.Typography.footnote)
                        .accessibilityLabel("Re-scan")
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            }
            Text(scanText)
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                .padding(.horizontal, DesignTokens.Spacing.contentPadding)
        }
    }

    private var missingCoverage: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What is missing")
                .font(.system(size: 10, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                .padding(.horizontal, DesignTokens.Spacing.contentPadding)
                .padding(.top, 4)
            ForEach(snapshot.coverageGaps.prefix(3)) { gap in
                HStack(spacing: DesignTokens.Spacing.grid) {
                    Circle()
                        .fill(DesignTokens.Colors.inactive)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(gap.title)
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.Colors.label)
                            .lineLimit(1)
                        Text("\(gap.status) · \(gap.severity)")
                            .font(DesignTokens.Typography.footnote)
                            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .leading)
                .padding(.horizontal, DesignTokens.Spacing.contentPadding)
            }
        }
    }

    private var visibleCategories: [SecurityOverviewCategory] {
        let attention = snapshot.categories.filter(\.needsAttention)
        let populated = snapshot.categories.filter { !$0.resources.isEmpty && !$0.needsAttention }
        return Array((attention + populated).prefix(6))
    }

    private var scanText: String {
        guard let date = snapshot.lastSuccessfulScanAt else {
            return "Last scan: not yet run"
        }
        if abs(date.timeIntervalSinceNow) < 60 {
            return "Last scan: just now"
        }
        return "Last scan: \(RelativeDateTimeFormatter.securityOverview.localizedString(for: date, relativeTo: Date()))"
    }
}

private struct SecurityOverviewCategoryRow: View {
    let category: SecurityOverviewCategory
    let hasActiveTamper: Bool
    let onProtectResource: (SecurityOverviewResource) -> Void
    let onOpenAudit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DesignTokens.Spacing.grid) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(DesignTokens.Typography.body.weight(.medium))
                        .foregroundStyle(DesignTokens.Colors.label)
                        .lineLimit(1)
                    Text(category.summaryText)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(category.risk.rawValue)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            }

            if let resource = primaryActionResource {
                Button(action: { onProtectResource(resource) }) {
                    Text(resource.state == .missing ? "Review" : "Protect now")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else if category.mostRecentActivityAt != nil {
                Button(action: onOpenAudit) {
                    Text("View activity")
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, DesignTokens.Spacing.contentPadding)
        .accessibilityElement(children: .combine)
    }

    private var primaryActionResource: SecurityOverviewResource? {
        category.resources.first { $0.state == .needsReview || $0.state == .missing }
    }

    private var indicatorColor: Color {
        if hasActiveTamper {
            return DesignTokens.Colors.denial
        }
        if category.missingCount > 0 || category.unprotectedCount > 0 {
            return DesignTokens.Colors.warning
        }
        if category.protectedCount > 0 {
            return DesignTokens.Colors.active
        }
        return DesignTokens.Colors.inactive
    }
}

private extension RelativeDateTimeFormatter {
    static var securityOverview: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }
}

struct SecurityOverviewSection_Previews: PreviewProvider {
    static var previews: some View {
        SecurityOverviewSection(
            snapshot: SecurityOverviewSnapshot(
                categories: [
                    SecurityOverviewCategory(
                        id: .sshIdentities,
                        title: "SSH identities",
                        subtitle: "Keys and deploy identities",
                        risk: .critical,
                        resources: [
                            SecurityOverviewResource(
                                id: "ssh",
                                categoryID: .sshIdentities,
                                title: "SSH key directory",
                                displayPath: "~/.ssh",
                                state: .protected,
                                risk: .critical
                            )
                        ]
                    ),
                    SecurityOverviewCategory(
                        id: .browserWalletExtensions,
                        title: "Wallet extensions",
                        subtitle: "Chromium wallet extension storage",
                        risk: .critical,
                        resources: [
                            SecurityOverviewResource(
                                id: "metamask",
                                categoryID: .browserWalletExtensions,
                                title: "MetaMask",
                                displayPath: "Brave Default",
                                state: .needsReview,
                                risk: .critical
                            )
                        ]
                    )
                ],
                coverageGaps: [
                    CoverageGapSummary(id: "Gap 1", title: "Filesystem read prevention", status: "Detection only", severity: "High")
                ],
                lastSuccessfulScanAt: Date()
            )
        )
        .padding()
        .previewDisplayName("Security Overview Section")
    }
}
