// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct ProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let bundleIdentifier: String?
    public let codeSigningIdentifier: String?
    public let teamIdentifier: String?
    public let parentChain: [ProcessIdentity]
    public let environmentVars: Set<String>
    public let cwd: String?
    public let arguments: [String]
    public let loadedModulePaths: [String]
    public let packageDependencyNames: Set<String>
    public let childProcessObservations: [ChildProcessObservation]
    public let launchdLabel: String?

    public init(
        pid: Int32,
        executablePath: String,
        bundleIdentifier: String? = nil,
        codeSigningIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        parentChain: [ProcessIdentity] = [],
        environmentVars: Set<String> = [],
        environmentKeys: Set<String> = [],
        cwd: String? = nil,
        arguments: [String] = [],
        loadedModulePaths: [String] = [],
        packageDependencyNames: Set<String> = [],
        childProcessObservations: [ChildProcessObservation] = [],
        launchdLabel: String? = nil,
        parentExecutablePaths: [String] = []
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.codeSigningIdentifier = codeSigningIdentifier
        self.teamIdentifier = teamIdentifier
        self.parentChain = parentChain + parentExecutablePaths.enumerated().map { offset, path in
            ProcessIdentity(pid: Int32(-1 - offset), executablePath: path)
        }
        self.environmentVars = environmentVars.union(environmentKeys)
        self.cwd = cwd
        self.arguments = arguments
        self.loadedModulePaths = loadedModulePaths
        self.packageDependencyNames = packageDependencyNames
        self.childProcessObservations = childProcessObservations
        self.launchdLabel = launchdLabel
    }
}

public struct ChildProcessObservation: Equatable, Sendable {
    public let executablePath: String
    public let secondsAgo: TimeInterval

    public init(executablePath: String, secondsAgo: TimeInterval) {
        self.executablePath = executablePath
        self.secondsAgo = secondsAgo
    }
}

public enum AgentVerdict: Equatable, Sendable {
    case agent(reason: AgentReason, confidence: Confidence)
    case suspicious(reason: SuspicionReason)
    case notAgent
}

public enum AgentReason: Equatable, Sendable {
    case userTagged
    case knownList(String)
    case parentChain(String)
    case pythonRuntime
    case nodeRuntime
    case serviceLaunch
    case mcpServer(parent: String)
}

public enum SuspicionReason: Equatable, Sendable {
    case envVarsPlusShellSpawn
}

public enum Confidence: Equatable, Sendable {
    case high
    case medium
    case low
}

public struct KnownAgent: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let category: String
    public let executableNames: Set<String>
    public let bundleIdentifiers: Set<String>
    public let codeSigningIdentifiers: Set<String>
    public let teamIdentifiers: Set<String>
    public let pythonModuleMarkers: Set<String>
    public let nodePackageMarkers: Set<String>
    public let launchdPlistPatterns: Set<String>
    public let installPaths: Set<String>
    public let signedConfidence: Confidence
    public let pathOnlyConfidence: Confidence

    public init(
        id: String = "",
        displayName: String,
        category: String = "",
        executableNames: Set<String>,
        bundleIdentifiers: Set<String> = [],
        codeSigningIdentifiers: Set<String> = [],
        teamIdentifiers: Set<String> = [],
        pythonModuleMarkers: Set<String> = [],
        nodePackageMarkers: Set<String> = [],
        launchdPlistPatterns: Set<String> = [],
        installPaths: Set<String> = [],
        signedConfidence: Confidence = .high,
        pathOnlyConfidence: Confidence = .medium
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.executableNames = Set(executableNames.map { $0.lowercased() })
        self.bundleIdentifiers = bundleIdentifiers
        self.codeSigningIdentifiers = codeSigningIdentifiers
        self.teamIdentifiers = teamIdentifiers
        self.pythonModuleMarkers = pythonModuleMarkers
        self.nodePackageMarkers = nodePackageMarkers
        self.launchdPlistPatterns = launchdPlistPatterns
        self.installPaths = installPaths
        self.signedConfidence = signedConfidence
        self.pathOnlyConfidence = pathOnlyConfidence
    }
}

private extension ProcessIdentity {
    var pythonRuntimeMarkers: Set<String> {
        Set((loadedModulePaths + arguments).map { $0.lowercased() })
    }

    var hasLaunchdParent: Bool {
        parentChain.contains { $0.pid == 1 }
    }
}

