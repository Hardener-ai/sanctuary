// SPDX-License-Identifier: AGPL-3.0-only
// macOS' default /etc/pf.conf already evaluates anchors under com.apple/* for
// rdr and filter phases. Sanctuary uses com.apple/250.SanctuaryRedirect so CDP
// redirects become active without editing /etc/pf.conf. Each redirect may emit
// a preceding no-rdr rule for the proxy's upstream source-port range; this
// prevents proxy-to-Chrome traffic from being redirected back into the proxy.
// The anchor rules still live in Sanctuary-owned files under /etc/pf.anchors,
// and install/uninstall is idempotent: load or flush only our chosen anchor,
// then remove only our file.
import Darwin
import Foundation

public enum PFError: Error, Equatable, Sendable, CustomStringConvertible {
    case notRoot
    case cannotEnable(String)
    case commandFailed(command: String, arguments: [String], stderr: String)
    case cannotWriteAnchor(String)
    case cannotSetAnchorPermissions(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .notRoot:
            return "pf anchor installation requires root"
        case let .cannotEnable(stderr):
            return "cannot enable pf: \(stderr)"
        case let .commandFailed(command, arguments, stderr):
            return "\(command) \(arguments.joined(separator: " ")) failed: \(stderr)"
        case let .cannotWriteAnchor(reason):
            return "cannot write pf anchor: \(reason)"
        case let .cannotSetAnchorPermissions(reason):
            return "cannot set pf anchor permissions: \(reason)"
        case let .verificationFailed(reason):
            return "pf anchor verification failed: \(reason)"
        }
    }
}

public protocol PFAnchorManaging: Sendable {
    func ensurePFEnabled() throws
    func reloadSystemConfiguration() throws
    func install(redirects: [PFAnchorManager.Redirect]) throws
    func uninstall() throws
    var isInstalled: Bool { get }
}

public extension PFAnchorManaging {
    func reloadSystemConfiguration() throws {}
}

public final class PFAnchorManager: PFAnchorManaging, @unchecked Sendable {
    public static let defaultAnchorName = "com.apple/250.SanctuaryRedirect"

    public struct Redirect: Equatable, Hashable, Sendable {
        public let fromPort: UInt16
        public let toPort: UInt16
        public let bypassSourcePortRange: ClosedRange<UInt16>?

        public init(
            fromPort: UInt16,
            toPort: UInt16,
            bypassSourcePort: UInt16? = nil,
            bypassSourcePortRange: ClosedRange<UInt16>? = nil
        ) {
            self.fromPort = fromPort
            self.toPort = toPort
            if let bypassSourcePortRange {
                self.bypassSourcePortRange = bypassSourcePortRange
            } else if let bypassSourcePort {
                self.bypassSourcePortRange = bypassSourcePort...bypassSourcePort
            } else {
                self.bypassSourcePortRange = nil
            }
        }
    }

    private let anchorName: String
    private let pfctlPath: String
    private let anchorPath: URL
    private let commandRunner: any CommandRunning
    private let fileManager: FileManager
    private let effectiveUserID: @Sendable () -> uid_t
    private let lock = NSLock()
    private var installed = false

    public var isInstalled: Bool {
        lock.withLock { installed }
    }

    public init(anchorName: String = PFAnchorManager.defaultAnchorName) {
        self.anchorName = anchorName
        self.pfctlPath = "/sbin/pfctl"
        self.anchorPath = URL(fileURLWithPath: "/etc/pf.anchors/\(Self.anchorFileName(for: anchorName))")
        self.commandRunner = ProcessCommandRunner()
        self.fileManager = .default
        self.effectiveUserID = { currentEffectiveUserID() }
    }

    init(
        anchorName: String = PFAnchorManager.defaultAnchorName,
        pfctlPath: String = "/sbin/pfctl",
        anchorPath: URL,
        commandRunner: any CommandRunning,
        fileManager: FileManager = .default,
        effectiveUserID: @escaping @Sendable () -> uid_t = { currentEffectiveUserID() }
    ) {
        self.anchorName = anchorName
        self.pfctlPath = pfctlPath
        self.anchorPath = anchorPath
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.effectiveUserID = effectiveUserID
    }

    public func ensurePFEnabled() throws {
        let info = try runPFCTL(arguments: ["-s", "info"])
        logWarnings(info.stderr)

        switch Self.parsePFStatus(stdout: info.stdout, stderr: info.stderr) {
        case .enabled:
            return
        case .disabled:
            let enabled = try runPFCTL(arguments: ["-e"])
            logWarnings(enabled.stderr)
        case .unknown:
            return
        }
    }

