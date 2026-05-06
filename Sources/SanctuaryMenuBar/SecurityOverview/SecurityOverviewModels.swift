// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum SecurityOverviewCategoryID: String, CaseIterable, Codable, Sendable {
    case sshIdentities
    case cloudCredentials
    case gpgKeys
    case browserWalletExtensions
    case browserPasswordManagerExtensions
    case standaloneWalletApps
    case standalonePasswordManagerApps
    case browserProfileSessions
    case customResources
    case shellHistory
}

public enum SecurityOverviewRiskLevel: String, Codable, CaseIterable, Sendable {
    case critical = "Critical"
    case high = "High"
    case medium = "Medium"
    case low = "Low"
}

public enum SecurityOverviewResourceState: String, Codable, Sendable {
    case protected
    case needsReview
    case dismissed
    case unsupported
    case missing
    case inactive
}

public struct SecurityOverviewResource: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let categoryID: SecurityOverviewCategoryID
    public let title: String
    public let displayPath: String?
    public let state: SecurityOverviewResourceState
    public let risk: SecurityOverviewRiskLevel
    public let lastActivityAt: Date?

    public init(
        id: String,
        categoryID: SecurityOverviewCategoryID,
        title: String,
        displayPath: String? = nil,
        state: SecurityOverviewResourceState,
        risk: SecurityOverviewRiskLevel,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.categoryID = categoryID
        self.title = title
        self.displayPath = displayPath
        self.state = state
        self.risk = risk
        self.lastActivityAt = lastActivityAt
    }
}

public struct SecurityOverviewCategory: Identifiable, Codable, Equatable, Sendable {
    public let id: SecurityOverviewCategoryID
    public let title: String
    public let subtitle: String
    public let risk: SecurityOverviewRiskLevel
    public let resources: [SecurityOverviewResource]
    public let mostRecentActivityAt: Date?

    public init(
        id: SecurityOverviewCategoryID,
        title: String,
        subtitle: String,
        risk: SecurityOverviewRiskLevel,
        resources: [SecurityOverviewResource],
        mostRecentActivityAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.risk = risk
        self.resources = resources
        self.mostRecentActivityAt = mostRecentActivityAt
    }

    public var protectedCount: Int {
        resources.filter { $0.state == .protected || $0.state == .inactive }.count
    }

    public var unprotectedCount: Int {
        resources.filter { $0.state == .needsReview }.count
    }

    public var dismissedCount: Int {
        resources.filter { $0.state == .dismissed }.count
    }

    public var unsupportedCount: Int {
        resources.filter { $0.state == .unsupported }.count
    }

    public var missingCount: Int {
        resources.filter { $0.state == .missing }.count
    }

    public var detectedCount: Int {
        resources.filter { $0.state != .unsupported }.count
    }

    public var needsAttention: Bool {
        unprotectedCount > 0 || missingCount > 0
    }

    public var summaryText: String {
        if resources.isEmpty {
            return "None detected"
        }
        if unsupportedCount == resources.count {
            return "Not yet supported"
        }

        var parts: [String] = []
        if detectedCount > 0 {
            parts.append("\(detectedCount) detected")
        }
        if protectedCount > 0 {
            parts.append("\(protectedCount) protected")
        }
        if unprotectedCount > 0 {
            parts.append("\(unprotectedCount) needs review")
        }
        if dismissedCount > 0 {
            parts.append("\(dismissedCount) dismissed")
        }
        if missingCount > 0 {
            parts.append("\(missingCount) missing")
        }
        if unsupportedCount > 0 {
            parts.append("\(unsupportedCount) unsupported")
        }
        return parts.joined(separator: ", ")
    }
}

public struct CoverageGapSummary: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: String
    public let severity: String

    public init(id: String, title: String, status: String, severity: String) {
        self.id = id
        self.title = title
        self.status = status
        self.severity = severity
    }
}

public struct SecurityOverviewSnapshot: Codable, Equatable, Sendable {
    public let categories: [SecurityOverviewCategory]
    public let coverageGaps: [CoverageGapSummary]
    public let lastSuccessfulScanAt: Date?
    public let hasActiveTamper: Bool

    public init(
        categories: [SecurityOverviewCategory],
        coverageGaps: [CoverageGapSummary],
        lastSuccessfulScanAt: Date?,
        hasActiveTamper: Bool = false
    ) {
        self.categories = categories
        self.coverageGaps = coverageGaps
        self.lastSuccessfulScanAt = lastSuccessfulScanAt
        self.hasActiveTamper = hasActiveTamper
    }

    public static let empty = SecurityOverviewSnapshot(
        categories: [],
        coverageGaps: [],
        lastSuccessfulScanAt: nil
    )

    public var protectedCount: Int {
        categories.reduce(0) { $0 + $1.protectedCount }
    }

    public var unprotectedCount: Int {
        categories.reduce(0) { $0 + $1.unprotectedCount }
    }

    public var dismissedCount: Int {
        categories.reduce(0) { $0 + $1.dismissedCount }
    }

    public var unsupportedCount: Int {
        categories.reduce(0) { $0 + $1.unsupportedCount }
    }

    public var missingCount: Int {
        categories.reduce(0) { $0 + $1.missingCount }
    }

    public var needsAttentionCount: Int {
        unprotectedCount + missingCount
    }

    public func category(_ id: SecurityOverviewCategoryID) -> SecurityOverviewCategory? {
        categories.first { $0.id == id }
    }
}

public struct DiscoveredResource: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let categoryID: SecurityOverviewCategoryID
    public let title: String
    public let path: String?
    public let profilePath: String?
    public let extensionID: String?
    public let discoveredAt: Date?

    public init(
        id: String? = nil,
        categoryID: SecurityOverviewCategoryID,
        title: String,
        path: String? = nil,
        profilePath: String? = nil,
        extensionID: String? = nil,
        discoveredAt: Date? = nil
    ) {
        self.categoryID = categoryID
        self.title = title
        self.path = path
        self.profilePath = profilePath
        self.extensionID = extensionID
        self.discoveredAt = discoveredAt
        self.id = id ?? [
            categoryID.rawValue,
            title,
            path ?? "",
            profilePath ?? "",
            extensionID ?? ""
        ].joined(separator: ":")
    }
}

public struct DismissedResource: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let categoryID: SecurityOverviewCategoryID
    public let title: String
    public let path: String?
    public let dismissedAt: Date?

    public init(
        id: String? = nil,
        categoryID: SecurityOverviewCategoryID,
        title: String,
        path: String? = nil,
        dismissedAt: Date? = nil
    ) {
        self.categoryID = categoryID
        self.title = title
        self.path = path
        self.dismissedAt = dismissedAt
        self.id = id ?? [
            categoryID.rawValue,
            title,
            path ?? ""
        ].joined(separator: ":")
    }
}
