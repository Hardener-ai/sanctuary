// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SanctuaryCore

public enum PeerHealthStatus: Equatable, Sendable {
    case healthy
    case daemonDisconnected
    case suspectedTamper(reason: String)
}

public final class DaemonPeerMonitor: @unchecked Sendable {
    public struct State: Equatable, Sendable {
        public let health: PeerHealthStatus
        public let daemonUUID: UUID?
        public let failureCount: Int

        public init(health: PeerHealthStatus, daemonUUID: UUID?, failureCount: Int) {
            self.health = health
            self.daemonUUID = daemonUUID
            self.failureCount = failureCount
        }
    }

    private let socketPath: String
    private let instanceUUID: UUID
    private let interval: TimeInterval
    private let timeout: TimeInterval
    private let consecutiveFailuresForTamper: Int
    private let expectedStatusProvider: @Sendable () -> DaemonInstallation.Status
    private let ping: @Sendable (String, UUID, TimeInterval) throws -> PongMessage?
    private let auditLogger: any ExtensionAuditLogging
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastDaemonUUID: UUID?
    private var lastDaemonSeen: Date?
    private var failureCount = 0
    private var health: PeerHealthStatus = .healthy
    private var tamperReported = false
    private var statusHandler: (@Sendable (State) -> Void)?

    public init(
        socketPath: String = PeerMonitorPaths.socketPath(),
        instanceUUID: UUID = UUID(),
        interval: TimeInterval = 10,
        timeout: TimeInterval = 1,
        consecutiveFailuresForTamper: Int = 3,
        expectedStatusProvider: @escaping @Sendable () -> DaemonInstallation.Status = { DaemonInstallation.currentStatus() },
        ping: @escaping @Sendable (String, UUID, TimeInterval) throws -> PongMessage? = { socketPath, instanceUUID, timeout in
            try UnixDatagramPeerTransport.sendPingAndWait(
                socketPath: socketPath,
                sender: .menuBar,
                instanceUUID: instanceUUID,
                timeout: timeout
            )
        },
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.socketPath = socketPath
        self.instanceUUID = instanceUUID
        self.interval = interval
        self.timeout = timeout
        self.consecutiveFailuresForTamper = consecutiveFailuresForTamper
        self.expectedStatusProvider = expectedStatusProvider
        self.ping = ping
        self.auditLogger = auditLogger
        self.now = now
    }

    public func start(onStatusChange: @escaping @Sendable (State) -> Void) {
        stop()
        statusHandler = onStatusChange
        checkOnce()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.hardener.sanctuary.peer-monitor.menu"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkOnce()
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

    public func checkOnce() {
        let response = try? ping(socketPath, instanceUUID, timeout)
        if let response, response.responder == .daemon {
            handleResponse(response)
        } else {
            handleFailure()
        }
    }

    private func handleResponse(_ response: PongMessage) {
        let action: String? = lock.withLock {
            let oldUUID = lastDaemonUUID
            let wasDisconnected = failureCount > 0 || health != .healthy
            lastDaemonUUID = response.instanceUUID
            lastDaemonSeen = now()
            failureCount = 0
            tamperReported = false
            health = .healthy

            if let oldUUID, oldUUID != response.instanceUUID {
                return "PEER_RESTARTED"
            }
            if oldUUID == nil {
                return "PEER_CONNECTED"
            }
            if wasDisconnected {
                return "PEER_RECOVERED"
            }
            return nil
        }
        if let action {
            appendAudit(action: action, resource: "daemon_peer:\(response.instanceUUID.uuidString)")
        }
        publishState()
    }

    private func handleFailure() {
        let expected = expectedStatusProvider()
        let shouldReportTamper: Bool = lock.withLock {
            failureCount += 1
            if case let .installed(running) = expected,
               running,
               failureCount >= consecutiveFailuresForTamper
            {
                health = .suspectedTamper(reason: "peer_unresponsive")
                if !tamperReported {
                    tamperReported = true
                    return true
                }
                return false
            }

            health = .daemonDisconnected
            return false
        }

        if shouldReportTamper {
            appendAudit(
                action: "TAMPER_DETECTED",
                resource: "peer_unresponsive: daemon unresponsive despite running status"
            )
        } else {
            appendAudit(action: "PEER_DISCONNECTED", resource: "daemon_peer_unresponsive")
        }
        publishState()
    }

    private func publishState() {
        let snapshot = lock.withLock {
            State(health: health, daemonUUID: lastDaemonUUID, failureCount: failureCount)
        }
        statusHandler?(snapshot)
    }

    private func appendAudit(action: String, resource: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try? auditLogger.append(
            AuditEntry(
                ts: formatter.string(from: now()),
                kind: action == "TAMPER_DETECTED" ? "tamper" : "peer",
                action: action,
                policy: "peer_monitor",
                resource: resource
            )
        )
    }

    deinit {
        stop()
    }
}
