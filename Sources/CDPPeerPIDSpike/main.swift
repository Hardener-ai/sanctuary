// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Network

struct SpikeResult: Encodable {
    let expectedClientPID: Int32
    let listenerPort: UInt16
    let networkMetadataType: String
    let networkMetadataDescription: String
    let reflectedMetadataChildren: [String]
    let currentConclusion: String
}

enum SpikeError: Error, CustomStringConvertible {
    case invalidPort(String)
    case listenerFailed(String)
    case timedOut(String)

    var description: String {
        switch self {
        case let .invalidPort(value):
            return "invalid port: \(value)"
        case let .listenerFailed(reason):
            return "listener failed: \(reason)"
        case let .timedOut(reason):
            return "timed out: \(reason)"
        }
    }
}

final class CDPPeerPIDSpike {
    private let queue = DispatchQueue(label: "ai.hardener.sanctuary.cdp-peer-pid-spike")
    private let requestedPort: NWEndpoint.Port
    private let timeout: TimeInterval
    private var listener: NWListener?
    private var client: NWConnection?
    private var serverConnection: NWConnection?

    init(requestedPort: NWEndpoint.Port, timeout: TimeInterval = 5) {
        self.requestedPort = requestedPort
        self.timeout = timeout
    }

    func run() throws -> SpikeResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: SpikeResult?
        var failure: SpikeError?

        let listener = try NWListener(using: .tcp, on: requestedPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.serverConnection = connection
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                result = self.inspect(connection: connection)
                semaphore.signal()
            }
            connection.start(queue: self.queue)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port else {
                    failure = .listenerFailed("listener became ready without a bound port")
                    semaphore.signal()
                    return
                }
                self.openClientConnection(to: port)
            case let .failed(error):
                failure = .listenerFailed(String(describing: error))
                semaphore.signal()
            default:
                break
            }
        }

        listener.start(queue: queue)

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        cleanup()

        if let result {
            return result
        }

        if let failure {
            throw failure
        }

        if waitResult == .timedOut {
            throw SpikeError.timedOut("no accepted loopback connection became ready within \(timeout)s")
        }

        throw SpikeError.timedOut("spike ended without result")
    }

    private func openClientConnection(to port: NWEndpoint.Port) {
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        self.client = client
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(
                content: Data("GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8),
                completion: .contentProcessed { _ in }
            )
        }
        client.start(queue: queue)
    }

    private func inspect(connection: NWConnection) -> SpikeResult {
        let metadata = connection.metadata(definition: NWProtocolTCP.definition)
        let metadataDescription = metadata.map { String(describing: $0) } ?? "nil"
        let reflectedMetadata: Any = metadata as Any
        let children = Mirror(reflecting: reflectedMetadata).children.map { child in
            let label = child.label ?? "<unlabeled>"
            return "\(label): \(child.value)"
        }

        return SpikeResult(
            expectedClientPID: getpid(),
            listenerPort: listener?.port?.rawValue ?? requestedPort.rawValue,
            networkMetadataType: metadata.map { String(describing: type(of: $0)) } ?? "nil",
            networkMetadataDescription: metadataDescription,
            reflectedMetadataChildren: children,
            currentConclusion: conclusion(metadataDescription: metadataDescription, children: children)
        )
    }

    private func conclusion(metadataDescription: String, children: [String]) -> String {
        let expectedPID = String(getpid())
        let haystack = ([metadataDescription] + children).joined(separator: "\n")

        if haystack.contains(expectedPID) {
            return "possible-peer-pid-surface-found; inspect output before trusting this path"
        }

        return "no-peer-pid-surface-observed-via-public-network-metadata; proceed to proc_pidfdinfo fallback unless a lower-level NW API proves otherwise"
    }

    private func cleanup() {
        client?.cancel()
        serverConnection?.cancel()
        listener?.cancel()
    }
}

func parsePort(_ value: String?) throws -> NWEndpoint.Port {
    guard let value else {
        return NWEndpoint.Port(rawValue: 0)!
    }

    guard let parsed = UInt16(value), let port = NWEndpoint.Port(rawValue: parsed) else {
        throw SpikeError.invalidPort(value)
    }

    return port
}

do {
    let port = try parsePort(CommandLine.arguments.dropFirst().first)
    let spike = CDPPeerPIDSpike(requestedPort: port)
    let result = try spike.run()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("CDP peer pid spike failed: \(error)\n".utf8))
    exit(1)
}
