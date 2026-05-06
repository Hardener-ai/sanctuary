// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import SanctuaryCore

struct CDPProxyListenerTests {
    @Test func nonAgentProcessIsSplicedThrough() throws {
        let harness = try ProxyHarness(attribution: .definite(200), identity: Self.nonAgent(pid: 200), protectedProfiles: ["/profiles/protected"])
        defer { harness.stop() }

        let response = try sendRawTCPRequest(port: harness.proxyPort)

        #expect(response.contains("upstream-ok"))
        #expect(harness.listener.events.contains(CDPProxyEvent.allow(200, "/profiles/protected")))
    }

    @Test func agentProcessToProtectedProfileIsDroppedWith403() throws {
        let harness = try ProxyHarness(attribution: .definite(300), identity: Self.agent(pid: 300), protectedProfiles: ["/profiles/protected"])
        defer { harness.stop() }

        let response = try sendRawTCPRequest(port: harness.proxyPort)

        #expect(response.contains("403 Forbidden"))
        #expect(harness.listener.events.contains(CDPProxyEvent.deny(300, "/profiles/protected")))
    }

    @Test func acceptedConnectionAttributionUsesClientSideTuple() throws {
        let upstream = TestHTTPServer(responseText: httpResponse(body: "{\"status\":\"upstream-ok\"}"))
        try upstream.start()
        defer { upstream.stop() }

        let policy = ProtectionPolicy()
        let attributor = CapturingAttributor(result: .definite(200))
        let listener = CDPProxyListener(
            classifier: AgentClassifier(),
            attributor: attributor,
            policy: policy,
            identityProvider: FixedIdentityProvider(identities: [200: Self.nonAgent(pid: 200)])
        )
        try listener.start(on: 0)
        defer { listener.stop() }

        let proxyPort = try #require(listener.boundPort)
        policy.setRoute(proxyPort: proxyPort, targetPort: upstream.port, profilePath: "/profiles/protected")

        _ = try sendRawTCPRequest(port: proxyPort)

        let call = try #require(attributor.calls.first)
        #expect(call.remoteEndpoint.port == proxyPort)
        #expect(call.localEndpoint.port != proxyPort)
    }

    @Test func agentProcessToUnprotectedProfileIsSplicedAndLoggedAllowed() throws {
        let harness = try ProxyHarness(attribution: .definite(300), identity: Self.agent(pid: 300), protectedProfiles: [])
        defer { harness.stop() }

        let response = try sendRawTCPRequest(port: harness.proxyPort)

        #expect(response.contains("upstream-ok"))
        #expect(harness.listener.events.contains(CDPProxyEvent.allow(300, "/profiles/protected")))
    }

    @Test func unknownAttributionToProtectedProfileFailsClosed() throws {
        let harness = try ProxyHarness(attribution: .unknown, identity: nil, protectedProfiles: ["/profiles/protected"])
        defer { harness.stop() }

        let response = try sendRawTCPRequest(port: harness.proxyPort)

        #expect(response.contains("403 Forbidden"))
        #expect(harness.listener.events.contains(CDPProxyEvent.failClosed("/profiles/protected")))
    }

    @Test func multipleConcurrentConnectionsDoNotCrash() throws {
        let harness = try ProxyHarness(attribution: .definite(200), identity: Self.nonAgent(pid: 200), protectedProfiles: ["/profiles/protected"])
        defer { harness.stop() }
        let queue = DispatchQueue(label: "ai.hardener.sanctuary.tests.concurrent-proxy", attributes: .concurrent)
        let group = DispatchGroup()
        let failures = LockedBox<Int>(0)

        for _ in 0..<20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let response = try sendRawTCPRequest(port: harness.proxyPort)
                    if !response.contains("upstream-ok") {
                        failures.set(failures.get() + 1)
                    }
                } catch {
                    failures.set(failures.get() + 1)
                }
            }
        }

        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(failures.get() == 0)
    }

    @Test func stopCleanlyClosesInflightConnections() throws {
        let upstream = TestHTTPServer { _ in
            Thread.sleep(forTimeInterval: 1)
            return Data(httpResponse(body: "{\"late\":true}").utf8)
        }
        try upstream.start()
        defer { upstream.stop() }

        let policy = ProtectionPolicy(
            protectedProfiles: [],
            routes: []
        )
        let listener = CDPProxyListener(
            classifier: AgentClassifier(),
            attributor: FixedAttributor(result: .definite(200)),
            policy: policy,
            identityProvider: FixedIdentityProvider(identities: [200: Self.nonAgent(pid: 200)])
        )
        try listener.start(on: 0)
        let proxyPort = try #require(listener.boundPort)
        policy.setRoute(proxyPort: proxyPort, targetPort: upstream.port, profilePath: "/profiles/protected")

        let queue = DispatchQueue(label: "ai.hardener.sanctuary.tests.stop-proxy")
        let group = DispatchGroup()
        group.enter()
        queue.async {
            _ = try? sendRawTCPRequest(port: proxyPort)
            group.leave()
        }

        Thread.sleep(forTimeInterval: 0.05)
        listener.stop()

        #expect(group.wait(timeout: .now() + 2) == .success)
    }

    private static func nonAgent(pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(pid: pid, executablePath: "/usr/bin/curl")
    }

    private static func agent(pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            executablePath: "/usr/local/bin/claude",
            teamIdentifier: AgentClassifier.anthropicTeamID
        )
    }

}

private final class ProxyHarness {
    let upstream: TestHTTPServer
    let listener: CDPProxyListener
    let proxyPort: UInt16

    init(attribution: AttributionResult, identity: ProcessIdentity?, protectedProfiles: Set<String>) throws {
        upstream = TestHTTPServer(responseText: httpResponse(body: "{\"status\":\"upstream-ok\"}"))
        try upstream.start()

        let policy = ProtectionPolicy(
            protectedProfiles: protectedProfiles,
            routes: []
        )
        let identities = identity.map { [$0.pid: $0] } ?? [:]
        listener = CDPProxyListener(
            classifier: AgentClassifier(),
            attributor: FixedAttributor(result: attribution),
            policy: policy,
            identityProvider: FixedIdentityProvider(identities: identities)
        )
        try listener.start(on: 0)
        proxyPort = try #require(listener.boundPort)
        policy.setRoute(proxyPort: proxyPort, targetPort: upstream.port, profilePath: "/profiles/protected")
    }

    func stop() {
        listener.stop()
        upstream.stop()
    }
}

private struct FixedAttributor: PeerProcessAttributing {
    let result: AttributionResult

    func attribute(localEndpoint: SocketEndpoint, remoteEndpoint: SocketEndpoint) -> AttributionResult {
        result
    }
}

private struct FixedIdentityProvider: ProcessIdentityProviding {
    let identities: [pid_t: ProcessIdentity]

    func identity(for pid: pid_t) -> ProcessIdentity? {
        identities[pid]
    }
}

private final class CapturingAttributor: PeerProcessAttributing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: AttributionResult
    private var capturedCalls: [(localEndpoint: SocketEndpoint, remoteEndpoint: SocketEndpoint)] = []

    var calls: [(localEndpoint: SocketEndpoint, remoteEndpoint: SocketEndpoint)] {
        lock.withLock { capturedCalls }
    }

    init(result: AttributionResult) {
        self.result = result
    }

    func attribute(localEndpoint: SocketEndpoint, remoteEndpoint: SocketEndpoint) -> AttributionResult {
        lock.withLock {
            capturedCalls.append((localEndpoint, remoteEndpoint))
        }
        return result
    }
}
