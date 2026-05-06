// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

public protocol AuditSigningKeyProviding: Sendable {
    func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey
    func publicKeyData(keychainAccount: String) throws -> Data
}

public protocol CodeSignatureStateProviding: Sendable {
    func currentProcessIsAdHocSigned() -> Bool
}

public enum AuditSigningKeyProviderFactory {
    public static func defaultProvider(
        signatureStateProvider: any CodeSignatureStateProviding = SecCodeSignatureStateProvider(),
        logger: @escaping @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    ) -> any AuditSigningKeyProviding {
        if let devKeyPath = ProcessInfo.processInfo.environment["SANCTUARY_AUDIT_DEV_KEY_PATH"],
           !devKeyPath.isEmpty
        {
            logger("DEV MODE: using file-backed audit signing key for local verification")
            return FileAuditSigningKeyProvider(path: devKeyPath)
        }

        if signatureStateProvider.currentProcessIsAdHocSigned() {
            logger("DEV MODE: using ephemeral signing key; production builds use System keychain")
            return EphemeralAuditSigningKeyProvider.shared
        }
        return KeychainAuditSigningKeyProvider()
    }
}

public enum AuditSigningKey {
    // Bundle IDs migrated from app.sanctuary.* (early dev) to
    // ai.hardener.sanctuary.* (production, matches owned domain hardener.ai).
    // Sanctuary is the product; Hardener is the company. Old dev keychain
    // entries under app.sanctuary.* are orphaned but harmless.
    public static let keychainService = "ai.hardener.sanctuary.cli"

    public static func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        try loadOrCreate(keychainAccount: keychainAccount, backend: SecItemGenericPasswordStore())
    }

    public static func publicKeyData(keychainAccount: String) throws -> Data {
        try publicKeyData(keychainAccount: keychainAccount, backend: SecItemGenericPasswordStore())
    }

    public static func loadOrCreate(
        keychainAccount: String,
        backend: any KeychainGenericPasswordStoring
    ) throws -> Curve25519.Signing.PrivateKey {
        if let existing = try backend.read(service: keychainService, account: keychainAccount) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: existing)
        }

        let key = Curve25519.Signing.PrivateKey()
        try backend.write(key.rawRepresentation, service: keychainService, account: keychainAccount)
        return key
    }

    public static func publicKeyData(
        keychainAccount: String,
        backend: any KeychainGenericPasswordStoring
    ) throws -> Data {
        try loadOrCreate(keychainAccount: keychainAccount, backend: backend).publicKey.rawRepresentation
    }
}

public struct KeychainAuditSigningKeyProvider: AuditSigningKeyProviding {
    private let primary: any KeychainGenericPasswordStoring
    private let fallback: (any KeychainGenericPasswordStoring)?

    public init() {
        self.primary = SecItemGenericPasswordStore()
        self.fallback = nil
    }

    public init(
        primary: any KeychainGenericPasswordStoring,
        fallback: (any KeychainGenericPasswordStoring)? = DefaultKeychainGenericPasswordStore()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        do {
            return try AuditSigningKey.loadOrCreate(keychainAccount: keychainAccount, backend: primary)
        } catch {
            guard let fallback else {
                throw error
            }
            return try AuditSigningKey.loadOrCreate(keychainAccount: keychainAccount, backend: fallback)
        }
    }

    public func publicKeyData(keychainAccount: String) throws -> Data {
        do {
            return try AuditSigningKey.publicKeyData(keychainAccount: keychainAccount, backend: primary)
        } catch {
            guard let fallback else {
                throw error
            }
            return try AuditSigningKey.publicKeyData(keychainAccount: keychainAccount, backend: fallback)
        }
    }
}

public final class EphemeralAuditSigningKeyProvider: AuditSigningKeyProviding, @unchecked Sendable {
    public static let shared = EphemeralAuditSigningKeyProvider()

    private let lock = NSLock()
    private var keys: [String: Curve25519.Signing.PrivateKey] = [:]

    private init() {}

    public func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        lock.withLock {
            if let existing = keys[keychainAccount] {
                return existing
            }
            let key = Curve25519.Signing.PrivateKey()
            keys[keychainAccount] = key
            return key
        }
    }

    public func publicKeyData(keychainAccount: String) throws -> Data {
        try loadOrCreate(keychainAccount: keychainAccount).publicKey.rawRepresentation
    }
}

public final class FileAuditSigningKeyProvider: AuditSigningKeyProviding, @unchecked Sendable {
    private let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        try lock.withLock {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count == 32 {
                return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            }

            let key = Curve25519.Signing.PrivateKey()
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try key.rawRepresentation.write(to: url, options: [.atomic])
            chmod(path, S_IRUSR | S_IWUSR)
            return key
        }
    }

    public func publicKeyData(keychainAccount: String) throws -> Data {
        try loadOrCreate(keychainAccount: keychainAccount).publicKey.rawRepresentation
    }
}

public protocol KeychainGenericPasswordStoring: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
}

public enum AuditSigningKeyError: Error, CustomStringConvertible {
    case keychainRead(OSStatus)
    case keychainWrite(OSStatus)

    public var description: String {
        switch self {
        case let .keychainRead(status):
            return "keychain read failed: \(status)"
        case let .keychainWrite(status):
            return "keychain write failed: \(status)"
        }
    }
}

public struct SecCodeSignatureStateProvider: CodeSignatureStateProviding {
    private static let adHocSignatureFlag: UInt32 = 0x0002

    public init() {}

    public func currentProcessIsAdHocSigned() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return false
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let rawFlags = dictionary[kSecCodeInfoFlags as String] as? NSNumber
        else {
            return false
        }

        return rawFlags.uint32Value & Self.adHocSignatureFlag != 0
    }
}

public struct SecItemGenericPasswordStore: KeychainGenericPasswordStoring {
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuditSigningKeyError.keychainRead(status)
        }
        return result as? Data
    }

    public func write(_ data: Data, service: String, account: String) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let lookup = baseQuery(service: service, account: account)
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AuditSigningKeyError.keychainWrite(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw AuditSigningKeyError.keychainWrite(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context
        ]
        return query
    }
}

public typealias DefaultKeychainGenericPasswordStore = SecItemGenericPasswordStore
public typealias SystemKeychainGenericPasswordStore = SecItemGenericPasswordStore
