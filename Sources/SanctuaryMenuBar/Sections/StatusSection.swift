// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct StatusSection: View {
    let status: ProtectionStatus
    let peerHealthStatus: PeerHealthStatus
    let cdpGuardHealth: CDPGuardHealth
    let onApprove: () -> Void

    init(
        status: ProtectionStatus,
        peerHealthStatus: PeerHealthStatus = .healthy,
        cdpGuardHealth: CDPGuardHealth = .healthy,
        onApprove: @escaping () -> Void = {}
    ) {
        self.status = status
        self.peerHealthStatus = peerHealthStatus
        self.cdpGuardHealth = cdpGuardHealth
        self.onApprove = onApprove
    }

    var body: some View {
        Group {
            if status == .requiresApproval {
                Button(action: onApprove) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
        .frame(minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .center)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        HStack(spacing: DesignTokens.Spacing.grid) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(title)
                .font(DesignTokens.Typography.body.weight(.medium))
                .foregroundStyle(DesignTokens.Colors.label)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        switch peerHealthStatus {
        case .healthy:
            break
        case .daemonDisconnected:
            return "Sanctuary daemon disconnected"
        case let .suspectedTamper(reason):
            return "Tamper detected: \(reason)"
        }

        switch cdpGuardHealth {
        case .healthy:
            break
        case .rulesReloaded:
            return "CDP rules re-installed after tampering"
        case .suspectedTamper:
            return "CDP protection may be under attack"
        }

        switch status {
        case .active:
            return "All protections active"
        case .inactive:
            return "Protection paused"
        case .noDaemon:
            return "Daemon not running"
        case .starting:
            return "Starting protection..."
        case .requiresApproval:
            return "Approve in System Settings ->"
        }
    }

    private var indicatorColor: Color {
        switch peerHealthStatus {
        case .healthy:
            break
        case .daemonDisconnected:
            return DesignTokens.Colors.warning
        case .suspectedTamper:
            return DesignTokens.Colors.denial
        }

        switch cdpGuardHealth {
        case .healthy:
            break
        case .rulesReloaded:
            return DesignTokens.Colors.warning
        case .suspectedTamper:
            return DesignTokens.Colors.denial
        }

        switch status {
        case .active:
            return DesignTokens.Colors.active
        case .starting, .requiresApproval:
            return DesignTokens.Colors.warning
        case .inactive, .noDaemon:
            return DesignTokens.Colors.inactive
        }
    }
}

struct StatusSection_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            StatusSection(status: .active)
            StatusSection(status: .noDaemon)
            StatusSection(status: .requiresApproval)
        }
        .padding()
        .previewDisplayName("Status Section")
    }
}
