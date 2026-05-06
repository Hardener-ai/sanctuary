// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct RegistryEntry {
    var id = ""
    var friendlyName = ""
    var category = ""
    var executableNames: [String] = []
    var bundleIdentifiers: [String] = []
    var teamIdentifiers: [String] = []
    var codeSigningIdentifiers: [String] = []
    var installPaths: [String] = []
    var runtimePythonModules: [String] = []
    var runtimeNodePackages: [String] = []
    var launchdPlistPatterns: [String] = []
    var confidenceWhenSigned = "high"
    var confidenceWhenUnsigned = "medium"
}

enum GeneratorError: Error, CustomStringConvertible {
    case usage
    case malformed(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: AgentRegistryGenerator <agents.yaml> <GeneratedRegistry.swift>"
        case let .malformed(message):
            return "malformed agents.yaml: \(message)"
        }
    }
}

func parseFlowArray(_ value: String) -> [String] {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
        return []
    }

    let body = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    if body.isEmpty {
        return []
    }

    return body.split(separator: ",").compactMap { part in
        let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if value.isEmpty || value == "null" {
            return nil
        }
        return value
    }
}

func parseRegistry(_ yaml: String) throws -> [RegistryEntry] {
    var entries: [RegistryEntry] = []
    var current: RegistryEntry?
    var runtimeSection = false

    func finishCurrent() {
        if let current {
            entries.append(current)
        }
    }

    for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            continue
        }

        if trimmed.hasPrefix("- id:") {
            finishCurrent()
            runtimeSection = false
            current = RegistryEntry()
            current?.id = String(trimmed.dropFirst("- id:".count)).trimmingCharacters(in: .whitespaces)
            continue
        }

        guard current != nil else {
            continue
        }

        if trimmed == "runtime_fingerprint:" {
            runtimeSection = true
            continue
        }

        guard let separator = trimmed.firstIndex(of: ":") else {
            continue
        }

        let key = String(trimmed[..<separator])
        let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

        switch (runtimeSection, key) {
        case (_, "friendly_name"):
            current?.friendlyName = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        case (_, "category"):
            current?.category = value
        case (_, "executable_names"):
            current?.executableNames = parseFlowArray(value)
        case (_, "bundle_identifiers"):
            current?.bundleIdentifiers = parseFlowArray(value)
        case (_, "team_identifiers"):
            current?.teamIdentifiers = parseFlowArray(value)
        case (_, "code_signing_identifiers"):
            current?.codeSigningIdentifiers = parseFlowArray(value)
        case (_, "install_paths"):
            runtimeSection = false
            current?.installPaths = parseFlowArray(value)
        case (true, "python_modules"):
            current?.runtimePythonModules = parseFlowArray(value)
        case (true, "node_packages"):
            current?.runtimeNodePackages = parseFlowArray(value)
        case (_, "launchd_plist_patterns"):
            runtimeSection = false
            current?.launchdPlistPatterns = parseFlowArray(value)
        case (_, "confidence_when_signed"):
            runtimeSection = false
            current?.confidenceWhenSigned = value
        case (_, "confidence_when_unsigned"):
            runtimeSection = false
            current?.confidenceWhenUnsigned = value
        default:
            break
        }
    }

    finishCurrent()

    if entries.isEmpty {
        throw GeneratorError.malformed("no entries found")
    }

    return entries
}

func swiftString(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func swiftArray(_ values: [String], lowercase: Bool = false) -> String {
    let normalized = values.map { lowercase ? $0.lowercased() : $0 }
    return "[" + normalized.map(swiftString).joined(separator: ", ") + "]"
}

func confidence(_ value: String) -> String {
    switch value {
    case "high":
        return ".high"
    case "low":
        return ".low"
    default:
        return ".medium"
    }
}

func render(entries: [RegistryEntry]) -> String {
    var output = """
    // Generated by AgentRegistryGenerator. Do not edit by hand.

    enum GeneratedAgentRegistry {
        static let knownAgents: [KnownAgent] = [

    """

    for entry in entries {
        output += """
            KnownAgent(
                id: \(swiftString(entry.id)),
                displayName: \(swiftString(entry.friendlyName)),
                category: \(swiftString(entry.category)),
                executableNames: \(swiftArray(entry.executableNames, lowercase: true)),
                bundleIdentifiers: \(swiftArray(entry.bundleIdentifiers)),
                codeSigningIdentifiers: \(swiftArray(entry.codeSigningIdentifiers)),
                teamIdentifiers: \(swiftArray(entry.teamIdentifiers)),
                pythonModuleMarkers: \(swiftArray(entry.runtimePythonModules)),
                nodePackageMarkers: \(swiftArray(entry.runtimeNodePackages)),
                launchdPlistPatterns: \(swiftArray(entry.launchdPlistPatterns)),
                installPaths: \(swiftArray(entry.installPaths)),
                signedConfidence: \(confidence(entry.confidenceWhenSigned)),
                pathOnlyConfidence: \(confidence(entry.confidenceWhenUnsigned))
            ),

    """
    }

    output += """
        ]
    }

    """

    return output
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw GeneratorError.usage
    }

    let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let yaml = try String(contentsOf: inputURL, encoding: .utf8)
    let entries = try parseRegistry(yaml)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try render(entries: entries).write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
