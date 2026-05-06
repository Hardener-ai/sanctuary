// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Darwin
import Foundation

public protocol BrowserDebugPortDiscovering: Sendable {
    func discover() -> [BrowserDebugPortDiscovery.DebugPort]
    func startWatching(_ callback: @escaping ([BrowserDebugPortDiscovery.DebugPort]) -> Void)
    func stopWatching()
}

public final class BrowserDebugPortDiscovery: BrowserDebugPortDiscovering, @unchecked Sendable {
    public struct DebugPort: Equatable, Sendable {
        public let pid: pid_t
        public let bundleID: String
        public let port: UInt16
        public let userDataDir: String?

        public init(pid: pid_t, bundleID: String, port: UInt16, userDataDir: String?) {
            self.pid = pid
            self.bundleID = bundleID
            self.port = port
            self.userDataDir = userDataDir
        }
    }

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.brave.Browser.nightly",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium"
    ]

    private let argumentsProvider: any ProcessArgumentsProviding
    private let workspace: NSWorkspace
    private let callbackQueue = DispatchQueue(label: "ai.hardener.sanctuary.cdp.discovery")
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: DispatchSourceTimer?

    public init(
        argumentsProvider: any ProcessArgumentsProviding = DarwinProcessArgumentsProvider(),
        workspace: NSWorkspace = .shared
    ) {
        self.argumentsProvider = argumentsProvider
        self.workspace = workspace
    }

    public func discover() -> [DebugPort] {
        workspace.runningApplications.compactMap { app in
            guard
                let bundleID = app.bundleIdentifier,
                Self.browserBundleIDs.contains(bundleID)
            else {
                return nil
            }

            let args = argumentsProvider.arguments(for: app.processIdentifier)
            guard let port = Self.parseRemoteDebuggingPort(from: args) else {
                return nil
            }

            if port != 0, !Self.isCDPPort(host: "127.0.0.1", port: port) {
                return nil
            }

            return DebugPort(
                pid: app.processIdentifier,
                bundleID: bundleID,
                port: port,
                userDataDir: Self.parseUserDataDir(from: args)
            )
        }
    }

    public func startWatching(_ callback: @escaping ([DebugPort]) -> Void) {
        stopWatching()

        let notify: () -> Void = { [weak self] in
            guard let self else { return }
            callbackQueue.async {
                callback(self.discover())
            }
        }

        let center = workspace.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { _ in notify() },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { _ in notify() }
        ]

        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            callback(self.discover())
        }
        timer.resume()
        pollTimer = timer
    }

    public func stopWatching() {
        let center = workspace.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        pollTimer?.cancel()
        pollTimer = nil
    }

    deinit {
        stopWatching()
    }

    static func parseRemoteDebuggingPort(from arguments: [String]) -> UInt16? {
        parseIntegerFlag("--remote-debugging-port", from: arguments).flatMap { value in
            guard value >= 0, value <= Int(UInt16.max) else {
                return nil
            }
            return UInt16(value)
        }
    }

    static func parseUserDataDir(from arguments: [String]) -> String? {
        parseStringFlag("--user-data-dir", from: arguments)
    }

    static func isCDPPort(host: String, port: UInt16, timeout: TimeInterval = 1.0) -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/json/version") else {
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<Bool>(false)

        URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            guard
                error == nil,
                let data,
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["webSocketDebuggerUrl"] is String
            else {
                return
            }
            result.set(true)
        }.resume()

        _ = semaphore.wait(timeout: .now() + timeout + 0.25)
        return result.get()
    }

    private static func parseIntegerFlag(_ flag: String, from arguments: [String]) -> Int? {
        parseStringFlag(flag, from: arguments).flatMap(Int.init)
    }

    private static func parseStringFlag(_ flag: String, from arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }

            let prefix = "\(flag)="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }

        return nil
    }
}

public protocol ProcessArgumentsProviding: Sendable {
    func arguments(for pid: pid_t) -> [String]
}

public struct DarwinProcessArgumentsProvider: ProcessArgumentsProviding {
    public init() {}

    public func arguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return []
        }

        var buffer = Array(repeating: UInt8(0), count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else {
            return []
        }

        return Self.decodeProcArgs(buffer)
    }

    static func decodeProcArgs(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > MemoryLayout<Int32>.size else {
            return []
        }

        let argc = buffer.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: Int32.self)
        }
        guard argc > 0 else {
            return []
        }

        var offset = MemoryLayout<Int32>.size
        while offset < buffer.count, buffer[offset] != 0 {
            offset += 1
        }
        while offset < buffer.count, buffer[offset] == 0 {
            offset += 1
        }

        var args: [String] = []
        while offset < buffer.count, args.count < Int(argc) {
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 {
                offset += 1
            }
            if start < offset, let argument = String(bytes: buffer[start..<offset], encoding: .utf8) {
                args.append(argument)
            }
            while offset < buffer.count, buffer[offset] == 0 {
                offset += 1
            }
        }

        return args
    }
}
