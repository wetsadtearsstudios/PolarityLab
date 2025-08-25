import SwiftUI

private let scoreFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 4
    f.minimumFractionDigits = 0
    f.locale = .current
    return f
}()

struct TemplateEditorView: View {
    @State private var searchText: String = ""
    @State private var sortByScoreDescending: Bool = true
    @Binding var template: LexiconTemplate
    let onDeleteRow: (IndexSet) -> Void
    let onAddRow: () -> Void

    private var filteredSortedItems: [LexiconEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = q.isEmpty ? template.items : template.items.filter { $0.phrase.localizedCaseInsensitiveContains(q) }
        return base.sorted { a, b in
            sortByScoreDescending ? (a.score > b.score) : (a.score < b.score)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Header + mode
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { header }
                    VStack(alignment: .leading, spacing: 12) { header }
                }

                // Guidance
                GroupBox {
                    if template.mode == .vader {
                        Text("VADER scores are prior weights per token/phrase on a scale −4.0…+4.0. Use small magnitudes (±0.2…±1.0); reserve |score|≥2 for strong terms. Multi-word phrases are matched literally.")
                    } else {
                        Text("Domain Keyword Bias adjusts model outputs post-prediction on a scale −1.0…+1.0. Start conservatively (±0.05…±0.3). This does not retrain the model.")
                    }
                }

                // Search + sort controls
                HStack(spacing: 8) {
                    TextField("Search keywords", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                    Spacer()
                    Button(action: { sortByScoreDescending.toggle() }) {
                        Label(sortByScoreDescending ? "Score ↓" : "Score ↑",
                              systemImage: sortByScoreDescending ? "arrow.down" : "arrow.up")
                    }
                    .help("Toggle score sort order")
                }

                // Editable table
                Table(filteredSortedItems) {
                    TableColumn("Phrase") { entry in
                        TextField("keyword or phrase", text: binding(for: entry).phrase)
                    }
                    TableColumn("VADER Score") { entry in
                        TextField("score", value: binding(for: entry).score, formatter: scoreFormatter)
                            .frame(width: 100)
                    }
                    TableColumn("") { entry in
                        Button(role: .destructive) {
                            if let idx = template.items.firstIndex(where: { $0.id == entry.id }) {
                                onDeleteRow(IndexSet(integer: idx))
                            }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete row")
                    }
                    .width(34)
                }
                .frame(minHeight: 260, maxHeight: 420)

                // Actions
                HStack(spacing: 8) {
                    Button { onAddRow() } label: { Label("Add Row", systemImage: "plus") }
                    Button(role: .destructive) {
                        if let last = template.items.indices.last { onDeleteRow(IndexSet(integer: last)) }
                    } label: { Label("Delete Last", systemImage: "trash") }
                    Spacer()
                    Text("Rows: \(template.items.count)")
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
        }
        .id(template.id)
        .animation(.default, value: template.items)
    }

    @ViewBuilder private var header: some View {
        TextField("Template name", text: $template.name)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 300)

        Picker("", selection: $template.mode) {
            ForEach(TemplateEditorModel.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        Spacer(minLength: 0)

        if template.mode == .domainBias {
            Image(systemName: "questionmark.circle")
                .help("For AI models, keyword bias adjusts the output; it does not retrain the model.")
        }
    }

    private func binding(for entry: LexiconEntry) -> Binding<LexiconEntry> {
        guard let idx = template.items.firstIndex(where: { $0.id == entry.id }) else {
            return .constant(entry)
        }
        return $template.items[idx]
    }
}
