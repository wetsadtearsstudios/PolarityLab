// AnalysisResultsView+Scanning.swift
import SwiftUI
import Foundation

extension AnalysisResultsView {
 // Heartbeat progress storage (static for access from static scanners)
 static var progressTotal: Int {
  get { UserDefaults.standard.integer(forKey: "PL_HEARTBEAT_TOTAL") }
  set { UserDefaults.standard.set(newValue, forKey: "PL_HEARTBEAT_TOTAL") }
 }
 static var progressDone: Int {
  get { UserDefaults.standard.integer(forKey: "PL_HEARTBEAT_DONE") }
  set { UserDefaults.standard.set(newValue, forKey: "PL_HEARTBEAT_DONE") }
 }

 // Shared cache so UI-thread callers can reuse background results without I/O.
 private static var _termCache: [String: [String: Int]] = [:]
 
 // Prefer meta counts; fall back to file scan
 func buildPieCounts() {
  let path = effectiveExportPath
  let metaC = metaLabelCounts()
  if metaC.pos + metaC.neu + metaC.neg > 0 {
   var slices: [PieSlice] = []
   if hasNeutral {
    slices = [PieSlice(label: "Positive", count: metaC.pos),
              PieSlice(label: "Neutral",  count: metaC.neu),
              PieSlice(label: "Negative", count: metaC.neg)]
   } else {
    slices = [PieSlice(label: "Positive", count: metaC.pos),
              PieSlice(label: "Negative", count: metaC.neg)]
   }
   pieCounts = slices
   return
  }
  guard !path.isEmpty else { pieCounts = []; return }
  
  // Snapshot state needed off the main actor
  let headerSnapshot = self.headers
  let hasNeutral = self.hasNeutral
  
  // Kick work off-thread without requiring 'await'
  Task(priority: .utility) {
   let counts = Self.scanLabelCounts(jsonlPath: path, headers: headerSnapshot)
   var slices: [PieSlice] = []
   if hasNeutral {
    if counts.pos + counts.neu + counts.neg == 0 {
     await MainActor.run { self.pieCounts = [] }
     return
    }
    slices = [PieSlice(label: "Positive", count: counts.pos),
              PieSlice(label: "Neutral",  count: counts.neu),
              PieSlice(label: "Negative", count: counts.neg)]
   } else {
    if counts.pos + counts.neg == 0 {
     await MainActor.run { self.pieCounts = [] }
     return
    }
    slices = [PieSlice(label: "Positive", count: counts.pos),
              PieSlice(label: "Negative", count: counts.neg)]
   }
   await MainActor.run { self.pieCounts = slices }
  }
 }
 
 // NOTE: keywords are computed independently and are NOT tied to timeline/volume/events.
func buildTermCountsForVisibleTerms() {
    let listK = (topPosKeywords + topNegKeywords)
    let termsK: [String] = listK.isEmpty ? Array(keywords.prefix(20).map { $0.0 }) : listK.map { $0.0 }
    let setK = Set(termsK)
    guard !setK.isEmpty else { self.keywordCounts = [:]; return }

    // Build counts from meta payload only (no file I/O to keep UI responsive)
    var counts: [String:Int] = [:]

    if let table = self.meta["keywords_table"] as? [[String: Any]] {
        for row in table {
            if let w = row["keyword"] as? String, setK.contains(w) {
                counts[w, default: 0] += 1
            }
        }
    } else if let comp = self.meta["keywords_comp"] as? [[String: Any]] {
        for row in comp {
            let w = (row["word"] as? String) ?? (row["token"] as? String) ?? (row["term"] as? String)
            if let w, setK.contains(w) {
                counts[w, default: 0] += 1
            }
        }
    }

    // Publish on main actor
    self.keywordCounts = counts
}


 
 // Back-compat wrapper (some call sites use this name)

