import SwiftUI
import UniformTypeIdentifiers
import Foundation

// MARK: - Unified Models

struct UnifiedLexiconEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var phrase: String
    var vaderScore: Double?   // −4…+4
    var biasScore: Double?    // −1…+1
}

struct UnifiedLexiconTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var items: [UnifiedLexiconEntry]
}

// MARK: - Persistence

final class TemplatesStore {
    static let shared = TemplatesStore()
    private let url: URL
    
    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PolarityLab", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("templates.json")
    }
    
    func load() -> [UnifiedLexiconTemplate] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([UnifiedLexiconTemplate].self, from: data)) ?? []
    }
    
    func save(_ templates: [UnifiedLexiconTemplate]) {
        do {
            let data = try JSONEncoder().encode(templates)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("💾 Save error: \(error)")
        }
    }
}

// MARK: - Modes & Mapping

enum TemplateEditorMode: String, CaseIterable, Identifiable {
    case vader = "VADER"
    case bias  = "Domain Bias"
    var id: String { rawValue }
    var shortName: String { self == .vader ? "VADER" : "Bias" }
    var counterpart: TemplateEditorMode { self == .vader ? .bias : .vader }
    var scoreRange: ClosedRange<Double> { self == .vader ? (-4.0...4.0) : (-1.0...1.0) }
}

private func mapScore(_ value: Double, from: TemplateEditorMode, to: TemplateEditorMode) -> Double {
    guard from != to else { return value }
    switch (from, to) {
    case (.vader, .bias): return max(-1.0, min(1.0, value / 4.0))
    case (.bias, .vader): return max(-4.0, min(4.0, value * 4.0))
    default: return value
    }
}

// MARK: - Validator (light heuristic)

private let COMMON_VADER_BENCHMARK: [String: Double] = [
    "good": 2.0, "great": 3.0, "excellent": 3.5, "love": 3.2, "like": 1.5,
    "bad": -2.0, "terrible": -3.0, "awful": -3.2, "hate": -3.2,
    "bug": -1.5, "crash": -2.2, "slow": -1.4, "broken": -2.5,
    "intuitive": 1.6, "powerful": 1.8, "easy": 1.4, "hard": -1.2
]

private func validatorMessage(phrase: String, score: Double, mode: TemplateEditorMode) -> String? {
    let key = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard let vaderExpected = COMMON_VADER_BENCHMARK[key] else { return nil }
    let expected = (mode == .vader) ? vaderExpected : vaderExpected / 4.0
    let threshold = (mode == .vader) ? 0.75 : 0.25
    if abs(score - expected) >= threshold {
        return "Unusual score. Typical \(mode.shortName) ≈ \(String(format: "%.2f", expected))."
    }
    return nil
}

// MARK: - CSV Helpers (tiny, 2-column)

private func parseTemplateCSV(_ data: Data) -> (headers: [String], rows: [[String]])? {
    guard let s = String(data: data, encoding: .utf8) else { return nil }
    let lines = s.split(whereSeparator: \.isNewline).map { String($0) }
    guard !lines.isEmpty else { return nil }
    
    func splitCSVLine(_ line: String) -> [String] {
        var out: [String] = [], cur = ""; var inQ = false
        for ch in line {
            if ch == "\"" { inQ.toggle(); cur.append(ch) }
            else if ch == "," && !inQ { out.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        out.append(cur)
        return out.map {
            var t = $0
            if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t.removeFirst(); t.removeLast() }
            return t.replacingOccurrences(of: "\"\"", with: "\"")
        }
    }
    
    let headers = splitCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces) }
    let rows = lines.dropFirst().map { splitCSVLine($0) }
    return (headers, rows)
}

private func emptyTemplateCSVData() -> Data {
    Data("Keywords/Phrases,Score\n".utf8)
}

private func makeCSVData(from items: [UnifiedLexiconEntry], mode: TemplateEditorMode) -> Data {
    var out = "Keywords/Phrases,Score\n"
    for e in items {
        let score = (mode == .vader) ? e.vaderScore : e.biasScore
        let phrase = e.phrase.replacingOccurrences(of: "\"", with: "\"\"")
        let needsQuotes = phrase.contains(",") || phrase.contains("\n") || phrase.contains("\"")
        let field = needsQuotes ? "\"\(phrase)\"" : phrase
        if let s = score { out += "\(field),\(String(format: "%.4f", s))\n" }
        else { out += "\(field),\n" }
    }
    return Data(out.utf8)
}

