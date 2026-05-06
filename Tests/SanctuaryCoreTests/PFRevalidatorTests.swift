// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct PFAnchorValidatorTests {
    @Test func presentAnchorRulesParseAsPresent() {
        let result = CommandResult(
            exitCode: 0,
            stdout: "rdr   on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port = 9222 -> 127.0.0.1 port 49222\n",
            stderr: ""
        )

        #expect(PFAnchorValidator.state(from: result) == .present(rules: [
            "rdr on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port 9222 -> 127.0.0.1 port 49222"
        ]))
    }

    @Test func emptyPFCTLOutputParsesAsMissing() {
        let result = CommandResult(exitCode: 0, stdout: "\n", stderr: "")

        #expect(PFAnchorValidator.state(from: result) == .missing)
    }

    @Test func expectedRuleMismatchParsesAsModified() {
        let result = CommandResult(
            exitCode: 0,
            stdout: "rdr on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port 9333 -> 127.0.0.1 port 49222\n",
            stderr: ""
        )
        let expected = "rdr on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port 9222 -> 127.0.0.1 port 49222\n"

        guard case let .modified(actualRules, expectedRules) = PFAnchorValidator.state(from: result, expectedRules: expected) else {
            Issue.record("expected modified anchor state")
            return
        }
        #expect(actualRules.count == 1)
        #expect(expectedRules.count == 1)
    }

    @Test func pfctlFailureParsesAsError() {
        let result = CommandResult(exitCode: 1, stdout: "", stderr: "pfctl: anchor does not exist\n")

        #expect(PFAnchorValidator.state(from: result) == .pfctlError("pfctl: anchor does not exist"))
    }
}

struct PFRevalidatorTests {
    @Test func missingRulesTriggerTamperAuditAndReload() {
        let audit = CapturingPFAuditLogger()
        let reloadCount = LockedBox(0)
        let events = LockedBox<[PFRevalidator.Event]>([])
        let revalidator = PFRevalidator(
            expectedRulesProvider: { expectedRules },
            activeProvider: { true },
            stateProvider: { _, _ in .missing },
            reload: { reloadCount.withValue { $0 += 1 } },
            auditLogger: audit,
            eventHandler: { event in events.withValue { $0.append(event) } }
        )

        revalidator.validateOnce()

        #expect(reloadCount.value == 1)
        #expect(events.value == [.rulesMissing(expectedCount: 1)])
        #expect(audit.entries.map(\.action).contains("TAMPER_DETECTED"))
        #expect(audit.entries.contains { $0.resource?.contains("pf_rules_flushed") == true })
    }

    @Test func modifiedRulesTriggerTamperAuditAndReload() {
        let audit = CapturingPFAuditLogger()
        let reloadCount = LockedBox(0)
        let revalidator = PFRevalidator(
            expectedRulesProvider: { expectedRules },
            activeProvider: { true },
            stateProvider: { _, expected in
                .modified(actualRules: ["rdr changed"], expectedRules: PFAnchorValidator.normalizedRules(expected))
            },
            reload: { reloadCount.withValue { $0 += 1 } },
            auditLogger: audit
        )

        revalidator.validateOnce()

        #expect(reloadCount.value == 1)
        #expect(audit.entries.map(\.action).contains("PF_RULES_MODIFIED"))
        #expect(audit.entries.contains { $0.resource?.contains("pf_rules_modified") == true })
    }

    @Test func matchingRulesDoNothing() {
        let audit = CapturingPFAuditLogger()
        let reloadCount = LockedBox(0)
        let revalidator = PFRevalidator(
            expectedRulesProvider: { expectedRules },
            activeProvider: { true },
            stateProvider: { _, expected in .present(rules: PFAnchorValidator.normalizedRules(expected)) },
            reload: { reloadCount.withValue { $0 += 1 } },
            auditLogger: audit
        )

        revalidator.validateOnce()

        #expect(reloadCount.value == 0)
        #expect(audit.entries.isEmpty)
    }

    @Test func inactiveGuardSkipsValidation() {
        let stateCalls = LockedBox(0)
        let revalidator = PFRevalidator(
            expectedRulesProvider: { expectedRules },
            activeProvider: { false },
            stateProvider: { _, _ in
                stateCalls.withValue { $0 += 1 }
                return .missing
            },
            reload: {}
        )

        revalidator.validateOnce()

        #expect(stateCalls.value == 0)
    }

    @Test func pfctlErrorsBackOffAfterThreshold() {
        let now = LockedBox(Date())
        let stateCalls = LockedBox(0)
        let revalidator = PFRevalidator(
            backoffInterval: 300,
            errorThreshold: 3,
            expectedRulesProvider: { expectedRules },
            activeProvider: { true },
            stateProvider: { _, _ in
                stateCalls.withValue { $0 += 1 }
                return .pfctlError("broken")
            },
            reload: {},
            now: { now.value }
        )

        revalidator.validateOnce()
        revalidator.validateOnce()
        revalidator.validateOnce()
        revalidator.validateOnce()

        #expect(stateCalls.value == 3)

        now.withValue { $0 = $0.addingTimeInterval(301) }
        revalidator.validateOnce()
        #expect(stateCalls.value == 4)
    }

    @Test func recoveryAfterTamperLogsValidatedOnce() {
        let audit = CapturingPFAuditLogger()
        let states = LockedBox<[AnchorState]>([
            .missing,
            .present(rules: PFAnchorValidator.normalizedRules(expectedRules)),
            .present(rules: PFAnchorValidator.normalizedRules(expectedRules))
        ])
        let revalidator = PFRevalidator(
            expectedRulesProvider: { expectedRules },
            activeProvider: { true },
            stateProvider: { _, _ in states.withValue { $0.removeFirst() } },
            reload: {},
            auditLogger: audit
        )

        revalidator.validateOnce()
        revalidator.validateOnce()
        revalidator.validateOnce()

        #expect(audit.entries.map(\.action).filter { $0 == "PF_RULES_VALIDATED" }.count == 1)
    }

    private var expectedRules: String {
        PFAnchorManager.generateRulesFile(redirects: [.init(fromPort: 9222, toPort: 49222)])
    }
}

private final class CapturingPFAuditLogger: ExtensionAuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AuditEntry] = []

    var entries: [AuditEntry] {
        lock.withLock { storage }
    }

    func append(_ entry: AuditEntry) throws {
        lock.withLock {
            storage.append(entry)
        }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock {
            try body(&storage)
        }
    }
}
