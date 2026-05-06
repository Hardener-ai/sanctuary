// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Network
import NetworkExtension

struct NEFilterSpikeResult: Encodable {
    struct ObservedIdentityFields: Encodable {
        let sourceAppIdentifier: String?
        let sourceAppAuditToken: String?
        let sourceProcessAuditToken: String?
        let sourcePID: Int32?
        let sourceSigningIdentifier: String?
    }

    struct ManagerAttempt: Encodable {
        let loadFromPreferences: String
        let saveToPreferences: String
        let removeFromPreferences: String
        let providerBundleIdentifier: String
        let filterSockets: Bool
        let grade: String
    }

    struct LocalhostProbe: Encodable {
        let listenerPort: UInt16?
        let connectionSucceeded: Bool
        let bytesSent: Int
        let bytesReceived: Int
        let error: String?
    }

    struct SDKObservation: Encodable {
        let sourceAppIdentifierAvailability: String
        let sourceAppAuditTokenAvailability: String
        let sourceProcessAuditTokenAvailability: String
    }

    let expected_pid: Int32
    let loopback_flow_observed: Bool
    let observed_identity_fields: ObservedIdentityFields
    let latency_ms: Double?
    let entitlement_status: String
    let manager_attempt: ManagerAttempt
    let localhost_probe: LocalhostProbe
    let sdk_observation: SDKObservation
    let attempted_steps: [String]
    let conclusion: String
}

private let providerBundleIdentifier = "ai.hardener.sanctuary.ne-filter-spike.extension"

func waitForNEOperation(_ operation: (@escaping (Error?) -> Void) -> Void) -> String {
    let deadline = Date().addingTimeInterval(10)
    var completed = false
    var result = "not-run"

    operation { error in
        if let error {
            result = String(describing: error)
        } else {
            result = "ok"
        }
        completed = true
    }

    while !completed && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    if !completed {
        return "timed-out"
    }

    return result
}

func attemptFilterManagerConfiguration() -> NEFilterSpikeResult.ManagerAttempt {
    let manager = NEFilterManager.shared()

    let loadResult = waitForNEOperation { completion in
        manager.loadFromPreferences(completionHandler: completion)
    }

    let configuration = NEFilterProviderConfiguration()
    configuration.filterSockets = true
    configuration.filterDataProviderBundleIdentifier = providerBundleIdentifier

    manager.localizedDescription = "Sanctuary NEFilter spike"
    manager.providerConfiguration = configuration
    manager.grade = .firewall
    manager.isEnabled = true

    let saveResult = waitForNEOperation { completion in
        manager.saveToPreferences(completionHandler: completion)
    }

    let removeResult: String
    if saveResult == "ok" {
        removeResult = waitForNEOperation { completion in
            manager.removeFromPreferences(completionHandler: completion)
        }
    } else {
        removeResult = "not-run-save-failed"
    }

    return .init(
        loadFromPreferences: loadResult,
        saveToPreferences: saveResult,
        removeFromPreferences: removeResult,
        providerBundleIdentifier: providerBundleIdentifier,
        filterSockets: configuration.filterSockets,
        grade: "firewall"
    )
}

final class LocalhostProbeRunner {
    private let queue = DispatchQueue(label: "ai.hardener.sanctuary.ne-filter-spike.localhost")
    private var listener: Network.NWListener?
    private var serverConnection: Network.NWConnection?
    private var clientConnection: Network.NWConnection?