// MARK: - FileDocuments

struct UnifiedCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = d
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        .init(regularFileWithContents: data)
    }
}

struct UnifiedTemplatesJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }
    var templates: [UnifiedLexiconTemplate]
    init(templates: [UnifiedLexiconTemplate]) { self.templates = templates }
    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        templates = try JSONDecoder().decode([UnifiedLexiconTemplate].self, from: d)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let d = try JSONEncoder().encode(templates)
        return .init(regularFileWithContents: d)
    }
}

// MARK: - Main View

struct CustomTemplatesView: View {
    // Data
    @State private var templates: [UnifiedLexiconTemplate] = TemplatesStore.shared.load()
    @State private var selection: UUID?
    
    // Editor state
    @State private var currentMode: TemplateEditorMode = .vader
    @State private var selectedRowIDs: Set<UUID> = []
    
    // File UI
    @State private var showImportCSV = false
    @State private var showExportJSON = false
    @State private var errorMessage: String?
    
    // Delete confirm
    @State private var pendingDeleteID: UUID?
    @State private var showDeleteConfirm = false
    
    var body: some View {
        NavigationSplitView {
            TemplatesSidebar(
                templates: $templates,
                selection: $selection,
                onDeleteRequest: { id in pendingDeleteID = id; showDeleteConfirm = true }
            )
        } detail: {
            if let idx = currentTemplateIndex {
                TemplateEditor(
                    template: $templates[idx],
                    currentMode: $currentMode,
                    selectedRowIDs: $selectedRowIDs,
                    onImportCSV: { showImportCSV = true },
                    onTransferSelected: { transferSelectedRows(in: idx) }
                )
            } else {
                LandingView()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { addTemplate() } label: { Label("New Template", systemImage: "plus") }.font(.headline)
                Button(role: .destructive) {
                    if let sel = selection { pendingDeleteID = sel; showDeleteConfirm = true }
                } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selection == nil)
                    .font(.headline)
                Button { showExportJSON = true } label: { Label("Export All (JSON)", systemImage: "square.and.arrow.up.on.square") }.font(.headline)
            }
        }
        .alert("Import Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }.font(.headline)
        } message: { Text(errorMessage ?? "") }
            .alert("Delete Template?", isPresented: $showDeleteConfirm, presenting: pendingDeleteID) { id in
                Button("Delete", role: .destructive) { deleteTemplate(id) }.font(.headline)
                Button("Cancel", role: .cancel) { }.font(.headline)
            } message: { _ in Text("This cannot be undone.") }
            .fileImporter(isPresented: $showImportCSV, allowedContentTypes: [.commaSeparatedText]) { result in
                handleImport(result: result)
            }
            .fileExporter(isPresented: $showExportJSON,
                          document: UnifiedTemplatesJSONDocument(templates: templates),
                          contentTypes: [.json],
                          defaultFilename: "templates.json") { _ in }
            .environment(\.controlSize, .large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: templates) { TemplatesStore.shared.save($0) }
    }
    
    // MARK: - Sidebar helpers
    
    private var currentTemplateIndex: Int? {
        guard let sel = selection else { return nil }
        return templates.firstIndex { $0.id == sel }
    }
    
    private func addTemplate() {
        let t = UnifiedLexiconTemplate(name: "New Template", items: [])
        templates.append(t)
        selection = t.id
        selectedRowIDs.removeAll()
    }
    
    private func deleteTemplate(_ id: UUID) {
        if let idx = templates.firstIndex(where: { $0.id == id }) {
            templates.remove(at: idx)
        }
        if selection == id { selection = nil }
        pendingDeleteID = nil
        selectedRowIDs.removeAll()
    }
    
    // MARK: - Import / Export
    
    private func handleImport(result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            
            let data = try Data(contentsOf: url)
            guard let parsed = parseTemplateCSV(data) else {
                errorMessage = "Could not parse CSV file."
                return
            }
            guard parsed.headers.count == 2,
                  parsed.headers[0].trimmingCharacters(in: .whitespacesAndNewlines) == "Keywords/Phrases",
                  parsed.headers[1].trimmingCharacters(in: .whitespacesAndNewlines) == "Score" else {
                errorMessage = "CSV must have exactly two headers: “Keywords/Phrases,Score”."
                return
            }
            
            guard let idx = currentTemplateIndex else {
                errorMessage = "Select a template before importing."
                return
            }
            
            var dict = Dictionary(uniqueKeysWithValues:
                                    templates[idx].items.map { ($0.phrase.lowercased(), $0) })
            
            for row in parsed.rows {
                if row.isEmpty { continue }
                let phrase = (row.indices.contains(0) ? row[0] : "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let raw = (row.indices.contains(1) ? row[1] : "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard !phrase.isEmpty else { continue }
                guard let val = Double(raw) else {
                    errorMessage = "“\(raw)” is not a valid number for “\(phrase)”."
                    return
                }
                let allowed = currentMode.scoreRange
                guard allowed.contains(val) else {
                    errorMessage = "Score \(val) for “\(phrase)” is out of range \(allowed.lowerBound)…\(allowed.upperBound)."
                    return
                }
                
                var e = dict[phrase.lowercased()] ?? UnifiedLexiconEntry(phrase: phrase, vaderScore: nil, biasScore: nil)
                if currentMode == .vader { e.vaderScore = val } else { e.biasScore = val }
                dict[phrase.lowercased()] = e
            }
            
            templates[idx].items = dict.values.sorted {
                $0.phrase.localizedCaseInsensitiveCompare($1.phrase) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - Transfer
    
    private func transferSelectedRows(in templateIndex: Int) {
        let from = currentMode
        let to   = currentMode.counterpart
        
        for i in templates[templateIndex].items.indices {
            let e = templates[templateIndex].items[i]
            guard selectedRowIDs.contains(e.id) else { continue }
            
            switch (from, to) {
            case (.vader, .bias):
                if let v = e.vaderScore {
                    templates[templateIndex].items[i].biasScore = mapScore(v, from: .vader, to: .bias)
                }
            case (.bias, .vader):
                if let b = e.biasScore {
                    templates[templateIndex].items[i].vaderScore = mapScore(b, from: .bias, to: .vader)
                }
            default:
                break
            }
        }
    }
}

// MARK: - Subviews

private struct TemplatesSidebar: View {
    @Binding var templates: [UnifiedLexiconTemplate]
    @Binding var selection: UUID?
    var onDeleteRequest: (UUID) -> Void
    
    var body: some View {
        List(selection: $selection) {
            Section("Templates") {
                ForEach(templates) { tmpl in
                    HStack {
                        Text(tmpl.name)
                        Spacer()
                        Text("\(tmpl.items.count) items").foregroundColor(.secondary)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            onDeleteRequest(tmpl.id)
                        } label: {
                            Label("Delete Template", systemImage: "trash")
                        }
                        .font(.headline)
                    }
                    .tag(tmpl.id)
                }
            }
        }
        .frame(minWidth: 260)
    }
}

private struct TemplateEditor: View {
    @Binding var template: UnifiedLexiconTemplate
    @Binding var currentMode: TemplateEditorMode
    @Binding var selectedRowIDs: Set<UUID>
    
    var onImportCSV: () -> Void
    var onTransferSelected: () -> Void
    
    @State private var showExporter = false
    @State private var exportData = Data()
    @State private var exportFilename = "template.csv"
    
    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                templateName: $template.name,
                currentMode: $currentMode,
                selectedCount: selectedRowIDs.count,
                onImportCSV: onImportCSV,
                onExportCSVData: {
                    exportData = makeCSVData(from: template.items, mode: currentMode)
                    exportFilename = defaultCSVName(templateName: template.name, mode: currentMode)
                    showExporter = true
                },
                onDownloadBlankCSV: {
                    exportData = emptyTemplateCSVData()
                    exportFilename = "template_blank.csv"
                    showExporter = true
                },
                onTransferSelected: onTransferSelected
            )
            Divider()
            RowsList(
                template: $template,
                currentMode: $currentMode,
                selectedRowIDs: $selectedRowIDs
            )
        }
        .fileExporter(isPresented: $showExporter,
                      document: UnifiedCSVDocument(data: exportData),
                      contentTypes: [.commaSeparatedText],
                      defaultFilename: exportFilename) { _ in }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func defaultCSVName(templateName: String, mode: TemplateEditorMode) -> String {
        let base = templateName.replacingOccurrences(of: " ", with: "_").lowercased()
        return "\(base)_\(mode.shortName.lowercased()).csv"
    }
}

