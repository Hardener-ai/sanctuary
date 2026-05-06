// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct ExtensionsSection: View {
    let extensions: [ProtectedExtensionEntry]
    let onToggle: (ProtectedExtensionEntry, Bool) -> Void
    let onAdd: () -> Void

    init(
        extensions: [ProtectedExtensionEntry],
        onToggle: @escaping (ProtectedExtensionEntry, Bool) -> Void = { _, _ in },
        onAdd: @escaping () -> Void = {}
    ) {
        self.extensions = extensions
        self.onToggle = onToggle
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("WALLETS & PASSWORDS")
            if extensions.isEmpty {
                EmptySectionRow("None protected")
            } else {
                ForEach(extensions, id: \.rowID) { item in
                    ToggleIconLabelRow(
                        systemName: "key.fill",
                        title: item.friendlyName,
                        subtitle: item.profile,
                        isOn: true,
                        onChange: { onToggle(item, $0) }
                    )
                }
            }
            AddSectionRow(title: "+ Add wallet...", action: onAdd)
        }
    }
}

private extension ProtectedExtensionEntry {
    var rowID: String {
        "\(profilePath)-\(extensionID)-\(friendlyName)-\(profile)"
    }
}

struct ExtensionsSection_Previews: PreviewProvider {
    static var previews: some View {
        ExtensionsSection(extensions: [
            .init(friendlyName: "MetaMask", profile: "Brave Default"),
            .init(friendlyName: "1Password", profile: "Chrome Profile 1")
        ])
        .padding()
        .previewDisplayName("Extensions Section")
    }
}
