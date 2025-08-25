// Components/Controls.swift
import SwiftUI

struct ToggleButton: View {
    @Binding var isOn: Bool
    let label: String
    let icon: String
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) { Image(systemName: icon); Text(label) }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundColor(isOn ? .white : .primary)
        }.buttonStyle(.plain)
    }
}
