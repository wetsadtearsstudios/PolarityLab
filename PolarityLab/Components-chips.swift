// Components/Chips.swift
import SwiftUI

struct TagCapsule: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

struct WrapChips: View {
    let words: [String]; let color: Color
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
            ForEach(words, id: \.self) { w in
                Text(w)
                    .font(.caption.weight(.medium))
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(color))
            }
        }
    }
}
