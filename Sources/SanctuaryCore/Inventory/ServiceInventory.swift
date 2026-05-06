// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public enum InventoryCategory: String, Codable, Sendable {
    case foregroundCoding
    case backgroundService
    case browserAgent
    case mcpServer
    case runtimeFingerprint
    case suspicious
}

public enum MCPTransport: String, Codable, Sendable {
    case stdio
    case tcp
    case unix
}

public struct InventoryEntry: Equatable, Codable, Sendable {
    public let pid: pid_t
    public let executablePath: String
    public let displayName: String
    public let category: InventoryCategory
    public let verdict: AgentVerdict
    public let parentPid: pid_t?
    public let parentDisplayName: String?
    public let firstSeen: Date
    public let lastClassified: Date
    public let mcpTransport: MCPTransport?

    public init(
        pid: pid_t,
        executablePath: String,
        displayName: String,
        category: InventoryCategory,
        verdict: AgentVerdict,
        parentPid: pid_t?,
        parentDisplayName: String?,
        firstSeen: Date,
        lastClassified: Date,
        mcpTransport: MCPTransport?
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.displayName = displayName
        self.category = category
        self.verdict = verdict
        self.parentPid = parentPid
        self.parentDisplayName = parentDisplayName
        self.firstSeen = firstSeen
        self.lastClassified = lastClassified
        self.mcpTransport = mcpTransport
    }
}

public protocol ProcessInventoryProviding: Sendable {
    func listPIDs() throws -> [pid_t]
    func startTime(pid: pid_t) -> TimeInterval?
    func parentPID(pid: pid_t) -> pid_t?
}

public struct DarwinProcessInventoryProvider: ProcessInventoryProviding {
    public init() {}

    public func listPIDs() throws -> [pid_t] {
        try DarwinProc().listPIDs()
    }

    public func startTime(pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written == MemoryLayout<proc_bsdinfo>.stride else {
            return nil
        }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }

