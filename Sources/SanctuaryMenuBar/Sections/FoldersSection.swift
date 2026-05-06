// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct FoldersSection: View {
    let folders: [ProtectedFolderEntry]
    let onToggle: (ProtectedFolderEntry, Bool) -> Void
    let onAdd: () -> Void

    init(
        folders: [ProtectedFolderEntry],
        onToggle: @escaping (ProtectedFolderEntry, Bool) -> Void = { _, _ in },
        onAdd: @escaping () -> Void = {}
    ) {
        self.folders = folders
        self.onToggle = onToggle
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader("FOLDERS")
            if folders.isEmpty {
                EmptySectionRow("None protected")
            } else {
                ForEach(folders, id: \.displayPath) { folder in
                    ToggleIconLabelRow(
                        systemName: "folder",
                        title: folder.displayPath,
                        subtitle: nil,
                        isOn: true,
                        onChange: { onToggle(folder, $0) }
                    )
                }
            }
            AddSectionRow(title: "+ Add folder...", action: onAdd)
        }
    }
}

struct FoldersSection_Previews: PreviewProvider {
    static var previews: some View {
        FoldersSection(folders: [
            .init(displayPath: "~/.ssh", source: "default"),
            .init(displayPath: "~/Library/Application Support/Ledger Live", source: "default")
        ])
        .padding()
        .previewDisplayName("Folders Section")
    }
}