public struct AgentClassifier: Sendable {
    public static let anthropicTeamID = "ANTHROPIC"
    public static let cursorTeamID = "CURSORAI"
    public static let openAITeamID = "OPENAI"
    public static let blockTeamID = "BLOCK"
    public static let nousTeamID = "NOUS"

    public static let knownAgents: [KnownAgent] = GeneratedAgentRegistry.knownAgents
    public static let registrySchemaVersion = 1
    public static let registryUpdatedDate = "2026-05-06"

    public static let knownAgentNames: Set<String> = Set(knownAgents.flatMap(\.executableNames))

    private static let agentApiKeyEnvironment: Set<String> = [
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "OPENROUTER_API_KEY",
        "GEMINI_API_KEY",
        "GROQ_API_KEY",
        "MISTRAL_API_KEY"
    ]

    private static let pythonRuntimeMarkers = Set(knownAgents.flatMap(\.pythonModuleMarkers))

    private static let nodeRuntimeMarkers: Set<String> = Set(knownAgents.flatMap(\.nodePackageMarkers))

    public static let liveLaunchdPlistIndex = LaunchdPlistIndex.live()

    private let trustedExecutablePaths: Set<String>
    private let userAgentExecutablePaths: Set<String>
    private let userTaggedAgents: (any UserTaggedAgentChecking)?
    private let trustedPaths: (any TrustedPathChecking)?
    private let knownAgents: [KnownAgent]
    private let launchdPlistIndex: LaunchdPlistIndex
    private let processIdentityCollector: any ProcessIdentityCollecting

    public init(
        trustedExecutablePaths: Set<String> = [],
        userAgentExecutablePaths: Set<String> = [],
        userTaggedAgents: (any UserTaggedAgentChecking)? = nil,
        trustedPaths: (any TrustedPathChecking)? = nil,
        knownAgents: [KnownAgent] = Self.knownAgents,
        launchdPlistIndex: LaunchdPlistIndex = Self.liveLaunchdPlistIndex,
        processIdentityCollector: any ProcessIdentityCollecting = ProcessIdentityCollector()
    ) {
        self.trustedExecutablePaths = Set(trustedExecutablePaths.map { (try? PolicyExecutablePath.canonicalize($0)) ?? $0 })
        self.userAgentExecutablePaths = Set(userAgentExecutablePaths.map { (try? PolicyExecutablePath.canonicalize($0)) ?? $0 })
        self.userTaggedAgents = userTaggedAgents
        self.trustedPaths = trustedPaths
        self.knownAgents = knownAgents
        self.launchdPlistIndex = launchdPlistIndex
        self.processIdentityCollector = processIdentityCollector
    }

    public static func live(processIdentityCollector: any ProcessIdentityCollecting = ProcessIdentityCollector()) -> AgentClassifier {
        AgentClassifier(
            userTaggedAgents: try? UserTaggedAgentRegistry(),
            trustedPaths: try? TrustedPathRegistry(),
            processIdentityCollector: processIdentityCollector
        )
    }

    public func classify(_ identity: ProcessIdentity) -> AgentVerdict {
        classify(identity, visitedPIDs: [])
    }

    public func classify(pid: pid_t) -> AgentVerdict {
        guard let identity = processIdentityCollector.collect(pid: pid) else {
            return .notAgent
        }
        return classify(identity)
    }

    private func classify(_ identity: ProcessIdentity, visitedPIDs: Set<Int32>) -> AgentVerdict {
        let executablePath = (try? PolicyExecutablePath.canonicalize(identity.executablePath)) ?? identity.executablePath

        if trustedExecutablePaths.contains(executablePath) || trustedPaths?.contains(executablePath) == true {
            return .notAgent
        }

        if userAgentExecutablePaths.contains(executablePath) || userTaggedAgents?.contains(executablePath) == true {
            return .agent(reason: .userTagged, confidence: .high)
        }

        if let knownMatch = matchKnownAgent(identity) {
            return knownMatch
        }

        if let extensionMatch = matchVSCodeAgentExtension(identity) {
            return extensionMatch
        }

        for parent in identity.parentChain where parent.pid != 1 && !visitedPIDs.contains(parent.pid) {
            let parentVerdict = classify(parent, visitedPIDs: visitedPIDs.union([identity.pid]))
            if case let .agent(reason, confidence) = parentVerdict {
                return .agent(
                    reason: .parentChain(parentChainReasonName(parent, fallback: reason)),
                    confidence: confidence
                )
            }
        }

        if let serviceAgent = matchLaunchdService(identity) {
            return serviceAgent
        }

        if let pythonArgv = classifyByPythonArgv(identity) {
            return pythonArgv
        }

        if let nodeArgv = classifyByNodeArgv(identity) {
            return nodeArgv
        }

        if isPythonRuntime(identity), containsAnyMarker(in: identity.loadedModulePaths + identity.arguments, markers: Array(pythonRuntimeMarkers)) {
            return .agent(reason: .pythonRuntime, confidence: .medium)
        }

        if isNodeRuntime(identity), !identity.packageDependencyNames.isDisjoint(with: nodeRuntimeMarkers) {
            return .agent(reason: .nodeRuntime, confidence: .medium)
        }

        if let installPath = classifyByInstallPathPrefix(identity) {
            return installPath
        }

        if let venvPackages = classifyByVenvPackages(identity) {
            return venvPackages
        }

        if hasAgentAPIKey(identity), spawnedRecentShell(identity) {
            return .suspicious(reason: .envVarsPlusShellSpawn)
        }

        return .notAgent
    }