    // Made internal (default) so other files can call it.
        // Made internal (default) so other files can call it.
    func buildVisibleTermCounts() {
        // Build static keyword counts from the exported snapshot only (no rescans).
        func extractPairs() -> [(String, Double)] {
            if let kt = meta["keywords_table"] as? [[String: Any]] {
                var acc: [(String, Double)] = []
                for row in kt {
                    if let w = row["keyword"] as? String {
                        if let d = row["score"] as? Double { acc.append((w, d)) }
                        else if let n = row["score"] as? NSNumber { acc.append((w, n.doubleValue)) }
                        else if let s = row["score"] as? String, let d = Double(s) { acc.append((w, d)) }
                    }
                }
                if !acc.isEmpty { return acc }
            }
            if let kc = meta["keywords_comp"] as? [[String: Any]] {
                var acc: [(String, Double)] = []
                for row in kc {
                    var name: String?
                    if let w = row["word"] as? String { name = w }
                    if name == nil, let t = row["token"] as? String { name = t }
                    if name == nil, let t = row["term"]  as? String { name = t }
                    var sc: Double?
                    if let d = row["compound"] as? Double { sc = d }
                    else if let n = row["compound"] as? NSNumber { sc = n.doubleValue }
                    else if let s = row["compound"] as? String, let d = Double(s) { sc = d }
                    if let n = name, let s = sc { acc.append((n, s)) }
                }
                if !acc.isEmpty { return acc }
            }
            // Already sanitized upstream
            return keywords
        }

        let pairs = extractPairs()
        if pairs.isEmpty { keywordCounts = [:]; return }

        // Light keep-filter (no disk I/O, no dataset rescans)
        func keep(_ w: String) -> Bool {
            if w.isEmpty { return false }
            if w.contains("_") { return false }
            if w.count < 2 || w.count > 24 { return false }
            if w.rangeOfCharacter(from: CharacterSet.letters) == nil { return false }
            if w.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return false }
            return true
        }

        var filtered: [(String, Double)] = []
        var seen = Set<String>()
        for (w, s) in pairs {
            let k = w.trimmingCharacters(in: .whitespacesAndNewlines)
            let lk = k.lowercased()
            if keep(k), s.isFinite, seen.insert(lk).inserted {
                filtered.append((k, s))
            }
        }
        if filtered.isEmpty { keywordCounts = [:]; return }

        // Rank by absolute impact, then score desc, then alpha
        filtered.sort { a, b in
            let ia = abs(a.1), ib = abs(b.1)
            if ia == ib { return a.1 == b.1 ? (a.0 < b.0) : (a.1 > b.1) }
            return ia > ib
        }

        // Stable pseudo-counts to drive bars without rescans (scale 30..100)
        let maxN = min(filtered.count, 200)
        let top = Array(filtered.prefix(maxN))
        let hi = abs(top.first?.1 ?? 1.0)
        let lo = abs(top.last?.1 ?? 0.0)
        let denom = max(hi - lo, 0.001)

