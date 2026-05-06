// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct ProtectionToggleSection: View {
    let isOn: Bool
    let isBusy: Bool
    let onToggle: (Bool) -> Void

    init(isOn: Bool, isBusy: Bool = false, onToggle: @escaping (Bool) -> Void = { _ in }) {
        self.isOn = isOn
        self.isBusy = isBusy
        self.onToggle = onToggle
    }

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { isOn },
                set: { onToggle($0) }
            )
        ) {
            Text("Sanctuary protection")
                .font(DesignTokens.Typography.body.weight(.medium))
                .foregroundStyle(DesignTokens.Colors.label)
        }
        .toggleStyle(.switch)
        .disabled(isBusy)
        .frame(minHeight: DesignTokens.Spacing.rowMinHeight, alignment: .center)
        .contentShape(Rectangle())
    }
}

struct ProtectionToggleSection_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            ProtectionToggleSection(isOn: true)
            ProtectionToggleSection(isOn: false)
        }
        .padding()
        .previewDisplayName("Protection Toggle Section")
    }
}