private struct EditorToolbar: View {
    @Binding var templateName: String
    @Binding var currentMode: TemplateEditorMode
    let selectedCount: Int
    
    var onImportCSV: () -> Void
    var onExportCSVData: () -> Void
    var onDownloadBlankCSV: () -> Void
    var onTransferSelected: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // Name + mode: row on wide, stack on narrow
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    TextField("Template name", text: $templateName)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .frame(minWidth: 240, maxWidth: .infinity)
                    
                    Picker("Mode", selection: $currentMode) {
                        ForEach(TemplateEditorMode.allCases) { Text($0.shortName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .font(.headline)
                    .frame(minWidth: 200, maxWidth: 360)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Template name", text: $templateName)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .frame(minWidth: 240, maxWidth: .infinity)
                    
                    Picker("Mode", selection: $currentMode) {
                        ForEach(TemplateEditorMode.allCases) { Text($0.shortName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .font(.headline)
                    .frame(maxWidth: 420)
                }
            }
            
            // Buttons: flow into rows; each expands to fill its cell
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .leading)], spacing: 12) {
                Button(action: onImportCSV) {
                    Label("Import CSV (data)", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .font(.headline)
                .frame(maxWidth: .infinity)
                
                Button(action: onExportCSVData) {
                    Label("Export CSV (data)", systemImage: "arrow.up.doc")
                }
                .buttonStyle(.borderedProminent)
                .font(.headline)
                .frame(maxWidth: .infinity)
                
                Button(action: onDownloadBlankCSV) {
                    Label("Download CSV Template", systemImage: "doc")
                }
                .help("Blank CSV with headers: “Keywords/Phrases,Score”")
                .buttonStyle(.bordered)
                .font(.headline)
                .frame(maxWidth: .infinity)
                
                Button(action: onTransferSelected) {
                    Label("Transfer Selected → \(currentMode.counterpart.shortName)", systemImage: "arrow.right.arrow.left")
                }
                .disabled(selectedCount == 0)
                .buttonStyle(.borderedProminent)
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }
}
private struct RowsList: View {
    @Binding var template: UnifiedLexiconTemplate
    @Binding var currentMode: TemplateEditorMode
    @Binding var selectedRowIDs: Set<UUID>

    @State private var query: String = ""
    private enum SortKey: String, CaseIterable, Identifiable { case phrase, score; var id: String { rawValue } }
    @State private var sortKey: SortKey = .phrase
    @State private var ascending: Bool = true

    private func score(of e: UnifiedLexiconEntry) -> Double? {
        return currentMode == .vader ? e.vaderScore : e.biasScore
    }

    private var filteredSortedIndices: [Int] {
        let items = template.items
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var idxs = items.indices.filter { idx in
            q.isEmpty || items[idx].phrase.localizedCaseInsensitiveContains(q)
        }
        idxs.sort { i, j in
            let a = items[i], b = items[j]
            switch sortKey {
            case .phrase:
                let cmp = a.phrase.localizedCaseInsensitiveCompare(b.phrase)
                return ascending ? (cmp != .orderedDescending) : (cmp == .orderedDescending)
            case .score:
                let sa = score(of: a)
                let sb = score(of: b)
                let aNil = (sa == nil)
                let bNil = (sb == nil)
                if aNil != bNil { return !aNil } // non-nil first
                let va = sa ?? 0.0
                let vb = sb ?? 0.0
                if va == vb {
                    let cmp = a.phrase.localizedCaseInsensitiveCompare(b.phrase)
                    return cmp != .orderedDescending
                }
                return ascending ? (va < vb) : (va > vb)
            }
        }
        return idxs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header + search/sort controls
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Phrases (\(template.items.count))").font(.title3.bold())
                    Spacer()
                    HStack(spacing: 8) {
                        TextField("Search keywords", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                        Picker("Sort", selection: $sortKey) {
                            Text("Word").tag(SortKey.phrase)
                            Text("Score").tag(SortKey.score)
                        }
                        .pickerStyle(.segmented)
                        Button {
                            ascending.toggle()
                        } label: {
                            Label(ascending ? "Asc" : "Desc", systemImage: ascending ? "arrow.up" : "arrow.down")
                        }
                        .buttonStyle(.bordered)
                        Button("Select All")  { selectedRowIDs = Set(template.items.map { $0.id }) }
                        Button("Clear")       { selectedRowIDs.removeAll() }
                        Button(role: .destructive) {
                            template.items.removeAll { selectedRowIDs.contains($0.id) }
                            selectedRowIDs.removeAll()
                        } label: { Text("Delete Selected") }
                        .disabled(selectedRowIDs.isEmpty)
                    }
                    .font(.headline)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Phrases (\\(template.items.count))").font(.title3.bold())
                    HStack(spacing: 8) {
                        TextField("Search keywords", text: $query)
                            .textFieldStyle(.roundedBorder)
                        Picker("Sort", selection: $sortKey) {
                            Text("Word").tag(SortKey.phrase)
                            Text("Score").tag(SortKey.score)
                        }
                        .pickerStyle(.segmented)
                        Button {
                            ascending.toggle()
                        } label: {
                            Label(ascending ? "Asc" : "Desc", systemImage: ascending ? "arrow.up" : "arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        Button("Select All")  { selectedRowIDs = Set(template.items.map { $0.id }) }
                        Button("Clear")       { selectedRowIDs.removeAll() }
                        Button(role: .destructive) {
                            template.items.removeAll { selectedRowIDs.contains($0.id) }
                            selectedRowIDs.removeAll()
                        } label: { Text("Delete Selected") }
                        .disabled(selectedRowIDs.isEmpty)
                    }
                    .font(.headline)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            Divider()

            // Two-axis scrolling: horizontal for columns, vertical for rows
            ScrollView(.horizontal, showsIndicators: true) {
                let minContentWidth: CGFloat = 820
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredSortedIndices, id: \.self) { idx in
                                EditableRow(entry: $template.items[idx], mode: $currentMode, selectedRowIDs: $selectedRowIDs)
                                Divider()
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .frame(maxHeight: .infinity)
                }
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .frame(minWidth: minContentWidth, maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button {
                    // Insert new row at the TOP
                    template.items.insert(.init(phrase: "", vaderScore: nil, biasScore: nil), at: 0)
                } label: {
                    Label("Add Row", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerRow: some View {
        HStack {
            Text("").frame(width: 28)
            Text("Phrase").font(.headline)
            Spacer()
            Text("\(currentMode.shortName) Score").font(.headline)
                .frame(width: 180, alignment: .trailing)
            Text("").frame(width: 26)
        }
        .padding(.vertical, 8)
    }
}


private struct EditableRow: View {
    @Binding var entry: UnifiedLexiconEntry
    @Binding var mode: TemplateEditorMode
    @Binding var selectedRowIDs: Set<UUID>
    
    var body: some View {
        let bindingSelected = Binding<Bool>(
            get: { selectedRowIDs.contains(entry.id) },
            set: { isOn in
                if isOn { _ = selectedRowIDs.insert(entry.id) }
                else    { selectedRowIDs.remove(entry.id) }
            }
        )
        
        let scoreStr = Binding<String>(
            get: {
                let v = (mode == .vader) ? entry.vaderScore : entry.biasScore
                guard let v else { return "" }
                return String(format: "%.4f", v)
            },
            set: { newText in
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if mode == .vader { entry.vaderScore = nil } else { entry.biasScore = nil }
                } else if let v = Double(trimmed) {
                    let r = mode.scoreRange
                    let c = min(max(v, r.lowerBound), r.upperBound)
                    if mode == .vader { entry.vaderScore = c } else { entry.biasScore = c }
                }
            }
        )
        
        let numericScore: Double? = (mode == .vader) ? entry.vaderScore : entry.biasScore
        let warningText = numericScore.flatMap { validatorMessage(phrase: entry.phrase, score: $0, mode: mode) }
        
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: bindingSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 28)
            
            TextField("keyword or phrase", text: $entry.phrase)
                .lineLimit(1)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.body)
            
            Spacer()
            
            TextField("score", text: scoreStr)
                .frame(width: 180)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.body)
            
            if let msg = warningText {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .help(msg)
                    .frame(width: 26)
            } else {
                Color.clear.frame(width: 26)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Landing

private struct LandingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("Custom Lexicon Templates").font(.largeTitle.bold())
            Text("""
Templates let you **override** sentiment scores for phrases.

They apply in two ways:
• **VADER** (−4…+4): overrides the lexicon used by VADER.
• **Domain Bias** (−1…+1): adjusts AI model outputs post-prediction for domain terms.

Tip: Use the Playground to try scores before running a full dataset.
""")
            .foregroundColor(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 680)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
