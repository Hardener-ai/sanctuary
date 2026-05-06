// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct CDPGuardPFIntegrationTests {
    @Test func pfRedirectRoutesThroughCDPGuardListenerIsGated() throws {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_PF_TESTS"] == "1", currentEffectiveUserID() == 0 else {
            print("skipped: requires sudo and SANCTUARY_RUN_PF_TESTS=1")
            return
        }

        let chromeFixture = TestHTTPServer(responseText: httpResponse(body: "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1/devtools/browser/test\"}"))
        try chromeFixture.start()
        defer { chromeFixture.stop() }

        let discovery = FixedBrowserDiscovery(ports: [
            .init(pid: 10_001, bundleID: "com.google.Chrome", port: chromeFixture.port, userDataDir: "/profiles/unprotected")
        ])
        let policy = ProtectionPolicy()
        let guardInstance = CDPGuard(
            classifier: AgentClassifier(),
            attributor: PeerProcessAttributor(),
            discovery: discovery,
            policy: policy,
            pfAnchorManager: PFAnchorManager(),
            proxyPort: 0
        )

        try guardInstance.start()
        defer { guardInstance.stop() }
        Thread.sleep(forTimeInterval: 0.5)

        let response = try sendRawTCPRequest(port: chromeFixture.port)
        #expect(response.contains("webSocketDebuggerUrl"))

        guardInstance.stop()
        let rules = try ProcessCommandRunner().run(executable: "/sbin/pfctl", arguments: ["-a", PFAnchorManager.defaultAnchorName, "-s", "nat"])
        #expect(!rules.stdout.contains(String(chromeFixture.port)))
    }
}

private final class FixedBrowserDiscovery: BrowserDebugPortDiscovering, @unchecked Sendable {
    private let ports: [BrowserDebugPortDiscovery.DebugPort]

    init(ports: [BrowserDebugPortDiscovery.DebugPort]) {
        self.ports = ports
    }

    func discover() -> [BrowserDebugPortDiscovery.DebugPort] {
        ports
    }

    func startWatching(_ callback: @escaping ([BrowserDebugPortDiscovery.DebugPort]) -> Void) {
        callback(ports)
    }

    func stopWatching() {}
}
