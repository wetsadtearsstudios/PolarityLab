// Utils.swift
import SwiftUI

// Clamp to [-1, 1]
func clamp1(_ x: Double) -> Double { max(-1.0, min(1.0, x)) }

// Small chip
@ViewBuilder func chip(_ text: String) -> some View {
    Text(text)
        .font(.footnote.weight(.semibold))
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
}

func formattedDateLine() -> String {
    let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
    return f.string(from: Date())
}

func dateTooltip(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    f.dateStyle = .medium; return f.string(from: d)
}
