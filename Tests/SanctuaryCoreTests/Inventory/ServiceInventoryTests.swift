// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ServiceInventoryTests {
    @Test func knownListForegroundCodingUsesRegistryCategory() {
        let codex = ProcessIdentity(pid: 10, executablePath: "/opt/homebrew/bin/codex")
        let inventory = makeInventory(identities: [codex])

        inventory.refresh()

        #expect(inventory.entry(pid: 10)?.category == .foregroundCoding)
    }

    @Test func knownListBackgroundServiceUsesRegistryCategory() {
        let hermes = ProcessIdentity(pid: 11, executablePath: "/Users/test/.hermes/hermes")
        let inventory = makeInventory(identities: [hermes])

        inventory.refresh()

        #expect(inventory.entry(pid: 11)?.category == .backgroundService)
    }

    @Test func knownListBrowserAgentUsesRegistryCategory() {
        let browser = ProcessIdentity(pid: 12, executablePath: "/usr/local/bin/browser-use")
        let inventory = makeInventory(identities: [browser])

        inventory.refresh()

        #expect(inventory.entry(pid: 12)?.category == .browserAgent)
    }

    @Test func serviceLaunchMapsToBackgroundService() {
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let agent = ProcessIdentity(pid: 13, executablePath: "/tmp/service", parentChain: [launchd], launchdLabel: "ai.hermes.gateway")
        let inventory = makeInventory(
            identities: [agent],
            classifier: AgentClassifier(knownAgents: [hermesAgent()], launchdPlistIndex: LaunchdPlistIndex(entries: [
                .init(label: "ai.hermes.gateway", program: "/tmp/service")
            ])),
            knownAgents: [hermesAgent()],
            launchdPlistIndex: LaunchdPlistIndex(entries: [
                .init(label: "ai.hermes.gateway", program: "/tmp/service")
            ])
        )

        inventory.refresh()

        #expect(inventory.entry(pid: 13)?.category == .backgroundService)
    }

    @Test func parentChainInheritsParentCategory() {
        let parent = ProcessIdentity(pid: 14, executablePath: "/opt/homebrew/bin/codex")
        let child = ProcessIdentity(pid: 15, executablePath: "/bin/zsh", parentChain: [parent])
        let inventory = makeInventory(identities: [parent, child])

        inventory.refresh()

        #expect(inventory.entry(pid: 15)?.category == .foregroundCoding)
        #expect(inventory.entry(pid: 15)?.parentPid == 14)
        #expect(inventory.entry(pid: 15)?.parentDisplayName == "Codex CLI")
    }

    @Test func pythonRuntimeMapsToRuntimeFingerprint() {
        let python = ProcessIdentity(pid: 16, executablePath: "/usr/bin/python3", arguments: ["python3", "-m", "anthropic"])
        let inventory = makeInventory(identities: [python])

        inventory.refresh()

        #expect(inventory.entry(pid: 16)?.category == .runtimeFingerprint)
    }

    @Test func nodeRuntimeMapsToRuntimeFingerprint() {
        let node = ProcessIdentity(
            pid: 17,
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/tmp/node_modules/@anthropic-ai/sdk/index.js"]
        )
        let inventory = makeInventory(identities: [node])

        inventory.refresh()

        #expect(inventory.entry(pid: 17)?.category == .runtimeFingerprint)
    }

    @Test func userTaggedFallsBackToBackgroundService() {
        let custom = ProcessIdentity(pid: 18, executablePath: "/tmp/custom-agent")
        let inventory = makeInventory(
            identities: [custom],
            classifier: AgentClassifier(userAgentExecutablePaths: ["/tmp/custom-agent"])
        )

        inventory.refresh()

        #expect(inventory.entry(pid: 18)?.category == .backgroundService)
    }

    @Test func suspiciousMapsToSuspiciousCategory() {
        let suspicious = ProcessIdentity(
            pid: 19,
            executablePath: "/usr/bin/python3",
            environmentVars: ["OPENAI_API_KEY"],
            childProcessObservations: [.init(executablePath: "/bin/sh", secondsAgo: 5)]
        )
        let inventory = makeInventory(identities: [suspicious])

        inventory.refresh()

        #expect(inventory.entry(pid: 19)?.category == .suspicious)
    }

    @Test func notAgentIsExcluded() {
        let ordinary = ProcessIdentity(pid: 20, executablePath: "/usr/bin/ssh")
        let inventory = makeInventory(identities: [ordinary])

        inventory.refresh()

        #expect(inventory.entries().isEmpty)
    }

    @Test func firstSeenPersistsAcrossRefreshForSamePIDAndStartTime() {
        let clock = InventoryClock(Date(timeIntervalSince1970: 10))
        let provider = InventoryProcessProvider(pids: [21], startTimes: [21: 100])
        let collector = InventoryCollector([21: ProcessIdentity(pid: 21, executablePath: "/opt/homebrew/bin/codex")])
        let inventory = ServiceInventory(
            collector: collector,
            processProvider: provider,
            clock: { clock.now },
            currentPID: { 99999 },
            snapshotPath: nil
        )

        inventory.refresh()
        clock.now = Date(timeIntervalSince1970: 20)
        inventory.refresh()

        let entry = inventory.entry(pid: 21)
        #expect(entry?.firstSeen == Date(timeIntervalSince1970: 10))
        #expect(entry?.lastClassified == Date(timeIntervalSince1970: 20))
    }

    @Test func pidReuseResetsFirstSeenWhenStartTimeChanges() {
        let clock = InventoryClock(Date(timeIntervalSince1970: 10))
        let provider = InventoryProcessProvider(pids: [22], startTimes: [22: 100])
        let collector = InventoryCollector([22: ProcessIdentity(pid: 22, executablePath: "/opt/homebrew/bin/codex")])
        let inventory = ServiceInventory(collector: collector, processProvider: provider, clock: { clock.now }, currentPID: { 99999 }, snapshotPath: nil)

        inventory.refresh()
        provider.startTimes = [22: 200]
        clock.now = Date(timeIntervalSince1970: 30)
        inventory.refresh()

        #expect(inventory.entry(pid: 22)?.firstSeen == Date(timeIntervalSince1970: 30))
    }

    @Test func exitedProcessesAreRemovedFromCache() {
        let provider = InventoryProcessProvider(pids: [23], startTimes: [23: 100])
        let collector = InventoryCollector([23: ProcessIdentity(pid: 23, executablePath: "/opt/homebrew/bin/codex")])
        let inventory = ServiceInventory(collector: collector, processProvider: provider, currentPID: { 99999 }, snapshotPath: nil)

        inventory.refresh()
        provider.pids = []
        inventory.refresh()

        #expect(inventory.entry(pid: 23) == nil)
    }

    @Test func entriesCanFilterByCategory() {
        let inventory = makeInventory(identities: [
            ProcessIdentity(pid: 24, executablePath: "/opt/homebrew/bin/codex"),
            ProcessIdentity(pid: 25, executablePath: "/Users/test/.hermes/hermes"),
        ])

        inventory.refresh()

        #expect(inventory.entries(category: .foregroundCoding).map(\.pid) == [24])
        #expect(inventory.entries(category: .backgroundService).map(\.pid) == [25])
    }

    @Test func currentProcessIsExcluded() {
        let inventory = makeInventory(
            identities: [ProcessIdentity(pid: 26, executablePath: "/opt/homebrew/bin/codex")],
            currentPID: { 26 }
        )

        inventory.refresh()

        #expect(inventory.entries().isEmpty)
    }

    @Test func snapshotJSONIsWrittenAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-inventory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let inventory = makeInventory(
            identities: [ProcessIdentity(pid: 27, executablePath: "/opt/homebrew/bin/codex")],
            snapshotPath: url.path
        )

        inventory.refresh()

        let data = try Data(contentsOf: url)
        let entries = try JSONDecoder.inventoryDecoder.decode([InventoryEntry].self, from: data)
        #expect(entries.map(\.pid) == [27])
    }

    @Test func mcpChildWithMCPArgvAppearsAsMCPServer() {
        let parent = ProcessIdentity(pid: 28, executablePath: "/opt/homebrew/bin/codex")
        let child = ProcessIdentity(pid: 29, executablePath: "/usr/bin/python3", parentChain: [parent], arguments: ["python3", "-m", "my_mcp_server"])
        let inventory = makeInventory(identities: [parent, child])

        inventory.refresh()

        let entry = inventory.entry(pid: 29)
        #expect(entry?.category == .mcpServer)
        #expect(entry?.parentPid == 28)
        #expect(entry?.parentDisplayName == "Codex CLI")
        #expect(entry?.mcpTransport == .stdio)
    }

    @Test func mcpChildWithPackageFingerprintAppearsAsMCPServer() {
        let parent = ProcessIdentity(pid: 30, executablePath: "/opt/homebrew/bin/codex")
        let child = ProcessIdentity(
            pid: 31,
            executablePath: "/usr/local/bin/node",
            parentChain: [parent],
            arguments: ["node", "server.js"],
            packageDependencyNames: ["@modelcontextprotocol/sdk"]
        )
        let inventory = makeInventory(identities: [parent, child])

        inventory.refresh()

        #expect(inventory.entry(pid: 31)?.category == .mcpServer)
    }

    @Test func nonAgentLookingChildIsNotInventoriedWithoutAgentParent() {
        let child = ProcessIdentity(pid: 32, executablePath: "/usr/bin/python3", arguments: ["python3", "ordinary_server.py"])
        let inventory = makeInventory(identities: [child])

        inventory.refresh()

        #expect(inventory.entry(pid: 32) == nil)
    }

    @Test func mcpTransportDetectsTCPHints() {
        let parent = ProcessIdentity(pid: 33, executablePath: "/opt/homebrew/bin/codex")
        let child = ProcessIdentity(pid: 34, executablePath: "/usr/bin/python3", parentChain: [parent], arguments: ["mcp-server", "--transport", "tcp", "--port", "3000"])
        let inventory = makeInventory(identities: [parent, child])

        inventory.refresh()

        #expect(inventory.entry(pid: 34)?.mcpTransport == .tcp)
    }

    @Test func mcpTransportDetectsUnixSocketHints() {
        let parent = ProcessIdentity(pid: 35, executablePath: "/opt/homebrew/bin/codex")
        let child = ProcessIdentity(pid: 36, executablePath: "/usr/bin/python3", parentChain: [parent], arguments: ["mcp-server", "--socket", "/tmp/mcp.sock"])
        let inventory = makeInventory(identities: [parent, child])

        inventory.refresh()

        #expect(inventory.entry(pid: 36)?.mcpTransport == .unix)
    }

    @Test func inventoryJSONDoesNotContainEnvironmentVarNames() throws {
        let entry = InventoryEntry(
            pid: 37,
            executablePath: "/opt/homebrew/bin/codex",
            displayName: "Codex CLI",
            category: .foregroundCoding,
            verdict: .agent(reason: .knownList("Codex CLI"), confidence: .high),
            parentPid: nil,
            parentDisplayName: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastClassified: Date(timeIntervalSince1970: 0),
            mcpTransport: nil
        )

        let data = try JSONEncoder.inventoryEncoder.encode(entry)
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains("OPENAI_API_KEY"))
        #expect(!json.contains("ANTHROPIC_API_KEY"))
    }

    @Test func liveInventorySmokeTestIsGated() {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_INVENTORY_TESTS"] == "1" else {
            print("skipped: requires SANCTUARY_RUN_INVENTORY_TESTS=1")
            return
        }

        let inventory = ServiceInventory(snapshotPath: nil)
        inventory.refresh()
        let entries = inventory.entries()
        print("inventory live entries: \(entries.map { "\($0.pid):\($0.displayName):\($0.category.rawValue)" }.joined(separator: ", "))")
        #expect(!entries.contains { $0.pid == getpid() })
        #expect(entries.contains { entry in
            entry.displayName.localizedCaseInsensitiveContains("Codex")
                || entry.displayName.localizedCaseInsensitiveContains("Hermes")
        })
    }

    private func makeInventory(
        identities: [ProcessIdentity],
        classifier: AgentClassifier = AgentClassifier(),
        knownAgents: [KnownAgent] = AgentClassifier.knownAgents,
        launchdPlistIndex: LaunchdPlistIndex = LaunchdPlistIndex(entries: []),
        currentPID: @escaping @Sendable () -> pid_t = { 99999 },
        snapshotPath: String? = nil
    ) -> ServiceInventory {
        let pids = identities.map(\.pid)
        return ServiceInventory(
            classifier: classifier,
            collector: InventoryCollector(Dictionary(uniqueKeysWithValues: identities.map { ($0.pid, $0) })),
            processProvider: InventoryProcessProvider(
                pids: pids,
                startTimes: Dictionary(uniqueKeysWithValues: pids.map { ($0, TimeInterval($0)) })
            ),
            knownAgents: knownAgents,
            launchdPlistIndex: launchdPlistIndex,
            currentPID: currentPID,
            snapshotPath: snapshotPath
        )
    }

    private func hermesAgent() -> KnownAgent {
        KnownAgent(
            displayName: "Hermes Agent (Nous Research)",
            category: "background-service",
            executableNames: ["service"],
            pythonModuleMarkers: ["hermes_cli"],
            launchdPlistPatterns: ["ai.hermes.*"],
            installPaths: ["/tmp/service"],
            signedConfidence: .high,
            pathOnlyConfidence: .high
        )
    }
}

private final class InventoryCollector: ProcessIdentityCollecting, @unchecked Sendable {
    var identities: [pid_t: ProcessIdentity]

    init(_ identities: [pid_t: ProcessIdentity]) {
        self.identities = identities
    }

    func collect(pid: pid_t) -> ProcessIdentity? {
        identities[pid]
    }
}

private final class InventoryProcessProvider: ProcessInventoryProviding, @unchecked Sendable {
    var pids: [pid_t]
    var startTimes: [pid_t: TimeInterval]

    init(pids: [pid_t], startTimes: [pid_t: TimeInterval]) {
        self.pids = pids
        self.startTimes = startTimes
    }

    func listPIDs() throws -> [pid_t] {
        pids
    }

    func startTime(pid: pid_t) -> TimeInterval? {
        startTimes[pid]
    }

    func parentPID(pid: pid_t) -> pid_t? {
        nil
    }
}

private final class InventoryClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private extension JSONEncoder {
    static var inventoryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var inventoryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