    public func classifyMCP(child: ProcessIdentity, parent: ProcessIdentity) -> AgentVerdict {
        let parentVerdict = classify(parent)
        let childIsMCPCandidate = containsAnyMarker(in: [child.executablePath] + child.arguments, markers: ["mcp"]) ||
            (isAgentVerdict(parentVerdict) && hasMCPRuntimeFingerprint(child))

        guard childIsMCPCandidate else {
            return .notAgent
        }

        switch parentVerdict {
        case let .agent(reason, confidence):
            return .agent(reason: .mcpServer(parent: parentChainReasonName(parent, fallback: reason)), confidence: confidence)
        case let .suspicious(reason):
            return .suspicious(reason: reason)
        case .notAgent:
            return classify(child)
        }
    }

    private func matchKnownAgent(_ identity: ProcessIdentity) -> AgentVerdict? {
        let executableName = executableName(identity.executablePath)

        for agent in knownAgents {
            let signedMatch = matchesSignedIdentity(identity, agent: agent)
            let nameMatch = agent.executableNames.contains(executableName)
            let bundleMatch = identity.bundleIdentifier.map(agent.bundleIdentifiers.contains) ?? false

            if signedMatch && (nameMatch || bundleMatch || matchesCodeSigningOnly(identity, agent: agent)) {
                return .agent(reason: .knownList(agent.displayName), confidence: agent.signedConfidence)
            }

            if (nameMatch && !isGenericHostExecutable(executableName)) || bundleMatch {
                return .agent(reason: .knownList(agent.displayName), confidence: agent.pathOnlyConfidence)
            }
        }

        return nil
    }

    private func classifyByPythonArgv(_ identity: ProcessIdentity) -> AgentVerdict? {
        guard isPythonRuntime(identity) else {
            return nil
        }

        for (index, argument) in identity.arguments.enumerated() where argument == "-m" {
            guard index + 1 < identity.arguments.count else {
                continue
            }

            let module = identity.arguments[index + 1].lowercased()
            if pythonRuntimeMarkers.contains(where: { moduleMatches(module, marker: $0) }) {
                return .agent(reason: .pythonRuntime, confidence: .high)
            }
        }

        for argument in identity.arguments {
            let name = executableName(argument)
            guard knownAgents.contains(where: { $0.executableNames.contains(name) }) else {
                continue
            }

            let components = URL(fileURLWithPath: argument).pathComponents.map { $0.lowercased() }
            if components.count >= 3, components[components.count - 2] == "bin" {
                return .agent(reason: .pythonRuntime, confidence: .high)
            }
        }

        return nil
    }

    private func classifyByNodeArgv(_ identity: ProcessIdentity) -> AgentVerdict? {
        guard isNodeRuntime(identity), let scriptPath = nodeScriptPath(identity) else {
            return nil
        }

        if let package = nodePackageName(inNodeModulesPath: scriptPath),
           nodeRuntimeMarkers.contains(package) {
            return .agent(reason: .nodeRuntime, confidence: .high)
        }

        if packageJSONDeclaresAgentPackage(startingAt: URL(fileURLWithPath: scriptPath).deletingLastPathComponent()) {
            return .agent(reason: .nodeRuntime, confidence: .medium)
        }

        return nil
    }

    private func classifyByInstallPathPrefix(_ identity: ProcessIdentity) -> AgentVerdict? {
        let candidatePaths = [identity.executablePath] + (identity.cwd.map { [$0] } ?? [])

        for agent in knownAgents {
            guard !agent.installPaths.isEmpty else {
                continue
            }

            if agent.installPaths.contains(where: { pattern in
                candidatePaths.contains { LaunchdPlistIndex.path($0, matchesInstallPattern: pattern) }
            }) {
                return .agent(reason: .knownList(agent.displayName), confidence: .medium)
            }
        }

        return nil
    }

