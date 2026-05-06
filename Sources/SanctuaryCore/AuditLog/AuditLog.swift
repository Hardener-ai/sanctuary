// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import OSLog

public struct AuditEntry: Codable, Equatable, Sendable {
    public struct Attribution: Codable, Equatable, Sendable {
        public let level: String
        public let pid: Int32?
        public let processPath: String?
        public let agentPids: [Int32]

        public init(level: String, pid: Int32?, processPath: String?, agentPids: [Int32]) {
            self.level = level
            self.pid = pid
            self.processPath = processPath
            self.agentPids = agentPids
        }
    }

    public struct Process: Codable, Equatable, Sendable {
        public let pid: Int32
        public let path: String
        public let signingID: String?

        public init(pid: Int32, path: String, signingID: String?) {
            self.pid = pid
            self.path = path
            self.signingID = signingID
        }

        public init(identity: ProcessIdentity) {
            self.init(
                pid: identity.pid,
                path: identity.executablePath,
                signingID: identity.codeSigningIdentifier
            )
        }
    }

    public let ts: String
    public let kind: String
    public let action: String
    public let attribution: Attribution?
    public let policy: String?
    public let path: String?
    public let flags: UInt32?
    public let process: Process?
    public let profilePath: String?
    public let resource: String?
    public let prevHash: String?

    public init(
        ts: String,
        kind: String,
        action: String,
        attribution: Attribution? = nil,
        policy: String? = nil,
        path: String? = nil,
        flags: UInt32? = nil,
        process: Process? = nil,
        profilePath: String? = nil,
        resource: String? = nil,
        prevHash: String? = nil
    ) {
        self.ts = ts
        self.kind = kind
        self.action = action
        self.attribution = attribution
        self.policy = policy
        self.path = path
        self.flags = flags
        self.process = process
        self.profilePath = profilePath
        self.resource = resource
        self.prevHash = prevHash
    }
}

public enum VerificationFailure: Equatable, Sendable, CustomStringConvertible {
    case signatureFailure
    case hashChainBreak
    case entryParseFailure
    case missingEntry

    public var description: String {
        switch self {
        case .signatureFailure:
            return "signature verification failed"
        case .hashChainBreak:
            return "hash chain broken"
        case .entryParseFailure:
            return "entry parse failed"
        case .missingEntry:
            return "missing entry"
        }
    }
}

public enum VerificationResult: Equatable, Sendable {
    case valid(entryCount: Int)
    case invalid(reason: VerificationFailure, entryIndex: Int)

    public var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }

    public var totalEntries: Int {
        switch self {
        case let .valid(entryCount):
            return entryCount
        case let .invalid(_, entryIndex):
            return max(0, entryIndex - 1)
        }
    }

    public var failure: VerificationFailure? {
        if case let .invalid(reason, _) = self {
            return reason
        }
        return nil
    }
}

public enum AuditLogError: Error, CustomStringConvertible {
    case cannotOpen(String, Int32)
    case shortWrite(expected: Int, actual: Int)
    case fsyncFailed(Int32)
    case malformedLine

    public var description: String {
        switch self {
        case let .cannotOpen(path, errnoValue):
            return "cannot open audit log \(path): errno \(errnoValue)"
        case let .shortWrite(expected, actual):
            return "short audit log write: expected \(expected), wrote \(actual)"
        case let .fsyncFailed(errnoValue):
            return "audit log fsync failed: errno \(errnoValue)"
        case .malformedLine:
            return "malformed audit log line"
        }
    }
}

public final class AuditLog: ExtensionAuditLogging, @unchecked Sendable {
    public static var defaultPath: String { SanctuaryPaths.auditLogPath() }
    public static let defaultRotationSizeBytes: UInt64 = 100 * 1024 * 1024
    public static let genesisPrevHash = String(repeating: "0", count: 64)
    private static let logger = Logger(subsystem: "ai.hardener.sanctuary.cli", category: "audit")

    private let path: String
    private let keychainAccount: String
    private let signingKeyProvider: any AuditSigningKeyProviding
    private let rotationSizeBytes: UInt64
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let appendLock = NSLock()