    func run() -> NEFilterSpikeResult.LocalhostProbe {
        let semaphore = DispatchSemaphore(value: 0)
        var listenerPort: UInt16?
        var connectionSucceeded = false
        var bytesReceived = 0
        var error: String?
        let payload = Data("sanctuary-ne-filter-spike".utf8)

        do {
            let listener = try Network.NWListener(using: .tcp, on: 0)
            self.listener = listener

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.serverConnection = connection
                connection.stateUpdateHandler = { state in
                    if case let .failed(stateError) = state {
                        error = String(describing: stateError)
                        semaphore.signal()
                    }
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, receiveError in
                    if let receiveError {
                        error = String(describing: receiveError)
                    }
                    bytesReceived = data?.count ?? 0
                    semaphore.signal()
                }
                connection.start(queue: self.queue)
            }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        error = "listener-ready-without-port"
                        semaphore.signal()
                        return
                    }
                    listenerPort = port.rawValue
                    self.openClientConnection(to: port, payload: payload) {
                        connectionSucceeded = true
                    }
                case let .failed(stateError):
                    error = String(describing: stateError)
                    semaphore.signal()
                default:
                    break
                }
            }

            listener.start(queue: queue)

            if semaphore.wait(timeout: .now() + 5) == .timedOut {
                error = "timed-out"
            }
        } catch {
            return .init(
                listenerPort: nil,
                connectionSucceeded: false,
                bytesSent: 0,
                bytesReceived: 0,
                error: String(describing: error)
            )
        }

        cleanup()

        return .init(
            listenerPort: listenerPort,
            connectionSucceeded: connectionSucceeded,
            bytesSent: connectionSucceeded ? payload.count : 0,
            bytesReceived: bytesReceived,
            error: error
        )
    }

    private func openClientConnection(to port: Network.NWEndpoint.Port, payload: Data, onReady: @escaping () -> Void) {
        let connection = Network.NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        clientConnection = connection
        connection.stateUpdateHandler = { (state: Network.NWConnection.State) in
            guard case .ready = state else { return }
            onReady()
            connection.send(content: payload, completion: Network.NWConnection.SendCompletion.contentProcessed { _ in })
        }
        connection.start(queue: queue)
    }

    private func cleanup() {
        clientConnection?.cancel()
        serverConnection?.cancel()
        listener?.cancel()
    }
}

func entitlementStatus(from managerAttempt: NEFilterSpikeResult.ManagerAttempt) -> String {
    let combined = [
        managerAttempt.loadFromPreferences,
        managerAttempt.saveToPreferences
    ].joined(separator: "\n").lowercased()

    if combined.contains("permission") || combined.contains("denied") || combined.contains("not entitled") || combined.contains("entitlement") {
        return "missing-or-denied"
    }

    if managerAttempt.saveToPreferences == "ok" {
        return "available"
    }

    return "unknown"
}

func conclusion(entitlementStatus: String, managerAttempt: NEFilterSpikeResult.ManagerAttempt) -> String {
    if managerAttempt.saveToPreferences == "ok" {
        return "inconclusive-manager-configured-but-no-provider-callback-captured-by-swiftpm-controller"
    }

    if entitlementStatus == "missing-or-denied" {
        return "inconclusive-entitlement-or-provider-packaging-blocked-before-flow-callback"
    }

    return "inconclusive-filter-manager-configuration-did-not-activate-provider"
}

let managerAttempt = attemptFilterManagerConfiguration()
let localhostProbeRunner = LocalhostProbeRunner()
let localhostProbe = localhostProbeRunner.run()
let status = entitlementStatus(from: managerAttempt)

let result = NEFilterSpikeResult(
    expected_pid: getpid(),
    loopback_flow_observed: false,
    observed_identity_fields: .init(
        sourceAppIdentifier: nil,
        sourceAppAuditToken: nil,
        sourceProcessAuditToken: nil,
        sourcePID: nil,
        sourceSigningIdentifier: nil
    ),
    latency_ms: nil,
    entitlement_status: status,
    manager_attempt: managerAttempt,
    localhost_probe: localhostProbe,
    sdk_observation: .init(
        sourceAppIdentifierAvailability: "iOS-only; unavailable on macOS",
        sourceAppAuditTokenAvailability: "macOS 10.15+ public NEFilterFlow field",
        sourceProcessAuditTokenAvailability: "macOS 13.0+ public NEFilterFlow field"
    ),
    attempted_steps: [
        "load NEFilterManager preferences",
        "configure NEFilterProviderConfiguration with filterSockets=true and provider bundle id",
        "attempt saveToPreferences to activate the content filter",
        "open localhost TCP listener and connect from same process",
        "emit JSON result; no NEFilterDataProvider callback was reachable from this SwiftPM-only controller"
    ],
    conclusion: conclusion(entitlementStatus: status, managerAttempt: managerAttempt)
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(result)
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
