// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import SanctuaryCore
@testable import SanctuaryMenuBar

@Suite(.serialized)
struct OnboardingWindowTests {
    @Test func sentinelDetectionShowsOnlyBeforeDismissOrCompletion() throws {
        let defaults = try Self.defaults()

        #expect(OnboardingDefaults.shouldAutoShow(defaults: defaults))
        #expect(!OnboardingDefaults.shouldShowResume(defaults: defaults))

        defaults.set(true, forKey: OnboardingDefaults.dismissedKey)
        #expect(!OnboardingDefaults.shouldAutoShow(defaults: defaults))
        #expect(OnboardingDefaults.shouldShowResume(defaults: defaults))

        defaults.set(true, forKey: OnboardingDefaults.completedKey)
        #expect(!OnboardingDefaults.shouldAutoShow(defaults: defaults))
        #expect(!OnboardingDefaults.shouldShowResume(defaults: defaults))
    }

    @Test func finishSetsCompletionSentinelAndOpensMenuCallback() throws {
        let defaults = try Self.defaults()
        var opened = false
        var closed = false
        let model = OnboardingFlowModel(
            defaults: defaults,
            closeWindow: { closed = true },
            openMenu: { opened = true }
        )

        model.finish()

        #expect(defaults.bool(forKey: OnboardingDefaults.completedKey))
        #expect(!defaults.bool(forKey: OnboardingDefaults.dismissedKey))
        #expect(model.didOpenMenu)
        #expect(opened)
        #expect(closed)
    }

    @Test func stepButtonsAdvanceAndBackPersistProgress() throws {
        let defaults = try Self.defaults()
        let model = OnboardingFlowModel(defaults: defaults)

        model.advance()
        #expect(model.step == .howItWorks)
        #expect(defaults.integer(forKey: OnboardingDefaults.stepKey) == OnboardingStep.howItWorks.rawValue)

        model.back()
        #expect(model.step == .welcome)
        #expect(defaults.integer(forKey: OnboardingDefaults.stepKey) == OnboardingStep.welcome.rawValue)
    }

    @Test func defaultFolderDetectionFiltersNonexistentPaths() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".ssh"), withIntermediateDirectories: true)

        let detected = DefaultSensitivePaths.existingPaths(homeDirectory: root)
        let folders = OnboardingFlowModel.detectFolders(detected, homeDirectory: root)

        #expect(folders.map(\.displayPath) == ["~/.ssh"])
    }

    @Test func walletDetectionFiltersToKnownExtensions() {
        let installed = [
            InstalledBrowserExtension(profilePath: "/tmp/Brave/Default", extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn", friendlyName: "MetaMask"),
            InstalledBrowserExtension(profilePath: "/tmp/Brave/Default", extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", friendlyName: "Unknown")
        ]

        let wallets = OnboardingFlowModel.detectWallets(installed)

        #expect(wallets.count == 1)
        #expect(wallets.first?.extensionInfo.friendlyName == "MetaMask")
        #expect(wallets.first?.isSelected == true)
    }

    @Test func continueAnywayOnInstallFailureAdvancesToFolders() throws {
        let model = OnboardingFlowModel(defaults: try Self.defaults(), initialStep: .installProtection)

        model.continueAnywayFromInstall()

        #expect(model.step == .folders)
    }

    @Test func skipPathDismissesButLeavesResumeAvailable() throws {
        let defaults = try Self.defaults()
        var closed = false
        let model = OnboardingFlowModel(defaults: defaults, closeWindow: { closed = true })

        model.skipForNow()

        #expect(!defaults.bool(forKey: OnboardingDefaults.completedKey))
        #expect(defaults.bool(forKey: OnboardingDefaults.dismissedKey))
        #expect(OnboardingDefaults.shouldShowResume(defaults: defaults))
        #expect(model.didClose)
        #expect(closed)
    }

    @MainActor
    @Test func installFailureSurfacesRequiresApprovalAndCanContinue() async throws {
        let model = OnboardingFlowModel(defaults: try Self.defaults(), initialStep: .installProtection)

        await model.installProtection(confirm: { true }, install: {
            struct InstallError: Error {}
            throw InstallError()
        })

        guard case .requiresApproval = model.installState else {
            Issue.record("expected requiresApproval state")
            return
        }
        model.continueAnywayFromInstall()
        #expect(model.step == .folders)
    }

    @Test func addingCustomFolderDeduplicatesAndSelectsIt() throws {
        let model = OnboardingFlowModel(defaults: try Self.defaults(), folderProvider: { [] })
        let folder = URL(fileURLWithPath: "/tmp/sanctuary-onboarding-custom")

        model.addFolder(folder)
        model.addFolder(folder)

        #expect(model.folders.count == 1)
        #expect(model.folders.first?.isSelected == true)
        #expect(model.folders.first?.isCustom == true)
    }

    private static func defaults() throws -> UserDefaults {
        let name = "sanctuary-onboarding-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-onboarding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
