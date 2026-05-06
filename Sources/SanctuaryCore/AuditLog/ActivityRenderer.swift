// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct ActivityEntry: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let relativeTimeText: String
    public let summaryText: String
    public let attributionText: String
    public let isDenial: Bool

    public init(
        timestamp: Date,
        relativeTimeText: String,
        summaryText: String,
        attributionText: String,
        isDenial: Bool
    ) {
        self.timestamp = timestamp
        self.relativeTimeText = relativeTimeText
        self.summaryText = summaryText
        self.attributionText = attributionText
        self.isDenial = isDenial
    }
}

public enum ActivityRenderer {
    public static func summarize(_ entry: AuditEntry) -> ActivityEntry {
        summarize(entry, now: Date())
    }

    public static func summarize(_ entry: AuditEntry, now: Date) -> ActivityEntry {
        let timestamp = parseTimestamp(entry.ts) ?? now
        let denied = isDenial(entry)
        return ActivityEntry(
            timestamp: timestamp,
            relativeTimeText: relativeTime(from: timestamp, to: now),
            summaryText: summary(for: entry),
            attributionText: attributionText(for: entry, isDenial: denied),
            isDenial: denied
        )
    }

    public static func shouldRender(_ entry: AuditEntry) -> Bool {
        switch entry.action {
        case "DETECT_ALERT", "DENY", "DENY_READ", "FAIL_CLOSED", "TAMPER_DETECTED":
            return true
        default:
            return false
        }
    }

    public static func relativeTime(from timestamp: Date, to now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(timestamp)))
        if seconds < 60 {
            return "just now"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    private static func summary(for entry: AuditEntry) -> String {
        let agent = agentName(for: entry)
        switch entry.policy {
        case "protected_folder":
            return "\(agent) accessed \(folderDisplayName(entry.path))"
        case "protected_extension_storage":
            return "\(agent) tried to read \(extensionDisplayName(entry))"
        case "cdp_guard":
            return "\(agent) tried to attach to \(browserDisplayName(entry.profilePath))"
        case "cdp_guard_pf":
            return "Sanctuary detected CDP rule tampering"
        case "peer_monitor":
            return "Sanctuary detected daemon peer tampering"
        default:
            return "\(agent) triggered Sanctuary"
        }
    }

    private static func folderDisplayName(_ path: String?) -> String {
        guard let path else {
            return "a protected folder"
        }
        let normalized = ExtensionPathMaterializer.normalize(path)
        if isSensitiveFolder(".ssh", in: normalized) {
            return "~/.ssh"
        }
        if isSensitiveFolder(".aws", in: normalized) {
            return "~/.aws"
        }
        return DefaultSensitivePaths.displayPath(normalized)
    }

    private static func isSensitiveFolder(_ name: String, in path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.contains(name)
    }

    private static func extensionDisplayName(_ entry: AuditEntry) -> String {
        for candidate in [entry.resource, entry.path].compactMap({ $0 }) {
            if let name = extensionName(in: candidate) {
                return name
            }
        }
        return "extension storage"
    }

    private static func extensionName(in path: String) -> String? {
        let lowercase = path.lowercased()
        for extensionID in KnownExtensions.all.flatMap(\.extensionIDs) {
            if lowercase.contains(extensionID), let display = KnownExtensions.displayName(for: extensionID) {
                return display
            }
        }
        return nil
    }

    private static func browserDisplayName(_ profilePath: String?) -> String {
        guard let profilePath else {
            return "the browser"
        }
        let path = profilePath.lowercased()
        if path.contains("/bravesoftware/brave-browser/") {
            return "Brave"
        }
        if path.contains("/google/chrome/") {
            return "Chrome"
        }
        if path.contains("/arc/user data/") {
            return "Arc"
        }
        if path.contains("/microsoft edge/") {
            return "Edge"
        }
        if path.contains("/vivaldi/") {
            return "Vivaldi"
        }
        if path.contains("/com.operasoftware.opera") {
            return "Opera"
        }
        return "the browser"
    }

    private static func agentName(for entry: AuditEntry) -> String {
        if let path = entry.attribution?.processPath ?? entry.process?.path {
            return agentName(forProcessPath: path)
        }
        if let pid = entry.attribution?.pid {
            return "Process \(pid)"
        }
        return "Agent"
    }

    private static func agentName(forProcessPath path: String) -> String {
        let basename = URL(fileURLWithPath: path).lastPathComponent
        let normalizedBase = basename.lowercased()

        if let executableMatch = AgentClassifier.knownAgents.first(where: { agent in
            agent.executableNames.contains(normalizedBase)
        }) {
            return executableMatch.displayName
        }

        if let installPathMatch = AgentClassifier.knownAgents.first(where: { agent in
            agent.installPaths.contains { installPath in
                pathMatchesInstallPath(path, installPath: installPath)
            }
        }) {
            return installPathMatch.displayName
        }

        return basename.isEmpty ? "Agent" : basename
    }

    private static func pathMatchesInstallPath(_ path: String, installPath: String) -> Bool {
        let expanded = expandTilde(installPath)
        if expanded.contains("*") {
            return wildcardPath(path, matches: expanded)
        }
        return path == expanded || path.hasPrefix(expanded + "/")
    }

    private static func expandTilde(_ path: String) -> String {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        return path
    }

    private static func wildcardPath(_ path: String, matches pattern: String) -> Bool {
        let pathComponents = URL(fileURLWithPath: path).pathComponents
        let patternComponents = URL(fileURLWithPath: pattern).pathComponents
        guard pathComponents.count >= patternComponents.count else {
            return false
        }

        for (index, patternComponent) in patternComponents.enumerated() {
            if patternComponent == "*" {
                continue
            }
            if patternComponent != pathComponents[index] {
                return false
            }
        }
        return true
    }

    private static func attributionText(for entry: AuditEntry, isDenial: Bool) -> String {
        if isDenial {
            return "Blocked"
        }
        if entry.action == "TAMPER_DETECTED" {
            return "Tamper detected"
        }
        guard let level = entry.attribution?.level, !level.isEmpty else {
            return "Detected"
        }
        return "Detected · \(level)"
    }

    private static func isDenial(_ entry: AuditEntry) -> Bool {
        entry.action == "DENY" || entry.action == "DENY_READ" || entry.action == "FAIL_CLOSED"
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
