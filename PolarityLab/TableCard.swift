// TableCard.swift
import SwiftUI

struct TableCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content
    
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        // NOTE: no fixed width/height here—layout owns sizing.
    }
}
