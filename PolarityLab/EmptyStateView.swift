import SwiftUI
import UniformTypeIdentifiers

/// Phase 1: “Empty” state with a big Load CSV button
struct EmptyStateView: View {
  /// Called with the selected URL and parsed preview CSV
  let onLoad: (URL, SimpleCSV) -> Void

  @State private var showingImporter = false
  @State private var showingUnsupportedAlert = false
  @State private var unsupportedName = ""

  var body: some View {
    VStack(spacing: 32) {
      Image(systemName: "tray.and.arrow.down.fill")
        .font(.system(size: 60))
        .foregroundColor(.accentColor)

      Text("Sentiment Analysis")
        .font(.largeTitle)
        .bold()

      Text("Load a CSV file of text data (Excel is not supported). If your data is in .xlsx format, please export it as CSV first.")
        .multilineTextAlignment(.center)
        .foregroundColor(.secondary)
        .padding(.horizontal, 60)

      Button(action: { showingImporter = true }) {
        HStack(spacing: 12) {
          Image(systemName: "doc.text")
          Text("Load CSV")
            .font(.title2).bold()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 30)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor))
        .foregroundColor(.white)
      }
      .buttonStyle(.plain)
      .fileImporter(
        isPresented: $showingImporter,
        allowedContentTypes: [.commaSeparatedText, .plainText],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          guard let url = urls.first else { return }
          // Only .csv
          if url.pathExtension.lowercased() != "csv" {
            unsupportedName = url.lastPathComponent
            showingUnsupportedAlert = true
            return
          }
          if let csv = SimpleCSV(url: url) {
            onLoad(url, csv)
          } else {
            // parsing failed for malformed CSV
            unsupportedName = url.lastPathComponent
            showingUnsupportedAlert = true
          }
        case .failure(let err):
          print("❌ Import failed:", err)
        }
      }
      .alert("Unsupported File", isPresented: $showingUnsupportedAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text("\(unsupportedName) is not a valid CSV. Please export your Excel file to .csv and try again.")
      }
    }
    .padding()
  }
}

struct EmptyStateView_Previews: PreviewProvider {
  static var previews: some View {
    EmptyStateView { _, _ in }
  }
}
