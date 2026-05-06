// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import Observation
import SanctuaryCore
import SwiftUI

enum OnboardingDefaults {
    static let suiteName = "ai.getsanctuary.SanctuaryMenuBar"
    static let completedKey = "onboardingCompleted"
    static let dismissedKey = "onboardingDismissed"
    static let stepKey = "onboardingStep"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func shouldAutoShow(defaults: UserDefaults = defaults) -> Bool {
        !defaults.bool(forKey: completedKey) && !defaults.bool(forKey: dismissedKey)
    }

    static func shouldShowResume(defaults: UserDefaults = defaults) -> Bool {
        !defaults.bool(forKey: completedKey) && defaults.bool(forKey: dismissedKey)
    }
}

enum OnboardingStep: Int, CaseIterable, Codable {
    case welcome = 0
    case howItWorks
    case installProtection
    case folders
    case wallets
}

enum OnboardingInstallState: Equatable {
    case notInstalled
    case installing
    case active
    case requiresApproval(String)
}

struct OnboardingFolderCandidate: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let displayPath: String
    var isSelected: Bool
    let isCustom: Bool

    init(path: String, displayPath: String? = nil, isSelected: Bool = true, isCustom: Bool = false) {
        self.path = path
        self.displayPath = displayPath ?? DefaultSensitivePaths.displayPath(path)
        self.isSelected = isSelected
        self.isCustom = isCustom
    }
}

struct OnboardingWalletCandidate: Identifiable, Equatable {
    let id = UUID()
    let extensionInfo: InstalledBrowserExtension
    let profileDisplayName: String
    var isSelected: Bool
    let isCustom: Bool

    init(extensionInfo: InstalledBrowserExtension, isSelected: Bool = true, isCustom: Bool = false) {
        self.extensionInfo = extensionInfo
        self.profileDisplayName = MenuBarDataSource.profileDisplayName(for: extensionInfo.profilePath)
        self.isSelected = isSelected
        self.isCustom = isCustom
    }
}

@Observable
final class OnboardingFlowModel {
    var step: OnboardingStep
    var installState: OnboardingInstallState = .notInstalled
    var folders: [OnboardingFolderCandidate]
    var wallets: [OnboardingWalletCandidate]
    var didClose = false
    var didOpenMenu = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folderProvider: () -> [String]
    @ObservationIgnored private let walletProvider: () -> [InstalledBrowserExtension]
    @ObservationIgnored private let closeWindow: () -> Void
    @ObservationIgnored private let openMenu: () -> Void

    init(
        defaults: UserDefaults = OnboardingDefaults.defaults,
        initialStep: OnboardingStep? = nil,
        folderProvider: @escaping () -> [String] = { DefaultSensitivePaths.existingPaths() },
        walletProvider: @escaping () -> [InstalledBrowserExtension] = { BrowserProfileExtensionDiscovery.discoverInstalledKnownExtensions() },
        closeWindow: @escaping () -> Void = {},
        openMenu: @escaping () -> Void = {}
    ) {
        self.defaults = defaults
        self.folderProvider = folderProvider
        self.walletProvider = walletProvider
        self.closeWindow = closeWindow
        self.openMenu = openMenu
        let storedStep = OnboardingStep(rawValue: defaults.integer(forKey: OnboardingDefaults.stepKey)) ?? .welcome
        self.step = initialStep ?? storedStep
        self.folders = Self.detectFolders(folderProvider())
        self.wallets = Self.detectWallets(walletProvider())
    }

