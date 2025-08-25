//
//  SettingsView.swift
//  PolarityLab
//

import SwiftUI
import Combine
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Models

struct SignatureRule: Identifiable, Hashable, Codable {
    enum Kind: String, CaseIterable, Codable, Identifiable {
        case contains = "Contains"
        case beginsWith = "Begins With"
        case endsWith = "Ends With"
        var id: String { rawValue }
    }
    var id = UUID()
    var kind: Kind = .contains
    var text: String = ""
    var enabled: Bool = true
    var note: String = ""
}

// Runtime processing overrides for Python launcher.
struct ProcessingOverrides: Codable, Equatable {
    var enabled: Bool = false
    var batch: Int? = nil        // e.g. 32, 64
    var maxLen: Int? = nil       // e.g. 128, 256
    var chunkSize: Int? = nil    // e.g. 16000, 32000
    var ompThreads: Int? = nil   // e.g. 1..8
    
    func clamped() -> ProcessingOverrides {
        var out = self
        if let b = out.batch { out.batch = b.clamped(1, 4096) }
        if let m = out.maxLen { out.maxLen = m.clamped(16, 4096) }
        if let c = out.chunkSize { out.chunkSize = c.clamped(1024, 10_000_000) }
        if let o = out.ompThreads { out.ompThreads = o.clamped(1, 64) }
        return out
    }
}

private extension Comparable {
    func clamped(_ a: Self, _ b: Self) -> Self { min(max(self, a), b) }
}

