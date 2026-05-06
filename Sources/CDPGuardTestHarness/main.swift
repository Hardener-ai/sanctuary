// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SanctuaryCore

struct HarnessOptions {
    var debugPort: UInt16?
    var profilePath: String?
    var protectedProfile = false
    var auditPath: String?
    var auditDevKeyPath: String?
    var pfRevalidationInterval: TimeInterval = 30
}

func parseOptions() -> HarnessOptions {
    var options = HarnessOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") {
        print("""
        sanctuary-cdpguard-test [--debug-port <port>] [--profile <path>] [--protected]

        Without arguments, discovers real Chromium debug ports. With --debug-port,
        uses a fixture discovery entry for e2e verification.
        """)
        exit(0)
    }
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--debug-port":
            if let value = args.first, let port = UInt16(value) {
                options.debugPort = port
                args.removeFirst()
            }
        case "--profile":
            if let value = args.first {
                options.profilePath = value
                args.removeFirst()
            }
        case "--protected":
            options.protectedProfile = true
        case "--audit-path":
            if let value = args.first {
                options.auditPath = value
                args.removeFirst()
            }
        case "--audit-dev-key-path":
            if let value = args.first {
                options.auditDevKeyPath = value
                args.removeFirst()
            }
        case "--pf-revalidation-interval":
            if let value = args.first, let interval = TimeInterval(value) {
                options.pfRevalidationInterval = interval
                args.removeFirst()
            }
        default:
            break
        }
    }
    return options
}

final class HarnessDiscovery: BrowserDebugPortDiscovering, @unchecked Sendable {
    private let port: BrowserDebugPortDiscovery.DebugPort

    init(port: BrowserDebugPortDiscovery.DebugPort) {
        self.port = port
    }

    func discover() -> [BrowserDebugPortDiscovery.DebugPort] {
        [port]
    }

    func startWatching(_ callback: @escaping ([BrowserDebugPortDiscovery.DebugPort]) -> Void) {
        callback([port])
    }

    func stopWatching() {}
}

let options = parseOptions()
if let auditPath = options.auditPath {
    setenv("SANCTUARY_AUDIT_PATH", auditPath, 1)
}
if let auditDevKeyPath = options.auditDevKeyPath {
    setenv("SANCTUARY_AUDIT_DEV_KEY_PATH", auditDevKeyPath, 1)
}
let classifier = AgentClassifier.live()
let attributor = PeerProcessAttributor()
let policy = ProtectionPolicy()
if options.protectedProfile, let profilePath = options.profilePath {
    policy.protectProfile(profilePath)
}
let discovery: any BrowserDebugPortDiscovering = options.debugPort.map {
    HarnessDiscovery(port: .init(
        pid: getpid(),
        bundleID: "com.sanctuary.fixture-browser",
        port: $0,
        userDataDir: options.profilePath
    ))
} ?? BrowserDebugPortDiscovery()
let auditLogger: any ExtensionAuditLogging = options.auditPath.map {
    AuditLog(path: $0)
} ?? AuditLog()
let guardInstance = CDPGuard(
    classifier: classifier,
    attributor: attributor,
    discovery: discovery,
    policy: policy,
    proxyPort: 0,
    auditLogger: auditLogger,
    pfRevalidationInterval: options.pfRevalidationInterval,
    pfRevalidationEventHandler: { event in
        print("pf revalidator event: \(event)")
        fflush(stdout)
    }
)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let signalQueue = DispatchQueue(label: "ai.hardener.sanctuary.cdpguard-test.signals")
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
let terminateSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)

func stopAndExit() {
    guardInstance.stop()
    print("sanctuary-cdpguard-test stopped; pf redirects cleared.")
    fflush(stdout)
    exit(0)
}

interruptSource.setEventHandler(handler: stopAndExit)
terminateSource.setEventHandler(handler: stopAndExit)
interruptSource.resume()
terminateSource.resume()

do {
    try guardInstance.start()
    print("sanctuary-cdpguard-test running. Press Ctrl-C to stop.")
    RunLoop.current.run()
} catch {
    fputs("sanctuary-cdpguard-test failed: \(error)\n", stderr)
    exit(1)
}
