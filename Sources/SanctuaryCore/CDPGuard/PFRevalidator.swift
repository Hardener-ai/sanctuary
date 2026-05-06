// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public final class PFRevalidator: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case rulesMissing(expectedCount: Int)
        case rulesModified(actualCount: Int, expectedCount: Int)
        case rulesValidated
        case pfctlError(String)
    }

    private enum HealthState: Equatable {
        case healthy
        case missing
        case modified
        case error
    }

    private let anchorName: String
    private let interval: TimeInterval
    private let backoffInterval: TimeInterval
    private let errorThreshold: Int
    private let expectedRulesProvider: @Sendable () -> String
    private let activeProvider: @Sendable () -> Bool
    private let stateProvider: @Sendable (String, String) -> AnchorState
    private let reload: @Sendable () throws -> Void
    private let auditLogger: any ExtensionAuditLogging
    private let auditErrorHandler: @Sendable (Error) -> Void
    private let now: @Sendable () -> Date
    private let eventHandler: @Sendable (Event) -> Void
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var consecutivePFCTLErrors = 0
    private var backoffUntil: Date?
    private var lastHealthState: HealthState = .healthy

    public init(
        anchorName: String = PFAnchorManager.defaultAnchorName,
        interval: TimeInterval = 30,
        backoffInterval: TimeInterval = 300,
        errorThreshold: Int = 3,
        expectedRulesProvider: @escaping @Sendable () -> String,
        activeProvider: @escaping @Sendable () -> Bool,
        stateProvider: @escaping @Sendable (String, String) -> AnchorState = { anchor, expectedRules in
            PFAnchorValidator.currentAnchorState(anchor: anchor, expectedRules: expectedRules)
        },
        reload: @escaping @Sendable () throws -> Void,
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        auditErrorHandler: @escaping @Sendable (Error) -> Void = { error in
            FileHandle.standardError.write(Data("Sanctuary pf revalidator audit failed: \(error)\n".utf8))
        },
        now: @escaping @Sendable () -> Date = { Date() },
        eventHandler: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.anchorName = anchorName
        self.interval = interval
        self.backoffInterval = backoffInterval
        self.errorThreshold = errorThreshold
        self.expectedRulesProvider = expectedRulesProvider
        self.activeProvider = activeProvider
        self.stateProvider = stateProvider
        self.reload = reload
        self.auditLogger = auditLogger
        self.auditErrorHandler = auditErrorHandler
        self.now = now
        self.eventHandler = eventHandler
    }

    public func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.hardener.sanctuary.pf-revalidator"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.validateOnce()
        }
        lock.withLock {
            self.timer = timer
        }
        timer.resume()
    }

    public func stop() {
        let oldTimer = lock.withLock { () -> DispatchSourceTimer? in
            let old = timer
            timer = nil
            return old
        }
        oldTimer?.cancel()
    }

    public func validateOnce() {
        guard activeProvider() else {
            return
        }

        let currentTime = now()
        if let backoff = lock.withLock({ backoffUntil }), currentTime < backoff {
            return
        }

        let expectedRules = expectedRulesProvider()
        guard !PFAnchorValidator.normalizedRules(expectedRules).isEmpty else {
            return
        }

        switch stateProvider(anchorName, expectedRules) {
        case .present:
            handleHealthy()
        case .missing:
            handleMissing(expectedRules: expectedRules)
        case let .modified(actualRules, expectedRules):
            handleModified(actualCount: actualRules.count, expectedCount: expectedRules.count)
        case let .pfctlError(reason):
            handlePFCTLError(reason)
        }
    }

    private func handleHealthy() {
        let shouldLogRecovery = lock.withLock { () -> Bool in
            consecutivePFCTLErrors = 0
            backoffUntil = nil
            defer { lastHealthState = .healthy }
            return lastHealthState != .healthy
        }
        if shouldLogRecovery {
            emit(.rulesValidated)
            appendAudit(action: "PF_RULES_VALIDATED", resource: "state=recovered")
        }
    }

    private func handleMissing(expectedRules: String) {
        let expectedCount = PFAnchorValidator.normalizedRules(expectedRules).count
        lock.withLock {
            consecutivePFCTLErrors = 0
            backoffUntil = nil
            lastHealthState = .missing
        }
        emit(.rulesMissing(expectedCount: expectedCount))
        appendAudit(action: "PF_RULES_MISSING", resource: "reason=missing;expected_count=\(expectedCount);actual_count=0")
        appendAudit(action: "TAMPER_DETECTED", resource: "reason=pf_rules_flushed;expected_count=\(expectedCount);actual_count=0")
        do {
            try reload()
        } catch {
            auditErrorHandler(error)
        }
    }

    private func handleModified(actualCount: Int, expectedCount: Int) {
        lock.withLock {
            consecutivePFCTLErrors = 0
            backoffUntil = nil
            lastHealthState = .modified
        }
        emit(.rulesModified(actualCount: actualCount, expectedCount: expectedCount))
        appendAudit(
            action: "PF_RULES_MODIFIED",
            resource: "reason=modified;expected_count=\(expectedCount);actual_count=\(actualCount)"
        )
        appendAudit(
            action: "TAMPER_DETECTED",
            resource: "reason=pf_rules_modified;expected_count=\(expectedCount);actual_count=\(actualCount)"
        )
        do {
            try reload()
        } catch {
            auditErrorHandler(error)
        }
    }

    private func handlePFCTLError(_ reason: String) {
        lock.withLock {
            consecutivePFCTLErrors += 1
            lastHealthState = .error
            if consecutivePFCTLErrors >= errorThreshold {
                backoffUntil = now().addingTimeInterval(backoffInterval)
            }
        }
        emit(.pfctlError(reason))
    }

    private func emit(_ event: Event) {
        eventHandler(event)
    }

    private func appendAudit(action: String, resource: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            try auditLogger.append(
                AuditEntry(
                    ts: formatter.string(from: now()),
                    kind: action == "TAMPER_DETECTED" ? "tamper" : "cdp_guard",
                    action: action,
                    policy: "cdp_guard_pf",
                    resource: resource
                )
            )
        } catch {
            auditErrorHandler(error)
        }
    }

    deinit {
        stop()
    }
}
