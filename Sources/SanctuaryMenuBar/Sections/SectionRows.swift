// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct SectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

struct IconLabelRow: View {
    let systemName: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.grid) {
            Image(systemName: systemName)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .center)
        .padding(.horizontal, DesignTokens.Spacing.contentPadding)
    }
}

struct ToggleIconLabelRow: View {
    let systemName: String
    let title: String
    let subtitle: String?
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.grid) {
            Image(systemName: systemName)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.footnote)
                        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .frame(minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .center)
        .padding(.horizontal, DesignTokens.Spacing.contentPadding)
    }
}

struct AddSectionRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.grid) {
                Image(systemName: "plus.circle")
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.contentPadding)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
    }
}

struct EmptySectionRow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(DesignTokens.Typography.body)
            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.contentPadding)
    }
}
