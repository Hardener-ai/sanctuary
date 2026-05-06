// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SanctuaryCore

let args = Array(CommandLine.arguments.dropFirst())

do {
    try run(args)
} catch {
    fputs("sanctuary: \(error)\n", stderr)
    exit(1)
}

private func run(_ args: [String]) throws {
    switch args.first {
case "status":
    try statusCommand()
case "agents":
    try agentsCommand(Array(args.dropFirst()))
case "trust":
    try trustCommand(Array(args.dropFirst()))
case "protect-extension":
    try protectExtension(Array(args.dropFirst()))
case "unprotect-extension":
    try unprotectExtension(Array(args.dropFirst()))
case "list-extensions":
    try listExtensions(Array(args.dropFirst()))
case "setup":
    try setupCommand(Array(args.dropFirst()))
case "protect":
    try protectFolder(Array(args.dropFirst()))
case "unprotect":
    try unprotectFolder(Array(args.dropFirst()))
case "list-folders":
    try listFolders(Array(args.dropFirst()))
case "inventory":
    try inventoryCommand(Array(args.dropFirst()))
case "log":
    try logCommand(Array(args.dropFirst()))
case "peer-monitor-simulate":
    try peerMonitorSimulate(Array(args.dropFirst()))
default:
    print("""
    sanctuary <command>

    Commands:
      status                  Show daemon/protection status
      agents                  Add, remove, or list user-tagged agents
      trust                   Add, remove, or list trusted executable paths
      protect-extension       Protect a browser extension storage area
      unprotect-extension     Remove extension storage protection
      list-extensions         List protected or available known extensions
      setup                   Configure default sensitive folder detection
      protect                 Protect a folder or resource
      unprotect               Remove protection
      list-folders            List protected folders
      inventory               List or watch running agent inventory
      log                     Show audit log entries
      override                Request a hardware-gated allow-once override
    """)
    }
}

private func peerMonitorSimulate(_ args: [String]) throws {
    var duration: TimeInterval = 45
    var interval: TimeInterval = 10
    var timeout: TimeInterval = 1
    var expectRunning = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--duration":
            if index + 1 < args.count {
                duration = TimeInterval(args[index + 1]) ?? duration
                index += 1
            }
        case "--interval":
            if index + 1 < args.count {
                interval = TimeInterval(args[index + 1]) ?? interval
                index += 1
            }
        case "--timeout":
            if index + 1 < args.count {
                timeout = TimeInterval(args[index + 1]) ?? timeout
                index += 1
            }
        case "--expect-running":
            expectRunning = true
        default:
            break
        }
        index += 1
    }

    let instanceUUID = UUID()
    let deadline = Date().addingTimeInterval(duration)
    var daemonUUID: UUID?
    var failureCount = 0
    var tamperReported = false
    let auditLog = AuditLog()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    func appendAudit(action: String, resource: String) {
        try? auditLog.append(
            AuditEntry(
                ts: formatter.string(from: Date()),
                kind: action == "TAMPER_DETECTED" ? "tamper" : "peer",
                action: action,
                policy: "peer_monitor",
                resource: resource
            )
        )
    }

    func printLine(_ line: String) {
        print(line)
        fflush(stdout)
    }

    while Date() < deadline {
        let response = try? UnixDatagramPeerTransport.sendPingAndWait(
            sender: .menuBar,
            instanceUUID: instanceUUID,
            timeout: timeout
        )

        if let response, response.responder == .daemon {
            let wasDisconnected = failureCount > 0
            failureCount = 0
            if let daemonUUID, daemonUUID != response.instanceUUID {
                printLine("daemon_peer_restarted \(daemonUUID.uuidString) -> \(response.instanceUUID.uuidString)")
                appendAudit(action: "PEER_RESTARTED", resource: "daemon_peer:\(daemonUUID.uuidString)->\(response.instanceUUID.uuidString)")
            } else if daemonUUID == nil {
                printLine("daemon_peer_connected \(response.instanceUUID.uuidString)")
                appendAudit(action: "PEER_CONNECTED", resource: "daemon_peer:\(response.instanceUUID.uuidString)")
            } else if wasDisconnected {
                printLine("daemon_peer_recovered \(response.instanceUUID.uuidString)")
                appendAudit(action: "PEER_RECOVERED", resource: "daemon_peer:\(response.instanceUUID.uuidString)")
            }
            daemonUUID = response.instanceUUID
            tamperReported = false
        } else {
            failureCount += 1
            printLine("daemon_peer_disconnected failure_count=\(failureCount)")
            if expectRunning && failureCount >= 3 && !tamperReported {
                printLine("TAMPER_DETECTED peer_unresponsive")
                appendAudit(
                    action: "TAMPER_DETECTED",
                    resource: "peer_unresponsive: daemon unresponsive despite running status"
                )
                tamperReported = true
            } else {
                appendAudit(action: "PEER_DISCONNECTED", resource: "daemon_peer_unresponsive")
            }
        }

        Thread.sleep(forTimeInterval: interval)
    }
}

