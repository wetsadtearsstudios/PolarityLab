import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Sentiment Playground (uses external SentimentRuntime.swift)
struct LexiconView: View {

    // ────────── user-editable state ──────────
    @State private var selectedModel: SentimentModel = .vader
    @State private var inputText = ""
    @ObservedObject private var runtime = SentimentRuntime.shared

    // ────────── result / activity state ─────
    @State private var scores: (pos: Double, neu: Double, neg: Double, compound: Double)?
    @State private var finalSentiment = ""
    @State private var isRunning = false

    // ────────── warm-up overlay timer state ─
    @State private var elapsed: Double = 0
    @State private var showSpinner = false
    private let warmUpTarget: Double = 40     // seconds (progress bar → spinner fallback)
    private let hardCutoff: Double = 90       // safety: UI won’t get stuck
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Derived
    private var isWarming: Bool {
        if case .warming = runtime.status { return true }
        return false
    }

    var body: some View {
        ZStack {
            // ────────────────────────────── main UI
            VStack(spacing: 24) {

                // — title + blurb —
                VStack(spacing: 6) {
                    Text("Sentiment Playground")
                        .font(.largeTitle.bold())
                    Text("Try out any sentence with the local models. Great for quick experiments or debugging.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 600)
                }
                .padding(.top, 8)

                // — model picker —
                Picker("Sentiment Model", selection: $selectedModel) {
                    ForEach(SentimentModel.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: selectedModel) { m in
                    print("🪄 Model changed to \(m.rawValue)")
                    Task { await runtime.ensureReady(for: m) }
                }

                // — multi-line input —
                TextEditor(text: $inputText)
                    .font(.system(size: 15, design: .monospaced))
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.4))
                    .padding(.horizontal)

                // — score button —
                Button(action: runAnalysis) {
                    Label("Score Text", systemImage: "bolt.fill")
                        .font(.title2.bold())
                        .padding(.vertical, 14)
                        .padding(.horizontal, 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.accentColor)
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || isRunning || isWarming)

                // — results table —
                if let sc = scores {
                    VStack(spacing: 6) {
                        Text("Result: \(finalSentiment)")
                            .font(.title2).bold()
                            .foregroundColor(colorForSentiment(finalSentiment))
                        HStack(spacing: 20) {
                            scoreLabel("Pos", sc.pos)
                            scoreLabel("Neu", sc.neu)
                            scoreLabel("Neg", sc.neg)
                            scoreLabel("Comp", sc.compound)
                        }
                    }
                    .padding(.top, 6)
                }

                Spacer()
            }
            .padding(.bottom)

            // ────────────────────────────── warm-up overlay (driven by runtime.status)
            if case let .warming(model, idx, total) = runtime.status {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(spacing: 12) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 44, weight: .semibold))
                        .symbolEffect(.pulse, options: .repeating, value: isWarming) // macOS 14+
                        .padding(.bottom, 4)

                    ProgressView(value: Double(idx) / Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 240)

                    if showSpinner {
                        ProgressView().progressViewStyle(.circular)
                        Text("Still warming… \(model.rawValue)")
                    } else {
                        Text("Loading models… \(idx)/\(total) · \(Int(max(warmUpTarget - elapsed, 0))) s")
                            .monospacedDigit()
                    }
                }
                .foregroundColor(.white)
            }
        }
        .onAppear {
            print("👀 LexiconView.onAppear")
            elapsed = 0
            showSpinner = false
            Task {
                // Initialize Python + warm ALL models (sequential) once.
                await PythonBridge.shared.initializePython()
                await runtime.prewarmAll(startWith: selectedModel)
            }
        }
        .onChange(of: runtime.status) { old, new in
            print("🔁 runtime.status: \(old) → \(new)")
            switch new {
            case .warming:
                // (re)start countdown UI
                elapsed = 0
                showSpinner = false
            case .ready:
                // done – hide overlay
                elapsed = 0
                showSpinner = false
            case .failed(let msg):
                // hide overlay but leave logs
                print("❌ Warm-up failed: \(msg)")
                showSpinner = false
            case .idle:
                break
            }
        }
        .onReceive(timer) { _ in
            guard isWarming else { return }
            elapsed += 1
            if elapsed >= warmUpTarget { showSpinner = true }
            if elapsed >= hardCutoff {
                // Safety: don’t lock the UI; runtime will keep working in background
                print("⏱️ Warm-up overlay timed out; hiding overlay")
                // We only hide the countdown UI; worker keeps prewarming in background.
                showSpinner = true
            }
        }
    }

    // MARK: - Run the analysis
    private func runAnalysis() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isRunning = true
        scores = nil
        print("▶️ runAnalysis model=\(selectedModel.rawValue)")

        Task {
            // Ensure selected model is hot before scoring
            await runtime.ensureReady(for: selectedModel)

            let json = await PythonBridge.shared.scoreSentence(text, model: selectedModel)

            await MainActor.run {
             if let data = json.data(using: .utf8),
                let top  = try? JSONSerialization.jsonObject(with: data) as? [String:Any] {
              
              // Accept either {rows:[row]} or a flat row dict
              let first: [String:Any]
              if let rows = top["rows"] as? [[String:Any]], let r0 = rows.first {
               first = r0
              } else {
               first = top
              }
              
              let pos  = (first["pos"]      as? NSNumber)?.doubleValue ?? 0
              let neu  = (first["neu"]      as? NSNumber)?.doubleValue ?? 0
              let neg  = (first["neg"]      as? NSNumber)?.doubleValue ?? 0
              let comp = (first["compound"] as? NSNumber)?.doubleValue ?? 0
              let lbl  = (first["final_sentiment"] as? String)
              ?? (first["model_label"] as? String)
              ?? "NEUTRAL"
              
              self.scores = (pos, neu, neg, comp)
              self.finalSentiment = lbl
              self.isRunning = false
              print("✅ runAnalysis done label=\(lbl) comp=\(comp)")
             } else {
              self.isRunning = false
              // Helpful: show the actual JSON so failures aren’t opaque
              print("⚠️ runAnalysis parsing failed; json=\(json)")
             }
            }
        }
    }

    // MARK: - small view helpers
    private func scoreLabel(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(String(format: "%.3f", value))
                .font(.system(size: 14, design: .monospaced))
                .bold()
        }
    }

    private func colorForSentiment(_ label: String) -> Color {
        switch label.uppercased() {
        case "POSITIVE": return .green
        case "NEGATIVE": return .red
        case "NEUTRAL":  return .secondary
        default:         return .primary
        }
    }
}
