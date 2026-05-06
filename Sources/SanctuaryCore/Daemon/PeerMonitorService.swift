// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum PeerMonitorEvent: Equatable, Sendable {
    case connected(PeerRole, UUID)
    case disconnected(PeerRole, UUID)
    case restarted(PeerRole, old: UUID, new: UUID)
}

public final class PeerMonitorService: SanctuaryDaemonService, @unchecked Sendable {
    public let name = "peer-monitor"

    // The daemon monitors the menu bar passively by answering pings and
    // checking their cadence. A missing UI can be normal, so only the menu
    // bar treats daemon loss as tamper-sensitive.
    private let socketPath: String
    private let instanceUUID: UUID
    private let interval: TimeInterval
    private let staleAfter: TimeInterval
    private let now: @Sendable () -> Date
    private let auditLogger: any ExtensionAuditLogging
    private let auditErrorHandler: @Sendable (Error) -> Void
    private let eventHandler: @Sendable (PeerMonitorEvent) -> Void
    private let lock = NSLock()
    private var server: UnixDatagramPeerServer?
    private var timer: DispatchSourceTimer?
    private var lastMenuBarUUID: UUID?
    private var lastMenuBarSeen: Date?
    private var menuBarConnected = false

    public init(
        socketPath: String = PeerMonitorPaths.socketPath(),
        instanceUUID: UUID = UUID(),
        interval: TimeInterval = 10,
        staleAfter: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() },
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        auditErrorHandler: @escaping @Sendable (Error) -> Void = { error in
            FileHandle.standardError.write(Data("Sanctuary peer-monitor audit failed: \(error)\n".utf8))
        },
        eventHandler: @escaping @Sendable (PeerMonitorEvent) -> Void = { _ in }
    ) {
        self.socketPath = socketPath
        self.instanceUUID = instanceUUID
        self.interval = interval
        self.staleAfter = staleAfter
        self.now = now
        self.auditLogger = auditLogger
        self.auditErrorHandler = auditErrorHandler
        self.eventHandler = eventHandler
    }

    public func start() throws {
        let server = UnixDatagramPeerServer(
            socketPath: socketPath,
            responder: .daemon,
            instanceUUID: instanceUUID,
            now: now
        ) { [weak self] message in
            self?.recordPing(message)
        }
        try server.start()
        lock.withLock {
            self.server = server
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.hardener.sanctuary.peer-monitor.daemon"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.checkForStalePeers()
        }
        lock.withLock {
            self.timer = timer
        }
        timer.resume()
    }

    public func stop() {
        let resources = lock.withLock { () -> (DispatchSourceTimer?, UnixDatagramPeerServer?) in
            let oldTimer = timer
            let oldServer = server
            timer = nil
            server = nil
            menuBarConnected = false
            return (oldTimer, oldServer)
        }
        resources.0?.cancel()
        resources.1?.stop()
    }

    public func recordPing(_ message: PingMessage) {
        guard message.sender == .menuBar else {
            return
        }
        let event: PeerMonitorEvent? = lock.withLock {
            let previous = lastMenuBarUUID
            lastMenuBarUUID = message.instanceUUID
            lastMenuBarSeen = now()

            if let previous, previous != message.instanceUUID {
                menuBarConnected = true
                return .restarted(.menuBar, old: previous, new: message.instanceUUID)
            }
            if !menuBarConnected {
                menuBarConnected = true
                return .connected(.menuBar, message.instanceUUID)
            }
            return nil
        }
        if let event {
            emit(event)
        }
    }

    public func checkForStalePeers() {
        let event: PeerMonitorEvent? = lock.withLock {
            guard menuBarConnected,
                  let lastMenuBarSeen,
                  let lastMenuBarUUID,
                  now().timeIntervalSince(lastMenuBarSeen) > staleAfter
            else {
                return nil
            }
            menuBarConnected = false
            return .disconnected(.menuBar, lastMenuBarUUID)
        }
        if let event {
            emit(event)
        }
    }

    private func emit(_ event: PeerMonitorEvent) {
        eventHandler(event)
        let entry = AuditEntry(
            ts: Self.timestamp(now()),
            kind: "peer",
            action: event.auditAction,
            policy: "peer_monitor",
            resource: event.auditResource
        )
        do {
            try auditLogger.append(entry)
        } catch {
            auditErrorHandler(error)
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension PeerMonitorEvent {
    var auditAction: String {
        switch self {
        case .connected:
            return "PEER_CONNECTED"
        case .disconnected:
            return "PEER_DISCONNECTED"
        case .restarted:
            return "PEER_RESTARTED"
        }
    }

    var auditResource: String {
        switch self {
        case let .connected(role, uuid):
            return "\(role.rawValue)_peer_connected:\(uuid.uuidString)"
        case let .disconnected(role, uuid):
            return "\(role.rawValue)_peer_disconnected:\(uuid.uuidString)"
        case let .restarted(role, old, new):
            return "\(role.rawValue)_peer_restarted:\(old.uuidString)->\(new.uuidString)"
        }
    }
}