private struct CLIOptions {
    var positional: [String] = []
    var profile: String?
    var browser: String?
    var path: String?
    var source: String?
    var category: String?
    var available = false
    var auto = false
    var reset = false
    var json = false
}

private enum CLIError: Error, CustomStringConvertible {
    case missingExtension
    case missingProfile
    case missingPath
    case invalidSource(String)
    case invalidCategory(String)
    case missingPID
    case invalidPID(String)
    case unknownInventoryCommand(String?)
    case unknownAgentsCommand(String?)
    case unknownTrustCommand(String?)
    case unknownExtension(String)
    case unknownLogCommand(String?)
    case pathDoesNotExist(String)

    var description: String {
        switch self {
        case .missingExtension:
            return "missing extension id or friendly name"
        case .missingProfile:
            return "--profile is required until protected browser profiles are wired"
        case .missingPath:
            return "missing path"
        case let .invalidSource(source):
            return "invalid source: \(source)"
        case let .invalidCategory(category):
            return "invalid inventory category: \(category)"
        case .missingPID:
            return "missing pid"
        case let .invalidPID(value):
            return "invalid pid: \(value)"
        case let .unknownInventoryCommand(command):
            return "unknown inventory command: \(command ?? "<missing>")"
        case let .unknownAgentsCommand(command):
            return "unknown agents command: \(command ?? "<missing>")"
        case let .unknownTrustCommand(command):
            return "unknown trust command: \(command ?? "<missing>")"
        case let .unknownExtension(value):
            return "unknown extension: \(value)"
        case let .unknownLogCommand(command):
            return "unknown log command: \(command ?? "<missing>")"
        case let .pathDoesNotExist(path):
            return "path does not exist: \(path)"
        }
    }
}

private func agentsCommand(_ args: [String]) throws {
    let command = args.first ?? "list"
    let rest = Array(args.dropFirst())
    let registry = try UserTaggedAgentRegistry()
    switch command {
    case "add":
        guard let path = rest.first else {
            throw CLIError.missingPath
        }
        let canonical = try canonicalExistingPath(path)
        try registry.add(canonical)
        print("Tagged \(canonical) as agent")
    case "remove":
        guard let path = rest.first else {
            throw CLIError.missingPath
        }
        let canonical = try canonicalPath(path)
        try registry.remove(canonical)
        print("Removed \(canonical) from agent list")
    case "list":
        print("User-tagged agents:")
        let userTagged = registry.list()
        if userTagged.isEmpty {
            print("(none)")
        } else {
            userTagged.forEach { print("- \($0)") }
        }
        print("")
        print("Bundled known agents:")
        for name in AgentClassifier.knownAgentNames.sorted() {
            print("- \(name)")
        }
    default:
        throw CLIError.unknownAgentsCommand(command)
    }
}

