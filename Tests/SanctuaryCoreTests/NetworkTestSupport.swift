// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Network
@testable import SanctuaryCore

final class TestHTTPServer {
    private let response: (Data) -> Data
    private let queue = DispatchQueue(label: "ai.hardener.sanctuary.tests.http-server")
    private var listener: NWListener?

    private(set) var port: UInt16 = 0

    init(response: @escaping (Data) -> Data) {
        self.response = response
    }

    convenience init(responseText: String) {
        self.init { _ in Data(responseText.utf8) }
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: 0)!)
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

        listener.newConnectionHandler = { [response, queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                let request = data ?? Data()
                connection.send(content: response(request), isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }

        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 1)
        guard !failed.get(), let assignedPort = listener.port?.rawValue else {
            throw TestNetworkError.listenerFailed
        }

        self.listener = listener
        self.port = assignedPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

enum TestNetworkError: Error {
    case listenerFailed
    case invalidPort
    case connectionFailed
    case responseTimedOut
}

func fixture(named name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CDP/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

func httpResponse(status: String = "200 OK", body: String) -> String {
    """
    HTTP/1.1 \(status)\r
    Content-Type: application/json\r
    Connection: close\r
    Content-Length: \(body.utf8.count)\r
    \r
    \(body)
    """
}

func sendRawTCPRequest(port: UInt16, request: String = "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") throws -> String {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
        throw TestNetworkError.invalidPort
    }

    let queue = DispatchQueue(label: "ai.hardener.sanctuary.tests.tcp-client.\(UUID().uuidString)")
    let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    let ready = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let failed = LockedBox<Bool>(false)
    let received = LockedBox<Data>(Data())

    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            ready.signal()
        case .failed:
            failed.set(true)
            ready.signal()
            finished.signal()
        case .cancelled:
            finished.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)

    guard ready.wait(timeout: .now() + 2) == .success, !failed.get() else {
        connection.cancel()
        throw TestNetworkError.connectionFailed
    }

    connection.send(content: Data(request.utf8), isComplete: false, completion: .contentProcessed { error in
        if error != nil {
            failed.set(true)
            finished.signal()
        }
    })

    func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                received.set(received.get() + data)
            }
            if isComplete || error != nil || data == nil {
                finished.signal()
            } else {
                receiveLoop()
            }
        }
    }
    receiveLoop()

    guard finished.wait(timeout: .now() + 3) == .success else {
        connection.cancel()
        throw TestNetworkError.responseTimedOut
    }

    connection.cancel()
    return String(decoding: received.get(), as: UTF8.self)
}
