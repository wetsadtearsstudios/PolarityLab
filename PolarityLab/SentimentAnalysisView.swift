// SentimentAnalysisView.swift
import SwiftUI
import Foundation
import Combine

// --- Sanitizer: keep keywords independent & clean ---
// --- Sanitizer: keep keywords independent & clean (drops likely PERSON names) ---
// --- Sanitizer: keep keywords independent & clean (drops likely PERSON names) ---
private func sanitizeKeywordPairs(_ pairs: [(String, Double)], headers: [String]) -> [(String, Double)] {
    let headerSet = Set(headers.map { $0.lowercased() })
    let stops: Set<String> = [
      // generic noise / common column names
      "type","post_id","comment_id","parent_comment_id","depth","date","user_id","user_name",
      "company","product_line","product_model","product_sku","category","title","body","__dt","__bucket",
      // new internal/export columns
      "drivers","removed_signature","removed_handles","pos","neu","neg","compound","compound_raw",
      "compound_effective","compound_override","model_label","model_confidence","final_sentiment","used",
      // months (lowercased)
      "jan","january","feb","february","mar","march","apr","april","may","jun","june","jul","july",
      "aug","august","sep","sept","september","oct","october","nov","november","dec","december"
    ]

    // Likely PERSON-name detector: titlecased alphabetic tokens (e.g., "Alice", "Johnson")
    func isLikelyPersonName(_ w: String) -> Bool {
        let s = w.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        if s.contains("@") || s.contains("_") || s.contains("#") { return false }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "’'-"))
        if s.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }
        if s.count < 2 || s.count > 24 { return false }
        let first = s.prefix(1)
        let rest  = s.dropFirst()
        let isTitle = (first.uppercased() == first) && (rest.lowercased() == rest)
        let isAllUpper = (s.uppercased() == s)
        return isTitle && !isAllUpper
    }

    func isAllDigits(_ w: String) -> Bool {
        return w.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }
    func looksLikeID(_ w: String) -> Bool {
        if w.count <= 1 { return false }
        let u = w.uppercased()
        if u.hasPrefix("P") || u.hasPrefix("C") {
            let rest = String(u.dropFirst())
            if rest.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return true }
        }
        return false
    }
    func keep(_ w: String) -> Bool {
        let lw = w.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lw.isEmpty { return false }
        if lw.count < 2 || lw.count > 24 { return false }
        if headerSet.contains(lw) { return false }
        if stops.contains(lw) { return false }
        if isAllDigits(lw) { return false }              // drop 2025, 07, 22, etc.
        if looksLikeID(w) { return false }               // drop P0006096, C00000001, etc.
        if lw.rangeOfCharacter(from: .letters) == nil {  // must include at least one letter
            return false
        }
        if lw.contains("_") { return false }             // drop obvious handles/IDs
        if isLikelyPersonName(w) { return false }        // drop likely PERSON names
        return true
    }

    var seen = Set<String>()
    var out: [(String, Double)] = []
    for (w, c) in pairs {
        let lw = w.lowercased()
        if keep(w) && !seen.contains(lw) {
            out.append((w, c))
            seen.insert(lw)
        }
    }
    return out
}


// MARK: - CSV helper (still used for exports elsewhere)
fileprivate func csvEscape(_ value: String) -> String {
 var v = value.replacingOccurrences(of: "\"", with: "\"\"")
 if v.contains(",") || v.contains("\n") || v.contains("\r") { v = "\"\(v)\"" }
 return v
}

// MARK: - Small helpers

/// Order-preserving unique (case-insensitive) for tokens/keywords.
fileprivate func dedupeTokens(_ items: [(String, Double)]) -> [(String, Double)] {
 var seen = Set<String>()
 var out: [(String, Double)] = []
 for (w, s) in items {
  let k = w.lowercased()
   .trimmingCharacters(in: .whitespacesAndNewlines)
   .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:!?()[]{}"))
  guard !k.isEmpty else { continue }
  if seen.insert(k).inserted {
   out.append((w, s))
  }
 }
 return out
}

