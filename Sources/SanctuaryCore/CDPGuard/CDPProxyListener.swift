// SPDX-License-Identifier: AGPL-3.0-only
// The pf redirect sends client traffic from 127.0.0.1:<debug-port> to this
// listener. When the proxy splices to Chrome's real port, it must not match the
// same rdr rule again. CDPGuard configures an upstream source-port range and
// PFAnchorManager emits a matching no-rdr rule before the redirect.
import Darwin
import Foundation
import Network

public struct CDPProxyRoute: Equatable, Sendable {
    public let proxyPort: UInt16
    public let targetPort: UInt16
    public let profilePath: String
    public let attributionDestinationPort: UInt16?

    public init(
        proxyPort: UInt16,
        targetPort: UInt16,
        profilePath: String,
        attributionDestinationPort: UInt16? = nil
    ) {
        self.proxyPort = proxyPort
        self.targetPort = targetPort
        self.profilePath = profilePath
        self.attributionDestinationPort = attributionDestinationPort
    }
}

public enum CDPProxyEvent: Equatable, Sendable {
    case allow(pid_t, String)
    case deny(pid_t?, String)
    case failClosed(String)
}

public final class ProtectionPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var protectedProfiles: Set<String>
    private var routesByProxyPort: [UInt16: CDPProxyRoute]

    public init(protectedProfiles: Set<String> = [], routes: [CDPProxyRoute] = []) {
        self.protectedProfiles = Set(protectedProfiles.map(Self.normalizeProfilePath))
        self.routesByProxyPort = Dictionary(uniqueKeysWithValues: routes.map { ($0.proxyPort, $0) })
    }

    public func isProfileProtected(path: String) -> Bool {
        lock.withLock {
            protectedProfiles.contains(Self.normalizeProfilePath(path))
        }
    }

    public func protectProfile(_ path: String) {
        _ = lock.withLock {
            protectedProfiles.insert(Self.normalizeProfilePath(path))
        }
    }

    public func setRoute(
        proxyPort: UInt16,
        targetPort: UInt16,
        profilePath: String,
        attributionDestinationPort: UInt16? = nil
    ) {
        lock.withLock {
            routesByProxyPort[proxyPort] = CDPProxyRoute(
                proxyPort: proxyPort,
                targetPort: targetPort,
                profilePath: profilePath,
                attributionDestinationPort: attributionDestinationPort
            )
        }
    }

    public func route(forProxyPort port: UInt16) -> CDPProxyRoute? {
        lock.withLock {
            routesByProxyPort[port]
        }
    }

    private static func normalizeProfilePath(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        guard standardized.count > 1 else {
            return standardized
        }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}

public protocol ProcessIdentityProviding: Sendable {
    func identity(for pid: pid_t) -> ProcessIdentity?
}

public struct DarwinProcessIdentityProvider: ProcessIdentityProviding {
    public init() {}

    public func identity(for pid: pid_t) -> ProcessIdentity? {
        var buffer = Array(repeating: CChar(0), count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return nil
        }

        let path = String(cString: buffer)
        return ProcessIdentity(pid: pid, executablePath: path)
    }
}

public enum CDPProxyListenerError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidPort
    case bindFailed
}

