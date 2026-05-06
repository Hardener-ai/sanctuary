// SPDX-License-Identifier: AGPL-3.0-only
import SanctuaryCore
import SwiftUI

struct AgentsSection: View {
    let groups: [AgentGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("RUNNING AGENTS (\(groups.count))")
            if groups.isEmpty {
                EmptySectionRow("No agents detected")
            } else {
                ForEach(Array(groups.prefix(5)), id: \.representativePid) { group in
                    IconLabelRow(
                        systemName: "terminal",
                        title: group.rootIdentity,
                        subtitle: subtitle(for: group)
                    )
                }
                if groups.count > 5 {
                    EmptySectionRow("and \(groups.count - 5) more")
                }
            }
        }
    }

    private func subtitle(for group: AgentGroup) -> String {
        if group.processCount > 1 {
            return "\(group.category.displayName) · \(group.processCount) processes"
        }
        return group.category.displayName
    }
}

private extension InventoryCategory {
    var displayName: String {
        switch self {
        case .foregroundCoding:
            return "Coding agent"
        case .backgroundService:
            return "Background service"
        case .browserAgent:
            return "Browser agent"
        case .mcpServer:
            return "MCP server"
        case .runtimeFingerprint:
            return "Runtime fingerprint"
        case .suspicious:
            return "Suspicious"
        }
    }
}

struct AgentsSection_Previews: PreviewProvider {
    static var previews: some View {
        AgentsSection(groups: [
            AgentGroup(
                rootIdentity: "Codex CLI",
                category: .foregroundCoding,
                processCount: 3,
                representativePid: 42,
                representativeVerdict: .agent(reason: .knownList("Codex CLI"), confidence: .medium)
            )
        ])
        .padding()
        .previewDisplayName("Agents Section")
    }
}
