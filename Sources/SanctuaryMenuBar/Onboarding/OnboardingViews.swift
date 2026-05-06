// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SanctuaryCore
import SwiftUI

struct OnboardingRootView: View {
    let model: OnboardingFlowModel
    let dataSource: MenuBarDataSource

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)
            StepIndicator(step: model.step)
                .padding(.bottom, 18)
        }
        .frame(width: 480, height: 560)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome:
            WelcomeStep(model: model)
        case .howItWorks:
            HowItWorksStep(model: model)
        case .installProtection:
            InstallProtectionStep(model: model, dataSource: dataSource)
        case .folders:
            FolderChoiceStep(model: model, dataSource: dataSource)
        case .wallets:
            WalletChoiceStep(model: model, dataSource: dataSource)
        }
    }
}

private struct WelcomeStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)
            Image(systemName: "shield")
                .font(.system(size: 80, weight: .regular))
                .foregroundStyle(DesignTokens.Colors.label)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Welcome to Sanctuary")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignTokens.Colors.label)
                Text("Stop AI agents from accessing your wallets, SSH keys, and secrets. Even when they have full system access.")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("This setup takes about 30 seconds.")
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            }
            Spacer()
            VStack(spacing: 8) {
                Button("Get Started") {
                    model.advance()
                }
                .keyboardShortcut(.defaultAction)
                Button("Skip for now") {
                    model.skipForNow()
                }
            }
        }
    }
}

private struct HowItWorksStep: View {
    let model: OnboardingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "How Sanctuary works")
            VStack(alignment: .leading, spacing: 14) {
                ExplanationRow(systemName: "lock.shield", title: "Detects AI agents", detail: "Identifies 41+ known agents like Codex, Cursor, Hermes, OpenClaw plus runtime fingerprinting")
                ExplanationRow(systemName: "eye.slash", title: "Watches protected zones", detail: "Logs every agent access to folders and wallet extensions you protect")
                ExplanationRow(systemName: "shield.lefthalf.filled", title: "Blocks browser attacks", detail: "Prevents agents from attaching to Brave or Chrome to drain wallets via CDP")
            }
            Spacer()
            NavigationButtons(back: model.back, nextTitle: "Continue", next: model.advance, skip: model.skipForNow)
        }
    }
}