private func trustCommand(_ args: [String]) throws {
    let command = args.first ?? "list"
    let rest = Array(args.dropFirst())
    let registry = try TrustedPathRegistry()
    switch command {
    case "add":
        guard let path = rest.first else {
            throw CLIError.missingPath
        }
        let canonical = try canonicalExistingPath(path)
        try registry.add(canonical)
        print("Trusted \(canonical)")
    case "remove":
        guard let path = rest.first else {
            throw CLIError.missingPath
        }
        let canonical = try canonicalPath(path)
        try registry.remove(canonical)
        print("Removed \(canonical) from trusted paths")
    case "list":
        print("Trusted paths:")
        let paths = registry.list()
        if paths.isEmpty {
            print("(none)")
        } else {
            paths.forEach { print("- \($0)") }
        }
    default:
        throw CLIError.unknownTrustCommand(command)
    }
}

private func inventoryCommand(_ args: [String]) throws {
    let command = args.first
    let rest = Array(args.dropFirst())
    switch command {
    case "list":
        try inventoryList(rest)
    case "get":
        try inventoryGet(rest)
    case "watch":
        try inventoryWatch(rest)
    default:
        throw CLIError.unknownInventoryCommand(command)
    }
}

private func inventoryList(_ args: [String]) throws {
    let options = parse(args)
    let inventory = makeInventory()
    inventory.refresh()
    let entries = try filterInventory(inventory.entries(), category: options.category)
    if options.json {
        try printJSON(entries)
    } else {
        printInventoryTable(entries)
    }
}

private func inventoryGet(_ args: [String]) throws {
    let options = parse(args)
    guard let value = options.positional.first else {
        throw CLIError.missingPID
    }
    guard let pid = pid_t(value) else {
        throw CLIError.invalidPID(value)
    }
    let inventory = makeInventory()
    inventory.refresh()
    guard let entry = inventory.entry(pid: pid) else {
        return
    }
    if options.json {
        try printJSON(entry)
    } else {
        printInventoryTable([entry])
    }
}

private func inventoryWatch(_ args: [String]) throws {
    let options = parse(args)
    while true {
        let inventory = makeInventory()
        inventory.refresh()
        let entries = try filterInventory(inventory.entries(), category: options.category)
        print("\u{001B}[2J\u{001B}[H", terminator: "")
        printInventoryTable(entries)
        fflush(stdout)
        Thread.sleep(forTimeInterval: 5)
    }
}

private func makeInventory() -> ServiceInventory {
    ServiceInventory(classifier: AgentClassifier.live(), collector: ProcessIdentityCollector())
}

private func filterInventory(_ entries: [InventoryEntry], category: String?) throws -> [InventoryEntry] {
    guard let category else {
        return entries
    }
    let parsed = try parseInventoryCategory(category)
    return entries.filter { $0.category == parsed }
}

private func parseInventoryCategory(_ value: String) throws -> InventoryCategory {
    switch value {
    case "foregroundCoding", "foreground-coding":
        return .foregroundCoding
    case "backgroundService", "background-service":
        return .backgroundService
    case "browserAgent", "browser-agent":
        return .browserAgent
    case "mcpServer", "mcp-server":
        return .mcpServer
    case "runtimeFingerprint", "runtime-fingerprint":
        return .runtimeFingerprint
    case "suspicious":
        return .suspicious
    default:
        throw CLIError.invalidCategory(value)
    }
}

