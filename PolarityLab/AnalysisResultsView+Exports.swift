// AnalysisResultsView+Exports.swift
import SwiftUI
import Charts
import UniformTypeIdentifiers
import Darwin
#if canImport(AppKit)
import AppKit
import CoreText
import CoreGraphics
#endif

// MARK: - Lightweight score extractor (keeps type-checker fast)
fileprivate func keywordScore(from dict: [String: Any]) -> Double {
 for k in ["compound", "impact", "score"] {
  if let n = dict[k] as? NSNumber { return n.doubleValue }
  if let d = dict[k] as? Double   { return d }
  if let s = dict[k] as? String, let v = Double(s) { return v }
 }
 return 0.0
}

extension AnalysisResultsView {
 @ViewBuilder func exportBar(contentWidth: CGFloat) -> some View {
  SectionCard("Export") {
   HStack(spacing: 12) {
    Spacer()
    Button { exportAnalysisCSV() } label: {
     Label("Analysis CSV", systemImage: "square.and.arrow.up")
    }
    .buttonStyle(.borderedProminent)
    .disabled(effectiveExportPath.isEmpty)
    
    // Keywords-only (tokens)
    Button { exportKeywordsCSV() } label: {
     Label("Keywords CSV", systemImage: "square.and.arrow.up")
    }
    .buttonStyle(.borderedProminent)
    .disabled(effectiveExportPath.isEmpty && keywords.isEmpty)
    
    if let syn = synopsis, !syn.isEmpty {
     Button { exportSynopsisPDF() } label: {
      Label("Synopsis PDF", systemImage: "doc.richtext")
     }
     .buttonStyle(.borderedProminent)
    }
    
    Button { exportGraphicsPNG() } label: {
     Label("Charts (PNG)", systemImage: "photo.on.rectangle.angled")
    }
    .buttonStyle(.bordered)
    
    Divider().frame(height: 22)
    
    Button(role: .none) {
#if canImport(Darwin)
     if let pid = UserDefaults.standard.value(forKey: "PL_PY_PID") as? Int32 {
      _ = kill(pid_t(pid), SIGKILL)
      UserDefaults.standard.removeObject(forKey: "PL_PY_PID")
     }
#endif
     onReset()
    } label: {
     Label("Reset Flow", systemImage: "arrow.counterclockwise")
    }
    .buttonStyle(.bordered)
    Spacer()
   }
  }
  .frame(width: contentWidth)
 }
 
 // MARK: Analysis CSV (rows)
 func exportAnalysisCSV() {
  let path = effectiveExportPath
  guard !path.isEmpty else { return }
#if canImport(AppKit)
  let panel = NSSavePanel()
  panel.allowedContentTypes = [.commaSeparatedText]
  panel.nameFieldStringValue = "analysis.csv"
  panel.begin { resp in
   guard resp == .OK, let url = panel.url else { return }
   do {
    let hdrs = effectiveHeaders.isEmpty ? inferHeadersFromJSONL(path: path) : effectiveHeaders
    try makeCSVFromJSONL(path: path, headers: hdrs).write(to: url, options: .atomic)
   } catch {
    NSLog("Export CSV failed: \(error.localizedDescription)")
   }
  }
#endif
 }
 // MARK: Keywords CSV (tokens + score)
 func exportKeywordsCSV() {
 #if canImport(AppKit)
   let panel = NSSavePanel()
   panel.allowedContentTypes = [.commaSeparatedText]
   panel.nameFieldStringValue = "keywords.csv"
   panel.begin { resp in
     guard resp == .OK, let url = panel.url else { return }
     do {
       // Gather raw rows from meta or in-memory fallback
       var rawRows: [[String: Any]] = []
       if !effectiveExportPath.isEmpty {
         let meta = readMetaFromJSONL(path: effectiveExportPath)
         rawRows = normalizeKeywordsTable(from: meta)
       }
       if rawRows.isEmpty { // fallback to in-memory effectiveKeywords
         rawRows = keywords.map { ["keyword": $0.0, "score": $0.1] }
       }

       // Map to export headers expected by the template override importer
       let headers = ["Keywords/Phrases", "Score"]
       let mapped: [[String: Any]] = rawRows.compactMap { r in
         // name field from common possibilities
         let name = (r["keyword"] ?? r["phrase"] ?? r["word"] ?? r["token"] ?? r["term"] ?? r["text"] ?? r["name"]) as? String
         let scoreVal = keywordScore(from: r) // supports "compound"/"impact"/"score"
         guard let n = name, !n.isEmpty else { return nil }
         return ["Keywords/Phrases": n, "Score": scoreVal]
       }

       try writeRowsCSV(url: url, headers: headers, rows: mapped)
     } catch {
       NSLog("Export keywords failed: \(error.localizedDescription)")
     }
   }
 #endif
 }

 
 // MARK: Signatures CSV (trace of removals)

 
 // MARK: Synopsis PDF
 func exportSynopsisPDF() {
#if canImport(AppKit)
  guard let syn = synopsis, !syn.isEmpty else { return }
  let panel = NSSavePanel()
  panel.allowedContentTypes = [.pdf]
  panel.nameFieldStringValue = "synopsis.pdf"
  panel.begin { resp in
   guard resp == .OK, let url = panel.url else { return }
   if let data = SynopsisPDFWriter.makePDF(
    title: "Sentiment Analysis Synopsis",
    dateLine: formattedDateLine(),
    filters: appliedFilterSummary,
    dateFilter: appliedDateSummary,
    body: syn,
    posKeywords: topPosKeywords.map(\.0),
    negKeywords: topNegKeywords.map(\.0)
   ) {
    try? data.write(to: url, options: .atomic)
   }
  }
#endif
 }
 
