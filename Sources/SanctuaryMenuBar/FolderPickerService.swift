// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import SanctuaryCore

enum FolderPickerService {
    @MainActor
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Protect"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum ExtensionPickerService {
    @MainActor
    static func pickExtension(from candidates: [InstalledBrowserExtension]) -> InstalledBrowserExtension? {
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No supported wallets found"
            alert.informativeText = "Install a supported wallet or password manager extension in Chrome, Brave, Arc, Edge, Vivaldi, or Opera, then try again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return nil
        }

        let sorted = candidates.sorted {
            if $0.friendlyName != $1.friendlyName {
                return $0.friendlyName < $1.friendlyName
            }
            return $0.profilePath < $1.profilePath
        }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        for item in sorted {
            picker.addItem(withTitle: "\(item.friendlyName) - \(MenuBarDataSource.profileDisplayName(for: item.profilePath))")
        }

        let alert = NSAlert()
        alert.messageText = "Add wallet protection"
        alert.informativeText = "Choose an installed wallet or password manager extension."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Protect")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return sorted[picker.indexOfSelectedItem]
    }
}
