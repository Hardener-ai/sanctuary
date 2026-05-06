// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct BrowserDebugPortDiscoveryTests {
    @Test func parsesEqualsRemoteDebuggingPort() {
        #expect(BrowserDebugPortDiscovery.parseRemoteDebuggingPort(from: ["chrome", "--remote-debugging-port=9222"]) == 9222)
    }

    @Test func parsesSpaceSeparatedRemoteDebuggingPort() {
        #expect(BrowserDebugPortDiscovery.parseRemoteDebuggingPort(from: ["chrome", "--remote-debugging-port", "9222"]) == 9222)
    }

    @Test func parsesEphemeralRemoteDebuggingPort() {
        #expect(BrowserDebugPortDiscovery.parseRemoteDebuggingPort(from: ["chrome", "--remote-debugging-port=0"]) == 0)
    }

    @Test func missingRemoteDebuggingPortIsNil() {
        #expect(BrowserDebugPortDiscovery.parseRemoteDebuggingPort(from: ["chrome"]) == nil)
    }

    @Test func parsesEqualsUserDataDir() {
        #expect(BrowserDebugPortDiscovery.parseUserDataDir(from: ["chrome", "--user-data-dir=/foo"]) == "/foo")
    }

    @Test func parsesSpaceSeparatedUserDataDir() {
        #expect(BrowserDebugPortDiscovery.parseUserDataDir(from: ["chrome", "--user-data-dir", "/foo bar"]) == "/foo bar")
    }

    @Test func isCDPPortReturnsTrueForVersionJSONWithWebSocketDebuggerURL() throws {
        let body = try fixture(named: "json-version-cdp.json")
        let server = TestHTTPServer(responseText: httpResponse(body: body))
        try server.start()
        defer { server.stop() }

        #expect(BrowserDebugPortDiscovery.isCDPPort(host: "127.0.0.1", port: server.port))
    }

    @Test func isCDPPortReturnsFalseForNonCDPHTTPServer() throws {
        let body = try fixture(named: "json-version-non-cdp.json")
        let server = TestHTTPServer(responseText: httpResponse(body: body))
        try server.start()
        defer { server.stop() }

        #expect(!BrowserDebugPortDiscovery.isCDPPort(host: "127.0.0.1", port: server.port))
    }

    @Test func isCDPPortReturnsFalseOnConnectionRefused() throws {
        let server = TestHTTPServer(responseText: httpResponse(body: "{}"))
        try server.start()
        let port = server.port
        server.stop()

        #expect(!BrowserDebugPortDiscovery.isCDPPort(host: "127.0.0.1", port: port, timeout: 0.1))
    }
}