public final class CDPProxyListener: @unchecked Sendable {
    private let classifier: AgentClassifier
    private let attributor: any PeerProcessAttributing
    private let policy: ProtectionPolicy
    private let identityProvider: any ProcessIdentityProviding
    private let auditLogger: any ExtensionAuditLogging
    private let upstreamSourcePortRange: ClosedRange<UInt16>?
    private var nextUpstreamSourcePort: UInt16?
    private let queue = DispatchQueue(label: "ai.hardener.sanctuary.cdp.proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var recordedEvents: [CDPProxyEvent] = []
    private var listenPort: UInt16?

    public var boundPort: UInt16? {
        lock.withLock { listenPort }
    }

    public var events: [CDPProxyEvent] {
        lock.withLock { recordedEvents }
    }

    public init(
        classifier: AgentClassifier,
        attributor: PeerProcessAttributor,
        policy: ProtectionPolicy,
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        upstreamSourcePortRange: ClosedRange<UInt16>? = nil
    ) {
        self.classifier = classifier
        self.attributor = attributor
        self.policy = policy
        self.identityProvider = DarwinProcessIdentityProvider()
        self.auditLogger = auditLogger
        self.upstreamSourcePortRange = upstreamSourcePortRange
        self.nextUpstreamSourcePort = upstreamSourcePortRange?.lowerBound
    }

    init(
        classifier: AgentClassifier,
        attributor: any PeerProcessAttributing,
        policy: ProtectionPolicy,
        identityProvider: any ProcessIdentityProviding,
        auditLogger: any ExtensionAuditLogging = NoopAuditLogger(),
        upstreamSourcePortRange: ClosedRange<UInt16>? = nil
    ) {
        self.classifier = classifier
        self.attributor = attributor
        self.policy = policy
        self.identityProvider = identityProvider
        self.auditLogger = auditLogger
        self.upstreamSourcePortRange = upstreamSourcePortRange
        self.nextUpstreamSourcePort = upstreamSourcePortRange?.lowerBound
    }

    public func start(on port: UInt16) throws {
        guard listener == nil else {
            throw CDPProxyListenerError.alreadyRunning
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw CDPProxyListenerError.invalidPort
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: nwPort)
        let ready = DispatchSemaphore(value: 0)
        let failed = LockedBox<Bool>(false)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed:
                failed.set(true)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 1)
        if failed.get() {
            throw CDPProxyListenerError.bindFailed
        }
        self.listener = listener
        self.listenPort = listener.port?.rawValue ?? port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        listenPort = nil

        let connections = lock.withLock { () -> [NWConnection] in
            let values = Array(activeConnections.values)
            activeConnections.removeAll()
            return values
        }
        connections.forEach { $0.cancel() }
    }

