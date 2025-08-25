import SwiftUI
import Foundation

extension AnalysisResultsView {
 // Shared helper
 func clamp1(_ x: Double) -> Double { max(-1, min(1, x)) }
 
 // Resolve exported JSONL path from meta or prop
 var effectiveExportPath: String {
  if !exportSourcePath.isEmpty { return exportSourcePath }
  if let p = meta["pl_out"] as? String { return p }
  if let p = meta["export_path"] as? String { return p }
  if let p = meta["jsonl_path"] as? String { return p }
  return ""
 }
 
 // Resolve headers from meta or prop
 var effectiveHeaders: [String] {
  if !headers.isEmpty { return headers }
  if let h = meta["row_headers"] as? [String] { return h }
  if let h = meta["headers"] as? [String] { return h }
  return []
 }
 
 // MARK: - Keywords (UI-safe, no I/O or rescans)
 var effectiveKeywords: [(String, Double)] {
  if !keywords.isEmpty {
   return keywords.map { ($0.0, clamp1($0.1)) }
  }
  return []
 }
 
 // MARK: - Blends & tops
 var blendedKeywords: [(String, Double)] {
  var dict = Dictionary(uniqueKeysWithValues: effectiveKeywords.map { ($0.0, clamp1($0.1)) })
  let blend = 0.35
  if let overrides = keywordOverrides {
   for (k, oRaw) in overrides {
    let base = dict[k] ?? 0
    dict[k] = clamp1(base + clamp1(oRaw) * blend)
   }
  }
  return dict.map { ($0.key, $0.value) }
 }
 
 var topPosKeywords: [(String, Double)] {
  blendedKeywords
   .filter { $0.1 > 0 }
   .sorted { ($0.1, $0.0.lowercased()) > ($1.1, $1.0.lowercased()) }
   .prefix(12)
   .map { ($0.0, $0.1) }
 }
 
 var topNegKeywords: [(String, Double)] {
  blendedKeywords
   .filter { $0.1 < 0 }
   .sorted {
    let a = abs($0.1), b = abs($1.1)
    return a == b ? $0.0.lowercased() < $1.0.lowercased() : a > b
   }
   .prefix(12)
   .map { ($0.0, $0.1) }
 }
 
 // MARK: - Domains / ticks
 var defaultXDomain: ClosedRange<Date> {
  guard let first = allDates.first, let last = allDates.last else {
   let now = Date()
   return now...now
  }
  if first == last {
   return first.addingTimeInterval(-43_200)...last.addingTimeInterval(43_200)
  }
  return first...last
 }
 
 var visibleRange: ClosedRange<Date> {
  let full = defaultXDomain
  let half = max(visibleSpan, 86_400) / 2
  let c = scrollX
  let lo = max(full.lowerBound.timeIntervalSince1970, c.timeIntervalSince1970 - half)
  let hi = min(full.upperBound.timeIntervalSince1970, c.timeIntervalSince1970 + half)
  let lower = Date(timeIntervalSince1970: lo)
  let upper = lo < hi ? Date(timeIntervalSince1970: hi) : lower.addingTimeInterval(86_400)
  return lower...upper
 }
 
 var adaptiveY: ClosedRange<Double> { yDomain ?? computeAdaptiveYDomain() }
 var visibleX: ClosedRange<Date> { visibleRange }
 var yTicks: [Double] { yTickValues(for: adaptiveY, xVisible: visibleX) }
 
 // Explicit component to silence inference warning
 var refYear: Int {
  calUTC.component(Calendar.Component.year, from: visibleX.upperBound)
 }
}
