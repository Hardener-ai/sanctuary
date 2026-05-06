// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI

enum DesignTokens {
    enum Typography {
        static let title: Font = .system(size: 15, weight: .semibold)
        static let body: Font = .system(size: 13)
        static let footnote: Font = .system(size: 11)
    }

    enum Spacing {
        static let grid: CGFloat = 8
        static let contentPadding: CGFloat = 12
        static let rowMinHeight: CGFloat = 28
    }

    enum Colors {
        static let accent = Color(nsColor: .controlAccentColor)
        static let label = Color(nsColor: .labelColor)
        static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
        static let separator = Color(nsColor: .quaternaryLabelColor)
        static let active = Color(nsColor: .systemGreen)
        static let warning = Color(nsColor: .systemYellow)
        static let inactive = Color(nsColor: .systemGray)
        static let denial = Color(nsColor: .systemRed)
    }
}
