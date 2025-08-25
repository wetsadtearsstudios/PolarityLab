import SwiftUI
import UniformTypeIdentifiers

/// Phase 1: big “Load CSV” button.
struct EmptyStateView: View {
    /// Called with the selected URL and *parsed* preview CSV.
    let onLoad: (URL, SimpleCSV) -> Void

    @State private var showingImporter         = false
    @State private var showingUnsupportedAlert = false
    @State private var unsupportedName         = ""

    var body: some View {
        VStack(spacing: 32) {

            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)

            Text("Sentiment Analysis")
                .font(.largeTitle).bold()

            Text("Load a CSV file of text data. (Excel isn’t supported — export "
                 + "your .xlsx as .csv first.)")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 60)

            // ── Load CSV button ─────────────────────────────────────────
            Button { showingImporter = true } label: {
                Label("Load CSV", systemImage: "doc.text")
                    .font(.title2.bold())
                    .padding(.vertical, 14)
                    .padding(.horizontal, 30)
                    .background(RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.accentColor))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            // ── File importer ───────────────────────────────────────────
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText, .plainText],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }

                    // Guard against non-CSV extensions
                    guard url.pathExtension.lowercased() == "csv" else {
                        unsupportedName = url.lastPathComponent
                        showingUnsupportedAlert = true
                        return
                    }

                    // Try parsing; treat failure the same as “unsupported”
                    if let csv = try? SimpleCSV(url: url) {
                        onLoad(url, csv)
                    } else {
                        unsupportedName = url.lastPathComponent
                        showingUnsupportedAlert = true
                    }

                case .failure(let error):
                    print("❌ Import failed:", error)
                }
            }
            // ── Unsupported alert ───────────────────────────────────────
            .alert("Unsupported File", isPresented: $showingUnsupportedAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("\(unsupportedName) isn’t a valid CSV. "
                     + "Please export your Excel file to .csv and try again.")
            }
        }
        .padding()
    }
}

#Preview {
    EmptyStateView { _, _ in }
}