    public init(
        path: String = AuditLog.defaultPath,
        keychainAccount: String = "sanctuary.audit-signing"
    ) {
        self.path = path
        self.keychainAccount = keychainAccount
        self.signingKeyProvider = AuditSigningKeyProviderFactory.defaultProvider()
        self.rotationSizeBytes = Self.defaultRotationSizeBytes
        self.fileManager = .default
        self.encoder = Self.makeEncoder()
    }

    public init(
        path: String,
        keychainAccount: String = "sanctuary.audit-signing",
        signingKeyProvider: any AuditSigningKeyProviding,
        rotationSizeBytes: UInt64 = AuditLog.defaultRotationSizeBytes,
        fileManager: FileManager = .default
    ) {
        self.path = path
        self.keychainAccount = keychainAccount
        self.signingKeyProvider = signingKeyProvider
        self.rotationSizeBytes = rotationSizeBytes
        self.fileManager = fileManager
        self.encoder = Self.makeEncoder()
    }

    public func append(_ entry: AuditEntry) throws {
        try appendLock.withLock {
            try rotateIfNeeded()
            let previousHash = try lastSignedEntryHash() ?? Self.genesisPrevHash
            let chainedEntry = entry.withPrevHash(previousHash)
            let entryJSON = try canonicalJSONData(for: chainedEntry)
            let signature = try signingKeyProvider
                .loadOrCreate(keychainAccount: keychainAccount)
                .signature(for: entryJSON)
                .base64EncodedString()
            var line = Data()
            line.append(entryJSON)
            line.append(Data(#","sig":""#.utf8))
            line.append(Data(signature.utf8))
            line.append(Data(#"""#.utf8))
            line.append(Data("\n".utf8))

            let url = URL(fileURLWithPath: path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                throw AuditLogError.cannotOpen(path, errno)
            }
            defer { Darwin.close(fd) }

            let written = line.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return Darwin.write(fd, baseAddress, buffer.count)
            }
            guard written == line.count else {
                throw AuditLogError.shortWrite(expected: line.count, actual: written)
            }
            guard Darwin.fsync(fd) == 0 else {
                throw AuditLogError.fsyncFailed(errno)
            }
        }
    }

    public func rotateIfNeeded() throws {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value > rotationSizeBytes
        else {
            return
        }

        for generation in stride(from: 5, through: 1, by: -1) {
            let current = rotatedPath(generation)
            if generation == 5 {
                if fileManager.fileExists(atPath: current) {
                    try fileManager.removeItem(atPath: current)
                }
                continue
            }

            let next = rotatedPath(generation + 1)
            if fileManager.fileExists(atPath: next) {
                try fileManager.removeItem(atPath: next)
            }
            if fileManager.fileExists(atPath: current) {
                try fileManager.moveItem(atPath: current, toPath: next)
            }
        }

        let first = rotatedPath(1)
        if fileManager.fileExists(atPath: first) {
            try fileManager.removeItem(atPath: first)
        }
        if fileManager.fileExists(atPath: path) {
            try fileManager.moveItem(atPath: path, toPath: first)
        }
    }

    public func verify() throws -> VerificationResult {
        try Self.verify(path: path, publicKeyData: signingKeyProvider.publicKeyData(keychainAccount: keychainAccount))
    }

    public static func parseSignedLine(_ line: String) -> (entryJSON: Data, signature: String)? {
        guard line.hasSuffix(#"""#),
              let range = line.range(of: #","sig":""#, options: .backwards)
        else {
            return nil
        }

        let json = String(line[..<range.lowerBound])
        let signatureStart = range.upperBound
        let signatureEnd = line.index(before: line.endIndex)
        guard signatureStart <= signatureEnd else {
            return nil
        }

        return (Data(json.utf8), String(line[signatureStart..<signatureEnd]))
    }

    public static func verify(path: String, publicKeyData: Data) throws -> VerificationResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .valid(entryCount: 0)
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let contents = String(data: data, encoding: .utf8), !contents.isEmpty else {
            return .valid(entryCount: 0)
        }
        let rawLines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        var previousHash: String?
        var hashChainStarted = false
        var entryCount = 0

        for (index, rawLine) in rawLines.enumerated() {
            if rawLine.isEmpty && index == rawLines.count - 1 {
                continue
            }

            entryCount += 1
            let line = String(rawLine)
            guard let parsed = Self.parseSignedLine(line),
                  let signature = Data(base64Encoded: parsed.signature),
                  let entry = try? JSONDecoder().decode(AuditEntry.self, from: parsed.entryJSON)
            else {
                return .invalid(reason: .entryParseFailure, entryIndex: entryCount)
            }

            guard publicKey.isValidSignature(signature, for: parsed.entryJSON) else {
                return .invalid(reason: .signatureFailure, entryIndex: entryCount)
            }

            if let prevHash = entry.prevHash {
                hashChainStarted = true
                let expected = previousHash ?? Self.genesisPrevHash
                guard prevHash == expected else {
                    return .invalid(reason: .hashChainBreak, entryIndex: entryCount)
                }
            } else if hashChainStarted {
                return .invalid(reason: .hashChainBreak, entryIndex: entryCount)
            }

            guard let signedHash = try? signedEntryHash(entryJSON: parsed.entryJSON, signature: parsed.signature) else {
                return .invalid(reason: .entryParseFailure, entryIndex: entryCount)
            }
            previousHash = signedHash
        }

        return .valid(entryCount: entryCount)
    }

    public static func signedEntryHash(entryJSON: Data, signature: String) throws -> String {
        let canonical = try canonicalSignedEntryJSON(entryJSON: entryJSON, signature: signature)
        let digest = SHA256.hash(data: canonical)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalSignedEntryJSON(entryJSON: Data, signature: String) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: entryJSON) as? [String: Any] else {
            throw AuditLogError.malformedLine
        }
        object["sig"] = signature
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public func recoverFromTamperingIfNeeded() throws {
        let result = try verify()
        guard case let .invalid(reason, entryIndex) = result else {
            return
        }

        let originalPath = path
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let timestamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let tamperedPath = "\(originalPath).tampered.\(timestamp)"
        let priorHash = try fileManager.fileExists(atPath: originalPath)
            ? Self.fileSHA256Hex(path: originalPath)
            : Self.genesisPrevHash

        Self.logger.error("Audit log verification failed at entry \(entryIndex): \(String(describing: reason), privacy: .public). Rotating to \(tamperedPath, privacy: .public)")
        fputs(
            "sanctuaryd audit log verification failed at entry \(entryIndex): \(reason). Rotating to \(tamperedPath)\n",
            stderr
        )

        if fileManager.fileExists(atPath: tamperedPath) {
            try fileManager.removeItem(atPath: tamperedPath)
        }
        if fileManager.fileExists(atPath: originalPath) {
            try fileManager.moveItem(atPath: originalPath, toPath: tamperedPath)
        }

        try append(
            AuditEntry(
                ts: formatter.string(from: now),
                kind: "tamper",
                action: "TAMPER_DETECTED",
                policy: "audit_log",
                path: tamperedPath,
                resource: "prior_sha256=\(priorHash); failure=\(reason); entry=\(entryIndex)"
            )
        )
    }

    private func canonicalJSONData(for entry: AuditEntry) throws -> Data {
        try encoder.encode(entry)
    }

    private func lastSignedEntryHash() throws -> String? {
        guard fileManager.fileExists(atPath: path) else {
            return nil
        }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        guard let lastLine = contents.split(separator: "\n", omittingEmptySubsequences: true).last,
              let parsed = Self.parseSignedLine(String(lastLine))
        else {
            return nil
        }
        return try Self.signedEntryHash(entryJSON: parsed.entryJSON, signature: parsed.signature)
    }

    private func rotatedPath(_ generation: Int) -> String {
        "\(path).\(generation)"
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func fileSHA256Hex(path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct NoopAuditLogger: ExtensionAuditLogging {
    public init() {}

    public func append(_ entry: AuditEntry) throws {}
}

private extension AuditEntry {
    func withPrevHash(_ prevHash: String) -> AuditEntry {
        AuditEntry(
            ts: ts,
            kind: kind,
            action: action,
            attribution: attribution,
            policy: policy,
            path: path,
            flags: flags,
            process: process,
            profilePath: profilePath,
            resource: resource,
            prevHash: prevHash
        )
    }
}