private func printInventoryTable(_ entries: [InventoryEntry]) {
    print("pid\tname\tcategory\tverdict\tparent")
    for entry in entries {
        let parent = entry.parentPid.map { "\($0):\(entry.parentDisplayName ?? "")" } ?? ""
        print("\(entry.pid)\t\(entry.displayName)\t\(entry.category.rawValue)\t\(describe(entry.verdict))\t\(parent)")
    }
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

private func describe(_ verdict: AgentVerdict) -> String {
    switch verdict {
    case let .agent(reason, confidence):
        return "agent(\(describe(reason)), \(describe(confidence)))"
    case let .suspicious(reason):
        return "suspicious(\(describe(reason)))"
    case .notAgent:
        return "notAgent"
    }
}

private func describe(_ reason: AgentReason) -> String {
    switch reason {
    case .userTagged:
        return "userTagged"
    case let .knownList(name):
        return "knownList:\(name)"
    case let .parentChain(name):
        return "parentChain:\(name)"
    case .pythonRuntime:
        return "pythonRuntime"
    case .nodeRuntime:
        return "nodeRuntime"
    case .serviceLaunch:
        return "serviceLaunch"
    case let .mcpServer(parent):
        return "mcpServer:\(parent)"
    }
}

private func describe(_ reason: SuspicionReason) -> String {
    switch reason {
    case .envVarsPlusShellSpawn:
        return "envVarsPlusShellSpawn"
    }
}

private func describe(_ confidence: Confidence) -> String {
    switch confidence {
    case .high:
        return "high"
    case .medium:
        return "medium"
    case .low:
        return "low"
    }
}

private func setupCommand(_ args: [String]) throws {
    let options = parse(args)
    let flow = try SanctuarySetupFlow(
        folderRegistry: ProtectedFolderRegistry(),
        extensionRegistry: ProtectedExtensionRegistry(),
        prompt: { question, defaultYes in
            ask(question, defaultYes: defaultYes)
        },
        write: { line in
            print(line)
        }
    )
    _ = try flow.run(auto: options.auto, reset: options.reset)
}

private func ask(_ question: String, defaultYes: Bool) -> Bool {
    print("\(question) ", terminator: "")
    let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if answer == nil || answer == "" {
        return defaultYes
    }
    return answer == "y" || answer == "yes"
}

private func statusCommand() throws {
    let snapshot = try SanctuaryStatusReader.snapshot(
        folderRegistry: ProtectedFolderRegistry(),
        extensionRegistry: ProtectedExtensionRegistry()
    )
    print(SanctuaryStatusFormatter.format(snapshot))
}

private func protectFolder(_ args: [String]) throws {
    let options = parse(args)
    guard let path = options.positional.first else {
        throw CLIError.missingPath
    }
    let registry = try ProtectedFolderRegistry()
    try registry.protect(path: path, source: "user")
    print("Protected \(ProtectedFolderRegistry.normalize(path))")
}

private func unprotectFolder(_ args: [String]) throws {
    let options = parse(args)
    guard let path = options.positional.first else {
        throw CLIError.missingPath
    }
    let registry = try ProtectedFolderRegistry()
    try registry.unprotect(path: path)
    print("Unprotected \(ProtectedFolderRegistry.normalize(path))")
}

private func listFolders(_ args: [String]) throws {
    let options = parse(args)
    let registry = try ProtectedFolderRegistry()
    let source = options.source ?? "all"
    let folders: [ProtectedFolder]
    switch source {
    case "all":
        folders = try registry.list()
    case "default", "user":
        folders = try registry.list(bySource: source)
    default:
        throw CLIError.invalidSource(source)
    }

    for folder in folders {
        print("\(folder.source)\t\(folder.path)")
    }
}

private func protectExtension(_ args: [String]) throws {
    let options = parse(args)
    guard let requested = options.positional.first else {
        throw CLIError.missingExtension
    }
    guard let profile = options.profile else {
        throw CLIError.missingProfile
    }
    let resolved = try resolveExtension(requested)
    let registry = try ProtectedExtensionRegistry()
    for id in resolved.extensionIDs {
        try registry.protect(profilePath: profile, extensionID: id, friendlyName: resolved.friendlyName)
        print("Protected \(resolved.friendlyName) (\(id)) for \(ExtensionPathMaterializer.normalize(profile))")
    }
}

private func unprotectExtension(_ args: [String]) throws {
    let options = parse(args)
    guard let requested = options.positional.first else {
        throw CLIError.missingExtension
    }
    guard let profile = options.profile else {
        throw CLIError.missingProfile
    }
    let resolved = try resolveExtension(requested)
    let registry = try ProtectedExtensionRegistry()
    for id in resolved.extensionIDs {
        try registry.unprotect(profilePath: profile, extensionID: id)
        print("Unprotected \(resolved.friendlyName) (\(id)) for \(ExtensionPathMaterializer.normalize(profile))")
    }
}

private func listExtensions(_ args: [String]) throws {
    let options = parse(args)
    if options.available {
        guard let profile = options.profile else {
            throw CLIError.missingProfile
        }
        for installed in availableExtensions(profilePath: profile) {
            print("\(installed.id)\t\(installed.name ?? "unknown")")
        }
        return
    }

    let registry = try ProtectedExtensionRegistry()
    for row in try registry.list() {
        print("\(row.extensionID)\t\(row.friendlyName ?? "unknown")\t\(row.profilePath)")
    }
}

private func logCommand(_ args: [String]) throws {
    guard args.first == "verify" else {
        throw CLIError.unknownLogCommand(args.first)
    }

    let options = parse(Array(args.dropFirst()))
    let result = try AuditLog(path: options.path ?? SanctuaryPaths.auditLogPath()).verify()
    switch result {
    case let .valid(entryCount):
        print("Audit log valid. \(entryCount) entries verified. Hash chain intact.")
    case let .invalid(reason, entryIndex):
        print("Audit log VERIFICATION FAILED at entry \(entryIndex).")
        switch reason {
        case .hashChainBreak:
            print("Reason: hash chain broken between entry \(max(0, entryIndex - 1)) and entry \(entryIndex).")
            print("This indicates the log was modified, truncated, or rolled back.")
        case .signatureFailure:
            print("Reason: signature verification failed for entry \(entryIndex).")
            print("This indicates the log entry was modified or signed by an unexpected key.")
        case .entryParseFailure:
            print("Reason: entry parse failure at entry \(entryIndex).")
            print("This indicates the log was truncated or contains malformed data.")
        case .missingEntry:
            print("Reason: missing audit log entry at entry \(entryIndex).")
        }
        exit(1)
    }
}

private func resolveExtension(_ value: String) throws -> KnownBrowserExtension {
    if let known = KnownExtensions.lookup(value) {
        return known
    }
    let id = value.lowercased()
    guard KnownExtensions.isValidChromiumExtensionID(id) else {
        throw CLIError.unknownExtension(value)
    }
    return KnownBrowserExtension(friendlyName: id, extensionIDs: [id], notes: "Custom user-provided extension ID")
}

private func parse(_ args: [String]) -> CLIOptions {
    var options = CLIOptions()
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--profile":
            if index + 1 < args.count {
                options.profile = args[index + 1]
                index += 1
            }
        case "--browser":
            if index + 1 < args.count {
                options.browser = args[index + 1]
                index += 1
            }
        case "--path":
            if index + 1 < args.count {
                options.path = args[index + 1]
                index += 1
            }
        case "--source":
            if index + 1 < args.count {
                options.source = args[index + 1]
                index += 1
            }
        case "--category":
            if index + 1 < args.count {
                options.category = args[index + 1]
                index += 1
            }
        case "--available":
            options.available = true
        case "--auto":
            options.auto = true
        case "--reset":
            options.reset = true
        case "--json":
            options.json = true
        default:
            options.positional.append(arg)
        }
        index += 1
    }
    return options
}

private func availableExtensions(profilePath: String) -> [(id: String, name: String?)] {
    let extensionsURL = URL(fileURLWithPath: ExtensionPathMaterializer.normalize(profilePath), isDirectory: true)
        .appendingPathComponent("Extensions", isDirectory: true)
    guard
        let contents = try? FileManager.default.contentsOfDirectory(
            at: extensionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    else {
        return []
    }

    return contents.compactMap { url in
        let id = url.lastPathComponent.lowercased()
        guard KnownExtensions.isValidChromiumExtensionID(id) else {
            return nil
        }
        return (id: id, name: KnownExtensions.displayName(for: id))
    }.sorted { $0.id < $1.id }
}

private func canonicalExistingPath(_ path: String) throws -> String {
    guard FileManager.default.fileExists(atPath: path.replacingOccurrences(of: "~", with: NSHomeDirectory(), options: [.anchored])) else {
        throw CLIError.pathDoesNotExist(path)
    }
    return try PolicyExecutablePath.canonicalize(path, requireExists: true)
}

private func canonicalPath(_ path: String) throws -> String {
    try PolicyExecutablePath.canonicalize(path)
}