    static func detectFolders(
        _ paths: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [OnboardingFolderCandidate] {
        paths
            .map {
                OnboardingFolderCandidate(
                    path: $0,
                    displayPath: DefaultSensitivePaths.displayPath($0, homeDirectory: homeDirectory),
                    isSelected: true
                )
            }
            .sorted { $0.displayPath < $1.displayPath }
    }

    static func detectWallets(_ installed: [InstalledBrowserExtension]) -> [OnboardingWalletCandidate] {
        installed
            .filter { KnownExtensions.lookup($0.extensionID) != nil }
            .map { OnboardingWalletCandidate(extensionInfo: $0, isSelected: true) }
            .sorted {
                if $0.profileDisplayName != $1.profileDisplayName {
                    return $0.profileDisplayName < $1.profileDisplayName
                }
                return $0.extensionInfo.friendlyName < $1.extensionInfo.friendlyName
            }
    }

    func advance() {
        guard let index = OnboardingStep.allCases.firstIndex(of: step),
              index + 1 < OnboardingStep.allCases.count
        else {
            return
        }
        step = OnboardingStep.allCases[index + 1]
        persistProgress()
    }

    func back() {
        guard let index = OnboardingStep.allCases.firstIndex(of: step),
              index > 0
        else {
            return
        }
        step = OnboardingStep.allCases[index - 1]
        persistProgress()
    }

    func addFolder(_ url: URL) {
        let path = ExtensionPathMaterializer.normalize(url.path)
        guard !folders.contains(where: { $0.path == path }) else {
            return
        }
        folders.append(.init(path: path, isSelected: true, isCustom: true))
        folders.sort { $0.displayPath < $1.displayPath }
    }

    func addWallet(_ extensionInfo: InstalledBrowserExtension) {
        guard !wallets.contains(where: { $0.extensionInfo.profilePath == extensionInfo.profilePath && $0.extensionInfo.extensionID == extensionInfo.extensionID }) else {
            return
        }
        wallets.append(.init(extensionInfo: extensionInfo, isSelected: true, isCustom: true))
        wallets.sort {
            if $0.profileDisplayName != $1.profileDisplayName {
                return $0.profileDisplayName < $1.profileDisplayName
            }
            return $0.extensionInfo.friendlyName < $1.extensionInfo.friendlyName
        }
    }

    @MainActor
    func installProtection(
        confirm: () async -> Bool = { await BiometricAuth.confirm(reason: "install background protection") },
        install: () async throws -> Void
    ) async {
        guard await confirm() else {
            return
        }
        installState = .installing
        do {
            try await install()
            installState = .active
        } catch {
            installState = .requiresApproval("Approval is required in System Settings before background protection can run.")
        }
    }

    func continueAnywayFromInstall() {
        step = .folders
        persistProgress()
    }

    func skipForNow() {
        defaults.set(false, forKey: OnboardingDefaults.completedKey)
        defaults.set(true, forKey: OnboardingDefaults.dismissedKey)
        persistProgress()
        didClose = true
        closeWindow()
    }

    func finish() {
        defaults.set(true, forKey: OnboardingDefaults.completedKey)
        defaults.set(false, forKey: OnboardingDefaults.dismissedKey)
        persistProgress()
        didClose = true
        didOpenMenu = true
        closeWindow()
        openMenu()
    }

    private func persistProgress() {
        defaults.set(step.rawValue, forKey: OnboardingDefaults.stepKey)
    }
}

@MainActor
final class OnboardingWindowController {
    private var panel: NSPanel?
    private var panelDelegate: OnboardingPanelDelegate?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func showIfNeeded(
        dataSource: MenuBarDataSource,
        onDismiss: @escaping () -> Void = {},
        onOpenMenu: @escaping () -> Void = {}
    ) {
        guard OnboardingDefaults.shouldAutoShow() else {
            return
        }
        show(dataSource: dataSource, initialStep: nil, onDismiss: onDismiss, onOpenMenu: onOpenMenu)
    }

    func resume(
        dataSource: MenuBarDataSource,
        onDismiss: @escaping () -> Void = {},
        onOpenMenu: @escaping () -> Void = {}
    ) {
        show(dataSource: dataSource, initialStep: nil, onDismiss: onDismiss, onOpenMenu: onOpenMenu)
    }

    func show(
        dataSource: MenuBarDataSource,
        initialStep: OnboardingStep?,
        onDismiss: @escaping () -> Void,
        onOpenMenu: @escaping () -> Void
    ) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = OnboardingFlowModel(
            initialStep: initialStep,
            closeWindow: { [weak self] in
                self?.close()
                onDismiss()
            },
            openMenu: onOpenMenu
        )
        let view = OnboardingRootView(model: model, dataSource: dataSource)
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.title = "Sanctuary"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.center()
        let delegate = OnboardingPanelDelegate { [weak self] in
            OnboardingDefaults.defaults.set(false, forKey: OnboardingDefaults.completedKey)
            OnboardingDefaults.defaults.set(true, forKey: OnboardingDefaults.dismissedKey)
            self?.panel = nil
            self?.panelDelegate = nil
            onDismiss()
        }
        panel.delegate = delegate
        self.panelDelegate = delegate
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        panel?.delegate = nil
        panel?.close()
        panel = nil
        panelDelegate = nil
    }
}

private final class OnboardingPanelDelegate: NSObject, NSWindowDelegate {
    private let didClose: () -> Void

    init(didClose: @escaping () -> Void) {
        self.didClose = didClose
    }

    func windowWillClose(_ notification: Notification) {
        didClose()
    }
}
