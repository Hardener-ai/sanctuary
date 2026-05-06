// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public enum PeerRole: String, Codable, Sendable {
    case menuBar
    case daemon
}

public struct PingMessage: Codable, Equatable, Sendable {
    public let sender: PeerRole
    public let timestamp: Date
    public let instanceUUID: UUID

    public init(sender: PeerRole, timestamp: Date, instanceUUID: UUID) {
        self.sender = sender
        self.timestamp = timestamp
        self.instanceUUID = instanceUUID
    }

    private enum CodingKeys: String, CodingKey {
        case sender
        case timestamp
        case instanceUUID = "instance_uuid"
    }
}

public struct PongMessage: Codable, Equatable, Sendable {
    public let responder: PeerRole
    public let timestamp: Date
    public let instanceUUID: UUID

    public init(responder: PeerRole, timestamp: Date, instanceUUID: UUID) {
        self.responder = responder
        self.timestamp = timestamp
        self.instanceUUID = instanceUUID
    }

    private enum CodingKeys: String, CodingKey {
        case responder
        case timestamp
        case instanceUUID = "instance_uuid"
    }
}

public enum PeerEnvelope: Codable, Equatable, Sendable {
    case ping(PingMessage)
    case pong(PongMessage)

    private enum CodingKeys: String, CodingKey {
        case type
        case ping
        case pong
    }

    private enum EnvelopeType: String, Codable {
        case ping
        case pong
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EnvelopeType.self, forKey: .type) {
        case .ping:
            self = .ping(try container.decode(PingMessage.self, forKey: .ping))
        case .pong:
            self = .pong(try container.decode(PongMessage.self, forKey: .pong))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ping(message):
            try container.encode(EnvelopeType.ping, forKey: .type)
            try container.encode(message, forKey: .ping)
        case let .pong(message):
            try container.encode(EnvelopeType.pong, forKey: .type)
            try container.encode(message, forKey: .pong)
        }
    }
}

public enum PeerProtocolCodec {
    public static func encode(_ envelope: PeerEnvelope) throws -> Data {
        try encoder.encode(envelope)
    }

    public static func decode(_ data: Data) throws -> PeerEnvelope {
        try decoder.decode(PeerEnvelope.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum PeerMonitorPaths {
    public static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["SANCTUARY_PEER_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return "/tmp/ai.hardener.sanctuary.peer-monitor.sock"
    }
}

public enum PeerTransportError: Error, CustomStringConvertible {
    case socketFailed(Int32)
    case bindFailed(String, Int32)
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case invalidPath(String)

    public var description: String {
        switch self {
        case let .socketFailed(errnoValue):
            return "peer socket failed: errno \(errnoValue)"
        case let .bindFailed(path, errnoValue):
            return "peer bind failed for \(path): errno \(errnoValue)"
        case let .sendFailed(errnoValue):
            return "peer send failed: errno \(errnoValue)"
        case let .receiveFailed(errnoValue):
            return "peer receive failed: errno \(errnoValue)"
        case let .invalidPath(path):
            return "peer socket path too long or invalid: \(path)"
        }
    }
}

public final class UnixDatagramPeerServer: @unchecked Sendable {
    private let socketPath: String
    private let responder: PeerRole
    private let instanceUUID: UUID
    private let onPing: @Sendable (PingMessage) -> Void
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = false

    public init(
        socketPath: String = PeerMonitorPaths.socketPath(),
        responder: PeerRole = .daemon,
        instanceUUID: UUID,
        now: @escaping @Sendable () -> Date = { Date() },
        onPing: @escaping @Sendable (PingMessage) -> Void
    ) {
        self.socketPath = socketPath
        self.responder = responder
        self.instanceUUID = instanceUUID
        self.onPing = onPing
        self.now = now
    }

    public func start() throws {
        try lock.withLock {
            guard !running else {
                return
            }
            let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
            guard socketFD >= 0 else {
                throw PeerTransportError.socketFailed(errno)
            }
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            unlink(socketPath)
            var address = try UnixDatagramPeerTransport.address(for: socketPath)
            let length = UnixDatagramPeerTransport.addressLength(for: socketPath)
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, length)
                }
            }
            guard bindResult == 0 else {
                let errnoValue = errno
                Darwin.close(socketFD)
                throw PeerTransportError.bindFailed(socketPath, errnoValue)
            }

            fd = socketFD
            running = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.receiveLoop(socketFD)
            }
        }
    }

    public func stop() {
        let oldFD = lock.withLock { () -> Int32 in
            guard running else {
                return -1
            }
            running = false
            let old = fd
            fd = -1
            return old
        }
        if oldFD >= 0 {
            Darwin.close(oldFD)
        }
        unlink(socketPath)
    }

    private func receiveLoop(_ socketFD: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while lock.withLock({ running && fd == socketFD }) {
            var source = sockaddr_un()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bufferCount = buffer.count
            let count = withUnsafeMutablePointer(to: &source) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    buffer.withUnsafeMutableBytes {
                        Darwin.recvfrom(socketFD, $0.baseAddress, bufferCount, 0, sockaddrPointer, &sourceLength)
                    }
                }
            }
            guard count > 0 else {
                continue
            }

            let data = Data(buffer.prefix(count))
            guard case let .ping(message) = try? PeerProtocolCodec.decode(data) else {
                continue
            }
            onPing(message)

            let pong = PongMessage(responder: responder, timestamp: now(), instanceUUID: instanceUUID)
            guard let response = try? PeerProtocolCodec.encode(.pong(pong)) else {
                continue
            }
            var responseSource = source
            _ = withUnsafePointer(to: &responseSource) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    response.withUnsafeBytes {
                        Darwin.sendto(socketFD, $0.baseAddress, response.count, 0, sockaddrPointer, sourceLength)
                    }
                }
            }
        }
    }

    deinit {
        stop()
    }
}