 // MARK: Graphics (PNG)
 func prepareSnapshotStateForExport() {
  buildTimeline()
  parseEvents()
  xDomain = nil; yDomain = nil
  let full = defaultXDomain
  scrollX = Date(
   timeIntervalSince1970:
    (full.lowerBound.timeIntervalSince1970 + full.upperBound.timeIntervalSince1970) / 2
  )
  visibleSpan = max(full.upperBound.timeIntervalSince(full.lowerBound), 86_400)
  xDomain = full
  buildOverlays()
 }
 
 func exportGraphicsPNG() {
#if canImport(AppKit)
  prepareSnapshotStateForExport()
  guard !visibleSeries.isEmpty else { return }
  let footer = exportFooterText()
  
  let panel = NSSavePanel()
  panel.allowedContentTypes = [.png]
  panel.nameFieldStringValue = "sentiment_timeline.png"
  panel.begin { resp in
   guard resp == .OK, let url1 = panel.url else { return }
   let chartView = VStack(spacing: 8) {
    chartPlotOnly(export: true).padding(.horizontal, 60).padding(.vertical, 30)
    Text(footer).font(.caption2).foregroundStyle(.secondary).padding(.bottom, 10)
   }
    .frame(width: 2000, height: 860)
    .background(Color.white)
    .environment(\.colorScheme, .light)
   if let data1 = renderPNG(from: chartView) { try? data1.write(to: url1, options: .atomic) }
   
   let panel2 = NSSavePanel()
   panel2.allowedContentTypes = [.png]
   panel2.nameFieldStringValue = "sentiment_distribution.png"
   panel2.begin { resp2 in
    guard resp2 == .OK, let url2 = panel2.url else { return }
    let pieView = VStack(spacing: 8) {
     piePlotOnly().padding(40)
     Text(footer).font(.caption2).foregroundStyle(.secondary).padding(.bottom, 10)
    }
     .frame(width: 900, height: 640)
     .background(Color.white)
     .environment(\.colorScheme, .light)
    if let data2 = renderPNG(from: pieView) { try? data2.write(to: url2, options: .atomic) }
   }
  }
#endif
 }
 
 // MARK: CSV helpers (robust nested lookups + dotted keys)
 private func dottedLookup(_ key: String, in dict: [String: Any]) -> Any? {
  var current: Any? = dict
  for part in key.split(separator: ".").map(String.init) {
   guard let d = current as? [String: Any] else { return nil }
   current = d[part]
  }
  return current
 }
 
 private func value(for header: String, in obj: [String: Any]) -> Any? {
  if let v = obj[header] { return v }
  for k in ["row", "data", "fields", "payload", "record"] {
   if let sub = obj[k] as? [String: Any] {
    if let v = sub[header] { return v }
    if let v2 = dottedLookup(header, in: sub) { return v2 }
   }
  }
  return dottedLookup(header, in: obj)
 }
 