// MARK: - Persistent Store

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    
    // Appearance
    enum ThemeMode: String, CaseIterable, Identifiable, Codable { case system, light, dark; var id: String { rawValue } }
    @Published var themeMode: ThemeMode = .system { didSet { applyTheme() } }
    
    // Signature rules
    @Published var rules: [SignatureRule] = []
    
    // Processing overrides
    @Published var processing: ProcessingOverrides = ProcessingOverrides()
    
    // Storage
    private let fm = FileManager.default
    private var cancellables: Set<AnyCancellable> = []
    
    private var appSupportDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
                                 ?? NSTemporaryDirectory()), isDirectory: true)
        let dir = base.appendingPathComponent("PolarityLab", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }
    private var settingsURL: URL { appSupportDir.appendingPathComponent("settings.json") }
    
    struct Payload: Codable {
        var themeMode: ThemeMode
        var rules: [SignatureRule]
        var processing: ProcessingOverrides
    }
    
    private init() {
        load()
        Publishers.CombineLatest3($themeMode, $rules, $processing)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _,_,_ in self?.save() }
            .store(in: &cancellables)
        DispatchQueue.main.async { [weak self] in self?.applyTheme() }
    }
    
    // MARK: Load / Save
    func load() {
        if let data = try? Data(contentsOf: settingsURL),
           let p = try? JSONDecoder().decode(Payload.self, from: data) {
            themeMode = p.themeMode
            rules = p.rules
            processing = p.processing
        } else {
            rules = [
                SignatureRule(kind: .contains, text: "Sent from my iPhone", enabled: true, note: "Mobile footer"),
                SignatureRule(kind: .endsWith, text: "--", enabled: true, note: "Email sig divider (line starting with --)")
            ]
            processing = ProcessingOverrides()
            save()
        }
    }
    
    func save() {
        _ = appSupportDir
        let payload = Payload(themeMode: themeMode, rules: rules, processing: processing.clamped())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }
    
    // MARK: Theme (safe)
    func applyTheme() {
        let apply = {
            switch self.themeMode {
            case .system: NSApplication.shared.appearance = nil
            case .light:  NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case .dark:   NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async { apply() } }
    }
    
    // MARK: Launch helpers (env consumed by Python)
    func overrideEnv() -> [String: String] {
        guard processing.enabled else { return [:] }
        let p = processing.clamped()
        var env: [String: String] = ["PL_PERF_PROFILE": "manual"]
        if let v = p.batch      { env["PL_BATCH"] = String(v) }
        if let v = p.maxLen     { env["PL_MAXLEN"] = String(v) }
        if let v = p.chunkSize  { env["PL_CHUNKSIZE"] = String(v) }
        if let v = p.ompThreads {
            env["OMP_NUM_THREADS"] = String(v)
            env["MKL_NUM_THREADS"] = String(v)
            env["OPENBLAS_NUM_THREADS"] = String(v)
            env["VECLIB_MAXIMUM_THREADS"] = String(v)
            env["NUMEXPR_NUM_THREADS"] = String(v)
        }
        return env
    }
    
    // CSV Template / Export / Import (CSV)
    private var csvHeader: String { "enabled,kind,text,note\n" }
    
    func exportTemplateCSV() -> URL? {
        let url = appSupportDir.appendingPathComponent("signature-template.csv")
        let body = csvHeader + "true,Contains,Sent from my iPhone,Example\n"
        do { try body.data(using: .utf8)?.write(to: url, options: .atomic); return url } catch { return nil }
    }
    
    func exportSignatureCSV() -> URL? {
        let url = appSupportDir.appendingPathComponent("signature-rules-\(Int(Date().timeIntervalSince1970)).csv")
        var lines = [csvHeader]
        for r in rules {
            let esc: (String) -> String = { s in
                if s.contains("\"") || s.contains(",") { return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                else { return s }
            }
            lines.append("\(r.enabled),\(r.kind.rawValue),\(esc(r.text)),\(esc(r.note))\n")
        }
        do { try lines.joined().data(using: .utf8)?.write(to: url, options: .atomic); return url } catch { return nil }
    }
    
    func importSignatureCSV(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let str = String(data: data, encoding: .utf8) else { throw NSError(domain: "csv", code: -1) }
        let rows = str.split(whereSeparator: \.isNewline)
        guard !rows.isEmpty else { return }
        var newRules: [SignatureRule] = []
        for (i, rawLine) in rows.enumerated() {
            let line = String(rawLine)
            if i == 0 && line.lowercased().contains("enabled") { continue }
            let cols = parseCSVLine(line)
            guard cols.count >= 4 else { continue }
            let enabled = cols[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
            let kindStr = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = SignatureRule.Kind.allCases.first { $0.rawValue == kindStr } ?? .contains
            let text = cols[2]
            let note = cols[3]
            newRules.append(SignatureRule(kind: kind, text: text, enabled: enabled, note: note))
        }
        rules = newRules
    }
    
    private func parseCSVLine(_ line: String) -> [String] {
        var res: [String] = []; var cur = ""; var i = line.startIndex; var inQuotes = false
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                if inQuotes {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" { cur.append("\""); i = next } else { inQuotes = false }
                } else { inQuotes = true }
            } else if ch == "," && !inQuotes { res.append(cur); cur = "" }
            else { cur.append(ch) }
            i = line.index(after: i)
        }
        res.append(cur)
        return res.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Auto baseline (mirror of Python defaults)

private struct AutoBaseline {
    let batch: Int
    let maxLen: Int
    let chunkSize: Int
    let omp: Int
    let cores: Int
    let ramGB: Int
}

private func detectAutoBaseline() -> AutoBaseline {
    let ramBytes = ProcessInfo.processInfo.physicalMemory
    let ramGB = max(1, Int(Double(ramBytes) / 1e9))
    let cores = max(1, ProcessInfo.processInfo.processorCount)
    
    // Python-like heuristic
    let base = 32
    var scale = Int(Double(ramGB) / 8.0 * sqrt(Double(cores)))
    scale = max(1, min(scale, 4))
    let batch = min(max(base * scale, 16), 512)
    let maxLen = 128
    let chunk = min(max(ramGB * 4000, 8000), 50_000)
    let omp = (cores <= 4) ? 1 : min(4, cores / 2)
    
    return AutoBaseline(batch: batch, maxLen: maxLen, chunkSize: chunk, omp: omp, cores: cores, ramGB: ramGB)
}

// MARK: - Settings View

struct SettingsView: View {
    @StateObject private var store = SettingsStore.shared
    
    // Export / Import
    @State private var exportURL: URL?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importError: String?
    
    // Cached baseline
    @State private var baseline: AutoBaseline = detectAutoBaseline()
    
