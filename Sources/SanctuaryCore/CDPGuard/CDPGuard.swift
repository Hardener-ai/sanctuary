// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum CDPGuardError: Error, Equatable, Sendable {
    case alreadyRunning
}

public final class CDPGuard {
    private static let upstreamBypassSourcePortRange: ClosedRange<UInt16> = 49_223...49_322

    private let classifier: AgentClassifier
    private let attributor: PeerProcessAttributor
    private let discovery: any BrowserDebugPortDiscovering
    private let proxyListener: CDPProxyListener
    private let pfAnchorManager: any PFAnchorManaging
    private let policy: ProtectionPolicy
    private let requestedProxyPort: UInt16
    private let auditLogger: any ExtensionAuditLogging
    private let pfRevalidationInterval: TimeInterval
    private let pfRevalidationEnabled: Bool
    private let pfRevalidationEventHandler: @Sendable (PFRevalidator.Event) -> Void
    private let lock = NSLock()
    private var currentRedirects: [PFAnchorManager.Redirect] = []
    private var pfRevalidator: PFRevalidator?

    public private(set) var isRunning = false

    public init(
        classifier: AgentClassifier,
        attributor: PeerProcessAttributor,
        discovery: any BrowserDebugPortDiscovering = BrowserDebugPortDiscovery(),
        proxyListener: CDPProxyListener? = nil,
        policy: ProtectionPolicy = ProtectionPolicy(),
        pfAnchorManager: any PFAnchorManaging = PFAnchorManager(),
        proxyPort: UInt16 = 49_222,
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        pfRevalidationInterval: TimeInterval = 30,
        pfRevalidationEnabled: Bool = true,
        pfRevalidationEventHandler: @escaping @Sendable (PFRevalidator.Event) -> Void = { _ in }
    ) {
        self.classifier = classifier
        self.attributor = attributor
        self.discovery = discovery
        self.policy = policy
        self.pfAnchorManager = pfAnchorManager
        self.requestedProxyPort = proxyPort
        self.auditLogger = auditLogger
        self.pfRevalidationInterval = pfRevalidationInterval
        self.pfRevalidationEnabled = pfRevalidationEnabled
        self.pfRevalidationEventHandler = pfRevalidationEventHandler
        self.proxyListener = proxyListener ?? CDPProxyListener(
            classifier: classifier,
            attributor: attributor,
            policy: policy,
            upstreamSourcePortRange: Self.upstreamBypassSourcePortRange
        )
    }

    public func start() throws {
        guard !isRunning else {
            throw CDPGuardError.alreadyRunning
        }

        try pfAnchorManager.uninstall()
        try proxyListener.start(on: requestedProxyPort)
        guard let listenerPort = proxyListener.boundPort else {
            throw CDPProxyListenerError.bindFailed
        }

        try pfAnchorManager.ensurePFEnabled()
        try installRedirects(for: discovery.discover(), listenerPort: listenerPort)

        discovery.startWatching { [weak self] ports in
            guard let self else { return }
            debugPrint("Sanctuary CDPGuard discovered debug ports: \(ports)")
            do {
                try self.installRedirects(for: ports, listenerPort: listenerPort)
            } catch {
                debugPrint("Sanctuary CDPGuard failed to install pf redirects: \(error)")
            }
        }

        _ = classifier
        _ = attributor
        isRunning = true
        startPFRevalidatorIfNeeded()
    }

    public func stop() {
        pfRevalidator?.stop()
        pfRevalidator = nil
        try? pfAnchorManager.uninstall()
        proxyListener.stop()
        discovery.stopWatching()
        isRunning = false
    }

    public func reloadPFRules() throws {
        let redirects = lock.withLock { currentRedirects }
        if redirects.isEmpty {
            try pfAnchorManager.uninstall()
        } else {
            try pfAnchorManager.reloadSystemConfiguration()
            try pfAnchorManager.ensurePFEnabled()
            try pfAnchorManager.install(redirects: redirects)
        }
    }

    private func installRedirects(
        for ports: [BrowserDebugPortDiscovery.DebugPort],
        listenerPort: UInt16
    ) throws {
        let usablePorts = ports.filter { $0.port != 0 }
        let redirects = usablePorts.map {
            PFAnchorManager.Redirect(
                fromPort: $0.port,
                toPort: listenerPort,
                bypassSourcePortRange: Self.upstreamBypassSourcePortRange
            )
        }

        if let primary = usablePorts.sorted(by: { $0.port < $1.port }).first {
            policy.setRoute(
                proxyPort: listenerPort,
                targetPort: primary.port,
                profilePath: primary.userDataDir ?? "",
                attributionDestinationPort: primary.port
            )
        }

        if redirects.isEmpty {
            try pfAnchorManager.uninstall()
        } else {
            try pfAnchorManager.install(redirects: redirects)
        }
        lock.withLock {
            currentRedirects = redirects
        }
    }

    private func startPFRevalidatorIfNeeded() {
        guard pfRevalidationEnabled else {
            return
        }
        let revalidator = PFRevalidator(
            interval: pfRevalidationInterval,
            expectedRulesProvider: { [weak self] in
                guard let self else { return "" }
                let redirects = self.lock.withLock { self.currentRedirects }
                return PFAnchorManager.generateRulesFile(redirects: redirects)
            },
            activeProvider: { [weak self] in
                guard let self else { return false }
                let redirects = self.lock.withLock { self.currentRedirects }
                return self.isRunning && !redirects.isEmpty
            },
            reload: { [weak self] in
                try self?.reloadPFRules()
            },
            auditLogger: auditLogger,
            eventHandler: pfRevalidationEventHandler
        )
        pfRevalidator = revalidator
        revalidator.start()
    }
}
