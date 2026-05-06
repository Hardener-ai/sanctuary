// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Observation
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct SanctuaryMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dataSource = MenuBarDataSource()
    @State private var onboardingWindow = OnboardingWindowController()
    @State private var peerMonitor = DaemonPeerMonitor()
    @State private var checkedOnboarding = false
    @State private var showResumeSetup = OnboardingDefaults.shouldShowResume()

    var body: some Scene {
        MenuBarExtra {
            SanctuaryDropdownView(
                dataSource: dataSource,
                showResumeSetup: showResumeSetup,
                onResumeSetup: resumeOnboarding
            ) {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: menuBarSymbolName)
                .foregroundStyle(menuBarForegroundStyle)
                .accessibilityLabel("Sanctuary")
                .onAppear {
                    dataSource.startAutoRefresh(interval: 5)
                    peerMonitor.start { state in
                        DispatchQueue.main.async {
                            dataSource.peerHealthStatus = state.health
                        }
                    }
                    showOnboardingIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarSymbolName: String {
        if let lastDenialAt = dataSource.lastDenialAt,
           Date().timeIntervalSince(lastDenialAt) < 60 {
            return "shield.lefthalf.filled"
        }
        return dataSource.status.menuBarSymbolName
    }

    private var menuBarForegroundStyle: AnyShapeStyle {
        if let lastDenialAt = dataSource.lastDenialAt,
           Date().timeIntervalSince(lastDenialAt) < 60 {
            // Denials use shape rather than color so the menu bar stays native
            // in both light and dark mode without introducing a custom palette.
            return AnyShapeStyle(.primary)
        }
        return dataSource.status.menuBarForegroundStyle
    }

    @MainActor
    private func showOnboardingIfNeeded() {
        showResumeSetup = OnboardingDefaults.shouldShowResume()
        guard !checkedOnboarding else {
            return
        }
        checkedOnboarding = true
        onboardingWindow.showIfNeeded(
            dataSource: dataSource,
            onDismiss: updateResumeSetup,
            onOpenMenu: openConfiguredMenu
        )
    }

    @MainActor
    private func resumeOnboarding() {
        onboardingWindow.resume(
            dataSource: dataSource,
            onDismiss: updateResumeSetup,
            onOpenMenu: openConfiguredMenu
        )
    }

    @MainActor
    private func updateResumeSetup() {
        showResumeSetup = OnboardingDefaults.shouldShowResume()
    }

    @MainActor
    private func openConfiguredMenu() {
        dataSource.refreshAsync()
        showResumeSetup = OnboardingDefaults.shouldShowResume()
        // SwiftUI MenuBarExtra does not expose the underlying NSStatusItem.
        // The onboarding callback keeps the data warm so the next menu click
        // opens directly into the configured state.
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension ProtectionStatus {
    var menuBarSymbolName: String {
        switch self {
        case .active, .inactive, .starting, .requiresApproval:
            return "shield"
        case .noDaemon:
            // `shield.slash` is intentionally explicit: in the menu bar,
            // tint-only differences are too subtle to explain a stopped daemon.
            return "shield.slash"
        }
    }

    var menuBarForegroundStyle: AnyShapeStyle {
        switch self {
        case .active, .inactive, .starting, .requiresApproval:
            return AnyShapeStyle(.primary)
        case .noDaemon:
            return AnyShapeStyle(.secondary)
        }
    }
}
