// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum AgentRegistryYAMLParser {
    public static func parseKnownAgents(from yaml: String) throws -> [KnownAgent] {
        var entries: [KnownAgent] = []
        var current = MutableEntry()
        var hasCurrent = false
        var runtimeSection = false

        func finishCurrent() {
            guard hasCurrent else {
                return
            }

            entries.append(current.knownAgent)
        }

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.hasPrefix("- id:") {
                finishCurrent()
                current = MutableEntry()
                hasCurrent = true
                runtimeSection = false
                current.id = String(trimmed.dropFirst("- id:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard hasCurrent, let separator = trimmed.firstIndex(of: ":") else {
                continue
            }

            if trimmed == "runtime_fingerprint:" {
                runtimeSection = true
                continue
            }

            let key = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)

            switch (runtimeSection, key) {
            case (_, "friendly_name"):
                current.friendlyName = unquote(value)
            case (_, "category"):
                current.category = value
            case (_, "executable_names"):
                current.executableNames = parseFlowArray(value)
            case (_, "bundle_identifiers"):
                current.bundleIdentifiers = parseFlowArray(value)
            case (_, "team_identifiers"):
                current.teamIdentifiers = parseFlowArray(value)
            case (_, "code_signing_identifiers"):
                current.codeSigningIdentifiers = parseFlowArray(value)
            case (_, "install_paths"):
                runtimeSection = false
                current.installPaths = parseFlowArray(value)
            case (true, "python_modules"):
                current.pythonModules = parseFlowArray(value)
            case (true, "node_packages"):
                current.nodePackages = parseFlowArray(value)
            case (_, "launchd_plist_patterns"):
                runtimeSection = false
                current.launchdPlistPatterns = parseFlowArray(value)
            case (_, "confidence_when_signed"):
                runtimeSection = false
                current.signedConfidence = confidence(value)
            case (_, "confidence_when_unsigned"):
                runtimeSection = false
                current.unsignedConfidence = confidence(value)
            default:
                break
            }
        }

        finishCurrent()
        return entries
    }

    private static func parseFlowArray(_ value: String) -> Set<String> {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return []
        }

        let body = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if body.isEmpty {
            return []
        }

        return Set(body.split(separator: ",").compactMap { part in
            let value = unquote(part.trimmingCharacters(in: .whitespacesAndNewlines))
            if value.isEmpty || value == "null" {
                return nil
            }
            return value
        })
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func confidence(_ value: String) -> Confidence {
        switch value {
        case "high":
            return .high
        case "low":
            return .low
        default:
            return .medium
        }
    }

    private struct MutableEntry {
        var id = ""
        var friendlyName = ""
        var category = ""
        var executableNames: Set<String> = []
        var bundleIdentifiers: Set<String> = []
        var teamIdentifiers: Set<String> = []
        var codeSigningIdentifiers: Set<String> = []
        var installPaths: Set<String> = []
        var pythonModules: Set<String> = []
        var nodePackages: Set<String> = []
        var launchdPlistPatterns: Set<String> = []
        var signedConfidence: Confidence = .high
        var unsignedConfidence: Confidence = .medium

        var knownAgent: KnownAgent {
            KnownAgent(
                id: id,
                displayName: friendlyName,
                category: category,
                executableNames: executableNames,
                bundleIdentifiers: bundleIdentifiers,
                codeSigningIdentifiers: codeSigningIdentifiers,
                teamIdentifiers: teamIdentifiers,
                pythonModuleMarkers: pythonModules,
                nodePackageMarkers: nodePackages,
                launchdPlistPatterns: launchdPlistPatterns,
                installPaths: installPaths,
                signedConfidence: signedConfidence,
                pathOnlyConfidence: unsignedConfidence
            )
        }
    }
}