private struct InstallProtectionStep: View {
    let model: OnboardingFlowModel
    let dataSource: MenuBarDataSource

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(
                title: "Install background protection",
                body: "Sanctuary needs admin authorization to install a background service. This runs whenever your Mac is on and only watches what you choose to protect."
            )
            installStatus
            Spacer()
            HStack {
                Button("Back", action: model.back)
                Spacer()
                if case .requiresApproval = model.installState {
                    Button("Continue anyway") {
                        model.continueAnywayFromInstall()
                    }
                }
                Button(primaryTitle) {
                    Task { @MainActor in
                        if model.installState == .active {
                            model.advance()
                        } else {
                            await model.installProtection(install: dataSource.enableProtection)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.installState == .installing)
            }
            Button("Skip for now") {
                model.skipForNow()
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
        }
    }

    private var primaryTitle: String {
        model.installState == .active ? "Continue" : "Install Protection"
    }

    private var installStatus: some View {
        HStack(spacing: 10) {
            switch model.installState {
            case .notInstalled:
                Circle()
                    .fill(DesignTokens.Colors.inactive)
                    .frame(width: 8, height: 8)
                Text("Not installed")
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("Installing...")
            case .active:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignTokens.Colors.active)
                Text("Protection active")
            case .requiresApproval:
                Circle()
                    .fill(DesignTokens.Colors.warning)
                    .frame(width: 8, height: 8)
                Button("Approve in System Settings ->") {
                    try? DaemonInstallation.openSystemSettingsApprovalPane()
                }
                .buttonStyle(.plain)
            }
        }
        .font(DesignTokens.Typography.body.weight(.medium))
        .foregroundStyle(DesignTokens.Colors.label)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FolderChoiceStep: View {
    let model: OnboardingFlowModel
    let dataSource: MenuBarDataSource

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(
                title: "Protect your folders",
                body: "Sanctuary recommends these folders. You can always change this later from the menu bar."
            )
            ScrollView {
                VStack(spacing: 6) {
                    if model.folders.isEmpty {
                        Text("No default folders found on this Mac.")
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.folders.indices, id: \.self) { index in
                        Toggle(isOn: Binding(
                            get: { model.folders[index].isSelected },
                            set: { model.folders[index].isSelected = $0 }
                        )) {
                            Text(model.folders[index].displayPath)
                                .font(DesignTokens.Typography.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            Button("+ Add custom folder...") {
                if let url = FolderPickerService.pickFolder() {
                    model.addFolder(url)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            Spacer()
            NavigationButtons(back: model.back, nextTitle: "Continue", next: protectAndAdvance, skip: model.skipForNow)
        }
    }

    private func protectAndAdvance() {
        Task { @MainActor in
            for folder in model.folders where folder.isSelected {
                try? await dataSource.protectFolder(folder.path)
            }
            model.advance()
        }
    }
}

private struct WalletChoiceStep: View {
    let model: OnboardingFlowModel
    let dataSource: MenuBarDataSource

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(
                title: "Protect your wallets and password managers",
                body: "We found these in your browsers. Toggle which to protect."
            )
            ScrollView {
                VStack(spacing: 6) {
                    if model.wallets.isEmpty {
                        Text("No supported browser wallets found yet.")
                            .font(DesignTokens.Typography.body)
                            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.wallets.indices, id: \.self) { index in
                        Toggle(isOn: Binding(
                            get: { model.wallets[index].isSelected },
                            set: { model.wallets[index].isSelected = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.wallets[index].extensionInfo.friendlyName)
                                    .font(DesignTokens.Typography.body)
                                Text(model.wallets[index].profileDisplayName)
                                    .font(DesignTokens.Typography.footnote)
                                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                            }
                        }
                    }
                }
            }
            Button("+ Add custom wallet...") {
                if let selected = ExtensionPickerService.pickExtension(from: dataSource.detectedExtensions()) {
                    model.addWallet(selected)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            Spacer()
            HStack {
                Button("Back", action: model.back)
                Spacer()
                Button("Finish") {
                    Task { @MainActor in
                        for wallet in model.wallets where wallet.isSelected {
                            try? await dataSource.protectExtension(wallet.extensionInfo)
                        }
                        dataSource.refresh()
                        model.finish()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            Button("Skip for now") {
                model.skipForNow()
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
        }
    }
}

private struct StepTitle: View {
    let title: String
    var text: String?

    init(title: String, body: String? = nil) {
        self.title = title
        self.text = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DesignTokens.Colors.label)
            if let text {
                Text(text)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ExplanationRow: View {
    let systemName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 20))
                .frame(width: 28)
                .foregroundStyle(DesignTokens.Colors.secondaryLabel)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DesignTokens.Typography.body.weight(.medium))
                Text(detail)
                    .font(DesignTokens.Typography.footnote)
                    .foregroundStyle(DesignTokens.Colors.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NavigationButtons: View {
    let back: () -> Void
    let nextTitle: String
    let next: () -> Void
    let skip: () -> Void

    var body: some View {
        HStack {
            Button("Back", action: back)
            Spacer()
            Button(nextTitle, action: next)
                .keyboardShortcut(.defaultAction)
        }
        Button("Skip for now", action: skip)
            .buttonStyle(.plain)
            .foregroundStyle(DesignTokens.Colors.secondaryLabel)
    }
}

private struct StepIndicator: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.self) { item in
                Circle()
                    .fill(item == step ? DesignTokens.Colors.label : DesignTokens.Colors.separator)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

struct OnboardingRootView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingRootView(
            model: OnboardingFlowModel(),
            dataSource: MenuBarDataSource(
                folderLoader: { [] },
                extensionLoader: { [] },
                inventoryLoader: { [] },
                daemonIsRunning: { true },
                auditLogPath: { "/tmp/sanctuary-audit.log" }
            )
        )
            .previewDisplayName("Onboarding")
    }
}
