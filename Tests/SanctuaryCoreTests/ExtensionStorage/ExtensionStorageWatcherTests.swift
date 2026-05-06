// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ExtensionStorageWatcherTests {
    @Test func mockBackendCallbackFiresInsideProtectedPath() throws {
        let backend = MockFSEventsBackend()
        let root = "/tmp/protected"
        let watcher = ExtensionStorageWatcher(protectedPaths: [root], backend: backend)
        let received = LockedBox<[ExtensionStorageEvent]>([])
        try watcher.start { event in
            received.set(received.get() + [event])
        }

        backend.emit(.init(path: "/tmp/protected/file.txt", flags: 1))

        #expect(received.get().map(\.path) == ["/tmp/protected/file.txt"])
    }

    @Test func mockBackendCallbackIgnoresOutsideProtectedPath() throws {
        let backend = MockFSEventsBackend()
        let watcher = ExtensionStorageWatcher(protectedPaths: ["/tmp/protected"], backend: backend)
        let received = LockedBox<[ExtensionStorageEvent]>([])
        try watcher.start { event in
            received.set(received.get() + [event])
        }

        backend.emit(.init(path: "/tmp/other/file.txt", flags: 1))

        #expect(received.get().isEmpty)
    }

    @Test func stopUnsubscribesMockStream() throws {
        let backend = MockFSEventsBackend()
        let watcher = ExtensionStorageWatcher(protectedPaths: ["/tmp/protected"], backend: backend)
        try watcher.start { _ in }

        watcher.stop()

        #expect(backend.handle?.isStopped == true)
        #expect(!watcher.isRunning)
    }

    @Test func updateProtectedPathsRestartsRunningWatcher() throws {
        let backend = MockFSEventsBackend()
        let watcher = ExtensionStorageWatcher(protectedPaths: ["/tmp/old"], backend: backend)
        let received = LockedBox<[String]>([])
        try watcher.start { event in
            received.set(received.get() + [event.path])
        }

        try watcher.updateProtectedPaths(["/tmp/new"])
        backend.emit(.init(path: "/tmp/old/file", flags: 1))
        backend.emit(.init(path: "/tmp/new/file", flags: 1))

        #expect(received.get() == ["/tmp/new/file"])
    }

    @Test func doubleStartThrows() throws {
        let watcher = ExtensionStorageWatcher(protectedPaths: ["/tmp/protected"], backend: MockFSEventsBackend())
        try watcher.start { _ in }

        #expect(throws: ExtensionStorageWatcherError.alreadyRunning) {
            try watcher.start { _ in }
        }
    }
}

final class MockFSEventsBackend: FSEventsBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (ExtensionStorageEvent) -> Void)?
    private(set) var handle: MockFSEventsHandle?

    func start(
        paths: [String],
        latency: TimeInterval,
        callback: @escaping @Sendable (ExtensionStorageEvent) -> Void
    ) throws -> any FSEventsStreamHandle {
        let handle = MockFSEventsHandle()
        lock.withLock {
            self.callback = callback
            self.handle = handle
        }
        return handle
    }

    func emit(_ event: ExtensionStorageEvent) {
        lock.withLock { callback }?(event)
    }
}

final class MockFSEventsHandle: FSEventsStreamHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        lock.withLock {
            stopped = true
        }
    }
}