public enum UnixDatagramPeerTransport {
    public static func sendPingAndWait(
        socketPath: String = PeerMonitorPaths.socketPath(),
        sender: PeerRole,
        instanceUUID: UUID,
        timeout: TimeInterval = 1.0,
        now: @Sendable () -> Date = { Date() }
    ) throws -> PongMessage? {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            throw PeerTransportError.socketFailed(errno)
        }
        defer { Darwin.close(socketFD) }

        let clientPath = "/tmp/ai.hardener.sanctuary.peer.\(UUID().uuidString).sock"
        defer { unlink(clientPath) }
        unlink(clientPath)
        var clientAddress = try address(for: clientPath)
        let clientLength = addressLength(for: clientPath)
        let bindResult = withUnsafePointer(to: &clientAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, clientLength)
            }
        }
        guard bindResult == 0 else {
            throw PeerTransportError.bindFailed(clientPath, errno)
        }

        let ping = PingMessage(sender: sender, timestamp: now(), instanceUUID: instanceUUID)
        let data = try PeerProtocolCodec.encode(.ping(ping))
        var serverAddress = try address(for: socketPath)
        let serverLength = addressLength(for: socketPath)
        let sent = withUnsafePointer(to: &serverAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                data.withUnsafeBytes {
                    Darwin.sendto(socketFD, $0.baseAddress, data.count, 0, sockaddrPointer, serverLength)
                }
            }
        }
        guard sent == data.count else {
            return nil
        }

        var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let pollResult = Darwin.poll(&pollFD, 1, Int32(timeout * 1000))
        guard pollResult > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bufferCount = buffer.count
        let received = buffer.withUnsafeMutableBytes {
            Darwin.recv(socketFD, $0.baseAddress, bufferCount, 0)
        }
        guard received > 0 else {
            throw PeerTransportError.receiveFailed(errno)
        }
        guard case let .pong(message) = try PeerProtocolCodec.decode(Data(buffer.prefix(received))) else {
            return nil
        }
        return message
    }

    static func address(for path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8)
        guard !pathBytes.isEmpty, pathBytes.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw PeerTransportError.invalidPath(path)
        }
        var address = sockaddr_un()
        let length = addressLength(for: path)
        guard length <= UInt8.max else {
            throw PeerTransportError.invalidPath(path)
        }
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.copyBytes(from: pathBytes)
            rawBuffer[pathBytes.count] = 0
        }
        return address
    }

    static func addressLength(for path: String) -> socklen_t {
        let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        return socklen_t(pathOffset + path.utf8.count + 1)
    }
}
