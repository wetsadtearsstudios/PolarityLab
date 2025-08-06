import SwiftUI
import UniformTypeIdentifiers

/// Shows your final sentiment results and keyword compound scores.
struct AnalysisResultsView: View {
    // MARK: – Inputs
    let selectedColumns: [String]
    let allRows: [[String: Any]]        // full rows, with appended pos/neu/neg/compound
    let keywords: [(String, Double)]    // [(word, compoundScore)]
    let exportData: Data?
    let keywordExportData: Data?
    @Binding var showingExporter: Bool
    @Binding var showingKeywordExporter: Bool
    let onReset: () -> Void

    // MARK: – Layout constants
    private let cellWidth: CGFloat       = 100
    private let cellPadding: CGFloat     = 8
    private let maxPreviewRows           = 100

    // build the final column order: text cols first, then pos/neut/neg/compound
    private var displayColumns: [String] {
        let sentimentCols = ["pos","neu","neg","compound"]
        let extras = sentimentCols.filter { !selectedColumns.contains($0) }
        return selectedColumns + extras
    }

    var body: some View {
        VStack(spacing: 0) {
            // ─── Title & Reset ───────────────────────────
            HStack {
                Text("Results")
                    .font(.largeTitle).bold()
                Spacer()
                Button(action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.title3).bold()
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                        )
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top, 16)

            Divider()

            // ─── Main Results Table ──────────────────────
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(spacing: 0) {
                    // Header row
                    HStack(spacing: 0) {
                        ForEach(displayColumns, id: \.self) { col in
                            Text(col.capitalized)
                                .font(.headline).bold()
                                .frame(width: cellWidth)
                                .padding(.vertical, cellPadding)
                        }
                    }
                    .background(Color.secondary.opacity(0.1))
                    Divider()

                    // Data rows (limit to 100)
                    ForEach(Array(allRows.prefix(maxPreviewRows).enumerated()), id: \.offset) { idx, row in
                        HStack(spacing: 0) {
                            ForEach(displayColumns, id: \.self) { col in
                                cellText(for: row[col])
                                    .frame(width: cellWidth)
                                    .padding(.vertical, cellPadding)
                            }
                        }
                        if idx < min(allRows.count, maxPreviewRows) - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, cellPadding)
            }
            .frame(maxHeight: 300)

            Divider()
                .padding(.vertical, 16)

            // ─── Keyword Compound Table ─────────────────
            if !keywords.isEmpty {
                Text("Keyword Compound Scores")
                    .font(.title2).bold()
                    .padding(.bottom, 8)

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 0) {
                        // header
                        HStack {
                            Text("Word")
                                .font(.headline)
                                .frame(width: 150, alignment: .leading)
                            Spacer()
                            Text("Compound")
                                .font(.headline)
                                .frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        Divider()

                        // rows
                        ForEach(keywords, id: \.0) { word, comp in
                            HStack {
                                Text(word)
                                    .frame(width: 150, alignment: .leading)
                                Spacer()
                                Text(String(format: "%+.2f", comp))
                                    .foregroundColor(comp > 0
                                                      ? .green
                                                      : comp < 0
                                                        ? .red
                                                        : .primary)
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding(.horizontal, cellPadding)
                }
                .frame(maxHeight: 200)
            }

            Spacer(minLength: 20)

            // ─── Export Buttons ──────────────────────────
            HStack(spacing: 16) {
                // Analysis CSV
                Button(action: { showingExporter = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2)
                        Text("Export Analysis CSV")
                            .font(.title3).bold()
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 30)
                    .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.accentColor))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .fileExporter(
                    isPresented: $showingExporter,
                    document: CSVDocument(data: exportData ?? Data()),
                    contentTypes: [.commaSeparatedText],
                    defaultFilename: "analysis.csv"
                ) { _ in }

                // Keywords CSV
                Button(action: { showingKeywordExporter = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2)
                        Text("Export Keywords CSV")
                            .font(.title3).bold()
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 30)
                    .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.accentColor))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .fileExporter(
                    isPresented: $showingKeywordExporter,
                    document: CSVDocument(data: keywordExportData ?? Data()),
                    contentTypes: [.commaSeparatedText],
                    defaultFilename: "keywords.csv"
                ) { _ in }
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Rounds doubles to two decimals, otherwise shows the string
    @ViewBuilder
    private func cellText(for value: Any?) -> some View {
        if let d = value as? Double {
            Text(String(format: "%.2f", d))
                .font(.callout)
        } else if let s = value as? String, let d = Double(s) {
            Text(String(format: "%.2f", d))
                .font(.callout)
        } else if let s = value as? String {
            Text(s).font(.callout)
        } else {
            Text("").font(.callout)
        }
    }
}