/// Best-effort guess at a text column plus optional date column for a nicer default.
fileprivate func guessInitialColumns(from headers: [String]) -> [String] {
 guard !headers.isEmpty else { return [] }
 let candidates = ["body","text","comment","message","content","title","review","post","description"]
 var chosen: [String] = []
 if let t = headers.first(where: { candidates.contains($0.lowercased()) }) {
  chosen.append(t)
 } else if let first = headers.first {
  chosen.append(first)
 }
 if let d = headers.first(where: { $0.lowercased() == "date" || $0.lowercased().contains("date") }) {
  if !chosen.contains(d) { chosen.append(d) }
 }
 return chosen
}

// MARK: - Stage
enum AnalysisStage: Equatable {
 case empty
 case preview(csv: SimpleCSV)
 case analyzing(progress: Int?) // heartbeat count from Python
 case results(
  keywords: [(String, Double)],
  exportSourcePath: String,
  headers: [String],
  meta: [String: Any]
 )
 static func == (lhs: AnalysisStage, rhs: AnalysisStage) -> Bool {
  switch (lhs, rhs) {
  case (.empty, .empty): return true
  case (.analyzing(let a), .analyzing(let b)): return a == b
  case let (.preview(a), .preview(b)): return a.url == b.url
  case (.results, .results): return true
  default: return false
  }
 }
}

// MARK: - Main view
struct SentimentAnalysisView: View {
 @State private var stage: AnalysisStage = .empty
 @State private var selectedColumns: [String] = []
 @State private var selectedModel: SentimentModel = .vader
 @State private var showingExporter = false
 @State private var selectedPostIDColumn: String? = nil
 
 // Preview toggles
 @State private var selectedSynopsis: Bool = true
 @State private var signatureRemoval: Bool = true
 @State private var usernameRemoval: Bool = true
 
 // Template / filters / dates
 @State private var selectedTemplate: UnifiedLexiconTemplate?
 @State private var selectedFilter: FilterPayload?
 @State private var selectedDateFilter: DateFilterPayload?
 
 // Results adornments
 @State private var resultsSynopsis: String?
 @State private var resultsFilterSummary: String?
 @State private var resultsDateSummary: String?
 @State private var resultsKeywordOverrides: [String: Double]?
 
 // Progress
 @State private var processedSoFar: Int = 0
 @State private var analysisTask: Task<Void, Never>? = nil
 private static var warmedModels = Set<SentimentModel>()
 
 // Fallback guard to avoid infinite re-run loops
 @State private var didDateFallback: Bool = false
 
