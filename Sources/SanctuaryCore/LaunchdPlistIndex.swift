// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public final class LaunchdPlistIndex: @unchecked Sendable {
    public struct Entry: Equatable, Sendable {
        public let label: String?
        public let program: String
        public let programArguments: [String]
        public let moduleSpecifier: String?

        public init(label: String?, program: String, programArguments: [String] = [], moduleSpecifier: String? = nil) {
            self.label = label
            self.program = program
            self.programArguments = programArguments
            self.moduleSpecifier = moduleSpecifier
        }
    }

    private let lock = NSLock()
    private let plistDirectories: [URL]
    private var entries: [Entry]
    private var watcher: ExtensionStorageWatcher?

    public init(entries: [Entry] = []) {
        self.plistDirectories = []
        self.entries = entries
    }

    public init(plistDirectories: [URL], watchForChanges: Bool = false) {
        self.plistDirectories = plistDirectories
        self.entries = Self.walk(plistDirectories: plistDirectories)

        if watchForChanges {
            let existingDirectories = plistDirectories.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existingDirectories.isEmpty {
                let watcher = ExtensionStorageWatcher(protectedPaths: existingDirectories.map(\.path))
                try? watcher.start { [weak self] _ in
                    self?.reload()
                }
                self.watcher = watcher
            }
        }
    }

    deinit {
        watcher?.stop()
    }

    public static func live(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> LaunchdPlistIndex {
        LaunchdPlistIndex(
            plistDirectories: [
                homeDirectory.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
                homeDirectory.appendingPathComponent("Library/LaunchDaemons", isDirectory: true),
                URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)
            ],
            watchForChanges: true
        )
    }

    public func reload() {
        let reloaded = Self.walk(plistDirectories: plistDirectories)
        lock.withLock {
            entries = reloaded
        }
    }

    public func agentEntry(
        for identity: ProcessIdentity,
        registry: [KnownAgent]
    ) -> KnownAgent? {
        let snapshot = lock.withLock { entries }
        return snapshot.lazy.compactMap { entry -> KnownAgent? in
            guard self.entry(entry, plausiblyStarted: identity) else {
                return nil
            }

            return registry.first { agent in
                self.matches(entry: entry, identity: identity, agent: agent)
            }
        }.first
    }

    private func entry(_ entry: Entry, plausiblyStarted identity: ProcessIdentity) -> Bool {
        if let label = identity.launchdLabel {
            return entry.label == label
        }

        let identityArguments = Set(identity.arguments)
        if normalize(entry.program) == normalize(identity.executablePath) ||
            entry.programArguments.contains(where: { normalize($0) == normalize(identity.executablePath) }) {
            return true
        }

        if let module = entry.moduleSpecifier,
           identity.arguments.indices.contains(where: { index in
               identity.arguments[index] == "-m" &&
                   index + 1 < identity.arguments.count &&
                   identity.arguments[index + 1] == module
           }) {
            return true
        }

        let significantPlistArguments = entry.programArguments.filter { argument in
            argument.count > 2 && argument != entry.program && argument != "-m"
        }
        return significantPlistArguments.contains { identityArguments.contains($0) }
    }

    private func matches(entry: Entry, identity: ProcessIdentity, agent: KnownAgent) -> Bool {
        if let label = identity.launchdLabel, entry.label != label {
            return false
        }

        if let label = entry.label, agent.launchdPlistPatterns.contains(where: { Self.glob($0, matches: label) }) {
            return true
        }

        if let module = entry.moduleSpecifier?.lowercased(),
           agent.pythonModuleMarkers.contains(where: { moduleRoot(module) == $0.lowercased() || module.hasPrefix($0.lowercased() + ".") }) {
            return true
        }

        let programExecutable = executableName(entry.program)
        let identityExecutable = executableName(identity.executablePath)
        if (agent.executableNames.contains(programExecutable) && !Self.isGenericHostExecutable(programExecutable)) ||
            (agent.executableNames.contains(identityExecutable) && !Self.isGenericHostExecutable(identityExecutable)) {
            return true
        }

        let paths = [entry.program] + entry.programArguments + [identity.executablePath, identity.cwd].compactMap { $0 }
        return agent.installPaths.contains { pattern in
            paths.contains { Self.path($0, matchesInstallPattern: pattern) }
        }
    }

    private static func walk(plistDirectories: [URL]) -> [Entry] {
        let fileManager = FileManager.default
        let plistURLs = plistDirectories.flatMap { directory -> [URL] in
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension == "plist" else {
                    return nil
                }
                return url
            }
        }

        return plistURLs.compactMap(Self.entry(from:))
    }

    private static func entry(from url: URL) -> Entry? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        let label = plist["Label"] as? String
        let programArguments = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String
        let firstArgument = programArguments.first

        guard let resolvedProgram = program ?? firstArgument else {
            return nil
        }

        return Entry(
            label: label,
            program: resolvedProgram,
            programArguments: programArguments,
            moduleSpecifier: moduleSpecifier(in: programArguments)
        )
    }

    private static func moduleSpecifier(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() where argument == "-m" {
            guard index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        return nil
    }

    static func path(_ path: String, matchesInstallPattern pattern: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let normalizedPath = normalizePath(path)
        let normalizedPattern = normalizeInstallPattern(pattern, homeDirectory: homeDirectory)
        let pathComponents = normalizedPath.split(separator: "/").map(String.init)
        let patternComponents = normalizedPattern.split(separator: "/").map(String.init)
        guard patternComponents.count <= pathComponents.count else {
            return false
        }

        for (index, patternComponent) in patternComponents.enumerated() {
            if patternComponent == "*" {
                continue
            }
            guard patternComponent == pathComponents[index] else {
                return false
            }
        }
        return true
    }

    static func glob(_ pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return value.range(of: "^\(escaped)$", options: [.regularExpression]) != nil
    }

    private static func normalizeInstallPattern(_ pattern: String, homeDirectory: String) -> String {
        var expanded = pattern
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "~", with: homeDirectory, options: [.anchored])
        expanded = (expanded as NSString).standardizingPath
        return stripTrailingSlash(expanded)
    }

    private static func normalizePath(_ path: String) -> String {
        stripTrailingSlash((path as NSString).standardizingPath)
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else {
            return path
        }
        return String(path.dropLast())
    }

    private func executableName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    private static func isGenericHostExecutable(_ name: String) -> Bool {
        name == "node"
            || name == "python"
            || name == "python3"
            || name.hasPrefix("python3.")
            || name == "bash"
            || name == "sh"
            || name == "zsh"
    }

    private func moduleRoot(_ module: String) -> String {
        module.split(separator: ".").first.map(String.init) ?? module
    }

    private func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
