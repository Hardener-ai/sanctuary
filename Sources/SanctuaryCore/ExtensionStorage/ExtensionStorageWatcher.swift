// SPDX-License-Identifier: AGPL-3.0-only
import CoreServices
import Foundation

public struct ExtensionStorageEvent: Equatable, Sendable {
    public let path: String
    public let flags: UInt32
    public let timestamp: Date

    public init(path: String, flags: UInt32, timestamp: Date = Date()) {
        self.path = ExtensionPathMaterializer.normalize(path)
        self.flags = flags
        self.timestamp = timestamp
    }
}

public protocol FSEventsStreamHandle: AnyObject, Sendable {
    func stop()
}

public protocol FSEventsBackend: Sendable {
    func start(
        paths: [String],
        latency: TimeInterval,
        callback: @escaping @Sendable (ExtensionStorageEvent) -> Void
    ) throws -> any FSEventsStreamHandle
}

public enum ExtensionStorageWatcherError: Error, Equatable {
    case alreadyRunning
    case streamCreateFailed
}

public final class ExtensionStorageWatcher: @unchecked Sendable {
    private let backend: any FSEventsBackend
    private let latency: TimeInterval
    private let lock = NSLock()
    private var protectedPaths: [String]
    private var handle: (any FSEventsStreamHandle)?
    private var callback: (@Sendable (ExtensionStorageEvent) -> Void)?

    public init(
        protectedPaths: [String],
        backend: any FSEventsBackend = SystemFSEventsBackend(),
        latency: TimeInterval = 0.1
    ) {
        self.protectedPaths = Self.normalizeProtectedPaths(protectedPaths)
        self.backend = backend
        self.latency = latency
    }

    public var isRunning: Bool {
        lock.withLock { handle != nil }
    }

    public func start(callback: @escaping @Sendable (ExtensionStorageEvent) -> Void) throws {
        try lock.withLock {
            guard handle == nil else {
                throw ExtensionStorageWatcherError.alreadyRunning
            }

            self.callback = callback
            guard !protectedPaths.isEmpty else {
                return
            }

            handle = try backend.start(paths: protectedPaths, latency: latency) { [weak self] event in
                self?.route(event)
            }
        }
    }

    public func stop() {
        let oldHandle = lock.withLock { () -> (any FSEventsStreamHandle)? in
            let old = handle
            handle = nil
            callback = nil
            return old
        }
        oldHandle?.stop()
    }

    public func updateProtectedPaths(_ paths: [String]) throws {
        let running = isRunning
        let oldCallback = lock.withLock { () -> (@Sendable (ExtensionStorageEvent) -> Void)? in
            protectedPaths = Self.normalizeProtectedPaths(paths)
            return callback
        }

        if running, let oldCallback {
            stop()
            try start(callback: oldCallback)
        }
    }

    private func route(_ event: ExtensionStorageEvent) {
        let current = lock.withLock { (protectedPaths, callback) }
        guard current.0.contains(where: { event.path == $0 || event.path.hasPrefix($0 + "/") }) else {
            return
        }
        current.1?(event)
    }

    private static func normalizeProtectedPaths(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.map(ExtensionPathMaterializer.normalize)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .sorted()
    }
}

public struct SystemFSEventsBackend: FSEventsBackend {
    public init() {}

    public func start(
        paths: [String],
        latency: TimeInterval,
        callback: @escaping @Sendable (ExtensionStorageEvent) -> Void
    ) throws -> any FSEventsStreamHandle {
        let box = FSEventsCallbackBox(callback: callback)
        let unmanagedBox = Unmanaged.passRetained(box)
        var context = FSEventStreamContext(
            version: 0,
            info: unmanagedBox.toOpaque(),
            retain: nil,
            release: { info in
                if let info {
                    Unmanaged<FSEventsCallbackBox>.fromOpaque(info).release()
                }
            },
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, eventCount, eventPaths, eventFlags, _ in
                guard let info else { return }
                let box = Unmanaged<FSEventsCallbackBox>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                for index in 0..<eventCount {
                    guard index < paths.count else { continue }
                    box.callback(
                        ExtensionStorageEvent(
                            path: paths[index],
                            flags: eventFlags[index],
                            timestamp: Date()
                        )
                    )
                }
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            unmanagedBox.release()
            throw ExtensionStorageWatcherError.streamCreateFailed
        }

        let handle = SystemFSEventsStreamHandle(stream: stream)
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "ai.hardener.sanctuary.extension-storage.fsevents"))
        FSEventStreamStart(stream)
        return handle
    }
}

private final class FSEventsCallbackBox: @unchecked Sendable {
    let callback: @Sendable (ExtensionStorageEvent) -> Void

    init(callback: @escaping @Sendable (ExtensionStorageEvent) -> Void) {
        self.callback = callback
    }
}

private final class SystemFSEventsStreamHandle: FSEventsStreamHandle, @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let lock = NSLock()
    private var stopped = false

    init(stream: FSEventStreamRef) {
        self.stream = stream
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            stopped = true
        }
    }

    deinit {
        stop()
    }
}