        var out: [String: Int] = [:]
        for (w, s) in top {
            let t = (abs(s) - lo) / denom
            let count = Int(30 + round(t * 70))
            out[w] = max(count, 1)
        }
        keywordCounts = out
    }



 
 // === Low-level scanners (handle dict rows OR array rows with headers) ===
  static func scanLabelCounts(jsonlPath: String, headers: [String]) -> (pos: Int, neu: Int, neg: Int) {
  var pos = 0, neu = 0, neg = 0
  guard let fh = FileHandle(forReadingAtPath: jsonlPath) else { return (0,0,0) }
  defer { try? fh.close() }
  let chunkSize = 1_048_576
  var buffer = Data()

  @inline(__always)
  func applyLabel(_ s: String) {
   switch s.uppercased() {
   case "POSITIVE", "POS", "P", "+", "1": pos += 1
   case "NEGATIVE", "NEG", "N", "-", "-1": neg += 1
   case "NEUTRAL",  "NEU", "Z", "0":      neu += 1
   default: break
   }
  }

  @inline(__always)
  func parseDoubleSafe(_ any: Any?) -> Double? {
   if let n = any as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : 0.0 }
   if let d = any as? Double   { return d.isFinite ? d : 0.0 }
   if let s = any as? String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if t.isEmpty || t == "nan" || t == "+nan" || t == "-nan" ||
        t == "inf" || t == "+inf" || t == "-inf" ||
        t == "infinity" || t == "+infinity" || t == "-infinity" {
     return 0.0
    }
    if let v = Double(t) { return v.isFinite ? v : 0.0 }
   }
   return nil
  }

  @inline(__always)
  func mapNumericLabel(_ vIn: Double) -> String {
   let v = vIn.isFinite ? vIn : 0.0
   if v >= 0.5 || v == 1 { return "POSITIVE" }
   if v <= -0.5 || v == -1 { return "NEGATIVE" }
   return "NEUTRAL"
  }

  @inline(__always)
  func labelFromDict(_ d: [String: Any]) -> String? {
   for key in ["final_sentiment","model_label","label","sentiment","polarity","pred","prediction","class"] {
    if let s = d[key] as? String, !s.isEmpty {
     if let v = parseDoubleSafe(s) { return mapNumericLabel(v) }
     return s
    }
    if let n = d[key] as? NSNumber { return mapNumericLabel(n.doubleValue) }
    if let n = d[key] as? Double   { return mapNumericLabel(n) }
   }
   if let arr = d["scores"] as? [[String: Any]], !arr.isEmpty {
    var bestLab = "NEUTRAL"; var best = -Double.infinity
    for e in arr {
     let lab = (e["label"] as? String) ?? ""
     let sc  = parseDoubleSafe(e["score"]) ?? 0.0
     if sc > best { best = sc; bestLab = lab }
    }
    return bestLab
   }
   if let p = parseDoubleSafe(d["pos"]) ?? parseDoubleSafe(d["positive"]),
      let g = parseDoubleSafe(d["neg"]) ?? parseDoubleSafe(d["negative"]) {
    let n = parseDoubleSafe(d["neu"]) ?? parseDoubleSafe(d["neutral"]) ?? max(0, 1 - max(p,g))
    if p >= g && p >= n { return "POSITIVE" }
    if g >= p && g >= n { return "NEGATIVE" }
    return "NEUTRAL"
   }
   return nil
  }

  @inline(__always)
  func labelFromAny(_ any: Any) -> String? {
   if let d = any as? [String: Any] { return labelFromDict(d) }
   if let arr = any as? [Any] {
    let hdrs = headers.map { $0.lowercased() }
    for k in ["final_sentiment","model_label","label","sentiment","polarity","pred","prediction","class"] {
     if let i = hdrs.firstIndex(of: k), i < arr.count {
      let v = arr[i]
      if let s = v as? String, let dv = parseDoubleSafe(s) { return mapNumericLabel(dv) }
      if let n = v as? NSNumber { return mapNumericLabel(n.doubleValue) }
      if let d = v as? Double { return mapNumericLabel(d) }
      if let s = v as? String, !s.isEmpty { return s }
     }
    }
    if let s = arr.compactMap({ $0 as? String }).joined(separator: " ").nilIfEmpty {
     if s.range(of: #"(?i)\bpos(itive)?\b"#, options: .regularExpression) != nil { return "POSITIVE" }
     if s.range(of: #"(?i)\bneg(ative)?\b"#, options: .regularExpression) != nil { return "NEGATIVE" }
     if s.range(of: #"(?i)\bneu(tral)?\b"#, options: .regularExpression) != nil { return "NEUTRAL" }
    }
   }
   return nil
  }

  // Heartbeat handler (local helper; posts notification + stores for anyone observing)
  func handleHeartbeat(_ json: String) {
   guard
     let data = json.data(using: .utf8),
     let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
     (obj["__meta__"] as? Bool) == true,
     let meta = obj["meta"] as? [String: Any]
   else { return }

   let total = (meta["total"] as? Int) ?? (meta["rows_total"] as? Int) ?? (meta["count"] as? Int)
   let done  = (meta["done"] as? Int)  ?? (meta["rows_done"] as? Int)  ?? (meta["processed"] as? Int) ?? (meta["n"] as? Int)

   DispatchQueue.main.async {
     let ud = UserDefaults.standard
     if let total { ud.set(total, forKey: "PL_HEARTBEAT_TOTAL") }
     if let done  { ud.set(done,  forKey: "PL_HEARTBEAT_DONE")  }
     ud.synchronize()
     NotificationCenter.default.post(
       name: Notification.Name("PLHeartbeat"),
       object: nil,
       userInfo: ["total": total as Any, "done": done as Any]
     )
   }
  }

  while true {
   let dataOpt = try? fh.read(upToCount: chunkSize)
   guard let data = dataOpt, !data.isEmpty else { break }
   buffer.append(data)
   while let nl = buffer.firstRange(of: Data([0x0A])) {
    let lineData = buffer.subdata(in: buffer.startIndex..<nl.lowerBound)
    buffer.removeSubrange(buffer.startIndex...nl.lowerBound)
    if lineData.isEmpty { continue }
    guard let line = String(data: lineData, encoding: .utf8) else { continue }
    if line.contains(#""__meta__": true"#) {
     handleHeartbeat(String(line))
     continue
    }
    if let d = line.data(using: .utf8),
       let any = try? JSONSerialization.jsonObject(with: d) {
     if let lab = labelFromAny(any) { applyLabel(lab) }
    }
   }
  }
  if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
   if !line.contains(#""__meta__": true"#),
      let d = line.data(using: .utf8),
      let any = try? JSONSerialization.jsonObject(with: d),
      let lab = labelFromAny(any) {
    applyLabel(lab)
   }
  }
  return (pos, neu, neg)
 }

 
 /// Counts occurrences of `terms` in the JSONL.
 /// - Keywords: call with `wholeWord = true` to enforce word boundaries.
 static func scanTermCounts(
  jsonlPath: String,
  terms: [String],
  headers: [String],
  wholeWord: Bool = false,
  dateRange: (Date?, Date?)? = nil,
  filterKeywords: [String] = [],
  filterPatterns: [String] = [],
  filterModeAll: Bool = false
 ) -> [String: Int] {
  guard !terms.isEmpty else { return [:] }
  
  var counts = Dictionary(uniqueKeysWithValues: terms.map { ($0, 0) })
  guard let fh = FileHandle(forReadingAtPath: jsonlPath) else { return counts }
  defer { try? fh.close() }
  
  // Compile keyword/pattern regexes (case-insensitive, whole-word for keywords)
  var kwRegexes: [NSRegularExpression] = []
  var patRegexes: [NSRegularExpression] = []
  for t in filterKeywords where !t.isEmpty {
   let esc = NSRegularExpression.escapedPattern(for: t)
   let pattern = "(?i)(?<![\\p{L}\\p{N}_])\(esc)(?![\\p{L}\\p{N}_])"
   if let re = try? NSRegularExpression(pattern: pattern) { kwRegexes.append(re) }
  }
  for p in filterPatterns where !p.isEmpty {
   if let re = try? NSRegularExpression(pattern: "(?i)\(p)") {
    patRegexes.append(re)
   } else if let re = try? NSRegularExpression(pattern: "(?i)\(NSRegularExpression.escapedPattern(for: p))") {
    patRegexes.append(re)
   }
  }
  
  let chunkSize = 1_048_576
  var buffer = Data()
  
  // Helpers
  @inline(__always) func matchTextFilter(_ text: String) -> Bool {
   if kwRegexes.isEmpty && patRegexes.isEmpty { return true }
   let ns = text as NSString
   if filterModeAll {
    for re in kwRegexes { if re.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length)) == 0 { return false } }
    for re in patRegexes { if re.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length)) == 0 { return false } }
    return true
   } else {
    for re in kwRegexes { if re.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length)) > 0 { return true } }
    for re in patRegexes { if re.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length)) > 0 { return true } }
    return (kwRegexes.isEmpty && patRegexes.isEmpty)
   }
  }
   func handleHeartbeat(_ json: String) {
   guard
    let data = json.data(using: .utf8),
    let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    (obj["__meta__"] as? Bool) == true,
    let meta = obj["meta"] as? [String: Any]
   else { return }
   
   let total = (meta["total"] as? Int)
   ?? (meta["rows_total"] as? Int)
   ?? (meta["count"] as? Int)
   let done  = (meta["done"] as? Int)
   ?? (meta["rows_done"] as? Int)
   ?? (meta["processed"] as? Int)
   ?? (meta["n"] as? Int)
   
   DispatchQueue.main.async {
    if let total { self.progressTotal = total }
    if let done  { self.progressDone  = done  }
   }
  }
  @inline(__always) func parseAnyDate(_ s: String) -> Date? {
   let iso = ISO8601DateFormatter()
   iso.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withTimeZone, .withFractionalSeconds]
   if let d = iso.date(from: s) { return d }
   let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(secondsFromGMT: 0)
   let fmts = ["yyyy-MM-dd","yyyy-MM","yyyy-MM-dd'T'HH:mm:ssXXXXX","yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"]
   for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
   if let epoch = Double(s) { return Date(timeIntervalSince1970: epoch) }
   if s.count == 7, s.contains("-") { df.dateFormat = "yyyy-MM-dd"; return df.date(from: s + "-01") }
   return nil
  }
  
  @inline(__always) func rowDate(_ any: Any) -> Date? {
   if let d = any as? [String: Any] {
    // direct
    if let s = d["__dt"] as? String, let dt = parseAnyDate(s) { return dt }
    // nested common wrappers
    for k in ["row","data","payload","fields","record"] {
     if let sub = d[k] as? [String: Any] {
      if let s = sub["__dt"] as? String, let dt = parseAnyDate(s) { return dt }
     }
    }
   }
   return nil
  }
  
  let startDate = dateRange?.0
  let endDate   = dateRange?.1
  
  @inline(__always) func inDateRange(_ dt: Date?) -> Bool {
   if startDate == nil && endDate == nil { return true }
   guard let dt else { return false }
   if let s = startDate, dt < s { return false }
   if let e = endDate, dt > e { return false }
   return true
  }
  
  @inline(__always) func countInText(_ text: String) {
   let hay = text.lowercased()
   let needleList = terms.map { $0.lowercased() }
   for (i, needle) in needleList.enumerated() where !needle.isEmpty {
    var c = 0
    var searchRange: Range<String.Index>? = hay.startIndex..<hay.endIndex
    while let r = hay.range(of: needle, range: searchRange) {
     c += 1
     searchRange = r.upperBound..<hay.endIndex
    }
    if c > 0 { counts[terms[i], default: 0] += c }
   }
  }
  
  func collectTextFromArray(_ arr: [Any], headers: [String]) -> String {
   let hdrs = headers.map { $0.lowercased() }
   if hdrs.count == arr.count {
    for key in ["cleaned_text","clean_text","text","body","content","message","comment","post","title","selftext","description","review"] {
     if let i = hdrs.firstIndex(of: key), i < arr.count, let s = arr[i] as? String, !s.isEmpty { return s }
    }
   }
   let joined = arr.compactMap { $0 as? String }.joined(separator: " ")
   return joined.isEmpty ? "" : joined
  }
  
  func collectTextDeep(_ any: Any, maxDepth: Int = 4, _ depth: Int = 0) -> String {
   if depth > maxDepth { return "" }
   var pieces: [String] = []
   if let s = any as? String, !s.isEmpty { pieces.append(s) }
   else if let d = any as? [String: Any] {
    let preferredKeys = ["cleaned_text","clean_text","text","body","content","message","comment","post","title","selftext","description","review"]
    for k in preferredKeys { if let s = d[k] as? String, !s.isEmpty { pieces.append(s) } }
    for (_, v) in d {
     if let s = v as? String, !s.isEmpty { pieces.append(s) }
     else if let arr = v as? [String] { pieces.append(arr.joined(separator: " ")) }
     else if v is [Any] || v is [String: Any] {
      let inner = collectTextDeep(v, maxDepth: maxDepth, depth + 1)
      if !inner.isEmpty { pieces.append(inner) }
     }
    }
   } else if let arr = any as? [Any] {
    for v in arr {
     if let s = v as? String, !s.isEmpty { pieces.append(s) }
     else if v is [Any] || v is [String: Any] {
      let inner = collectTextDeep(v, maxDepth: maxDepth, depth + 1)
      if !inner.isEmpty { pieces.append(inner) }
     }
    }
   }
   return pieces.joined(separator: " ")
  }
  
  func collectText(from any: Any) -> String {
   if let d = any as? [String: Any] { return collectTextDeep(d) }
   if let arr = any as? [Any] {
    let mapped = collectTextFromArray(arr, headers: headers)
    if !mapped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return mapped }
    return collectTextDeep(arr)
   }
   return ""
  }
  
  while true {
   let dataOpt = try? fh.read(upToCount: chunkSize)
   guard let data = dataOpt, !data.isEmpty else { break }
   buffer.append(data)
   while let nl = buffer.firstRange(of: Data([0x0A])) {
    let lineData = buffer.subdata(in: buffer.startIndex..<nl.lowerBound)
    buffer.removeSubrange(buffer.startIndex...nl.lowerBound)
    if lineData.isEmpty { continue }
    guard let line = String(data: lineData, encoding: .utf8) else { continue }
    if line.contains(#""__meta__": true"#) {
     handleHeartbeat(String(line))
     continue
    }
    if let d = line.data(using: .utf8),
       let any = try? JSONSerialization.jsonObject(with: d) {
     let text = collectText(from: any)
     if !matchTextFilter(text) { continue }
     if !inDateRange(rowDate(any)) { continue }
     countInText(text)
    }
   }
  }
  if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
   if !line.contains(#""__meta__": true"#),
      let d = line.data(using: .utf8),
      let any = try? JSONSerialization.jsonObject(with: d) {
    let text = collectText(from: any)
    if matchTextFilter(text) && inDateRange(rowDate(any)) { countInText(text) }
   }
  }
  Self._termCache[jsonlPath] = counts
  return counts
 }

 
 // === Back-compat instance forwarders for old call sites ===
 func scanLabelCounts(jsonlPath: String) -> (pos: Int, neu: Int, neg: Int) {
  Self.scanLabelCounts(jsonlPath: jsonlPath, headers: self.headers)
 }


 
 // --- helpers for text collection ---
 
 /// Deep, tolerant text collector that walks nested dicts/arrays (depth-limited).
 func collectTextDeep(_ any: Any, maxDepth: Int = 4, _ depth: Int = 0) -> String {
  if depth > maxDepth { return "" }
  var pieces: [String] = []
  
  if let s = any as? String, !s.isEmpty {
   pieces.append(s)
  } else if let d = any as? [String: Any] {
   // Prefer common text fields first
   let preferredKeys = ["cleaned_text","clean_text","text","body","content","message","comment","post","title","selftext","description","review"]
   for k in preferredKeys {
    if let s = d[k] as? String, !s.isEmpty { pieces.append(s) }
   }
   // Then walk everything else
   for (_, v) in d {
    if let s = v as? String, !s.isEmpty {
     pieces.append(s)
    } else if let arr = v as? [String] {
     pieces.append(arr.joined(separator: " "))
    } else if v is [Any] || v is [String: Any] {
     let inner = collectTextDeep(v, maxDepth: maxDepth, depth + 1)
     if !inner.isEmpty { pieces.append(inner) }
    }
   }
  } else if let arr = any as? [Any] {
   for v in arr {
    if let s = v as? String, !s.isEmpty { pieces.append(s) }
    else if v is [Any] || v is [String: Any] {
     let inner = collectTextDeep(v, maxDepth: maxDepth, depth + 1)
     if !inner.isEmpty { pieces.append(inner) }
    }
   }
  }
  return pieces.joined(separator: " ")
 }
 
 func collectTextFromDict(_ obj: [String: Any]) -> String {
  var pieces: [String] = []
  let preferredKeys = ["cleaned_text","clean_text","text","body","content","message","comment","post","title","selftext"]
  for k in preferredKeys {
   if let s = obj[k] as? String, !s.isEmpty { pieces.append(s) }
  }
  for (_, v) in obj {
   if let s = v as? String, !s.isEmpty { pieces.append(s) }
   else if let arr = v as? [String] { pieces.append(arr.joined(separator: " ")) }
  }
  // If still empty, fall back to deep scan
  let joined = pieces.joined(separator: " ")
  return joined.isEmpty ? collectTextDeep(obj) : joined
 }
 
 func collectTextFromArray(_ arr: [Any]) -> String {
  let hdrs = self.headers.map { $0.lowercased() }
  if hdrs.count == arr.count {
   // Try preferred columns first
   for key in ["cleaned_text","clean_text","text","body","content","message","comment","post","title","selftext","description","review"] {
    if let i = hdrs.firstIndex(of: key), i < arr.count, let s = arr[i] as? String, !s.isEmpty {
     return s
    }
   }
  }
  // Fallback: join any string-like fields
  let joined = arr.compactMap { $0 as? String }.joined(separator: " ")
  return joined.isEmpty ? "" : joined
 }
 
 // Reads label counts from meta if available.
 private func metaLabelCounts() -> (pos: Int, neu: Int, neg: Int) {
  func readDict(_ any: Any?) -> (Int, Int, Int)? {
   guard let d = any as? [String: Any] else { return nil }
   let pos = (d["POSITIVE"] as? Int)
   ?? (d["positive"] as? Int)
   ?? Int("\(d["POSITIVE"] ?? "")")
   ?? Int("\(d["positive"] ?? "")")
   let neg = (d["NEGATIVE"] as? Int)
   ?? (d["negative"] as? Int)
   ?? Int("\(d["NEGATIVE"] ?? "")")
   ?? Int("\(d["negative"] ?? "")")
   let neu = (d["NEUTRAL"] as? Int)
   ?? (d["neutral"] as? Int)
   ?? Int("\(d["NEUTRAL"] ?? "")")
   ?? Int("\(d["neutral"] ?? "")")
   if let pos, let neu, let neg { return (pos, neu, neg) }
   return nil
  }
  if let t = readDict(meta["label_counts"]) { return t }
  if let t = readDict(meta["sentiment_counts"]) { return t }
  return (0,0,0)
 }
 
 // --- meta-first helpers for keyword counts ---
 private func countsFromMetaKeywords(terms: [String]) -> [String: Int] {
  guard !terms.isEmpty else { return [:] }
  var result = Dictionary(uniqueKeysWithValues: terms.map { ($0, 0) })
  
  func norm(_ s: String) -> String {
   s.lowercased()
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }
  let termSet = Dictionary(uniqueKeysWithValues: terms.map { (norm($0), $0) }) // normalized -> original
  
  // 1) stats arrays with counts
  if let arr = meta["keyword_stats"] as? [[String: Any]] {
   for m in arr {
    let keyName: String = (m["word"] as? String)
    ?? (m["term"] as? String)
    ?? (m["text"] as? String)
    ?? ""
    let keyN = norm(keyName)
    guard let orig = termSet[keyN] else { continue }
    if let c = (m["count"] as? Int)
        ?? (m["freq"] as? Int)
        ?? (m["n"] as? Int)
        ?? Int("\(m["count"] ?? "")") {
     result[orig, default: 0] += max(0, c)
    }
   }
  }
  
  // 2) cleaned lists (no counts, but if present we can set to 1 as a minimum signal)
  func bumpOne(from any: Any?) {
   if let arr = any as? [[String: Any]] {
    for m in arr {
     let w = (m["word"] as? String)
     ?? (m["term"] as? String)
     ?? (m["text"] as? String)
     guard let w, let orig = termSet[norm(w)] else { continue }
     result[orig] = max(result[orig] ?? 0, 1)
    }
   } else if let arr = any as? [String] {
    for w in arr {
     if let orig = termSet[norm(w)] {
      result[orig] = max(result[orig] ?? 0, 1)
     }
    }
   }
  }
  bumpOne(from: meta["clean_keywords_pos"])
  bumpOne(from: meta["clean_keywords_neg"])
  bumpOne(from: meta["keywords"])
  
  return result
 }
}

private extension String {
 var nilIfEmpty: String? { isEmpty ? nil : self }
}
