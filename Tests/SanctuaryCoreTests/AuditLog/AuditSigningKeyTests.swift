// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Security
import Testing
@testable import SanctuaryCore

struct AuditSigningKeyTests {
    @Test func firstCallGeneratesAndStoresKey() throws {
        let backend = MemoryKeychainStore()

        let key = try AuditSigningKey.loadOrCreate(keychainAccount: "audit", backend: backend)

        #expect(backend.storedData(service: AuditSigningKey.keychainService, account: "audit") == key.rawRepresentation)
    }

    @Test func secondCallRetrievesSameKey() throws {
        let backend = MemoryKeychainStore()
        let first = try AuditSigningKey.loadOrCreate(keychainAccount: "audit", backend: backend)
        let second = try AuditSigningKey.loadOrCreate(keychainAccount: "audit", backend: backend)

        #expect(first.rawRepresentation == second.rawRepresentation)
    }

    @Test func publicKeyDerivationMatchesPrivateKey() throws {
        let backend = MemoryKeychainStore()
        let privateKey = try AuditSigningKey.loadOrCreate(keychainAccount: "audit", backend: backend)
        let publicKey = try AuditSigningKey.publicKeyData(keychainAccount: "audit", backend: backend)

        #expect(publicKey == privateKey.publicKey.rawRepresentation)
    }

    @Test func keychainProviderFallsBackWhenSystemKeychainIsUnavailable() throws {
        let fallback = MemoryKeychainStore()
        let provider = KeychainAuditSigningKeyProvider(
            primary: FailingKeychainStore(),
            fallback: fallback
        )

        let key = try provider.loadOrCreate(keychainAccount: "audit")

        #expect(fallback.storedData(service: AuditSigningKey.keychainService, account: "audit") == key.rawRepresentation)
        #expect(try provider.publicKeyData(keychainAccount: "audit") == key.publicKey.rawRepresentation)
    }

    @Test func ephemeralProviderKeepsStableKeyInCurrentProcessOnly() throws {
        let provider = EphemeralAuditSigningKeyProvider.shared
        let firstAccount = "audit-test-\(UUID().uuidString)"

        let first = try provider.loadOrCreate(keychainAccount: firstAccount)
        let second = try provider.loadOrCreate(keychainAccount: "audit-test-\(UUID().uuidString)")
        let firstAgain = try provider.loadOrCreate(keychainAccount: firstAccount)

        #expect(first.rawRepresentation != second.rawRepresentation)
        #expect(first.rawRepresentation == firstAgain.rawRepresentation)
    }

    @Test func fileProviderPersistsKeyAcrossProviderInstances() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanctuary-file-audit-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("audit-signing.key").path
        let firstProvider = FileAuditSigningKeyProvider(path: path)
        let secondProvider = FileAuditSigningKeyProvider(path: path)

        let first = try firstProvider.loadOrCreate(keychainAccount: "ignored")
        let second = try secondProvider.loadOrCreate(keychainAccount: "ignored")

        #expect(first.rawRepresentation == second.rawRepresentation)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).count == 32)
    }

    @Test func secItemBasedProviderStoresWithModernServiceName() throws {
        let backend = MemoryKeychainStore()
        let provider = KeychainAuditSigningKeyProvider(primary: backend, fallback: nil)

        let key = try provider.loadOrCreate(keychainAccount: "audit-modern")

        #expect(backend.storedData(service: "ai.hardener.sanctuary.cli", account: "audit-modern") == key.rawRepresentation)
    }

    @Test func adHocSignatureUsesEphemeralProviderAndLogsDevMode() throws {
        let logs = LogRecorder()
        let provider = AuditSigningKeyProviderFactory.defaultProvider(
            signatureStateProvider: MockCodeSignatureStateProvider(adHoc: true),
            logger: { logs.append($0) }
        )

        let first = try provider.loadOrCreate(keychainAccount: "adhoc-\(UUID().uuidString)")
        let second = try provider.loadOrCreate(keychainAccount: "adhoc-\(UUID().uuidString)")

        #expect(first.rawRepresentation != second.rawRepresentation)
        #expect(logs.values == ["DEV MODE: using ephemeral signing key; production builds use System keychain"])
    }

    @Test func nonAdHocSignatureUsesKeychainProviderPath() throws {
        let logs = LogRecorder()
        let provider = AuditSigningKeyProviderFactory.defaultProvider(
            signatureStateProvider: MockCodeSignatureStateProvider(adHoc: false),
            logger: { logs.append($0) }
        )

        #expect(provider is KeychainAuditSigningKeyProvider)
        #expect(logs.values.isEmpty)
    }
}

private final class MemoryKeychainStore: KeychainGenericPasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        lock.withLock {
            storage[key(service: service, account: account)]
        }
    }

    func write(_ data: Data, service: String, account: String) throws {
        lock.withLock {
            storage[key(service: service, account: account)] = data
        }
    }

    func storedData(service: String, account: String) -> Data? {
        lock.withLock {
            storage[key(service: service, account: account)]
        }
    }

    private func key(service: String, account: String) -> String {
        "\(service):\(account)"
    }
}

private struct FailingKeychainStore: KeychainGenericPasswordStoring {
    func read(service: String, account: String) throws -> Data? {
        throw AuditSigningKeyError.keychainRead(errSecNoSuchKeychain)
    }

    func write(_ data: Data, service: String, account: String) throws {
        throw AuditSigningKeyError.keychainWrite(errSecNoSuchKeychain)
    }
}

private struct MockCodeSignatureStateProvider: CodeSignatureStateProviding {
    let adHoc: Bool

    func currentProcessIsAdHocSigned() -> Bool {
        adHoc
    }
}

private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}
