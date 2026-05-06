// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

struct MenuBarPreviewSmokeTests {
    @Test func menuBarPreviewSourceIsPresent() throws {
        let source = try String(contentsOfFile: "Sources/SanctuaryMenuBar/SanctuaryDropdownView.swift")

        #expect(source.contains("SanctuaryDropdownView_Previews"))
        #expect(source.contains(".previewDisplayName(\"Sanctuary Menu\")"))
        #expect(source.contains("SanctuaryDropdownView(dataSource: .preview, quit: {})"))
    }

    @Test func menuBarSectionPreviewsArePresent() throws {
        let sections = [
            "StatusSection",
            "FoldersSection",
            "ExtensionsSection",
            "AgentsSection",
            "ActivitySection",
            "ProtectionToggleSection",
            "SecurityOverviewSection"
        ]

        for section in sections {
            let source = try String(contentsOfFile: "Sources/SanctuaryMenuBar/Sections/\(section).swift")
            #expect(source.contains("\(section)_Previews"))
            #expect(source.contains(".previewDisplayName("))
        }
    }

    @Test func menuBarAppUsesMenuBarExtraAndAccessoryPolicy() throws {
        let source = try String(contentsOfFile: "Sources/SanctuaryMenuBar/MenuBarApp.swift")

        #expect(source.contains("MenuBarExtra"))
        #expect(source.contains("setActivationPolicy(.accessory)"))
        #expect(source.contains(".accessibilityLabel(\"Sanctuary\")"))
    }
}
