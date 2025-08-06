import SwiftUI

/// Phase 3: full-screen progress indicator
struct AnalyzingView: View {
  var body: some View {
    VStack {
      Spacer()
      ProgressView("Analyzing…")
        .progressViewStyle(CircularProgressViewStyle(tint: .accentColor))
        .font(.title2)
        .padding()
      Spacer()
    }
    .transition(.opacity)
  }
}