    private func handle(_ client: NWConnection) {
        track(client)
        client.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            if case .ready = state {
                self.decideAndProxy(client)
            }
            if case .cancelled = state {
                self.untrack(client)
            }
        }
        client.start(queue: queue)
    }

    private func decideAndProxy(_ client: NWConnection) {
        guard
            let port = listenPort,
            let route = policy.route(forProxyPort: port)
        else {
            sendForbiddenAndClose(client)
            return
        }

        let protected = policy.isProfileProtected(path: route.profilePath)
        let verdict = attributionVerdict(
            for: client,
            clientDestinationPort: route.attributionDestinationPort ?? port
        )

        switch verdict {
        case let .agent(pid, _):
            if protected {
                record(.deny(pid, route.profilePath))
                sendForbiddenAndClose(client)
            } else {
                record(.allow(pid, route.profilePath))
                splice(client, to: route.targetPort)
            }
        case let .notAgent(pid):
            record(.allow(pid, route.profilePath))
            splice(client, to: route.targetPort)
        case .unknown:
            if protected {
                record(.failClosed(route.profilePath))
                sendForbiddenAndClose(client)
            } else {
                splice(client, to: route.targetPort)
            }
        }
    }

    private enum ClassifiedPeer {
        case agent(pid_t, AgentVerdict)
        case notAgent(pid_t)
        case unknown
    }

    private func attributionVerdict(
        for client: NWConnection,
        clientDestinationPort: UInt16
    ) -> ClassifiedPeer {
        guard
            let remote = client.endpoint.socketEndpoint,
            let originalDestination = try? SocketEndpoint(ipv4: "127.0.0.1", port: clientDestinationPort)
        else {
            return .unknown
        }

        // NWConnection exposes the server-side accepted socket as
        // local=proxy, remote=client. To identify the peer process, scan for
        // the client's own socket tuple. Under pf rdr, the client process still
        // sees the original browser debug port as its destination, not the
        // proxy listener port.
        switch attributor.attribute(localEndpoint: remote, remoteEndpoint: originalDestination) {
        case let .definite(pid):
            return classify(pid: pid)
        case let .ambiguous(pids):
            var sawNotAgent: pid_t?
            for pid in pids {
                let classified = classify(pid: pid)
                if case .agent = classified {
                    return classified
                }
                if case let .notAgent(notAgentPID) = classified {
                    sawNotAgent = notAgentPID
                }
            }
            return sawNotAgent.map(ClassifiedPeer.notAgent) ?? .unknown
        case .unknown:
            return .unknown
        }
    }

    private func classify(pid: pid_t) -> ClassifiedPeer {
        guard let identity = identityProvider.identity(for: pid) else {
            return .unknown
        }

        let verdict = classifier.classify(identity)
        switch verdict {
        case .agent, .suspicious:
            return .agent(pid, verdict)
        case .notAgent:
            return .notAgent(pid)
        }
    }

    private func splice(_ client: NWConnection, to targetPort: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: targetPort) else {
            client.cancel()
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let selectedSourcePort = allocateUpstreamSourcePort(),
           let sourcePort = NWEndpoint.Port(rawValue: selectedSourcePort) {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: sourcePort)
        }
        let upstream = NWConnection(host: "127.0.0.1", port: nwPort, using: parameters)
        track(upstream)
        upstream.stateUpdateHandler = { [weak self, weak client, weak upstream] state in
            guard let self, let client, let upstream else { return }
            if case .ready = state {
                self.pump(from: client, to: upstream)
                self.pump(from: upstream, to: client)
            }
            if case .cancelled = state {
                self.untrack(upstream)
            }
        }
        upstream.start(queue: queue)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak source, weak destination] data, _, isComplete, error in
            guard let self, let source, let destination else { return }

            if let data, !data.isEmpty {
                destination.send(content: data, isComplete: false, completion: .contentProcessed { [weak self, weak source, weak destination] sendError in
                    guard let self, let source, let destination else { return }
                    if sendError != nil {
                        source.cancel()
                        destination.cancel()
                    } else {
                        self.pump(from: source, to: destination)
                    }
                })
                return
            }

            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func sendForbiddenAndClose(_ connection: NWConnection) {
        let body = "Sanctuary blocked CDP access from agent process. See sanctuary log for details.\n"
        let response = """
        HTTP/1.1 403 Forbidden\r
        Content-Type: text/plain\r
        Connection: close\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), isComplete: true, completion: .contentProcessed { [weak connection] _ in
            connection?.cancel()
        })
    }

    private func track(_ connection: NWConnection) {
        lock.withLock {
            activeConnections[ObjectIdentifier(connection)] = connection
        }
    }

    private func untrack(_ connection: NWConnection) {
        _ = lock.withLock {
            activeConnections.removeValue(forKey: ObjectIdentifier(connection))
        }
    }

    private func record(_ event: CDPProxyEvent) {
        lock.withLock {
            recordedEvents.append(event)
        }
        try? auditLogger.append(event.auditEntry)
        fputs("Sanctuary CDPProxy event: \(event)\n", stderr)
        fflush(stderr)
    }

    private func allocateUpstreamSourcePort() -> UInt16? {
        lock.withLock {
            guard let range = upstreamSourcePortRange else {
                return nil
            }

            let selected = nextUpstreamSourcePort ?? range.lowerBound
            nextUpstreamSourcePort = selected == range.upperBound ? range.lowerBound : selected + 1
            return selected
        }
    }
}

private extension CDPProxyEvent {
    var auditEntry: AuditEntry {
        switch self {
        case let .allow(pid, profilePath):
            return AuditEntry(
                ts: Self.timestamp(),
                kind: "cdp_access",
                action: "ALLOW",
                attribution: .init(level: "definite", pid: pid, processPath: nil, agentPids: [pid]),
                policy: "cdp_guard",
                profilePath: profilePath
            )
        case let .deny(pid, profilePath):
            return AuditEntry(
                ts: Self.timestamp(),
                kind: "cdp_access",
                action: "DENY",
                attribution: .init(level: pid == nil ? "unknown" : "definite", pid: pid, processPath: nil, agentPids: pid.map { [$0] } ?? []),
                policy: "cdp_guard",
                profilePath: profilePath
            )
        case let .failClosed(profilePath):
            return AuditEntry(
                ts: Self.timestamp(),
                kind: "cdp_access",
                action: "FAIL_CLOSED",
                attribution: .init(level: "unknown", pid: nil, processPath: nil, agentPids: []),
                policy: "cdp_guard",
                profilePath: profilePath
            )
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private extension NWEndpoint {
    var socketEndpoint: SocketEndpoint? {
        guard case let .hostPort(host, port) = self else {
            return nil
        }

        let rawPort = port.rawValue
        switch host {
        case let .ipv4(address):
            return SocketEndpoint(address: .ipv4(Array(address.rawValue)), port: rawPort)
        case let .ipv6(address):
            return SocketEndpoint(address: .ipv6(Array(address.rawValue)), port: rawPort)
        case let .name(name, _):
            if let endpoint = try? SocketEndpoint(ipv4: name, port: rawPort) {
                return endpoint
            }
            return try? SocketEndpoint(ipv6: name, port: rawPort)
        default:
            return nil
        }
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.withLock {
            self.value = value
        }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}
