import SwiftUI

private enum AnalysisStage: Equatable {
    case empty
    case preview(csv: SimpleCSV)
    case analyzing
    case results(
        rows: [[String:String]],
        keywords: [(String,Double)],
        exportData: Data,
        keywordExportData: Data
    )

    static func ==(lhs: AnalysisStage, rhs: AnalysisStage) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty), (.analyzing, .analyzing):
            return true
        case let (.preview(a), .preview(b)):
            return a.url == b.url
        case (.results, .results):
            return true
        default:
            return false
        }
    }
}

struct SentimentAnalysisView: View {
    @State private var stage: AnalysisStage = .empty
    @State private var selectedColumns = [String]()
    @State private var selectedModel: SentimentModel = .vader
    @State private var showingExporter = false
    @State private var showingKeywordExporter = false

    var body: some View {
        ZStack {
            switch stage {
            case .empty:
                EmptyStateView { url, csv in
                    selectedColumns = [csv.headers.first!]
                    stage = .preview(csv: csv)
                }
                .onAppear {
                    print("🛑 DEBUG: empty state – waiting for Load CSV")
                }

            case .preview(let csv):
                CSVPreviewView(
                    csv: csv,
                    selectedColumns: $selectedColumns,
                    selectedModel: $selectedModel,
                    onAnalyze: runAnalysis
                )
                .onAppear {
                    print("✅ DEBUG: entering preview for \(csv.url.lastPathComponent)")
                }

            case .analyzing:
                AnalyzingView()
                    .onAppear {
                        print("🔄 DEBUG: started analyzing")
                    }

            case .results(let rows, let keywords, let exportData, let keywordExportData):
                AnalysisResultsView(
                    selectedColumns: selectedColumns,
                    allRows: rows,
                    keywords: keywords,
                    exportData: exportData,
                    keywordExportData: keywordExportData,
                    showingExporter: $showingExporter,
                    showingKeywordExporter: $showingKeywordExporter
                ) {
                    // Reset state
                    selectedColumns = []
                    showingExporter = false
                    showingKeywordExporter = false
                    stage = .empty
                }
                .onAppear {
                    print("🎉 DEBUG: got results with \(rows.count) rows")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut, value: stage)
        .onChange(of: stage) { newStage in
            print("📊 DEBUG: stage changed to \(newStage)")
        }
    }

    private func runAnalysis() {
        guard case .preview(let csv) = stage else { return }
        stage = .analyzing

        Task {
            let json = PythonBridge.runSentimentAnalysis(
                filePath:     csv.url.path,
                selectedCols: selectedColumns,
                skipRows:     0,
                mergeText:    true,
                model:         selectedModel
            )

            guard
                let data    = json.data(using: .utf8),
                let top     = try? JSONSerialization.jsonObject(with: data) as? [String:Any],
                let rowsAny = top["rows"] as? [[String:Any]],
                let headers = top["row_headers"] as? [String],
                let kwsComp = top["keywords_comp"] as? [[String:Any]]
            else {
                print("❌ DEBUG: failed to parse JSON, resetting to .empty")
                stage = .empty
                return
            }

            // Convert to [[String:String]]
            let stringRows: [[String:String]] = rowsAny.map { dict in
                Dictionary(uniqueKeysWithValues:
                    headers.map { key in (key, "\(dict[key] ?? "")") }
                )
            }

            // CSV export
            var lines = [headers.joined(separator: ",")]
            for row in stringRows {
                lines.append(headers.map { row[$0]! }.joined(separator: ","))
            }
            let exportData = lines.joined(separator: "\n").data(using: .utf8)!

            // Keyword CSV export
            var kwLines = ["word,compound"]
            for item in kwsComp {
                if let w = item["word"] as? String,
                   let c = item["compound"] as? Double {
                    kwLines.append("\(w),\(String(format: "%.2f", c))")
                }
            }
            let keywordExportData = kwLines.joined(separator: "\n").data(using: .utf8)!

            // Prepare keywords for display
            let kwList: [(String, Double)] = kwsComp.compactMap { item in
                if let w = item["word"] as? String,
                   let c = item["compound"] as? Double {
                    return (w, c)
                }
                return nil
            }

            await MainActor.run {
                stage = .results(
                    rows: stringRows,
                    keywords: kwList,
                    exportData: exportData,
                    keywordExportData: keywordExportData
                )
            }
        }
    }
}