    var body: some View {
        GeometryReader { proxy in
            // Fixed column width so a bottom scrollbar appears if window < 1100
            let columnWidth: CGFloat = 1100
            let sidePad: CGFloat = 20
            let containerWidth = max(proxy.size.width, columnWidth)
            
            ScrollView([.vertical, .horizontal]) {
                // Container expands to either window width (centering) or column width (scroll when smaller)
                ZStack {
                    // The entire settings content column
                    VStack(spacing: 28) {
                        
                        // Appearance
                        VStack(spacing: 10) {
                            Text("Appearance")
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                            Picker("", selection: $store.themeMode) {
                                Text("System").tag(SettingsStore.ThemeMode.system)
                                Text("Light").tag(SettingsStore.ThemeMode.light)
                                Text("Dark").tag(SettingsStore.ThemeMode.dark)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 520)
                            .accessibilityLabel("Appearance theme")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        
                        // Processing Overrides
                        VStack(spacing: 12) {
                            Text("Processing Overrides")
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                            
                            Text("Enable to bypass auto-detect and run with your presets. Leave disabled to auto-tune by RAM and CPU.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 820)
                            
                            Toggle("Use manual processing settings", isOn: $store.processing.enabled)
                                .toggleStyle(.switch)
                                .frame(maxWidth: 820, alignment: .center)
                            
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 14) {
                                    VStack(spacing: 10) {
                                        OptionPicker(title: "Batch size",
                                                     value: $store.processing.batch,
                                                     options: [16, 32, 64, 128, 256],
                                                     format: { "\($0)" },
                                                     help: "Items scored at once. Higher is faster, more RAM.",
                                                     segmented: true,
                                                     disabled: !store.processing.enabled)
                                        OptionPicker(title: "Chunk size (rows)",
                                                     value: $store.processing.chunkSize,
                                                     options: [8_000, 16_000, 32_000, 50_000],
                                                     format: { SettingsView.decimal($0) },
                                                     help: "Rows per write to JSONL. Larger reduces I/O.",
                                                     segmented: true,
                                                     disabled: !store.processing.enabled)
                                    }
                                    .frame(maxWidth: .infinity)
                                    VStack(spacing: 10) {
                                        OptionPicker(title: "Max tokens per item",
                                                     value: $store.processing.maxLen,
                                                     options: [96, 128, 256, 384, 512],
                                                     format: { "\($0)" },
                                                     help: "Truncation length per row.",
                                                     segmented: true,
                                                     disabled: !store.processing.enabled)
                                        OptionPicker(title: "OMP threads",
                                                     value: $store.processing.ompThreads,
                                                     options: [1, 2, 4],
                                                     format: { "\($0)" },
                                                     help: "CPU math threads. 1 keeps UI responsive.",
                                                     segmented: true,
                                                     disabled: !store.processing.enabled)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .frame(maxWidth: 820, alignment: .center)
                                
                                VStack(spacing: 10) {
                                    OptionPicker(title: "Batch size",
                                                 value: $store.processing.batch,
                                                 options: [16, 32, 64, 128, 256],
                                                 format: { "\($0)" },
                                                 help: "Items scored at once.",
                                                 segmented: false,
                                                 disabled: !store.processing.enabled)
                                    OptionPicker(title: "Max tokens per item",
                                                 value: $store.processing.maxLen,
                                                 options: [96, 128, 256, 384, 512],
                                                 format: { "\($0)" },
                                                 help: "Truncation length per row.",
                                                 segmented: false,
                                                 disabled: !store.processing.enabled)
                                    OptionPicker(title: "Chunk size (rows)",
                                                 value: $store.processing.chunkSize,
                                                 options: [8_000, 16_000, 32_000, 50_000],
                                                 format: { SettingsView.decimal($0) },
                                                 help: "Rows per write to JSONL.",
                                                 segmented: false,
                                                 disabled: !store.processing.enabled)
                                    OptionPicker(title: "OMP threads",
                                                 value: $store.processing.ompThreads,
                                                 options: [1, 2, 4],
                                                 format: { "\($0)" },
                                                 help: "CPU math threads.",
                                                 segmented: false,
                                                 disabled: !store.processing.enabled)
                                }
                                .frame(maxWidth: 820, alignment: .center)
                            }
                            
                            ValidationPanel(processing: store.processing, baseline: baseline)
                                .frame(maxWidth: 820, alignment: .center)
                            
                            // Learning table (centered)
                            VStack(alignment: .center) {
                                LearningTable()
                                    .frame(minWidth: 720, maxWidth: 820)
                                    .padding(.horizontal, 2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .frame(maxWidth: .infinity)
                        
                        // Signature Removal
                        VStack(spacing: 14) {
                            Text("Signature Removal").font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                            
                            Text("We automatically remove common signatures and boilerplate **at the end** of posts and strip @handles by default. Add company-specific patterns below.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 800)
                            
                            // Buttons (centered)
                            HStack(spacing: 10) {
                                Button {
                                    if let url = store.exportTemplateCSV() { exportURL = url; showExporter = true }
                                } label: { Label("Download Template CSV", systemImage: "doc.arrow.down") }
                                    .buttonStyle(TightPill())
                                
                                Button {
                                    if let url = store.exportSignatureCSV() { exportURL = url; showExporter = true }
                                } label: { Label("Export Signature Rules (CSV)", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(TightPill())
                                
                                Button { showImporter = true } label: {
                                    Label("Import Signature Rules (CSV)", systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(TightPill())
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            
                            // Rules table (centered)
                            RulesTable(rules: $store.rules)
                                .frame(minWidth: 720, maxWidth: .infinity)
                                .padding(.horizontal, 2)
                                .frame(height: 230, alignment: .center)
                            
                            VStack(spacing: 6) {
                                Text("How matching works").font(.headline)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("• **Contains** – removes the matched phrase **only if it appears at the end**.")
                                    Text("• **Begins With** – if this phrase appears near the end, removes **that phrase and everything after it**.")
                                    Text("• **Ends With** – if the final line ends with this marker, remove **from that marker to the very end**.")
                                    Text("Rules run after built-in cleaning and before sentiment scoring.")
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 760, alignment: .leading)
                                .multilineTextAlignment(.leading)
                            }
                            .padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity)
                        
                        // About
                        VStack(spacing: 8) {
                            Text("About PolarityLab").font(.title2.weight(.semibold))
                            Text("PolarityLab runs entirely offline. No data leaves your machine.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            VStack(spacing: 6) {
                                Link("twitter-roberta-base-sentiment (MIT) – Hugging Face",
                                     destination: URL(string: "https://huggingface.co/cardiffnlp/twitter-roberta-base-sentiment")!)
                                Link("distilbert-base-uncased-finetuned-sst-2-english (Apache 2.0) – Hugging Face",
                                     destination: URL(string: "https://huggingface.co/distilbert-base-uncased-finetuned-sst-2-english")!)
                            }
                            .font(.callout)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(width: columnWidth, alignment: .center) // fixed column width (centers all sections)
                    .padding(.vertical, 24)
                    .padding(.horizontal, sidePad)
                }
                .frame(width: containerWidth, alignment: .center) // center when window is wider; enable horizontal scroll when narrower
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.visible)
#if os(macOS)
            .scrollBounceBehavior(.basedOnSize)
#endif
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showExporter) { ExportSheet(url: exportURL, isPresented: $showExporter) }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            switch result {
            case .success(let url):
                do { try store.importSignatureCSV(from: url) }
                catch { importError = error.localizedDescription }
            case .failure(let err):
                importError = err.localizedDescription
            }
        }
                      .alert("Import Error", isPresented: Binding(get: { importError != nil },
                                                                  set: { _ in importError = nil })) {
                          Button("OK", role: .cancel) { }
                      } message: { Text(importError ?? "") }
            .onAppear { baseline = detectAutoBaseline() }
    }
    
    // MARK: - Tight Pill ButtonStyle
    
    private struct TightPill: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.callout.weight(.semibold))
                .padding(.vertical, 6).padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(Capsule().fill(configuration.isPressed ? Color.accentColor.opacity(0.85) : Color.accentColor))
                .foregroundColor(.white)
                .contentShape(Capsule())
                .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
                .accessibilityAddTraits(.isButton)
        }
    }
    
    // MARK: - OptionPicker
    
    private struct OptionPicker: View {
        let title: String
        @Binding var value: Int?
        let options: [Int]
        let format: (Int) -> String
        let help: String
        let segmented: Bool
        let disabled: Bool
        
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if segmented {
                    Picker("", selection: $value) {
                        Text("Auto").tag(nil as Int?)
                        ForEach(options, id: \.self) { v in Text(format(v)).tag(Optional(v)) }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(disabled)
                } else {
                    HStack {
                        Picker("", selection: $value) {
                            Text("Auto").tag(nil as Int?)
                            ForEach(options, id: \.self) { v in Text(format(v)).tag(Optional(v)) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(disabled)
                        Text(currentLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        
        private var currentLabel: String { value.map(format) ?? "Auto" }
    }
    
    // MARK: - Validation
    
    private struct ValidationPanel: View {
        let processing: ProcessingOverrides
        let baseline: AutoBaseline
        
        var items: [ValidationItem] {
            guard processing.enabled else { return [.info("Manual overrides disabled. Using auto-tuned settings.")] }
            var out: [ValidationItem] = []
            if let b = processing.batch {
                if b > 512 { out.append(.error("Batch \(b) exceeds hard ceiling 512.")) }
                else if b > baseline.batch * 3 { out.append(.error("Batch \(b) is >3× baseline (\(baseline.batch)). Risk of OOM.")) }
                else if b > baseline.batch * 2 { out.append(.warn("Batch \(b) is >2× baseline (\(baseline.batch)). Monitor memory.")) }
            } else { out.append(.info("Batch Auto = \(baseline.batch).")) }
            if let m = processing.maxLen {
                if m > 512 { out.append(.error("Max tokens \(m) too high. Use ≤512.")) }
                else if m > 256 { out.append(.warn("Max tokens \(m) is high. Throughput will drop.")) }
            } else { out.append(.info("Max tokens Auto = \(baseline.maxLen).")) }
            if let c = processing.chunkSize {
                if c > 50_000 { out.append(.error("Chunk size \(Self.decimal(c)) exceeds 50,000.")) }
                else if c > baseline.chunkSize * 2 { out.append(.warn("Chunk size \(Self.decimal(c)) is >2× baseline (\(Self.decimal(baseline.chunkSize))). Large memory spikes possible.")) }
            } else { out.append(.info("Chunk size Auto = \(Self.decimal(baseline.chunkSize)).")) }
            if let t = processing.ompThreads {
                if t > baseline.cores { out.append(.error("OMP \(t) exceeds core count (\(baseline.cores)).")) }
                else if t > max(2, baseline.cores/2) { out.append(.warn("OMP \(t) is high for \(baseline.cores) cores. UI may stutter.")) }
            } else { out.append(.info("OMP Auto = \(baseline.omp).")) }
            if let b = processing.batch, let m = processing.maxLen {
                let prod = b * m
                let baseProd = baseline.batch * baseline.maxLen
                if prod > baseProd * 2 { out.append(.warn("Batch×Tokens \(prod) is >2× baseline (\(baseProd)). Memory pressure likely.")) }
            }
            return out
        }
        
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Validation").font(.headline)
                ForEach(items) { it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: it.icon).foregroundStyle(it.color)
                        Text(it.message).font(.caption).foregroundStyle(it.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Auto baseline: batch \(baseline.batch), tokens \(baseline.maxLen), chunk \(Self.decimal(baseline.chunkSize)), OMP \(baseline.omp).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        }
        
        private static func decimal(_ n: Int) -> String {
            let nf = NumberFormatter(); nf.numberStyle = .decimal
            return nf.string(from: NSNumber(value: n)) ?? "\(n)"
        }
    }
    
    private struct ValidationItem: Identifiable {
        enum Level { case info, warn, error }
        let id = UUID()
        let level: Level
        let message: String
        var icon: String { switch level { case .info: "info.circle"; case .warn: "exclamationmark.triangle.fill"; case .error: "exclamationmark.octagon.fill" } }
        var color: Color { switch level { case .info: .secondary; case .warn: .orange; case .error: .red } }
        static func info(_ m: String) -> ValidationItem { .init(level: .info, message: m) }
        static func warn(_ m: String) -> ValidationItem { .init(level: .warn, message: m) }
        static func error(_ m: String) -> ValidationItem { .init(level: .error, message: m) }
    }
    
    // MARK: - Learning table
    
    private struct LearningTable: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("What each setting does").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    headerRow("Setting", "Effect", "Trade-offs", "Safe presets")
                    line("Batch size", "How many texts are scored together.", "Higher uses more RAM. Too high can OOM.", "16 • 32 • 64 • 128 • 256")
                    line("Max tokens", "Per-row token cap for models.", "Higher reduces truncation but slows scoring.", "96 • 128 • 256 • 384 • 512")
                    line("Chunk size (rows)", "Rows read and written per chunk.", "Higher peaks memory and file size between flushes.", "8k • 16k • 32k • 50k")
                    line("OMP threads", "Math library threads.", "Higher can starve UI; keep ≤ cores/2.", "1 • 2 • 4")
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        private func headerRow(_ a: String, _ b: String, _ c: String, _ d: String) -> some View {
            GridRow { Text(a).fontWeight(.semibold); Text(b).fontWeight(.semibold); Text(c).fontWeight(.semibold); Text(d).fontWeight(.semibold) }
        }
        private func line(_ a: String, _ b: String, _ c: String, _ d: String) -> some View {
            GridRow { Text(a); Text(b); Text(c); Text(d) }
        }
    }
    
    // MARK: - Rules Table
    
    private struct RulesTable: View {
        @Binding var rules: [SignatureRule]
        @State private var newRule = SignatureRule()
        
        var body: some View {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Picker("", selection: $newRule.kind) {
                        ForEach(SignatureRule.Kind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    
                    TextField("New pattern…", text: $newRule.text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260, maxWidth: 420)
                    
                    TextField("Note", text: $newRule.note)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    
                    Button {
                        let trimmed = newRule.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        newRule.text = trimmed
                        rules.append(newRule)
                        newRule = SignatureRule()
                    } label: {
                        Label("Add", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(TightPill())
                    Spacer(minLength: 0)
                }
                
                Table(rules, selection: .constant(Set<UUID>())) {
                    TableColumn("On") { r in
                        Toggle("", isOn: binding(for: r, \.enabled)).labelsHidden()
                    }.width(36)
                    
                    TableColumn("Type") { r in
                        Picker("", selection: binding(for: r, \.kind)) {
                            ForEach(SignatureRule.Kind.allCases) { k in Text(k.rawValue).tag(k) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    
                    TableColumn("Pattern") { r in
                        TextField("pattern", text: binding(for: r, \.text))
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    TableColumn("Note") { r in
                        TextField("note", text: binding(for: r, \.note))
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    TableColumn("") { r in
                        Button(role: .destructive) {
                            rules.removeAll { $0.id == r.id }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Delete rule")
                    }
                    .width(30)
                }
                .frame(minHeight: 220)
            }
        }
        
        private func binding<T>(for rule: SignatureRule, _ keyPath: WritableKeyPath<SignatureRule, T>) -> Binding<T> {
            guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else {
                return .constant(rule[keyPath: keyPath])
            }
            return Binding(
                get: { rules[idx][keyPath: keyPath] },
                set: { rules[idx][keyPath: keyPath] = $0 }
            )
        }
    }
    
    // MARK: - Export Sheet
    
    private struct ExportSheet: View {
        let url: URL?
        @Binding var isPresented: Bool
        
        var body: some View {
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill").imageScale(.large)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                }
                
                Text("File Ready").font(.title2.weight(.semibold))
                
                if let url {
                    Text(url.path)
                        .font(.callout)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: 520)
                    
                    HStack(spacing: 10) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        .buttonStyle(TightPill())
                        
                        Button {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(url.path, forType: .string)
                        } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                            .buttonStyle(TightPill())
                    }
                } else {
                    Text("No file URL.").foregroundStyle(.secondary)
                }
                
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(TightPill())
            }
            .padding(20)
            .frame(width: 520)
        }
    }
    
    // MARK: - Helpers
    
    private static func decimal(_ n: Int) -> String {
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