    public func reloadSystemConfiguration() throws {
        let result = try runPFCTL(arguments: ["-f", "/etc/pf.conf"])
        logWarnings(result.stderr)
    }

    public func install(redirects: [Redirect]) throws {
        guard effectiveUserID() == 0 else {
            throw PFError.notRoot
        }

        let content = Self.generateRulesFile(redirects: redirects)
        try writeAnchorAtomically(content)
        try setAnchorOwnershipAndPermissions()
        _ = try runPFCTL(arguments: ["-a", anchorName, "-f", anchorPath.path])

        lock.withLock {
            installed = true
        }
    }

    public func uninstall() throws {
        _ = try runPFCTL(arguments: ["-a", anchorName, "-F", "all"])
        if fileManager.fileExists(atPath: anchorPath.path) {
            do {
                try fileManager.removeItem(at: anchorPath)
            } catch {
                throw PFError.cannotWriteAnchor(error.localizedDescription)
            }
        }

        lock.withLock {
            installed = false
        }
    }

    public static func generateRulesFile(redirects: [Redirect]) -> String {
        redirects
            .sorted { lhs, rhs in
                lhs.fromPort == rhs.fromPort ? lhs.toPort < rhs.toPort : lhs.fromPort < rhs.fromPort
            }
            .flatMap { redirect -> [String] in
                var lines: [String] = []
                if let bypassSourcePortRange = redirect.bypassSourcePortRange {
                    lines.append("no rdr on lo0 inet proto tcp from 127.0.0.1 port \(Self.portSpec(for: bypassSourcePortRange)) to 127.0.0.1 port \(redirect.fromPort)")
                }
                lines.append("rdr on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port \(redirect.fromPort) -> 127.0.0.1 port \(redirect.toPort)")
                return lines
            }
            .joined(separator: "\n")
            .appending(redirects.isEmpty ? "" : "\n")
    }

    static func portSpec(for range: ClosedRange<UInt16>) -> String {
        range.lowerBound == range.upperBound ? "\(range.lowerBound)" : "\(range.lowerBound):\(range.upperBound)"
    }

    public enum PFStatus: Equatable, Sendable {
        case enabled
        case disabled
        case unknown
    }

    public static func parsePFStatus(stdout: String, stderr: String = "") -> PFStatus {
        let output = "\(stdout)\n\(stderr)"
        if output.range(of: "Status:\\s*Enabled", options: [.regularExpression, .caseInsensitive]) != nil {
            return .enabled
        }
        if output.range(of: "Status:\\s*Disabled", options: [.regularExpression, .caseInsensitive]) != nil {
            return .disabled
        }
        return .unknown
    }

    static func anchorFileName(for anchorName: String) -> String {
        anchorName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\"", with: "")
    }

    private func writeAnchorAtomically(_ content: String) throws {
        let tempURL = anchorPath.deletingLastPathComponent()
            .appendingPathComponent(".\(anchorPath.lastPathComponent).tmp.\(UUID().uuidString)")

        do {
            try Data(content.utf8).write(to: tempURL, options: [.withoutOverwriting])
            if fileManager.fileExists(atPath: anchorPath.path) {
                try fileManager.removeItem(at: anchorPath)
            }
            try fileManager.moveItem(at: tempURL, to: anchorPath)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw PFError.cannotWriteAnchor(error.localizedDescription)
        }
    }

    private func setAnchorOwnershipAndPermissions() throws {
        do {
            try fileManager.setAttributes(
                [
                    .ownerAccountID: NSNumber(value: 0),
                    .groupOwnerAccountID: NSNumber(value: 0),
                    .posixPermissions: NSNumber(value: 0o644)
                ],
                ofItemAtPath: anchorPath.path
            )
        } catch {
            throw PFError.cannotSetAnchorPermissions(error.localizedDescription)
        }
    }

    private func logWarnings(_ stderr: String) {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            debugPrint("pfctl warnings: \(trimmed)")
        }
    }

    private func runPFCTL(arguments: [String]) throws -> CommandResult {
        let result = try commandRunner.run(executable: pfctlPath, arguments: arguments)
        guard result.exitCode == 0 else {
            throw PFError.commandFailed(command: pfctlPath, arguments: arguments, stderr: result.stderr)
        }
        return result
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) throws -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(executable: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
