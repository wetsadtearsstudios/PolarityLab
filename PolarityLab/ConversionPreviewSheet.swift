import SwiftUI

struct ConversionPreviewSheet: View {
    let sourceMode: TemplateEditorModel
    let targetMode: TemplateEditorModel
    let items: [LexiconEntry]

    // Row model for the Table (avoid tuple headaches)
    private struct PreviewRow: Identifiable {
        let id: String          // use phrase as the stable id
        let phrase: String
        let sourceScore: Double
        let targetScore: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert Template")
                .font(.title2.bold())

            Text("""
You’re converting the scores from \(sourceMode.shortName) to \(targetMode.shortName).

Mapping:
• VADER (−4…+4) → Bias (−1…+1): score ÷ 4
• Bias (−1…+1) → VADER (−4…+4): score × 4

We’ll clamp anything out of range.
""")
            .foregroundColor(.secondary)

            Table(previewRows) {
                TableColumn("Phrase") { row in
                    Text(row.phrase)
                }
                TableColumn("\(sourceMode.shortName) Score") { row in
                    Text(String(format: "%.4f", row.sourceScore))
                }
                TableColumn("\(targetMode.shortName) Score") { row in
                    Text(String(format: "%.4f", row.targetScore))
                }
            }
            .frame(height: min(240, CGFloat(previewRows.count) * 28 + 40))
        }
        .padding(20)
        .frame(width: 560)
    }

    // Build up to 12 preview rows
    private var previewRows: [PreviewRow] {
        items.prefix(12).map { e in
            let mapped = mapScore(e.score, from: sourceMode, to: targetMode)
            return PreviewRow(id: e.phrase,
                              phrase: e.phrase,
                              sourceScore: e.score,
                              targetScore: mapped)
        }
    }
}