    private func classifyByVenvPackages(_ identity: ProcessIdentity) -> AgentVerdict? {
        let startedAt = Date()
        let candidates = pythonVenvCandidateRoots(identity)
        let fileManager = FileManager.default

        for root in candidates {
            if Date().timeIntervalSince(startedAt) > 0.05 {
                FileHandle.standardError.write(Data("Sanctuary classifier: venv package scan exceeded 50ms for pid \(identity.pid)\n".utf8))
                return nil
            }

            let libDirectory = root.appendingPathComponent("lib", isDirectory: true)
            guard let pythonDirectories = try? fileManager.contentsOfDirectory(
                at: libDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for pythonDirectory in pythonDirectories where pythonDirectory.lastPathComponent.hasPrefix("python") {
                let sitePackages = pythonDirectory.appendingPathComponent("site-packages", isDirectory: true)
                guard let packages = try? fileManager.contentsOfDirectory(
                    at: sitePackages,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                if packages.contains(where: { pythonRuntimeMarkers.contains($0.lastPathComponent.lowercased()) }) {
                    return .agent(reason: .pythonRuntime, confidence: .medium)
                }
            }
        }

        return nil
    }

    private func matchLaunchdService(_ identity: ProcessIdentity) -> AgentVerdict? {
        guard identity.hasLaunchdParent else {
            return nil
        }

        guard launchdPlistIndex.agentEntry(for: identity, registry: knownAgents) != nil else {
            return nil
        }

        return .agent(reason: .serviceLaunch, confidence: .high)
    }

    private func matchVSCodeAgentExtension(_ identity: ProcessIdentity) -> AgentVerdict? {
        let executableName = executableName(identity.executablePath)
        guard executableName == "code" || executableName == "electron" || executableName == "node" else {
            return nil
        }

        let joinedArguments = identity.arguments.joined(separator: " ").lowercased()
        if joinedArguments.contains("saoudrizwan.claude-dev") || joinedArguments.contains("cline") {
            return .agent(reason: .knownList("Cline"), confidence: .high)
        }

        if joinedArguments.contains("continue.continue") || joinedArguments.contains("continue") {
            return .agent(reason: .knownList("Continue"), confidence: .high)
        }

        return nil
    }

    private func matchesSignedIdentity(_ identity: ProcessIdentity, agent: KnownAgent) -> Bool {
        let teamMatches = identity.teamIdentifier.map(agent.teamIdentifiers.contains) ?? false
        let signingMatches = identity.codeSigningIdentifier.map(agent.codeSigningIdentifiers.contains) ?? false

        if !agent.teamIdentifiers.isEmpty && teamMatches {
            return true
        }

        if !agent.codeSigningIdentifiers.isEmpty && signingMatches {
            return true
        }

        return false
    }

    private func matchesCodeSigningOnly(_ identity: ProcessIdentity, agent: KnownAgent) -> Bool {
        let signingMatches = identity.codeSigningIdentifier.map(agent.codeSigningIdentifiers.contains) ?? false
        let teamMatches = identity.teamIdentifier.map(agent.teamIdentifiers.contains) ?? false
        return signingMatches || teamMatches
    }

    private func parentChainReasonName(_ parent: ProcessIdentity, fallback: AgentReason) -> String {
        if let known = matchKnownAgent(parent), case let .agent(.knownList(displayName), _) = known {
            return displayName
        }

        switch fallback {
        case let .knownList(displayName):
            return displayName
        case .userTagged:
            return executableName(parent.executablePath)
        case .pythonRuntime:
            return "Python agent runtime"
        case .nodeRuntime:
            return "Node agent runtime"
        case .serviceLaunch:
            return executableName(parent.executablePath)
        case let .mcpServer(parentName):
            return parentName
        case let .parentChain(displayName):
            return displayName
        }
    }

    private var pythonRuntimeMarkers: Set<String> {
        Set(knownAgents.flatMap(\.pythonModuleMarkers).map { $0.lowercased() })
    }

    private var nodeRuntimeMarkers: Set<String> {
        Set(knownAgents.flatMap(\.nodePackageMarkers).map { $0.lowercased() })
    }

    private func isPythonRuntime(_ identity: ProcessIdentity) -> Bool {
        let name = executableName(identity.executablePath)
        return name == "python" || name.hasPrefix("python3") || name.contains("jupyter")
    }

    private func isNodeRuntime(_ identity: ProcessIdentity) -> Bool {
        let name = executableName(identity.executablePath)
        return name == "node"
    }

    private func isGenericHostExecutable(_ name: String) -> Bool {
        name == "node" || name == "code" || name == "electron"
    }

    private func hasAgentAPIKey(_ identity: ProcessIdentity) -> Bool {
        !identity.environmentVars.isDisjoint(with: Self.agentApiKeyEnvironment)
    }

    private func spawnedRecentShell(_ identity: ProcessIdentity) -> Bool {
        identity.childProcessObservations.contains { observation in
            observation.secondsAgo <= 60 && isShell(observation.executablePath)
        }
    }

    private func isShell(_ path: String) -> Bool {
        let name = executableName(path)
        return name == "bash" || name == "zsh" || name == "sh" || name == "fish"
    }

    private func containsAnyMarker(in haystacks: [String], markers: [String]) -> Bool {
        haystacks.contains { value in
            let lowercasedValue = value.lowercased()
            return markers.contains { lowercasedValue.contains($0) }
        }
    }

    private func moduleMatches(_ module: String, marker: String) -> Bool {
        let normalizedModule = module.lowercased()
        let normalizedMarker = marker.lowercased()
        let root = normalizedModule.split(separator: ".").first.map(String.init) ?? normalizedModule
        return root == normalizedMarker || normalizedModule.hasPrefix(normalizedMarker + ".")
    }

    private func nodeScriptPath(_ identity: ProcessIdentity) -> String? {
        identity.arguments.dropFirst().first { !$0.hasPrefix("-") }
    }

    private func nodePackageName(inNodeModulesPath path: String) -> String? {
        let components = URL(fileURLWithPath: path).pathComponents
        guard let index = components.lastIndex(of: "node_modules"), index + 1 < components.count else {
            return nil
        }

        let first = components[index + 1]
        if first.hasPrefix("@"), index + 2 < components.count {
            return "\(first)/\(components[index + 2])".lowercased()
        }
        return first.lowercased()
    }

    private func packageJSONDeclaresAgentPackage(startingAt directory: URL) -> Bool {
        var current = directory
        for _ in 0..<3 {
            let packageURL = current.appendingPathComponent("package.json")
            if packageJSON(at: packageURL, containsAnyOf: nodeRuntimeMarkers) {
                return true
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return false
    }

    private func packageJSON(at url: URL, containsAnyOf packages: Set<String>) -> Bool {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        if let name = object["name"] as? String, packages.contains(name.lowercased()) {
            return true
        }

        let dependencyKeys = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]
        return dependencyKeys.contains { key in
            guard let dependencies = object[key] as? [String: Any] else {
                return false
            }
            return !Set(dependencies.keys.map { $0.lowercased() }).isDisjoint(with: packages)
        }
    }

    private func pythonVenvCandidateRoots(_ identity: ProcessIdentity) -> [URL] {
        let candidatePaths = [identity.executablePath] + identity.arguments
        var roots: [URL] = []

        for path in candidatePaths {
            let components = URL(fileURLWithPath: path).pathComponents
            guard let binIndex = components.lastIndex(of: "bin"), binIndex > 0 else {
                continue
            }

            let rootComponents = Array(components.prefix(binIndex))
            let rootPath = NSString.path(withComponents: rootComponents)
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            let pythonBinary = rootURL.appendingPathComponent("bin/python")
            let python3Binary = rootURL.appendingPathComponent("bin/python3")
            let pyvenvConfig = rootURL.appendingPathComponent("pyvenv.cfg")

            if FileManager.default.fileExists(atPath: pythonBinary.path) ||
                FileManager.default.fileExists(atPath: python3Binary.path) ||
                FileManager.default.fileExists(atPath: pyvenvConfig.path) {
                roots.append(rootURL)
            }
        }

        return Array(Set(roots.map(\.path))).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func executableName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    private func isAgentVerdict(_ verdict: AgentVerdict) -> Bool {
        if case .agent = verdict {
            return true
        }
        return false
    }

    private func hasMCPRuntimeFingerprint(_ identity: ProcessIdentity) -> Bool {
        identity.packageDependencyNames.contains("@modelcontextprotocol/sdk") ||
            containsAnyMarker(in: identity.loadedModulePaths + identity.arguments, markers: ["mcp"])
    }
}

@available(*, deprecated, renamed: "AgentVerdict")
public typealias AgentClassification = AgentVerdict
