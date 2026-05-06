// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct SanctuaryPathsTests {
    @Test func environmentOverrideWins() {
        var createdDirectories: [String] = []

        let path = SanctuaryPaths.resolvePath(
            environmentKey: "SANCTUARY_DB_PATH",
            fileName: "policy.sqlite",
            environment: ["SANCTUARY_DB_PATH": "/tmp/sanctuary-override/policy.sqlite"],
            effectiveUserID: 501,
            userHomeDirectory: "/Users/tester",
            fileExists: { _ in false },
            createDirectory: { createdDirectories.append($0) },
            warning: { _ in },
            preferUserWhenBothExist: true
        )

        #expect(path == "/tmp/sanctuary-override/policy.sqlite")
        #expect(createdDirectories == ["/tmp/sanctuary-override"])
    }

    @Test func rootWithoutOverrideUsesProductionDirectory() {
        var createdDirectories: [String] = []

        let path = SanctuaryPaths.resolvePath(
            environmentKey: "SANCTUARY_DB_PATH",
            fileName: "policy.sqlite",
            environment: [:],
            effectiveUserID: 0,
            userHomeDirectory: "/Users/tester",
            fileExists: { _ in false },
            createDirectory: { createdDirectories.append($0) },
            warning: { _ in },
            preferUserWhenBothExist: true
        )

        #expect(path == "/var/db/sanctuary/policy.sqlite")
        #expect(createdDirectories == ["/var/db/sanctuary"])
    }

    @Test func nonRootWithoutOverrideUsesUserApplicationSupport() {
        var createdDirectories: [String] = []

        let path = SanctuaryPaths.resolvePath(
            environmentKey: "SANCTUARY_DB_PATH",
            fileName: "policy.sqlite",
            environment: [:],
            effectiveUserID: 501,
            userHomeDirectory: "/Users/tester",
            fileExists: { _ in false },
            createDirectory: { createdDirectories.append($0) },
            warning: { _ in },
            preferUserWhenBothExist: true
        )

        #expect(path == "/Users/tester/Library/Application Support/sanctuary/policy.sqlite")
        #expect(createdDirectories == ["/Users/tester/Library/Application Support/sanctuary"])
    }

    @Test func policyDatabasePrefersUserPathWhenHistoricalProductionPathAlsoExists() {
        var warnings: [String] = []

        let path = SanctuaryPaths.resolvePath(
            environmentKey: "SANCTUARY_DB_PATH",
            fileName: "policy.sqlite",
            environment: [:],
            effectiveUserID: 0,
            userHomeDirectory: "/Users/tester",
            fileExists: { path in
                path == "/Users/tester/Library/Application Support/sanctuary/policy.sqlite" ||
                    path == "/var/db/sanctuary/policy.sqlite"
            },
            createDirectory: { _ in },
            warning: { warnings.append($0) },
            preferUserWhenBothExist: true
        )

        #expect(path == "/Users/tester/Library/Application Support/sanctuary/policy.sqlite")
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("both") == true)
    }

    @Test func auditPathDoesNotUsePolicyMigrationPreference() {
        let path = SanctuaryPaths.resolvePath(
            environmentKey: "SANCTUARY_AUDIT_PATH",
            fileName: "audit.log",
            environment: [:],
            effectiveUserID: 0,
            userHomeDirectory: "/Users/tester",
            fileExists: { _ in true },
            createDirectory: { _ in },
            warning: { _ in Issue.record("audit path should not warn on both-existing state") },
            preferUserWhenBothExist: false
        )

        #expect(path == "/var/db/sanctuary/audit.log")
    }
}
