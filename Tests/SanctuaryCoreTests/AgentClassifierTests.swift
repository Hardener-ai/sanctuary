// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct AgentClassifierTests {
    private let claude = KnownAgent(
        id: "claude-code",
        displayName: "Claude Code",
        executableNames: ["claude", "claude-code"],
        bundleIdentifiers: ["com.anthropic.claude-code"],
        codeSigningIdentifiers: ["com.anthropic.claude-code"],
        teamIdentifiers: [AgentClassifier.anthropicTeamID]
    )

    private let cursor = KnownAgent(
        id: "cursor",
        displayName: "Cursor",
        executableNames: ["cursor", "cursor helper", "cursor helper (renderer)"],
        bundleIdentifiers: ["com.cursor.Cursor"],
        teamIdentifiers: [AgentClassifier.cursorTeamID]
    )

    private let codex = KnownAgent(
        id: "codex-cli",
        displayName: "Codex CLI",
        executableNames: ["codex"],
        codeSigningIdentifiers: ["com.openai.codex"]
    )

    private let goose = KnownAgent(
        id: "goose",
        displayName: "Goose",
        executableNames: ["goose"],
        teamIdentifiers: [AgentClassifier.blockTeamID]
    )

    private let hermes = KnownAgent(
        id: "hermes-agent",
        displayName: "Hermes Agent",
        executableNames: ["hermes", "hermes-agent"],
        teamIdentifiers: [AgentClassifier.nousTeamID],
        pythonModuleMarkers: ["hermes_agent", "hermes_cli"],
        launchdPlistPatterns: ["ai.hermes.*"],
        installPaths: ["/tmp/sanctuary-test-hermes", "~/.hermes"]
    )

    private let openClaw = KnownAgent(
        id: "openclaw-node",
        displayName: "OpenClaw",
        executableNames: ["openclaw"],
        nodePackageMarkers: ["openclaw", "@anthropic-ai/sdk", "@modelcontextprotocol/sdk"],
        launchdPlistPatterns: ["ai.openclaw.*"],
        installPaths: ["/tmp/sanctuary-test-openclaw", "/opt/homebrew/lib/node_modules/openclaw"]
    )

    private let aider = KnownAgent(
        id: "aider",
        displayName: "Aider",
        executableNames: ["aider"]
    )

    private var fixtureRegistry: [KnownAgent] {
        [
            claude,
            cursor,
            codex,
            goose,
            hermes,
            aider,
            KnownAgent(id: "clawdbot", displayName: "ClawdBot", executableNames: ["clawdbot"]),
            openClaw,
            KnownAgent(id: "python-anthropic-sdk", displayName: "Python Anthropic SDK", executableNames: [], pythonModuleMarkers: ["anthropic"]),
            KnownAgent(id: "node-mcp-sdk", displayName: "Node MCP SDK", executableNames: [], nodePackageMarkers: ["@modelcontextprotocol/sdk"])
        ]
    }

    private func classifier(
        trustedExecutablePaths: Set<String> = [],
        userAgentExecutablePaths: Set<String> = [],
        userTaggedAgents: (any UserTaggedAgentChecking)? = nil,
        trustedPaths: (any TrustedPathChecking)? = nil,
        launchdPlistIndex: LaunchdPlistIndex = LaunchdPlistIndex()
    ) -> AgentClassifier {
        AgentClassifier(
            trustedExecutablePaths: trustedExecutablePaths,
            userAgentExecutablePaths: userAgentExecutablePaths,
            userTaggedAgents: userTaggedAgents,
            trustedPaths: trustedPaths,
            knownAgents: fixtureRegistry,
            launchdPlistIndex: launchdPlistIndex
        )
    }

    @Test func sourceRegistryParsesAndMatchesBundledRegistryCount() throws {
        let yamlURL = repoRoot().appendingPathComponent("agents.yaml")
        let yaml = try String(contentsOf: yamlURL, encoding: .utf8)
        let parsed = try AgentRegistryYAMLParser.parseKnownAgents(from: yaml)

        #expect(parsed.count == 44)
        #expect(parsed.count == AgentClassifier.knownAgents.count)
    }

    @Test func trustedPathWinsEvenWhenNameMatchesKnownAgent() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/trusted/claude")
        let classifier = classifier(trustedExecutablePaths: ["/opt/trusted/claude"])

        #expect(classifier.classify(identity) == .notAgent)
    }

    @Test func userTaggedPathIsHighConfidenceAgent() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/custom/openclaw")
        let classifier = classifier(userAgentExecutablePaths: ["/opt/custom/openclaw"])

        #expect(classifier.classify(identity) == .agent(reason: .userTagged, confidence: .high))
    }

    @Test func trustListWinsOverUserAgentList() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/custom/openclaw")
        let classifier = classifier(
            trustedExecutablePaths: ["/opt/custom/openclaw"],
            userAgentExecutablePaths: ["/opt/custom/openclaw"]
        )

        #expect(classifier.classify(identity) == .notAgent)
    }

    @Test func userTaggedRegistryClassifiesPathAsHighConfidenceAgent() throws {
        let fixture = try makeExecutableFixture(name: "plain-tool")
        let registry = try UserTaggedAgentRegistry(path: fixture.db.path)
        try registry.add(fixture.binary.path)
        let identity = ProcessIdentity(pid: 42, executablePath: fixture.binary.path)

        #expect(classifier(userTaggedAgents: registry).classify(identity) == .agent(reason: .userTagged, confidence: .high))
    }

    @Test func trustedPathRegistryWinsOverEverything() throws {
        let fixture = try makeExecutableFixture(name: "plain-tool")
        let trusted = try TrustedPathRegistry(path: fixture.db.path)
        try trusted.add(fixture.binary.path)
        let identity = ProcessIdentity(pid: 42, executablePath: fixture.binary.path)

        #expect(classifier(userAgentExecutablePaths: [fixture.binary.path], trustedPaths: trusted).classify(identity) == .notAgent)
    }

    @Test func trustedPathRegistryWinsEvenWhenNameMatchesKnownAgent() throws {
        let fixture = try makeExecutableFixture(name: "claude")
        let trusted = try TrustedPathRegistry(path: fixture.db.path)
        try trusted.add(fixture.binary.path)
        let identity = ProcessIdentity(pid: 42, executablePath: fixture.binary.path)

        #expect(classifier(trustedPaths: trusted).classify(identity) == .notAgent)
    }

    @Test func removingUserAgentTagRevertsToDefaultClassification() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/custom/not-an-agent")

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func signedClaudeCodeAtCanonicalPathIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/claude",
            teamIdentifier: AgentClassifier.anthropicTeamID
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Claude Code"), confidence: .high))
    }

    @Test func signedCursorIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
            bundleIdentifier: "com.cursor.Cursor",
            teamIdentifier: AgentClassifier.cursorTeamID
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Cursor"), confidence: .high))
    }

    @Test func signedCodexCLIIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/codex",
            codeSigningIdentifier: "com.openai.codex"
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Codex CLI"), confidence: .high))
    }

    @Test func signedGooseIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/goose",
            teamIdentifier: AgentClassifier.blockTeamID
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Goose"), confidence: .high))
    }

    @Test func signedHermesIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/hermes",
            teamIdentifier: AgentClassifier.nousTeamID
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Hermes Agent"), confidence: .high))
    }

    @Test func vscodeClineExtensionMarkerIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            arguments: ["--extensionDevelopmentPath=/Users/tg/.vscode/extensions/saoudrizwan.claude-dev"]
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Cline"), confidence: .high))
    }

    @Test func vscodeContinueExtensionMarkerIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
            arguments: ["--extensionDevelopmentPath=/Users/tg/.vscode/extensions/continue.continue"]
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Continue"), confidence: .high))
    }

    @Test func unsignedAiderNameMatchIsMediumConfidenceAgent() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/homebrew/bin/aider")

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Aider"), confidence: .medium))
    }

    @Test func userTaggedClawdBotIsHighConfidenceAgent() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/custom/clawdbot")
        let classifier = classifier(userAgentExecutablePaths: ["/opt/custom/clawdbot"])

        #expect(classifier.classify(identity) == .agent(reason: .userTagged, confidence: .high))
    }

    @Test func userTaggedOpenClawIsHighConfidenceAgent() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/custom/openclaw")
        let classifier = classifier(userAgentExecutablePaths: ["/opt/custom/openclaw"])

        #expect(classifier.classify(identity) == .agent(reason: .userTagged, confidence: .high))
    }

    @Test func unknownSignerWithKnownNameFallsBackToMediumConfidence() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/tmp/claude",
            teamIdentifier: "UNKNOWNTEAM"
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Claude Code"), confidence: .medium))
    }

    @Test func unsignedClaudeNameMatchIsMediumConfidenceAgent() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/tmp/claude")

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Claude Code"), confidence: .medium))
    }

    @Test func launchAgentPlistWithKnownBinaryIsHighConfidenceServiceLaunch() throws {
        let fixtureDirectory = try makeLaunchdFixture(program: "/opt/homebrew/bin/claude", label: "ai.hardener.sanctuary.test.claude")
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/sanctuary-test-wrapper",
            parentChain: [launchd],
            launchdLabel: "ai.hardener.sanctuary.test.claude"
        )
        let index = LaunchdPlistIndex(plistDirectories: [fixtureDirectory])

        #expect(classifier(launchdPlistIndex: index).classify(identity) == .agent(reason: .serviceLaunch, confidence: .high))
    }

    @Test func launchDaemonPlistWithKnownBinaryIsHighConfidenceServiceLaunch() throws {
        let fixtureDirectory = try makeLaunchdFixture(program: "/opt/homebrew/bin/hermes", label: "ai.hardener.sanctuary.test.hermes")
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/sanctuary-test-wrapper",
            parentChain: [launchd],
            launchdLabel: "ai.hardener.sanctuary.test.hermes"
        )
        let index = LaunchdPlistIndex(plistDirectories: [fixtureDirectory])

        #expect(classifier(launchdPlistIndex: index).classify(identity) == .agent(reason: .serviceLaunch, confidence: .high))
    }

    @Test func launchdParentWithoutPlistFallsThroughToOtherRules() {
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/custom-daemon", parentChain: [launchd])

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func pythonRuntimeFingerprintFromRegistryIsMediumConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/bin/python3",
            loadedModulePaths: ["/venv/lib/python3.12/site-packages/anthropic/__init__.py"]
        )

        #expect(AgentClassifier().classify(identity) == .agent(reason: .pythonRuntime, confidence: .medium))
    }

    @Test func nodeMCPRuntimeFingerprintFromRegistryIsMediumConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/node",
            packageDependencyNames: ["@modelcontextprotocol/sdk"]
        )

        #expect(AgentClassifier().classify(identity) == .agent(reason: .nodeRuntime, confidence: .medium))
    }

    @Test func pythonArgvHermesModuleIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/bin/python3",
            arguments: ["/usr/bin/python3", "-m", "hermes_cli.main"]
        )

        #expect(classifier().classify(identity) == .agent(reason: .pythonRuntime, confidence: .high))
    }

    @Test func pythonArgvAnthropicModuleIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/bin/python3.11",
            arguments: ["/usr/bin/python3.11", "-m", "anthropic"]
        )

        #expect(classifier().classify(identity) == .agent(reason: .pythonRuntime, confidence: .high))
    }

    @Test func pythonArgvUnrelatedModuleIsNotAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/bin/python3",
            arguments: ["/usr/bin/python3", "-m", "unrelated.thing"]
        )

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func pythonArgvVenvConsoleScriptIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/bin/python3",
            arguments: ["/tmp/sanctuary-test-hermes/venv/bin/hermes", "dashboard"]
        )

        #expect(classifier().classify(identity) == .agent(reason: .pythonRuntime, confidence: .high))
    }

    @Test func nodeArgvOpenClawNodeModulesPathIsHighConfidenceAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["/opt/homebrew/bin/node", "/tmp/sanctuary-test-openclaw/node_modules/openclaw/dist/index.js"]
        )

        #expect(classifier().classify(identity) == .agent(reason: .nodeRuntime, confidence: .high))
    }

    @Test func nodeArgvPackageJSONDependencyIsMediumConfidenceAgent() throws {
        let directory = try makeTemporaryDirectory(prefix: "sanctuary-node-agent-")
        let packageJSON = """
        {"name":"ordinary-tool","dependencies":{"@anthropic-ai/sdk":"latest"}}
        """
        try packageJSON.write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("bin/server.js")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "console.log('ok')".write(to: script, atomically: true, encoding: .utf8)
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["/opt/homebrew/bin/node", script.path]
        )

        #expect(classifier().classify(identity) == .agent(reason: .nodeRuntime, confidence: .medium))
    }

    @Test func nodeArgvPackageJSONWithoutAgentDependencyIsNotAgent() throws {
        let directory = try makeTemporaryDirectory(prefix: "sanctuary-node-ordinary-")
        let packageJSON = """
        {"name":"ordinary-tool","dependencies":{"express":"latest"}}
        """
        try packageJSON.write(to: directory.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("server.js")
        try "console.log('ok')".write(to: script, atomically: true, encoding: .utf8)
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/node",
            arguments: ["/opt/homebrew/bin/node", script.path]
        )

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func installPathPrefixUnderHermesDirectoryIsMediumConfidenceKnownAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/tmp/sanctuary-test-hermes/hermes-agent/venv/bin/python3",
            cwd: "/tmp/sanctuary-test-hermes/hermes-agent"
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Hermes Agent"), confidence: .medium))
    }

    @Test func venvPackageDirectoryHermesAgentIsMediumConfidenceAgent() throws {
        let root = try makeTemporaryDirectory(prefix: "sanctuary-venv-")
        let venv = root.appendingPathComponent("venv")
        let bin = venv.appendingPathComponent("bin")
        let sitePackages = venv.appendingPathComponent("lib/python3.11/site-packages/hermes_agent")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sitePackages, withIntermediateDirectories: true)
        try Data().write(to: bin.appendingPathComponent("python3"))
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: bin.appendingPathComponent("python3").path,
            arguments: [bin.appendingPathComponent("python3").path]
        )

        #expect(classifier().classify(identity) == .agent(reason: .pythonRuntime, confidence: .medium))
    }

    @Test func launchdPlistIndexMatchesHermesLabelGlobAndModuleSpecifier() throws {
        let fixtureDirectory = try makeLaunchdFixture(
            programArguments: ["/tmp/sanctuary-python/bin/python3", "-m", "hermes_cli.main"],
            label: "ai.hermes.gateway"
        )
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/tmp/sanctuary-python/bin/python3",
            parentChain: [launchd],
            launchdLabel: "ai.hermes.gateway"
        )
        let index = LaunchdPlistIndex(plistDirectories: [fixtureDirectory])

        #expect(index.agentEntry(for: identity, registry: fixtureRegistry)?.id == "hermes-agent")
    }

    @Test func launchdPlistIndexIgnoresUnrelatedPlist() throws {
        let fixtureDirectory = try makeLaunchdFixture(program: "/usr/local/bin/ordinary-service", label: "app.example.ordinary")
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/ordinary-service",
            parentChain: [launchd],
            launchdLabel: "app.example.ordinary"
        )
        let index = LaunchdPlistIndex(plistDirectories: [fixtureDirectory])

        #expect(index.agentEntry(for: identity, registry: fixtureRegistry) == nil)
    }

    @Test func classifierLaunchdIntegrationMatchesHermesServiceLaunch() throws {
        let fixtureDirectory = try makeLaunchdFixture(
            programArguments: ["/tmp/sanctuary-python/bin/python3", "-m", "hermes_cli.main"],
            label: "ai.hermes.gateway"
        )
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/tmp/sanctuary-python/bin/python3",
            parentChain: [launchd],
            launchdLabel: "ai.hermes.gateway"
        )
        let index = LaunchdPlistIndex(plistDirectories: [fixtureDirectory])

        #expect(classifier(launchdPlistIndex: index).classify(identity) == .agent(reason: .serviceLaunch, confidence: .high))
    }

    @Test func renamedClaudeWithValidSignatureStillMatchesKnownList() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/foo",
            codeSigningIdentifier: "com.anthropic.claude-code"
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Claude Code"), confidence: .high))
    }

    @Test func renamedUnsignedClaudeIsNotAnAgentUnlessUserTagged() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/foo")

        #expect(classifier().classify(identity) == .notAgent)
        #expect(
            classifier(userAgentExecutablePaths: ["/usr/local/bin/foo"]).classify(identity) ==
                .agent(reason: .userTagged, confidence: .high)
        )
    }

    @Test func symlinkResolvedToClaudePathClassifiesCorrectly() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/claude",
            teamIdentifier: AgentClassifier.anthropicTeamID
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Claude Code"), confidence: .high))
    }

    @Test func hardlinkResolvedToClaudePathClassifiesCorrectly() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/claude",
            teamIdentifier: AgentClassifier.anthropicTeamID
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Claude Code"), confidence: .high))
    }

    @Test func strippedSignatureFallsThroughToNameMatchOnly() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/opt/homebrew/bin/claude")

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Claude Code"), confidence: .medium))
    }

    @Test func agentExecsCatChildInheritsParentChainVerdict() {
        let parent = signedClaudeProcess(pid: 100)
        let child = ProcessIdentity(pid: 101, executablePath: "/bin/cat", parentChain: [parent])

        #expect(classifier().classify(child) == .agent(reason: .parentChain("Claude Code"), confidence: .high))
    }

    @Test func nohupSetsidCatStillInheritsWhenParentChainAvailable() {
        let parent = signedClaudeProcess(pid: 100)
        let child = ProcessIdentity(pid: 101, executablePath: "/bin/cat", parentChain: [parent])

        #expect(classifier().classify(child) == .agent(reason: .parentChain("Claude Code"), confidence: .high))
    }

    @Test func launchctlBootstrapOutsideTreeWithAPIKeyAndShellSpawnIsSuspicious() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/bootstrap-agent",
            environmentVars: ["OPENAI_API_KEY"],
            childProcessObservations: [ChildProcessObservation(executablePath: "/bin/zsh", secondsAgo: 30)]
        )

        #expect(classifier().classify(identity) == .suspicious(reason: .envVarsPlusShellSpawn))
    }

    @Test func launchctlBootstrapOutsideTreeWithoutSignalsIsNotAgent() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/bootstrap-agent")

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func pythonExecveCatDroppingEnvStillCaughtByParentChain() {
        let parent = signedClaudeProcess(pid: 100)
        let python = ProcessIdentity(pid: 101, executablePath: "/usr/bin/python3", parentChain: [parent])
        let cat = ProcessIdentity(pid: 102, executablePath: "/bin/cat", parentChain: [python, parent])

        #expect(classifier().classify(cat) == .agent(reason: .parentChain("Claude Code"), confidence: .high))
    }

    @Test func injectedNotAgentProcessStaysNotAgentWhenIdentityAndParentAreOrdinary() {
        let identity = ProcessIdentity(pid: 42, executablePath: "/Applications/Notes.app/Contents/MacOS/Notes")

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func eightDeepDescendantStillClassifiesViaParentChain() {
        let parent = signedClaudeProcess(pid: 100)
        var chain = [parent]
        for offset in 1...7 {
            chain.insert(ProcessIdentity(pid: Int32(100 + offset), executablePath: "/bin/zsh", parentChain: chain), at: 0)
        }
        let child = ProcessIdentity(pid: 200, executablePath: "/bin/cat", parentChain: chain)

        #expect(classifier().classify(child) == .agent(reason: .parentChain("Claude Code"), confidence: .high))
    }

    @Test func launchdOnlyParentChainIsNotAgent() {
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(pid: 42, executablePath: "/bin/zsh", parentChain: [launchd])

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func orphanedProcessReparentedToLaunchdWithoutAuditOriginIsNotAgent() {
        let launchd = ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")
        let identity = ProcessIdentity(pid: 42, executablePath: "/bin/cat", parentChain: [launchd])

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func terminalShellWithAPIKeyIsNotAgentWithoutShellSpawnPattern() {
        let terminal = ProcessIdentity(pid: 100, executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal")
        let shell = ProcessIdentity(
            pid: 101,
            executablePath: "/bin/zsh",
            parentChain: [terminal],
            environmentVars: ["OPENAI_API_KEY"]
        )

        #expect(classifier().classify(shell) == .notAgent)
    }

    @Test func zshLaunchedFromClaudeCodeIsAgent() {
        let shell = ProcessIdentity(pid: 101, executablePath: "/bin/zsh", parentChain: [signedClaudeProcess(pid: 100)])

        #expect(classifier().classify(shell) == .agent(reason: .parentChain("Claude Code"), confidence: .high))
    }

    @Test func cursorHelperRendererProcessMatchesBundleIdentifier() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)",
            bundleIdentifier: "com.cursor.Cursor",
            teamIdentifier: AgentClassifier.cursorTeamID
        )

        #expect(classifier().classify(identity) == .agent(reason: .knownList("Cursor"), confidence: .high))
    }

    @Test func pythonWithoutAIModulesIsNotAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/bin/python3",
            loadedModulePaths: ["/venv/lib/python3.12/site-packages/requests/__init__.py"]
        )

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func nodeWithoutAIDependenciesIsNotAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/opt/homebrew/bin/node",
            packageDependencyNames: ["express"]
        )

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func apiKeyAndRecentShellSpawnIsSuspicious() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/custom-tool",
            environmentVars: ["ANTHROPIC_API_KEY"],
            childProcessObservations: [ChildProcessObservation(executablePath: "/bin/zsh", secondsAgo: 30)]
        )

        #expect(classifier().classify(identity) == .suspicious(reason: .envVarsPlusShellSpawn))
    }

    @Test func apiKeyAndOldShellSpawnIsNotAgent() {
        let identity = ProcessIdentity(
            pid: 42,
            executablePath: "/usr/local/bin/custom-tool",
            environmentVars: ["OPENAI_API_KEY"],
            childProcessObservations: [ChildProcessObservation(executablePath: "/bin/zsh", secondsAgo: 90)]
        )

        #expect(classifier().classify(identity) == .notAgent)
    }

    @Test func falsePositiveResistanceForCommonSystemAndBuildTools() {
        let ordinaryProcesses = [
            ProcessIdentity(pid: 10, executablePath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores"),
            ProcessIdentity(pid: 11, executablePath: "/System/Library/CoreServices/backupd"),
            ProcessIdentity(pid: 12, executablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"),
            ProcessIdentity(pid: 13, executablePath: "/opt/homebrew/bin/brew")
        ]

        for identity in ordinaryProcesses {
            #expect(classifier().classify(identity) == .notAgent)
        }
    }

    @Test func mcpStdioChildInheritsHighConfidenceAgent() {
        let parent = signedClaudeProcess(pid: 100)
        let child = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/mcp-server-filesystem", arguments: ["mcp-server-filesystem"])

        #expect(classifier().classifyMCP(child: child, parent: parent) == .agent(reason: .mcpServer(parent: "Claude Code"), confidence: .high))
    }

    @Test func mcpStdioChildInheritsMediumConfidenceRuntime() {
        let parent = ProcessIdentity(
            pid: 100,
            executablePath: "/usr/bin/python3",
            loadedModulePaths: ["/site-packages/anthropic/__init__.py"]
        )
        let child = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/mcp-server", arguments: ["mcp-server"])

        #expect(classifier().classifyMCP(child: child, parent: parent) == .agent(reason: .mcpServer(parent: "Python agent runtime"), confidence: .medium))
    }

    @Test func suspiciousParentDoesNotPromoteMCPChildToAgent() {
        let parent = ProcessIdentity(
            pid: 100,
            executablePath: "/usr/local/bin/custom-tool",
            environmentVars: ["ANTHROPIC_API_KEY"],
            childProcessObservations: [ChildProcessObservation(executablePath: "/bin/zsh", secondsAgo: 30)]
        )
        let child = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/mcp-server", arguments: ["mcp-server"])

        #expect(classifier().classifyMCP(child: child, parent: parent) == .suspicious(reason: .envVarsPlusShellSpawn))
    }

    @Test func nonAgentParentWithMCPLookingChildIsNotAgentWithoutOtherSignals() {
        let parent = ProcessIdentity(pid: 100, executablePath: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let child = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/mcp-helper", arguments: ["mcp-helper"])

        #expect(classifier().classifyMCP(child: child, parent: parent) == .notAgent)
    }

    @Test func socketMCPServerInheritsFromConnectedAgent() {
        let parent = signedClaudeProcess(pid: 100)
        let server = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/postgres-mcp", arguments: ["postgres-mcp"])

        #expect(classifier().classifyMCP(child: server, parent: parent) == .agent(reason: .mcpServer(parent: "Claude Code"), confidence: .high))
    }

    @Test func socketMCPServerWithOnlyNonAgentClientStaysNotAgent() {
        let parent = ProcessIdentity(pid: 100, executablePath: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let server = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/json-rpc-service")

        #expect(classifier().classifyMCP(child: server, parent: parent) == .notAgent)
    }

    @Test func multipleMCPClientsUseStrongestVerdictWhenEvaluatedByCaller() {
        let server = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/postgres-mcp", arguments: ["postgres-mcp"])
        let high = classifier().classifyMCP(child: server, parent: signedClaudeProcess(pid: 100))
        let mediumParent = ProcessIdentity(
            pid: 102,
            executablePath: "/usr/bin/python3",
            loadedModulePaths: ["/site-packages/anthropic/__init__.py"]
        )
        let medium = classifier().classifyMCP(child: server, parent: mediumParent)

        #expect(high == .agent(reason: .mcpServer(parent: "Claude Code"), confidence: .high))
        #expect(medium == .agent(reason: .mcpServer(parent: "Python agent runtime"), confidence: .medium))
    }

    @Test func mcpAssociationExpiresWhenCallerStopsPassingAgentParent() {
        let terminal = ProcessIdentity(pid: 100, executablePath: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let server = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/postgres-mcp", arguments: ["postgres-mcp"])

        #expect(classifier().classifyMCP(child: server, parent: terminal) == .notAgent)
    }

    @Test func nodeMCPSDKRuntimeFingerprintMakesChildCandidateWhenParentIsAgent() {
        let parent = signedClaudeProcess(pid: 100)
        let child = ProcessIdentity(
            pid: 101,
            executablePath: "/opt/homebrew/bin/node",
            packageDependencyNames: ["@modelcontextprotocol/sdk"]
        )

        #expect(classifier().classifyMCP(child: child, parent: parent) == .agent(reason: .mcpServer(parent: "Claude Code"), confidence: .high))
    }

    @Test func protocolOnlyJSONRPCServiceDoesNotFalsePositive() {
        let parent = ProcessIdentity(pid: 100, executablePath: "/Applications/Terminal.app/Contents/MacOS/Terminal")
        let service = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/json-rpc-service", arguments: ["--jsonrpc"])

        #expect(classifier().classifyMCP(child: service, parent: parent) == .notAgent)
    }

    @Test func mcpAuditIdentityCanUseLoadedByParentName() {
        let parent = signedClaudeProcess(pid: 100)
        let child = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/filesystem-mcp", arguments: ["filesystem-mcp"])

        #expect(classifier().classifyMCP(child: child, parent: parent) == .agent(reason: .mcpServer(parent: "Claude Code"), confidence: .high))
    }

    @Test func mcpInventoryGroupingCanUseExplicitMCPVerdict() {
        let parent = signedClaudeProcess(pid: 100)
        let child = ProcessIdentity(pid: 101, executablePath: "/usr/local/bin/research-mcp", arguments: ["research-mcp"])

        if case let .agent(reason, confidence) = classifier().classifyMCP(child: child, parent: parent) {
            #expect(reason == .mcpServer(parent: "Claude Code"))
            #expect(confidence == .high)
        } else {
            Issue.record("Expected MCP child to inherit agent verdict")
        }
    }

    private func signedClaudeProcess(pid: Int32) -> ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            executablePath: "/usr/local/bin/claude",
            teamIdentifier: AgentClassifier.anthropicTeamID
        )
    }

    private func makeLaunchdFixture(program: String, label: String) throws -> URL {
        try makeLaunchdFixture(programArguments: [program, "--serve"], label: label)
    }

    private func makeLaunchdFixture(programArguments: [String], label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanctuary-launchd-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("\(label).plist"))
        return directory
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutableFixture(name: String) throws -> (root: URL, db: URL, binary: URL) {
        let root = try makeTemporaryDirectory(prefix: "sanctuary-policy-classifier-")
        let binary = root.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (root, root.appendingPathComponent("policy.sqlite"), binary)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
