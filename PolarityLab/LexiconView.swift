import SwiftUI

struct LexiconView: View {
    struct Entry: Identifiable {
        let word: String
        let rawSum: Double
        var id: String { word }

        private static var _cache: [Entry]?
        static func loadAll() -> [Entry] {
            if let c = _cache { return c }

            let bundle = Bundle.main

            // 1️⃣ Try CSV at top-level resources
            if let csvURL = bundle.url(forResource: "vader_lexicon", withExtension: "csv"),
               let csvText = try? String(contentsOf: csvURL, encoding: .utf8) {
                let lines = csvText
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)

                // If first row is header matching ["word","raw_score"], drop it
                let dataLines: [String]
                let headerTokens = lines.first?
                    .lowercased()
                    .split(separator: ",")
                    .map(String.init) ?? []
                if headerTokens == ["word", "raw_score"] {
                    dataLines = Array(lines.dropFirst())
                } else {
                    dataLines = lines
                }

                // Parse each data line
                let parsed = dataLines.compactMap { line -> Entry? in
                    // split into exactly two parts: word and raw_score
                    let cols = line
                        .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                        .map(String.init)
                    guard cols.count == 2,
                          let raw = Double(cols[1].trimmingCharacters(in: .whitespaces))
                    else {
                        return nil
                    }
                    return Entry(word: cols[0], rawSum: raw)
                }

                if !parsed.isEmpty {
                    _cache = parsed
                    return parsed
                }
            }

            // 2️⃣ Fallback to TXT loader
            guard let txtURL = bundle.url(forResource: "vader_lexicon", withExtension: "txt"),
                  let text   = try? String(contentsOf: txtURL, encoding: .utf8)
            else {
                _cache = []
                return []
            }
            let lines = text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            let parsed = lines.compactMap { rawLine -> Entry? in
                let parts = rawLine
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1)
                guard parts.count == 2,
                      let raw = Double(parts[1])
                else {
                    return nil
                }
                return Entry(word: String(parts[0]), rawSum: raw)
            }
            _cache = parsed
            return parsed
        }
    }

    @State private var entries: [Entry] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var searchText = ""

    private var filtered: [Entry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.word.lowercased().contains(searchText.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("VADER Lexicon")
                .font(.largeTitle)
                .padding(.top)

            // —— Description + 14 pt links ——
            VStack(spacing: 4) {
                Text(
                    "This is the default sentiment lexicon provided by VADER (Valence Aware Dictionary and sEntiment Reasoner), used by the app to score your data. It captures the sentiment intensity of commonly used words, phrases, and slang—especially in online communication. You can search this page to see how individual words are scored.This “Raw score” is simply the base sentiment value (ranging –4 to +4) assigned to a word or phrase in the default VADER lexicon. However, this isn’t the score used to evaluate your text. The app applies VADER’s rule-based heuristics—handling negations (“not”), intensity modifiers (“very”), capitalization/punctuation emphasis (“GREAT!!!”), and contrast words (“but”)—to adjust, sum, and then normalize into a single compound rating between –1 and +1, which becomes your final sentiment score ￼. This means a high or low raw score may end up softened or flipped once context is considered. If you’d like to override a word’s influence, simply set a different raw value via a Custom Lexicon Template, and the app will apply the same compounding rules to that new value."
                )
                .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    Link("View main lexicon", destination: URL(string:
                        "https://github.com/cjhutto/vaderSentiment/blob/master/vaderSentiment/vader_lexicon.txt"
                    )!)
                    Link("Emoji lexicon", destination: URL(string:
                        "https://github.com/cjhutto/vaderSentiment/blob/master/vaderSentiment/emoji_utf8_lexicon.txt"
                    )!)
                }
                .font(.system(size: 14))
            }
            .padding(.horizontal)

            Divider()

            // — Search bar —
            HStack {
                TextField("Search word…", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal, 16)
                Spacer()
            }

            // — Column headers —
            HStack(spacing: 0) {
                Text("Word")
                    .bold()
                    .frame(width: 180, alignment: .leading)
                Text("Raw Score")
                    .bold()
                    .frame(width: 100, alignment: .trailing)
                Spacer()
            }
            .padding(.horizontal, 16)
            Divider()

            // — Content —
            if isLoading {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if loadFailed {
                Spacer()
                Text("⛔️ Failed to load lexicon")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { e in
                            HStack(spacing: 0) {
                                Text(e.word)
                                    .frame(width: 180, alignment: .leading)
                                Text(String(format: "%+.2f", e.rawSum))
                                    .frame(width: 100, alignment: .trailing)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .onAppear(perform: loadLexicon)
    }

    private func loadLexicon() {
        guard entries.isEmpty else { return }
        isLoading = true
        loadFailed = false

        Task {
            let all = await Task.detached { Entry.loadAll() }.value
            // small pause so spinner shows
            try? await Task.sleep(nanoseconds: 30_000_000)
            await MainActor.run {
                entries    = all
                isLoading  = false
                loadFailed = all.isEmpty
            }
        }
    }
}
