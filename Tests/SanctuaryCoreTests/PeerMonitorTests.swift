// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore
@testable import SanctuaryMenuBar

struct PeerMonitorTests {
    @Test func pingPongCodecRoundTrips() throws {
        let uuid = UUID()
        let ping = PingMessage(sender: .menuBar, timestamp: Date(timeIntervalSince1970: 1), instanceUUID: uuid)

        let data = try PeerProtocolCodec.encode(.ping(ping))
        let decoded = try PeerProtocolCodec.decode(data)

        #expect(decoded == .ping(ping))
    }

    @Test func unixDatagramPingPongRoundTripWorks() throws {
        let socketPath = "/tmp/ai.hardener.sanctuary.peer-test-\(UUID().uuidString).sock"
        let daemonUUID = UUID()
        let server = UnixDatagramPeerServer(socketPath: socketPath, instanceUUID: daemonUUID) { _ in }
        try server.start()
        defer { server.stop() }

        let response = try UnixDatagramPeerTransport.sendPingAndWait(
            socketPath: socketPath,
            sender: .menuBar,
            instanceUUID: UUID(),
            timeout: 1
        )

        #expect(response?.responder == .daemon)
        #expect(response?.instanceUUID == daemonUUID)
    }

    @Test func daemonPeerMonitorUpdatesLastSeenOnPing() throws {
        let audit = CapturingPeerAuditLogger()
        let events = LockedBox<[PeerMonitorEvent]>([])
        let service = PeerMonitorService(
            auditLogger: audit,
            eventHandler: { event in events.withValue { $0.append(event) } }
        )
        let uuid = UUID()

        service.recordPing(.init(sender: .menuBar, timestamp: Date(), instanceUUID: uuid))

        #expect(events.value == [.connected(.menuBar, uuid)])
        #expect(audit.entries.map(\.action) == ["PEER_CONNECTED"])
    }

    @Test func daemonPeerMonitorStaleDetectionFiresAfterThirtySeconds() throws {
        let audit = CapturingPeerAuditLogger()
        let now = LockedBox(Date())
        let events = LockedBox<[PeerMonitorEvent]>([])
        let service = PeerMonitorService(
            staleAfter: 30,
            now: { now.value },
            auditLogger: audit,
            eventHandler: { event in events.withValue { $0.append(event) } }
        )
        let uuid = UUID()
        service.recordPing(.init(sender: .menuBar, timestamp: now.value, instanceUUID: uuid))

        now.withValue { $0 = $0.addingTimeInterval(31) }
        service.checkForStalePeers()

        #expect(events.value == [.connected(.menuBar, uuid), .disconnected(.menuBar, uuid)])
        #expect(audit.entries.map(\.action).contains("PEER_DISCONNECTED"))
    }

    @Test func daemonPeerMonitorDetectsInstanceUUIDChangeAsRestart() throws {
        let events = LockedBox<[PeerMonitorEvent]>([])
        let service = PeerMonitorService(eventHandler: { event in events.withValue { $0.append(event) } })
        let first = UUID()
        let second = UUID()

        service.recordPing(.init(sender: .menuBar, timestamp: Date(), instanceUUID: first))
        service.recordPing(.init(sender: .menuBar, timestamp: Date(), instanceUUID: second))

        #expect(events.value == [.connected(.menuBar, first), .restarted(.menuBar, old: first, new: second)])
    }

    @Test func menuMonitorReportsTamperAfterConsecutiveFailuresWhenDaemonExpectedRunning() throws {
        let audit = CapturingPeerAuditLogger()
        let states = LockedBox<[DaemonPeerMonitor.State]>([])
        let monitor = DaemonPeerMonitor(
            consecutiveFailuresForTamper: 3,
            expectedStatusProvider: { .installed(running: true) },
            ping: { _, _, _ in nil },
            auditLogger: audit
        )

        monitor.start { state in states.withValue { $0.append(state) } }
        monitor.stop()
        monitor.checkOnce()
        monitor.checkOnce()

        #expect(states.value.last?.health == .suspectedTamper(reason: "peer_unresponsive"))
        #expect(audit.entries.contains { $0.action == "TAMPER_DETECTED" })
    }

    @Test func menuMonitorDetectsRecovery() throws {
        let audit = CapturingPeerAuditLogger()
        let daemonUUID = UUID()
        let responses = LockedBox<[PongMessage?]>([
            .init(responder: .daemon, timestamp: Date(), instanceUUID: daemonUUID),
            nil,
            .init(responder: .daemon, timestamp: Date(), instanceUUID: daemonUUID)
        ])
        let states = LockedBox<[DaemonPeerMonitor.State]>([])
        let monitor = DaemonPeerMonitor(
            expectedStatusProvider: { .installed(running: false) },
            ping: { _, _, _ in responses.withValue { $0.removeFirst() } },
            auditLogger: audit
        )

        monitor.checkOnce()
        monitor.start { state in states.withValue { $0.append(state) } }
        monitor.stop()
        monitor.checkOnce()

        #expect(states.value.last?.health == .healthy)
        #expect(audit.entries.map(\.action).contains("PEER_RECOVERED"))
    }

    @Test func menuMonitorDetectsDaemonRestartByUUIDChange() throws {
        let audit = CapturingPeerAuditLogger()
        let first = UUID()
        let second = UUID()
        let responses = LockedBox<[PongMessage?]>([
            .init(responder: .daemon, timestamp: Date(), instanceUUID: first),
            .init(responder: .daemon, timestamp: Date(), instanceUUID: second)
        ])
        let monitor = DaemonPeerMonitor(
            ping: { _, _, _ in responses.withValue { $0.removeFirst() } },
            auditLogger: audit
        )

        monitor.checkOnce()
        monitor.checkOnce()

        #expect(audit.entries.map(\.action).contains("PEER_RESTARTED"))
    }
}

private final class CapturingPeerAuditLogger: ExtensionAuditLogging, @unchecked Sendable {
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