 private func csvCell(_ any: Any?) -> String {
  func esc(_ s: String) -> String {
   let e = s.replacingOccurrences(of: "\"", with: "\"\"")
   return (e.contains(",") || e.contains("\n") || e.contains("\r")) ? "\"\(e)\"" : e
  }
  guard let any else { return "" }
  if let d = any as? Double   { return String(format: "%.4f", d) }
  if let n = any as? NSNumber { return String(format: "%.4f", n.doubleValue) }
  if let i = any as? Int      { return "\(i)" }
  if let b = any as? Bool     { return b ? "true" : "false" }
  if let s = any as? String   { return esc(s) }
  if let a = any as? [Any]    { return esc(a.map { "\($0)" }.joined(separator: " ")) }
  if let m = any as? [String: Any],
     let data = try? JSONSerialization.data(withJSONObject: m),
     let s = String(data: data, encoding: .utf8) { return esc(s) }
  return esc("\(any)")
 }
 
 func makeCSVFromJSONL(path: String, headers: [String]) -> Data {
  // Strip legacy columns; we now emit removed_signature / removed_handles only.
  var headers2 = headers.filter { !["Signature Detection", "Cleaning", "drivers", "removed_signature", "removed_handles"].contains($0) }

  var out = headers2.joined(separator: ",") + "\n"
  guard let fh = FileHandle(forReadingAtPath: path) else { return Data(out.utf8) }
  defer { try? fh.close() }
  let blob = (try? fh.readToEnd()) ?? Data()
  guard let s = String(data: blob, encoding: .utf8) else { return Data(out.utf8) }

  // Deep-ish lookup (respects common wrappers + dotted keys)
  let wrappers = ["cleaning", "meta", "row", "data", "payload", "fields", "record"]
  func deepValue(_ key: String, in obj: [String: Any]) -> Any? {
    if let v = obj[key] { return v }
    for w in wrappers {
      if let sub = obj[w] as? [String: Any] {
        if let v = sub[key] { return v }
        if let v2 = dottedLookup(key, in: sub) { return v2 }
      }
    }
    return dottedLookup(key, in: obj)
  }

  for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
    if line.contains(#""__meta__": true"#) { continue }
    guard let d = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }

    // Compute removed_signature with simple sequential fallbacks (keeps type-checker fast)
    var sigRemoved: Any? = nil
    if sigRemoved == nil { sigRemoved = deepValue("removed_signature", in: obj) }
    if sigRemoved == nil { sigRemoved = deepValue("signature_removed", in: obj) }
    if sigRemoved == nil, let cl = deepValue("cleaning", in: obj) as? [String: Any] { sigRemoved = cl["removed_signature"] }
    if sigRemoved == nil, let cl = deepValue("cleaning", in: obj) as? [String: Any] { sigRemoved = cl["signatures_removed"] }
    if sigRemoved == nil, let rm = (deepValue("cleaning", in: obj) as? [String: Any])?["removed"] as? [String: Any] { sigRemoved = rm["signature"] ?? rm["signatures"] }
    if sigRemoved == nil { sigRemoved = deepValue("signatures_removed", in: obj) }
    if sigRemoved == nil { sigRemoved = deepValue("signature", in: obj) }
    if sigRemoved == nil { sigRemoved = deepValue("signatures", in: obj) }

    // Compute removed_handles with simple sequential fallbacks
    // Fallback: derive full signature text if JSONL didn't populate it
    if sigRemoved == nil
       || (sigRemoved as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
       || (sigRemoved as? NSNumber)?.intValue == 0
    {
      let body = (deepValue("body", in: obj) as? String) ?? ""
      let used = (deepValue("used", in: obj) as? String) ?? ""
      if !body.isEmpty, !used.isEmpty {
        if body.hasPrefix(used) {
          let tail = body.dropFirst(used.count)
          let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { sigRemoved = trimmed }
        } else if let r = body.range(of: used) {
          let tail = body[r.upperBound...]
          let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { sigRemoved = trimmed }
        }
      }
    }
    var handlesRemoved: Any? = nil
    if handlesRemoved == nil { handlesRemoved = deepValue("removed_handles", in: obj) }
    if handlesRemoved == nil { handlesRemoved = deepValue("handles_removed", in: obj) }
    if handlesRemoved == nil, let cl = deepValue("cleaning", in: obj) as? [String: Any] { handlesRemoved = cl["removed_handles"] }
    if handlesRemoved == nil, let cl = deepValue("cleaning", in: obj) as? [String: Any] { handlesRemoved = cl["mentions_removed"] }
    if handlesRemoved == nil, let rm = (deepValue("cleaning", in: obj) as? [String: Any])?["removed"] as? [String: Any] { handlesRemoved = rm["handles"] ?? rm["mentions"] }
    if handlesRemoved == nil { handlesRemoved = deepValue("mentions_removed", in: obj) }
    if handlesRemoved == nil { handlesRemoved = deepValue("user_mentions", in: obj) }
    if handlesRemoved == nil { handlesRemoved = deepValue("mentions", in: obj) }

    // Build row cells explicitly (avoid complex map closures for faster type-checking)
    var cells: [String] = []
    cells.reserveCapacity(headers2.count)
    for h in headers2 {
      if h == "removed_signature" {
        cells.append(csvCell(sigRemoved))
      } else if h == "removed_handles" {
        cells.append(csvCell(handlesRemoved))
      } else {
        let v = value(for: h, in: obj)
        cells.append(csvCell(v))
      }
    }
    out.append(cells.joined(separator: ",") + "\n")
  }

  return Data(out.utf8)
}





 
 private func inferHeadersFromJSONL(path: String) -> [String] {
  guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
  defer { try? fh.close() }
  let blob = (try? fh.readToEnd()) ?? Data()
  guard let s = String(data: blob, encoding: .utf8) else { return [] }
  for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
   if line.contains(#""__meta__": true"#) { continue }
   if let d = line.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
    return Array(obj.keys)
   }
  }
  return []
 }
 
 // Generic CSV writer for row dictionaries
 private func writeRowsCSV(url: URL, headers: [String], rows: [[String: Any]]) throws {
  var out = headers.joined(separator: ",") + "\n"
  for r in rows {
   let line = headers.map { h in csvCell(r[h]) }.joined(separator: ",")
   out.append(line + "\n")
  }
  try (out.data(using: .utf8) ?? Data()).write(to: url, options: .atomic)
 }
 
 // MARK: JSONL meta reader + normalization
 private func readMetaFromJSONL(path: String) -> [String: Any] {
  guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let s = String(data: data, encoding: .utf8) else { return [:] }
  var meta: [String: Any] = [:]
  var keywordsTable: [[String: Any]] = []
  var signatures: [[String: Any]] = []
  
  for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
   guard let d = String(raw).data(using: .utf8),
         let objAny = try? JSONSerialization.jsonObject(with: d),
         let obj = objAny as? [String: Any] else { continue }
   
   if let ktab = obj["keywords_table"] as? [[String: Any]], !ktab.isEmpty {
    keywordsTable = ktab
   }
   if let kcomp = obj["keywords_comp"] as? [[String: Any]],
      !kcomp.isEmpty, keywordsTable.isEmpty {
    var tmp: [[String: Any]] = []
    for it in kcomp {
     let name = (it["word"] as? String) ?? (it["token"] as? String) ?? (it["term"] as? String)
     let sc = keywordScore(from: it)
     if let n = name, !n.isEmpty { tmp.append(["keyword": n, "score": sc]) }
    }
    keywordsTable = tmp
   }
   if let sr = obj["signatures_removed"] as? [[String: Any]], !sr.isEmpty {
    signatures.append(contentsOf: sr)
   }
   
   if (obj["__meta__"] as? Bool) == true {
    if let m = obj["meta"] as? [String: Any] {
     for (k, v) in m { meta[k] = v }
    }
   }
   if let m = obj["meta"] as? [String: Any], !m.isEmpty {
    for (k, v) in m { meta[k] = v }
   }
  }
  if !keywordsTable.isEmpty { meta["keywords_table"] = keywordsTable }
  if !signatures.isEmpty    { meta["signatures_removed"] = signatures }
  return meta
 }
 
 private func normalizeKeywordsTable(from meta: [String: Any]) -> [[String: Any]] {
  if let k = meta["keywords_table"] as? [[String: Any]] { return k }
  return []
 }
 
 // MARK: PNG rendering helpers
 @MainActor func renderPNG(from view: some View) -> Data? {
#if canImport(AppKit)
  let renderer = ImageRenderer(content: view)
  renderer.isOpaque = true
  guard let tiff = renderer.nsImage?.tiffRepresentation,
        let rep  = NSBitmapImageRep(data: tiff),
        let png  = rep.representation(using: .png, properties: [:]) else { return nil }
  return png
#else
  return nil
#endif
 }
 
 func exportFooterText() -> String {
  let info = Bundle.main.infoDictionary
  let ver = (info?["CFBundleShortVersionString"] as? String) ?? "?"
  let build = (info?["CFBundleVersion"] as? String) ?? "?"
  let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
  let dt = df.string(from: Date())
  let band = String(format: "%.2f", neutralBandWidth)
  return "PolarityLab v\(ver) (\(build)) • \(dt) • Models: VADER, Social, Community • Neutral band ±\(band)"
 }
 
 // MARK: Export rendering helpers
 func chartPlotOnly(export: Bool = false) -> AnyView {
  if visibleSeries.isEmpty || allDates.isEmpty { return AnyView(Color.white) }
  let full = defaultXDomain
  let yDom = computeAdaptiveYDomain()
  let series = Array(visibleSeries)
  let maxCount = max(series.map { $0.count }.max() ?? 1, 1)
  let span = max(yDom.upperBound - yDom.lowerBound, 0.0001)
  func mapCount(_ c: Int) -> Double {
   let r = Double(c) / Double(maxCount)
   return yDom.lowerBound + r * span
  }
  
  let v = Chart {
   if showVolumeBand {
    ForEach(series, id: \.id) { p in
     BarMark(
      x: .value("Date", p.date),
      yStart: .value("VolumeBase", yDom.lowerBound),
      yEnd: .value("VolumeScaled", mapCount(p.count))
     )
     .opacity(0.25)
     .foregroundStyle(Color.secondary)
    }
   }
   ForEach(series, id: \.id) { p in
    LineMark(x: .value("Date", p.date), y: .value("Sentiment", p.avg))
     .interpolationMethod(.linear)
     .lineStyle(StrokeStyle(lineWidth: 2))
     .foregroundStyle(Color.accentColor)
   }
  }
   .chartYScale(domain: yDom.lowerBound...yDom.upperBound)
   .chartYAxis {
    AxisMarks(position: .trailing, values: yTicks) {
     AxisGridLine(); AxisTick(); AxisValueLabel()
    }
    AxisMarks(position: .leading, values: yTicks) { v in
     AxisGridLine(); AxisTick()
     AxisValueLabel {
      if let yy = v.as(Double.self) {
       let ratio = (yy - yDom.lowerBound) / span
       let c = max(0, Int(round(ratio * Double(maxCount))))
       Text("\(c)")
      }
     }
    }
   }
   .chartXScale(domain: full)
   .chartScrollableAxes(.horizontal)
   .chartScrollPosition(x: $scrollX)
   .chartXVisibleDomain(length: visibleSpan)
   .modifier(ExportXAxis(visible: full))
  
  return AnyView(v)
 }
 
 private struct ExportXAxis: ViewModifier {
  let visible: ClosedRange<Date>
  func body(content: Content) -> some View {
   content.chartXAxis {
    let days = max(1.0, visible.upperBound.timeIntervalSince(visible.lowerBound) / 86_400.0)
    if days <= 31 {
     AxisMarks(values: .stride(by: .day)) {
      AxisGridLine(); AxisTick()
      AxisValueLabel(format: .dateTime.month(.abbreviated).day())
     }
    } else if days <= 180 {
     AxisMarks(values: .stride(by: .weekOfYear)) {
      AxisGridLine(); AxisTick()
      AxisValueLabel(format: .dateTime.month(.abbreviated).day())
     }
    } else if days <= 800 {
     AxisMarks(values: .stride(by: .month)) {
      AxisGridLine(); AxisTick()
      AxisValueLabel(format: .dateTime.year().month())
     }
    } else {
     AxisMarks(values: .stride(by: .year)) {
      AxisGridLine(); AxisTick()
      AxisValueLabel(format: .dateTime.year())
     }
    }
   }
  }
 }
 
 func piePlotOnly() -> AnyView {
  let slices = Array(pieCounts)
  let v = Chart {
   ForEach(slices.indices, id: \.self) { i in
    let s = slices[i]
    SectorMark(
     angle: .value("Count", s.count),
     innerRadius: .ratio(0.5),
     angularInset: 1
    )
    .foregroundStyle(by: .value("Label", s.label))
   }
  }
   .chartLegend(position: .bottom, alignment: .center)
   .chartForegroundStyleScale([
    "Positive": Color.green,
    "Neutral": Color.gray,
    "Negative": Color.red
   ])
  return AnyView(v)
 }
}

// MARK: - Preserve insertion order of headers
fileprivate struct LinkedHashSet<T: Hashable> {
 private var set: Set<T> = []
 fileprivate var items: [T] = []
 mutating func insert(_ v: T) { if set.insert(v).inserted { items.append(v) } }
}