 @State private var isCancelling: Bool = false
 var body: some View {
  ZStack {
   switch stage {
   case .empty:
    EmptyStateView { _, csv in
     dlog("EmptyStateView -> got CSV at \(csv.url.path)")
     selectedColumns = []
     dlog("Initial selectedColumns=[]")
     stage = .preview(csv: csv)
    }
    
   case .preview(let csv):
    CSVPreviewView(
     csv: csv,
     selectedColumns: $selectedColumns,
     selectedModel: $selectedModel
    ) { template, filter, date, includeSynopsis, postIDColumn, signatureRemoval, usernameRemoval, _ /* includePhrases (ignored) */ in
     dlog("onAnalyze called. csv=\(csv.url.lastPathComponent) model=\(selectedModel.rawValue)")
     self.selectedTemplate     = template
     self.selectedFilter       = filter
     self.selectedDateFilter   = date
     self.selectedPostIDColumn = postIDColumn
     self.signatureRemoval     = signatureRemoval
     self.usernameRemoval      = usernameRemoval
     self.selectedSynopsis     = includeSynopsis
     
     dlog("""
                           options:
                             selectedColumns=\(selectedColumns)
                             template?=\(template != nil)
                             filter?=\(filter != nil)
                             date?=\(String(describing: date))
                             synopsis=\(includeSynopsis)
                             postID=\(postIDColumn ?? "nil")
                             sigRemoval=\(signatureRemoval) userRemoval=\(usernameRemoval)
                           """)
     runAnalysis()
    }
    
   case .analyzing(let progress):
    VStack(spacing: 10) {
     AnalyzingView()
     if let p = progress {
      Text("Processed \(p) rows")
       .font(.footnote)
       .foregroundStyle(.secondary)
       .onAppear { dlog("AnalyzingView shows processed=\(p)") }
     }
     Button(role: .destructive) {
      cancelAndResetToFilePicker()
     } label: {
      Text("Cancel Analysis & Reset").bold()
     }
     .buttonStyle(.borderedProminent)
     .tint(.red)
     .padding(.top, 6)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    
   case .results(let keywords, let exportSourcePath, let headers, let meta):
    AnalysisResultsView(
     keywords: keywords,
     exportSourcePath: exportSourcePath,
     headers: headers,
     meta: meta,
     hasNeutral: (selectedModel != .community),
     showingExporter: $showingExporter,
     onReset: { resetAll() },
     synopsis: resultsSynopsis,
     appliedFilterSummary: resultsFilterSummary,
     appliedDateSummary: resultsDateSummary,
     keywordOverrides: resultsKeywordOverrides
    )
    .onAppear {
     Task { await PythonBridge.shared.shutdownWorkerAfterResults() }
     dlog("Results appear. exportSourcePath=\(exportSourcePath) headers=\(headers.count) kw=\(keywords.count)")
    }
   }
  }
  .onAppear { dlog("File log at: \(FileLogger.shared.path)") }
  .animation(.easeInOut, value: stage)
  .onDisappear { analysisTask?.cancel() }
  .onChange(of: stage) { newValue in
   dlog("Stage changed ➜ \(newValue)")
  }
  // Async notifications, no Combine generics
  .task(priority: .background) {
    for await note in NotificationCenter.default.notifications(named: .plProgress) {
      guard let info = note.userInfo, let n = info["processed"] as? Int else {
        dlog("Progress notif (no userInfo)")
        continue
      }
      await MainActor.run {
        // Honor progress updates only while actively analyzing and not cancelling.
        if case .analyzing = stage, !isCancelling {
          processedSoFar = max(processedSoFar, n)
          stage = .analyzing(progress: processedSoFar)
        } else {
          dlog("Ignoring late progress (stage=\(stage))")
        }
      }
    }
  }


  .task(priority: .background) {
   for await _ in NotificationCenter.default.notifications(named: .plDone) {
    dlog("Received .plDone")
   }
  }
 }
 
 // MARK: - Runner
private func runAnalysis() {
 guard case .preview(let csv) = stage else { return }
 dlog("runAnalysis() starting for \(csv.url.lastPathComponent)")
 stage = .analyzing(progress: nil)
 processedSoFar = 0
 didDateFallback = false
 
 let templatePayload: TemplatePayload? = selectedTemplate.map { buildTemplatePayload(from: $0) }
 let filterPayload: FilterPayload? = selectedFilter
 
 analysisTask?.cancel()
 analysisTask = Task.detached(priority: .userInitiated) {
  dlog("initializePython()…")
  await PythonBridge.shared.initializePython()
  
  let err = await MainActor.run { PythonBridge.shared.initializationError }
  if let err {
   dlog("initializePython error: \(err)")
  } else {
   dlog("initializePython OK")
  }
  
  if !Self.warmedModels.contains(selectedModel) {
   do {
    dlog("Warming model \(selectedModel.rawValue)…")
    try await withThrowingTaskGroup(of: Void.self, returning: Void.self) { group in
     group.addTask { _ = await PythonBridge.shared.scoreSentence("warm-up", model: self.selectedModel) }
     group.addTask {
      try await Task.sleep(nanoseconds: 60_000_000_000)
      throw NSError(domain: "Warmup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Analysis warm-up timed out"])
     }
     _ = try await group.next()
     group.cancelAll()
     return ()
    }
    Self.warmedModels.insert(selectedModel)
    dlog("Warm-up done for \(selectedModel.rawValue)")
   } catch {
    dlog("⚠️ warm-up failed: \(error.localizedDescription)")
   }
  }
  
  // Normalize ISO 8601 → yyyy-MM-dd (some backends only date-filter on day precision)
  let normalizedDate: DateFilterPayload? = {
   guard let d = selectedDateFilter else { return nil }
   func trim(_ s: String) -> String {
    if let t = s.split(separator: "T").first { return String(t) }
    return s
   }
   return .init(column: d.column,
                start: d.start.map(trim),
                end:   d.end.map(trim))
  }()
  
  // Helper to parse a single analysis JSON (streamed or not)
  func parseAndPopulate(from json: String, allowProgress: Bool = true) async -> (exportPath: String?, headers: [String], keywords: [[String: Any]], meta: [String: Any], rows: [[String: Any]]) {
   var exportPath: String?
   var headers: [String] = []
   var kwsComp: [[String: Any]] = []
   var meta: [String: Any] = [:]
   var rowsAccum: [[String: Any]] = []
   
   guard let data = json.data(using: .utf8),
         let top  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    dlog("⚠️ analysis parse failed; json length=\(json.count) head=\(json.prefix(400))")
    return (nil, [], [], [:], [])
   }
   if let err = top["error"] as? String {
    dlog("❌ analysis error: \(err)")
    return (nil, [], [], [:], [])
   }
   
   if (top["streamed"] as? Bool) == true, let outPath = top["out_path"] as? String {
    dlog("Streamed path: \(outPath)")
    exportPath = outPath
    
    var lastTotal: Int? = nil
    var lastN: Int = -1
    var idleStart: Date?
    
    while !Task.isCancelled {
     let r = await PythonBridge.shared.readStreamedJSONL(
      at: outPath,
      onProgress: { n in
       if allowProgress {
        lastN = n
        Task { @MainActor in
         processedSoFar = n
         stage = .analyzing(progress: n)
        }
       }
      }
     )
     headers = r.headers
     kwsComp = r.keywords
     rowsAccum = r.rows // keep the snapshot we just read
     
     let candidate = r.meta
     let inner = (candidate["meta"] as? [String: Any]) ?? candidate
     var m = sanitizeMeta(inner) // timeline/status cleanup
     
     // Fallback: build timeline from rows if Python didn't produce it
     if (m["timeline"] as? [[String: Any]])?.isEmpty ?? true {
      let tl = buildTimelineFallback(from: rowsAccum)
      if !tl.isEmpty { m["timeline"] = tl }
     }
     meta = m
     
     lastTotal = (inner["total"] as? Int)
     ?? (inner["total_rows"] as? Int)
     ?? (inner["rows_total"] as? Int)
     
     let status = (inner["status"] as? String)?.lowercased()
     dlog("poll JSONL status=\(status ?? "<nil>") lastN=\(lastN) total=\(lastTotal.map(String.init) ?? "nil")")
     let finishedKeys: [Bool] = [
      (inner["final"] as? Bool) ?? false,
      (inner["done"] as? Bool) ?? false,
      (inner["finished"] as? Bool) ?? false,
      (inner["complete"] as? Bool) ?? false
     ]
     if status == "final" || finishedKeys.contains(true) {
      dlog("JSONL reports final")
      break
     }
     
     if lastTotal != nil, lastN >= (lastTotal ?? 0) {
      if idleStart == nil { idleStart = Date(); dlog("idle guard start") }
      if Date().timeIntervalSince(idleStart!) > 1.2 { dlog("idle guard break"); break }
     } else {
      idleStart = nil
     }
     try? await Task.sleep(nanoseconds: 350_000_000)
    }
    
    if let innerPl = meta["pl_out"] as? String, !innerPl.isEmpty { exportPath = innerPl }
   } else {
    dlog("Non-streamed or missing out_path. top=\(top)")
    headers = (top["row_headers"] as? [String]) ?? []
    kwsComp  = (top["keywords_comp"] as? [[String: Any]]) ?? []
    meta     = sanitizeMeta((top["meta"] as? [String: Any]) ?? [:])
    exportPath = (meta["pl_out"] as? String) ?? ""
   }
   
   return (exportPath, headers, kwsComp, meta, rowsAccum)
  }
  
  dlog("Calling runSentimentAnalysis(file=\(csv.url.path))")
  let json1 = await PythonBridge.shared.runSentimentAnalysis(
   fileURL:      csv.url,
   selectedCols: selectedColumns,
   skipRows:     0,
   mergeText:    true,
   model:        selectedModel,
   template:     templatePayload,
   filter:       filterPayload,
   date:         normalizedDate,     // may be nil
   synopsis:     selectedSynopsis,
   explain:      true,
   signatureRemoval: signatureRemoval,
   usernameRemoval:  usernameRemoval,
   includePhrases:   true
  )
  dlog("runSentimentAnalysis returned \(json1.count) bytes")
  
  guard !Task.isCancelled else { dlog("Task cancelled after run"); return }
  
  // Parse first attempt
  var (exportPath, headers, modelKWObjects, meta, rowsAccum) = await parseAndPopulate(from: json1)
  
  // Decide if we should fall back (date filter likely on & yielded zero)
  func processedCount(_ meta: [String: Any], rows: [[String: Any]]) -> Int {
   return (meta["processed"] as? Int)
   ?? (meta["total"] as? Int)
   ?? (meta["total_rows"] as? Int)
   ?? (meta["rows_total"] as? Int)
   ?? rows.count
  }
  let firstCount = processedCount(meta, rows: rowsAccum)
  
  var dateUsedInFinalRun = (normalizedDate != nil)
  if firstCount == 0, normalizedDate != nil, !didDateFallback {
   dlog("⚠️ 0 rows after date filter; retrying WITHOUT date range…")
   didDateFallback = true
   let json2 = await PythonBridge.shared.runSentimentAnalysis(
    fileURL:      csv.url,
    selectedCols: selectedColumns,
    skipRows:     0,
    mergeText:    true,
    model:        selectedModel,
    template:     templatePayload,
    filter:       filterPayload,
    date:         nil,              // ← no date filter on fallback
    synopsis:     selectedSynopsis,
    explain:      true,
    signatureRemoval: signatureRemoval,
    usernameRemoval:  usernameRemoval,
    includePhrases:   true
   )
   dlog("fallback run returned \(json2.count) bytes")
   (exportPath, headers, modelKWObjects, meta, rowsAccum) = await parseAndPopulate(from: json2, allowProgress: false)
   dateUsedInFinalRun = false
  }
  
  guard !Task.isCancelled else { dlog("Task cancelled before finalize"); return }
  
  // --- Keywords (MODEL TOKENS ONLY; no phrases, no fallback, no mutation)
  func extractScore(_ item: [String: Any]) -> Double? {
   if let n = item["compound"] as? NSNumber { return n.doubleValue }
   if let d = item["compound"] as? Double { return d }
   if let d = item["avg_compound"] as? Double { return d }
   if let d = item["impact"] as? Double { return d }
   if let d = item["score"] as? Double { return d }
   if let s = item["compound"] as? String, let d = Double(s) { return d }
   if let s = item["score"] as? String, let d = Double(s) { return d }
   if let s = item["avg_compound"] as? String, let d = Double(s) { return d }
   if let s = item["impact"] as? String, let d = Double(s) { return d }
   return nil
  }
  
  // Use exactly what Python emitted in keywords_comp; do NOT synthesize from rows.
  let modelKWObjectsLocal: [[String: Any]] = modelKWObjects
  var kwPairs: [(String, Double)] = []
  if !modelKWObjectsLocal.isEmpty {
   let nameKeys = ["word","token","term"]
   for item in modelKWObjectsLocal {
    if let name = nameKeys.compactMap({ item[$0] as? String }).first,
       name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil, // tokens only
       let sc = extractScore(item), sc.isFinite {
     kwPairs.append((name, sc))
    }
   }
  }
  dlog("keywords passthrough tokens=\(kwPairs.count)")
  
  // Prepare meta for export/consumer UIs
  var metaOut = meta
  if !modelKWObjectsLocal.isEmpty { metaOut["keywords_comp"] = modelKWObjectsLocal }
  if !kwPairs.isEmpty {
   metaOut["keywords_table"] = kwPairs.map { ["keyword": $0.0, "score": $0.1] }
  }
  
  let computedSynopsis: String? =
  (metaOut["synopsis"] as? String) ??
  (metaOut["executive_summary"] as? String) ??
  (metaOut["summary"] as? String)
  
  let computedFilterSummary: String? = {
   if let f = selectedFilter {
    let kwCount = f.keywords.count
    let mode = f.mode == .all ? "all" : "any"
    let ww = f.wholeWord ? "whole" : "part"
    return "\(kwCount) kw • \(mode) • \(ww)"
   }
   return nil
  }()
  
  let computedDateSummary: String? = {
   guard dateUsedInFinalRun, let d = selectedDateFilter else { return nil }
   var parts: [String] = []
   if let s = d.start { parts.append(s) }
   if let e = d.end   { parts.append("→ \(e)") }
   return parts.isEmpty ? nil : parts.joined(separator: " ")
  }()
  
  let computedOverrides: [String: Double]? = {
   guard let tmpl = selectedTemplate else { return nil }
   var ov: [String: Double] = [:]
   for it in tmpl.items {
    if let v = it.vaderScore { ov[it.phrase.lowercased()] = max(-1, min(1, v / 4.0)) }
    if let b = it.biasScore  { ov[it.phrase.lowercased()] = b }
   }
   return ov.isEmpty ? nil : ov
  }()



  // Apply template overrides across UI + meta (kwPairs, keywords_comp, top_keywords, table)
  let ovMap: [String: Double] = computedOverrides ?? [:]
  if !ovMap.isEmpty {
      // 1) Adjust UI kwPairs (tokens) with override, clamped to [-1, 1]
      kwPairs = kwPairs.map { (w, sc) in
          let k = w.lowercased()
          if let ov = ovMap[k] {
              return (w, max(-1.0, min(1.0, ov)))
          }
          return (w, sc)
      }
  
      // 2) Patch keywords_comp for exports: add compound_effective (+ compound_override when used)
      let nameKeys = ["word","token","term"]
      var patchedKWObjects: [[String: Any]] = []
      for item in modelKWObjectsLocal {
          var m = item
          if let name = nameKeys.compactMap({ item[$0] as? String }).first {
              let k = name.lowercased()
              if let ov = ovMap[k] {
                  m["compound_override"] = ov
                  m["compound_effective"] = ov
              } else if let raw = extractScore(item) {
                  m["compound_effective"] = raw
              }
          }
          patchedKWObjects.append(m)
      }
      metaOut["keywords_comp"] = patchedKWObjects
  
      // 3) Recompute keywords_table and top_keywords from adjusted kwPairs so exports/UI match
      metaOut["keywords_table"] = kwPairs.map { ["keyword": $0.0, "score": $0.1] }
      let pos = kwPairs.filter { $0.1 > 0 }.sorted { abs($0.1) > abs($1.1) }.prefix(10).map { $0.0 }
      let neg = kwPairs.filter { $0.1 < 0 }.sorted { abs($0.1) > abs($1.1) }.prefix(10).map { $0.0 }
      metaOut["top_keywords"] = ["positive": pos, "negative": neg]
  }

  
  dlog("Finalizing results. headers=\(headers.count) kwPairs=\(kwPairs.count) synopsis?=\(computedSynopsis != nil)")
  
  await MainActor.run {
   self.resultsSynopsis = computedSynopsis
   self.resultsFilterSummary = computedFilterSummary
   self.resultsDateSummary = computedDateSummary
   self.resultsKeywordOverrides = computedOverrides
   
   stage = .results(
    keywords:         sanitizeKeywordPairs(kwPairs, headers: headers),
    exportSourcePath: exportPath ?? "",
    headers:          headers,
    meta:             metaOut
   )
  }
 }
}

 private func buildTimelineFallback(from rows: [[String: Any]]) -> [[String: Any]] {
  guard !rows.isEmpty else { return [] }
  func num(_ v: Any?) -> Double? {
   if let n = v as? NSNumber { return n.doubleValue }
   if let d = v as? Double { return d }
   if let s = v as? String, let d = Double(s) { return d }
   return nil
  }
  var agg: [String: (c: Int, s: Double)] = [:]
  for r in rows {
   guard let bucket = (r["__bucket"] as? String) ?? (r["bucket"] as? String) ?? (r["__dt"] as? String) else { continue }
   let v = num(r["compound_effective"]) ?? num(r["compound"]) ?? num(r["compound_raw"]) ?? 0.0
   let cur = agg[bucket] ?? (0, 0.0)
   agg[bucket] = (cur.c + 1, cur.s + v)
  }
  let out = agg.keys.sorted().map { k -> [String: Any] in
   let a = agg[k]!
   let avg = (a.c > 0) ? max(-1.0, min(1.0, a.s / Double(a.c))) : 0.0
   return ["bucket": k, "count": a.c, "avg_compound": avg]
  }
  return out
 }
 
 // Build keywords from streamed rows when Python didn't emit any.
 // Build keywords from streamed rows when Python didn't emit any (no stoplist).
 private func buildKeywordsFallback(from rows: [[String: Any]]) -> [(String, Double)] {
  guard !rows.isEmpty else { return [] }
  let textFields = ["body","text","title","content","message","comment","review","post","description"]
  func num(_ v: Any?) -> Double {
   if let n = v as? NSNumber { return n.doubleValue }
   if let d = v as? Double { return d }
   if let s = v as? String, let d = Double(s) { return d }
   return 0.0
  }
  let pattern = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9_'’\\-]{2,}", options: [])
  var counts: [String:Int] = [:]
  var sums:   [String:Double] = [:]
  
  for r in rows {
   let comp = num(r["compound_effective"]) != 0.0 ? num(r["compound_effective"])
   : (num(r["compound"]) != 0.0 ? num(r["compound"]) : num(r["compound_raw"]))
   var text = ""
   for f in textFields {
    if let s = r[f] as? String, !s.isEmpty { text += " " + s }
   }
   if text.isEmpty { continue }
   guard let rx = pattern else { continue }
   let ns = text as NSString
   let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
   var seenThisRow = Set<String>()
   for m in matches {
    var tok = ns.substring(with: m.range).lowercased()
    tok = tok.trimmingCharacters(in: .punctuationCharacters)
    if tok.count < 3 { continue }
    if !seenThisRow.insert(tok).inserted { continue } // count once per row
    counts[tok, default: 0] += 1
    sums[tok, default: 0.0] += comp
   }
  }
  
  var scored: [(String, Double, Double, Int)] = []
  for (w, c) in counts {
   let avg = (c > 0) ? (sums[w, default: 0.0] / Double(c)) : 0.0
   let impact = abs(avg) * log(Double(c) + 1.0)
   scored.append((w, avg, impact, c))
  }
  scored.sort { (a, b) in a.2 == b.2 ? (a.3 > b.3) : (a.2 > b.2) }
  let pairs = scored.map { ($0.0, $0.1) }
  return Array(pairs.prefix(10))
 }
 
 private func cancelAndResetToFilePicker() {
  if isCancelling { return }
  isCancelling = true
  analysisTask?.cancel(); analysisTask = nil
  Task {
   await PythonBridge.shared.cancelActiveAnalysis()
   PythonBridge.shared.killStalePythonIfAny()
   await MainActor.run {
    selectedColumns.removeAll()
    selectedTemplate = nil
    selectedFilter = nil
    selectedDateFilter = nil
    resultsSynopsis = nil
    resultsFilterSummary = nil
    resultsDateSummary = nil
    resultsKeywordOverrides = nil
    processedSoFar = 0
    didDateFallback = false
    stage = .empty
    isCancelling = false
   }
  }
 }
 
 private func resetAll() {
  dlog("Reset requested")
  analysisTask?.cancel(); analysisTask = nil
  selectedColumns.removeAll()
  showingExporter = false
  resultsSynopsis = nil
  resultsFilterSummary = nil
  resultsDateSummary = nil
  resultsKeywordOverrides = nil
  processedSoFar = 0
  didDateFallback = false
  stage = .empty
 }
 
 // MARK: - Mapping
 private func buildTemplatePayload(from t: UnifiedLexiconTemplate) -> TemplatePayload {
  let vaderItems: [TemplatePayload.Item] = t.items.compactMap { e in
   guard let s = e.vaderScore else { return nil }
   return .init(phrase: e.phrase, score: s)
  }
  let biasItems: [TemplatePayload.Item] = t.items.compactMap { e in
   guard let s = e.biasScore else { return nil }
   return .init(phrase: e.phrase, score: s)
  }
  return TemplatePayload(vader: vaderItems, bias: biasItems)
 }
 
 // MARK: - Meta sanitation
 private func sanitizeMeta(_ meta: [String: Any]) -> [String: Any] {
  var out = meta
  // Clean synopsis: remove rule lines and collapse excessive blank lines (no infinite loops)
  if let syn0 = out["synopsis"] as? String {
   let lines = syn0.components(separatedBy: .newlines)
   let ruleChars = CharacterSet(charactersIn: "-─═—_=")
   let cleanedLines = lines.filter { line in
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return true }
    if t.unicodeScalars.count >= 4 && t.unicodeScalars.allSatisfy({ ruleChars.contains($0) }) { return false }
    return true
   }
   var syn = cleanedLines.joined(separator: "\n")
   syn = syn.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
   syn = syn.trimmingCharacters(in: .whitespacesAndNewlines)
   out["synopsis"] = syn
  }
  // Normalize timeline entries
  if var tl = out["timeline"] as? [[String: Any]] {
   tl = tl.compactMap { item in
    guard let bucket = (item["bucket"] as? String) ?? (item["date"] as? String) else { return nil }
    let countAny = item["count"] ?? item["n"]
    let avgAny   = item["avg_compound"] ?? item["average"] ?? item["avg"]
    let count = (countAny as? NSNumber)?.intValue ?? Int("\(countAny ?? 0)") ?? 0
    let avg: Double = {
     if let n = avgAny as? NSNumber { return n.doubleValue }
     if let d = avgAny as? Double { return d }
     return Double("\(avgAny ?? 0)") ?? .nan
    }()
    guard count >= 0, avg.isFinite else { return nil }
    return ["bucket": bucket, "count": count, "avg_compound": max(-1.0, min(1.0, avg))]
   }
   out["timeline"] = tl
  }
  if out["status"] == nil { out["status"] = "running" }
  
  // --- Synthesize lightweight events if Python didn't emit any ---
  let existingEvents = (out["events"] as? [[String: Any]]) ?? []
  if existingEvents.isEmpty {
   let tl = (out["timeline"] as? [[String: Any]]) ?? []
   if !tl.isEmpty {
    func num(_ v: Any?) -> Double {
     if let n = v as? NSNumber { return n.doubleValue }
     if let d = v as? Double   { return d }
     if let s = v as? String, let d = Double(s) { return d }
     return 0.0
    }
    func intVal(_ v: Any?) -> Int {
     if let n = v as? NSNumber { return n.intValue }
     if let i = v as? Int      { return i }
     if let s = v as? String, let i = Int(s) { return i }
     return 0
    }
    var events: [[String: Any]] = []
    events.append(["type": "timeline", "buckets": tl.count])
    
    let scoreKey: ( [String:Any] ) -> Double = { row in
     num(row["avg_compound"] ?? row["average"] ?? row["avg"])
    }
    if let best = tl.max(by: { scoreKey($0) < scoreKey($1) }) {
     events.append([
      "type": "best_bucket",
      "bucket": (best["bucket"] as? String) ?? (best["date"] as? String) ?? "",
      "avg": scoreKey(best),
      "count": intVal(best["count"] ?? best["n"])
     ])
    }
    if let worst = tl.min(by: { scoreKey($0) < scoreKey($1) }) {
     events.append([
      "type": "worst_bucket",
      "bucket": (worst["bucket"] as? String) ?? (worst["date"] as? String) ?? "",
      "avg": scoreKey(worst),
      "count": intVal(worst["count"] ?? worst["n"])
     ])
    }
    out["events"] = events
   }
  }
  return out
 }
 
}