    public func parentPID(pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let written = withUnsafeMutableBytes(of: &info) { buffer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written == MemoryLayout<proc_bsdinfo>.stride else {
            return nil
        }
        return pid_t(info.pbi_ppid)
    }
}

public final class ServiceInventory: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let pid: pid_t
        let startTime: TimeInterval
    }

    private struct CacheValue {
        let firstSeen: Date
        var lastClassified: Date
        var entry: InventoryEntry
    }

    private let classifier: AgentClassifier
    private let collector: any ProcessIdentityCollecting
    private let processProvider: any ProcessInventoryProviding
    private let knownAgents: [KnownAgent]
    private let launchdPlistIndex: LaunchdPlistIndex
    private let clock: @Sendable () -> Date
    private let currentPID: @Sendable () -> pid_t
    private let snapshotPath: String?
    private let lock = NSLock()
    private var cache: [CacheKey: CacheValue] = [:]
    private var timer: DispatchSourceTimer?

    public convenience init(
        classifier: AgentClassifier,
        collector: ProcessIdentityCollector
    ) {
        self.init(
            classifier: classifier,
            collector: collector as any ProcessIdentityCollecting
        )
    }

    public init(
        classifier: AgentClassifier = AgentClassifier(),
        collector: any ProcessIdentityCollecting = ProcessIdentityCollector(),
        processProvider: any ProcessInventoryProviding = DarwinProcessInventoryProvider(),
        knownAgents: [KnownAgent] = AgentClassifier.knownAgents,
        launchdPlistIndex: LaunchdPlistIndex = AgentClassifier.liveLaunchdPlistIndex,
        clock: @escaping @Sendable () -> Date = { Date() },
        currentPID: @escaping @Sendable () -> pid_t = { getpid() },
        snapshotPath: String? = SanctuaryPaths.inventorySnapshotPath()
    ) {
        self.classifier = classifier
        self.collector = collector
        self.processProvider = processProvider
        self.knownAgents = knownAgents
        self.launchdPlistIndex = launchdPlistIndex
        self.clock = clock
        self.currentPID = currentPID
        self.snapshotPath = snapshotPath
    }

    deinit {
        stop()
    }

    public func refresh() {
        let now = clock()
        let pids = (try? processProvider.listPIDs()) ?? []
        let excluded = Set(CurrentProcessExclusion.processGroup(
            containing: currentPID(),
            listPIDs: { pids },
            parentPID: { processProvider.parentPID(pid: $0) }
        ))
        let identities = pids
            .filter { $0 > 0 }
            .filter { !excluded.contains($0) }
            .compactMap { collector.collect(pid: $0) }

        let snapshot = buildSnapshot(identities: identities, now: now)
        lock.withLock {
            cache = snapshot
        }
        writeSnapshotIfNeeded(entries: snapshot.values.map(\.entry).sortedForInventory())
    }

    public func entries() -> [InventoryEntry] {
        lock.withLock { cache.values.map(\.entry).sortedForInventory() }
    }

    public func entries(category: InventoryCategory) -> [InventoryEntry] {
        entries().filter { $0.category == category }
    }

    public func entry(pid: pid_t) -> InventoryEntry? {
        entries().first { $0.pid == pid }
    }

    public func startContinuousRefresh(interval: TimeInterval = 5.0) {
        stop()
        refresh()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.hardener.sanctuary.service-inventory"))
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in
            self?.refresh()
        }
        source.resume()
        lock.withLock {
            timer = source
        }
    }

    public func stop() {
        let existing = lock.withLock { () -> DispatchSourceTimer? in
            let old = timer
            timer = nil
            return old
        }
        existing?.cancel()
    }

    private func buildSnapshot(identities: [ProcessIdentity], now: Date) -> [CacheKey: CacheValue] {
        let previous = lock.withLock { cache }
        let identitiesByPID = Dictionary(uniqueKeysWithValues: identities.map { ($0.pid, $0) })
        var entriesByPID: [pid_t: InventoryEntry] = [:]
        var verdictsByPID: [pid_t: AgentVerdict] = [:]

        for identity in identities {
            let verdict = classifier.classify(identity)
            verdictsByPID[identity.pid] = verdict
            guard verdict.isInventoryVisible else {
                continue
            }

            let parentPid = identity.parentChain.first?.pid
            let category = category(for: verdict, identity: identity, parentEntry: parentPid.flatMap { entriesByPID[$0] })
            entriesByPID[identity.pid] = makeEntry(
                identity: identity,
                verdict: verdict,
                category: category,
                parentPid: parentPid,
                parentDisplayName: parentPid.flatMap { entriesByPID[$0]?.displayName }
                    ?? identity.parentChain.first.map { displayName(for: $0, verdict: classifier.classify($0)) },
                mcpTransport: nil,
                previous: previous[cacheKey(for: identity)],
                now: now
            )
        }

        for parent in entriesByPID.values where parent.verdict.isAgent {
            let childIdentities = identities.filter { $0.parentChain.first?.pid == parent.pid }
            for child in childIdentities where isMCPCandidate(child) {
                let parentIdentity = identitiesByPID[parent.pid] ?? ProcessIdentity(pid: parent.pid, executablePath: parent.executablePath)
                let verdict = classifier.classifyMCP(child: child, parent: parentIdentity)
                guard case .agent = verdict else {
                    continue
                }
                entriesByPID[child.pid] = makeEntry(
                    identity: child,
                    verdict: verdict,
                    category: .mcpServer,
                    parentPid: parent.pid,
                    parentDisplayName: parent.displayName,
                    mcpTransport: detectMCPTransport(child),
                    previous: previous[cacheKey(for: child)],
                    now: now
                )
            }
        }

        var next: [CacheKey: CacheValue] = [:]
        for identity in identities where entriesByPID[identity.pid] != nil {
            let key = cacheKey(for: identity)
            let entry = entriesByPID[identity.pid]!
            next[key] = CacheValue(firstSeen: entry.firstSeen, lastClassified: entry.lastClassified, entry: entry)
        }
        return next
    }

    private func makeEntry(
        identity: ProcessIdentity,
        verdict: AgentVerdict,
        category: InventoryCategory,
        parentPid: pid_t?,
        parentDisplayName: String?,
        mcpTransport: MCPTransport?,
        previous: CacheValue?,
        now: Date
    ) -> InventoryEntry {
        let firstSeen = previous?.firstSeen ?? now
        return InventoryEntry(
            pid: identity.pid,
            executablePath: identity.executablePath,
            displayName: displayName(for: identity, verdict: verdict),
            category: category,
            verdict: verdict,
            parentPid: parentPid,
            parentDisplayName: parentDisplayName,
            firstSeen: firstSeen,
            lastClassified: now,
            mcpTransport: mcpTransport
        )
    }

    private func category(
        for verdict: AgentVerdict,
        identity: ProcessIdentity,
        parentEntry: InventoryEntry?
    ) -> InventoryCategory {
        switch verdict {
        case let .agent(reason, _):
            switch reason {
            case let .knownList(name):
                return registryCategory(displayName: name) ?? .backgroundService
            case .serviceLaunch:
                return .backgroundService
            case .parentChain:
                return parentEntry?.category ?? parentCategory(identity) ?? .backgroundService
            case .pythonRuntime, .nodeRuntime:
                return .runtimeFingerprint
            case .mcpServer:
                return .mcpServer
            case .userTagged:
                return closestRegistryCategory(identity) ?? .backgroundService
            }
        case .suspicious:
            return .suspicious
        case .notAgent:
            return .suspicious
        }
    }

    private func parentCategory(_ identity: ProcessIdentity) -> InventoryCategory? {
        for parent in identity.parentChain {
            let verdict = classifier.classify(parent)
            if verdict.isInventoryVisible {
                return category(for: verdict, identity: parent, parentEntry: nil)
            }
        }
        return nil
    }

    private func displayName(for identity: ProcessIdentity, verdict: AgentVerdict) -> String {
        switch verdict {
        case let .agent(reason, _):
            switch reason {
            case let .knownList(name), let .parentChain(name):
                return name
            case let .mcpServer(parent):
                return "\(basename(identity.executablePath)) MCP (\(parent))"
            case .serviceLaunch:
                return closestRegistryMatch(identity)?.displayName ?? basename(identity.executablePath)
            case .pythonRuntime:
                return pythonModuleDisplayName(identity) ?? closestRegistryMatch(identity)?.displayName ?? basename(identity.executablePath)
            case .nodeRuntime:
                return nodePackageDisplayName(identity) ?? closestRegistryMatch(identity)?.displayName ?? basename(identity.executablePath)
            case .userTagged:
                return closestRegistryMatch(identity)?.displayName ?? basename(identity.executablePath)
            }
        case .suspicious:
            return basename(identity.executablePath)
        case .notAgent:
            return basename(identity.executablePath)
        }
    }

    private func isMCPCandidate(_ identity: ProcessIdentity) -> Bool {
        let haystack = ([identity.executablePath] + identity.arguments + Array(identity.packageDependencyNames))
            .map { $0.lowercased() }
        if haystack.contains(where: { $0.contains("mcp") || $0.contains("mcp-server") }) {
            return true
        }
        let mcpPython = knownAgents.flatMap(\.pythonModuleMarkers).filter {
            $0.contains("mcp") || $0.contains("modelcontextprotocol")
        }
        let mcpNode = knownAgents.flatMap(\.nodePackageMarkers).filter {
            $0.contains("mcp") || $0.contains("modelcontextprotocol")
        }
        return !identity.packageDependencyNames.isDisjoint(with: Set(mcpNode))
            || haystack.contains(where: { value in mcpPython.contains(where: value.contains) })
    }

    private func detectMCPTransport(_ identity: ProcessIdentity) -> MCPTransport? {
        let args = identity.arguments.map { $0.lowercased() }
        if args.contains(where: { $0.contains(".sock") || $0.contains("unix") }) {
            return .unix
        }
        if args.contains(where: { $0.contains("tcp") || $0.contains("http") || $0.contains("port") }) {
            return .tcp
        }
        if args.contains(where: { $0.contains("stdio") || $0.contains("mcp") }) {
            return .stdio
        }
        return nil
    }

    private func registryCategory(displayName: String) -> InventoryCategory? {
        knownAgents.first { $0.displayName == displayName }.flatMap { mapRegistryCategory($0.category) }
    }

    private func closestRegistryCategory(_ identity: ProcessIdentity) -> InventoryCategory? {
        closestRegistryMatch(identity).flatMap { mapRegistryCategory($0.category) }
    }

    private func closestRegistryMatch(_ identity: ProcessIdentity) -> KnownAgent? {
        if let launchdMatch = launchdPlistIndex.agentEntry(for: identity, registry: knownAgents) {
            return launchdMatch
        }

        let executable = basename(identity.executablePath).lowercased()
        let args = identity.arguments.map { $0.lowercased() }
        return knownAgents.first { agent in
            agent.executableNames.contains(executable)
                || args.contains(where: { argument in
                    agent.pythonModuleMarkers.contains(where: argument.contains)
                        || agent.nodePackageMarkers.contains(where: argument.contains)
                })
                || agent.installPaths.contains(where: { LaunchdPlistIndex.path(identity.executablePath, matchesInstallPattern: $0) })
        }
    }

    private func pythonModuleDisplayName(_ identity: ProcessIdentity) -> String? {
        for (index, argument) in identity.arguments.enumerated() where argument == "-m" && index + 1 < identity.arguments.count {
            let module = identity.arguments[index + 1].lowercased()
            if let agent = knownAgents.first(where: { agent in
                agent.pythonModuleMarkers.contains(where: { module.hasPrefix($0) || module.contains($0) })
            }) {
                return agent.displayName
            }
        }
        return nil
    }

    private func nodePackageDisplayName(_ identity: ProcessIdentity) -> String? {
        let packages = identity.packageDependencyNames
        return knownAgents.first { !$0.nodePackageMarkers.isDisjoint(with: packages) }?.displayName
    }

    private func mapRegistryCategory(_ raw: String) -> InventoryCategory? {
        switch raw {
        case "foreground-coding":
            return .foregroundCoding
        case "background-service":
            return .backgroundService
        case "browser-agent":
            return .browserAgent
        case "mcp-server":
            return .mcpServer
        case "runtime-fingerprint":
            return .runtimeFingerprint
        default:
            return nil
        }
    }

    private func cacheKey(for identity: ProcessIdentity) -> CacheKey {
        CacheKey(pid: identity.pid, startTime: processProvider.startTime(pid: identity.pid) ?? 0)
    }

    private func writeSnapshotIfNeeded(entries: [InventoryEntry]) {
        guard let snapshotPath, !snapshotPath.isEmpty else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            let url = URL(fileURLWithPath: snapshotPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            FileHandle.standardError.write(Data("Sanctuary inventory snapshot failed: \(error)\n".utf8))
        }
    }

    private func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private extension Array where Element == InventoryEntry {
    func sortedForInventory() -> [InventoryEntry] {
        sorted {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            if $0.displayName != $1.displayName {
                return $0.displayName < $1.displayName
            }
            return $0.pid < $1.pid
        }
    }
}

