// SPDX-License-Identifier: AGPL-3.0-only
import SanctuaryCore
import Foundation
import SwiftUI

struct SanctuaryDropdownView: View {
    let dataSource: MenuBarDataSource
    let showResumeSetup: Bool
    let onResumeSetup: () -> Void
    let quit: () -> Void
    @State private var protectionToggleBusy = false

    init(
        dataSource: MenuBarDataSource = MenuBarDataSource.preview,
        showResumeSetup: Bool = false,
        onResumeSetup: @escaping () -> Void = {},
        quit: @escaping () -> Void
    ) {
        self.dataSource = dataSource
        self.showResumeSetup = showResumeSetup
        self.onResumeSetup = onResumeSetup
        self.quit = quit
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.grid) {
                titleRow
                ProtectionToggleSection(
                    isOn: dataSource.protectionEnabled,
                    isBusy: protectionToggleBusy,
                    onToggle: handleProtectionToggle
                )
                StatusSection(
                    status: dataSource.status,
                    peerHealthStatus: dataSource.peerHealthStatus,
                    cdpGuardHealth: dataSource.cdpGuardHealth,
                    onApprove: openApprovalPane
                )
                if showResumeSetup {
                    ResumeSetupRow(action: onResumeSetup)
                }
                divider
                FoldersSection(
                    folders: dataSource.folders,
                    onToggle: handleFolderToggle,
                    onAdd: addFolder
                )
                divider
                ExtensionsSection(
                    extensions: dataSource.extensions,
                    onToggle: handleExtensionToggle,
                    onAdd: addWallet
                )
                divider
                AgentsSection(groups: dataSource.agentGroups)
                if !dataSource.activities.isEmpty {
                    divider
                    ActivitySection(entries: dataSource.activities)
                }
                divider
                quitButton
            }
            .padding(DesignTokens.Spacing.contentPadding)
        }
        .frame(minWidth: 300, idealWidth: 320, alignment: .leading)
        .frame(maxHeight: 480)
        .background(.regularMaterial)
        .onAppear {
            dataSource.refreshAsync()
        }
        .onDisappear {
            BiometricAuth.resetAuthorizationWindow()
        }
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Sanctuary")
                .font(DesignTokens.Typography.title)
                .foregroundStyle(DesignTokens.Colors.label)
            Text("v0.1.0")
                .font(DesignTokens.Typography.footnote)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
        }
        .frame(minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .center)
    }

    private var divider: some View {
        Divider()
            .overlay(DesignTokens.Colors.separator)
    }

    private var quitButton: some View {
        Button("Quit", action: quit)
            .buttonStyle(.plain)
            .font(DesignTokens.Typography.body)
            .foregroundStyle(DesignTokens.Colors.label)
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func handleFolderToggle(_ folder: ProtectedFolderEntry, isOn: Bool) {
        guard !isOn else {
            Task { @MainActor in
                do {
                    try await dataSource.protectFolder(folder.path)
                } catch {
                    logMenuBarError("protect folder failed: \(error)")
                }
            }
            return
        }

        Task { @MainActor in
            let confirmed = await BiometricAuth.confirm(reason: "Confirm to remove protection from \(folder.displayPath)")
            guard confirmed else {
                dataSource.refresh()
                return
            }
            do {
                try await dataSource.unprotectFolder(folder.path)
            } catch {
                logMenuBarError("unprotect folder failed: \(error)")
            }
        }
    }

    private func addFolder() {
        Task { @MainActor in
            guard let url = FolderPickerService.pickFolder() else {
                return
            }
            do {
                try await dataSource.protectFolder(url.path)
            } catch {
                logMenuBarError("protect folder failed: \(error)")
            }
        }
    }

    private func handleExtensionToggle(_ item: ProtectedExtensionEntry, isOn: Bool) {
        guard !isOn else {
            return
        }

        Task { @MainActor in
            let confirmed = await BiometricAuth.confirm(reason: "Confirm to remove protection from \(item.friendlyName)")
            guard confirmed else {
                dataSource.refresh()
                return
            }
            do {
                try await dataSource.unprotectExtension(item)
            } catch {
                logMenuBarError("unprotect extension failed: \(error)")
            }
        }
    }

    private func addWallet() {
        Task { @MainActor in
            let candidates = dataSource.detectedExtensions()
            guard let selected = ExtensionPickerService.pickExtension(from: candidates) else {
                return
            }
            do {
                try await dataSource.protectExtension(selected)
            } catch {
                logMenuBarError("protect extension failed: \(error)")
            }
        }
    }

    private func handleProtectionToggle(_ isOn: Bool) {
        Task { @MainActor in
            protectionToggleBusy = true
            defer {
                protectionToggleBusy = false
            }

            let reason = isOn ? "install background protection" : "pause Sanctuary protection"
            let confirmed = await BiometricAuth.confirm(reason: reason)
            guard confirmed else {
                dataSource.refresh()
                return
            }

            do {
                if isOn {
                    try await dataSource.enableProtection()
                } else {
                    try await dataSource.disableProtection()
                }
            } catch {
                logMenuBarError("protection toggle failed: \(error)")
                dataSource.refresh()
            }
        }
    }

    private func openApprovalPane() {
        do {
            try DaemonInstallation.openSystemSettingsApprovalPane()
        } catch {
            logMenuBarError("open approval pane failed: \(error)")
        }
    }

    private func logMenuBarError(_ message: String) {
        FileHandle.standardError.write(Data(("Sanctuary menu bar: \(message)\n").utf8))
    }
}

private struct ResumeSetupRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.grid) {
                Image(systemName: "arrow.clockwise.circle")
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("Resume setup ->")
                    .font(DesignTokens.Typography.body)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignTokens.Colors.secondaryLabel)
    }
}

struct SanctuaryDropdownView_Previews: PreviewProvider {
    static var previews: some View {
        SanctuaryDropdownView(dataSource: .preview, quit: {})
            .previewDisplayName("Sanctuary Menu")
    }
}

private extension MenuBarDataSource {
    static var preview: MenuBarDataSource {
        let source = MenuBarDataSource(
            folderLoader: { [] },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/sanctuary-audit.log" }
        )
        source.status = .active
        source.protectionEnabled = true
        source.folders = [
            .init(displayPath: "~/.ssh", source: "default"),
            .init(displayPath: "~/.aws", source: "default")
        ]
        source.extensions = [
            .init(friendlyName: "MetaMask", profile: "Brave Default")
        ]
        source.activities = [
            ActivityEntry(
                timestamp: Date(),
                relativeTimeText: "just now",
                summaryText: "Codex tried to read MetaMask",
                attributionText: "Detected · definite",
                isDenial: false
            )
        ]
        return source
    }
}