private extension AgentVerdict {
    var isInventoryVisible: Bool {
        switch self {
        case .agent, .suspicious:
            return true
        case .notAgent:
            return false
        }
    }

    var isAgent: Bool {
        if case .agent = self {
            return true
        }
        return false
    }
}

extension AgentVerdict: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case reason
        case confidence
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .agent(reason, confidence):
            try container.encode("agent", forKey: .type)
            try container.encode(reason, forKey: .reason)
            try container.encode(confidence, forKey: .confidence)
        case let .suspicious(reason):
            try container.encode("suspicious", forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .notAgent:
            try container.encode("notAgent", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "agent":
            self = try .agent(
                reason: container.decode(AgentReason.self, forKey: .reason),
                confidence: container.decode(Confidence.self, forKey: .confidence)
            )
        case "suspicious":
            self = try .suspicious(reason: container.decode(SuspicionReason.self, forKey: .reason))
        default:
            self = .notAgent
        }
    }
}

extension AgentReason: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .userTagged:
            try container.encode("userTagged", forKey: .type)
        case let .knownList(value):
            try container.encode("knownList", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .parentChain(value):
            try container.encode("parentChain", forKey: .type)
            try container.encode(value, forKey: .value)
        case .pythonRuntime:
            try container.encode("pythonRuntime", forKey: .type)
        case .nodeRuntime:
            try container.encode("nodeRuntime", forKey: .type)
        case .serviceLaunch:
            try container.encode("serviceLaunch", forKey: .type)
        case let .mcpServer(parent):
            try container.encode("mcpServer", forKey: .type)
            try container.encode(parent, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "userTagged":
            self = .userTagged
        case "knownList":
            self = try .knownList(container.decode(String.self, forKey: .value))
        case "parentChain":
            self = try .parentChain(container.decode(String.self, forKey: .value))
        case "pythonRuntime":
            self = .pythonRuntime
        case "nodeRuntime":
            self = .nodeRuntime
        case "serviceLaunch":
            self = .serviceLaunch
        case "mcpServer":
            self = try .mcpServer(parent: container.decode(String.self, forKey: .value))
        default:
            self = .userTagged
        }
    }
}

extension SuspicionReason: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .envVarsPlusShellSpawn:
            try container.encode("envVarsPlusShellSpawn")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "envVarsPlusShellSpawn":
            self = .envVarsPlusShellSpawn
        default:
            self = .envVarsPlusShellSpawn
        }
    }
}

extension Confidence: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .high:
            try container.encode("high")
        case .medium:
            try container.encode("medium")
        case .low:
            try container.encode("low")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "high":
            self = .high
        case "medium":
            self = .medium
        case "low":
            self = .low
        default:
            self = .low
        }
    }
}
