// AnalysisResultsView+Timeline.swift
import SwiftUI

extension AnalysisResultsView {
 func setVisibleToFullRange() {
  let d = defaultXDomain
  let span = max(24*3600, d.upperBound.timeIntervalSince(d.lowerBound))
  scrollX = Date(timeIntervalSince1970: (d.lowerBound.timeIntervalSince1970 + d.upperBound.timeIntervalSince1970) / 2)
  visibleSpan = span
  xDomain = d
 }
 
func zoom(factor: Double) {
  guard !allDates.isEmpty else { return }
  let full = defaultXDomain
  let fullSpan = full.upperBound.timeIntervalSince(full.lowerBound)
  let minSpan: TimeInterval = 24 * 3600
  let maxSpan: TimeInterval = max(fullSpan, minSpan)
  let newSpan = max(minSpan, min(maxSpan, visibleSpan * factor))
  visibleSpan = newSpan

  // Enable scrolling when zoomed: clamp center and update xDomain
  let half = newSpan / 2
  let minCenter = full.lowerBound.addingTimeInterval(half)
  let maxCenter = full.upperBound.addingTimeInterval(-half)

  var center = scrollX
  if newSpan >= fullSpan || minCenter > maxCenter {
    // Snap to full range when fully zoomed out
    center = Date(timeIntervalSince1970: (full.lowerBound.timeIntervalSince1970 + full.upperBound.timeIntervalSince1970) / 2)
    scrollX = center
    xDomain = full
    visibleSpan = fullSpan
    return
  }

  if center < minCenter { center = minCenter }
  if center > maxCenter { center = maxCenter }
  scrollX = center
  let lo = center.addingTimeInterval(-half)
  let hi = center.addingTimeInterval(+half)
  xDomain = lo...hi
}


 
 func currentBucket(for visible: ClosedRange<Date>) -> Calendar.Component {
  let days = max(1.0, visible.upperBound.timeIntervalSince(visible.lowerBound) / 86400.0)
  if days <= 31 { return .day }
  if days <= 120 { return .weekOfYear }
  return .month
 }
 
 func buildTimeline() {
  let arr = (meta["timeline"] as? [[String: Any]])
  ?? ((meta["meta"] as? [String: Any])?["timeline"] as? [[String: Any]])
  ?? ((meta["syn_pack"] as? [String: Any])?["timeline"] as? [[String: Any]])
  ?? ((meta["synopsis_pack"] as? [String: Any])?["timeline"] as? [[String: Any]])
  guard let arr else { timeline = []; visibleSeries = []; allDates = []; yoyAvailable = false; return }
  
  let iso = ISO8601DateFormatter()
  iso.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withFractionalSeconds, .withTimeZone]
  let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(secondsFromGMT: 0)
  let patterns = ["yyyy-MM-dd'T'HH:mm:ssXXXXX","yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX","yyyy-MM-dd'T'HH:mm:ss","yyyy-MM-dd'T'HH:mm:ss.SSS","yyyy-MM","yyyy-MM-dd"]
  func parseBucket(_ s: String) -> Date? {
   if let d = iso.date(from: s) { return d }
   for p in patterns { df.dateFormat = p; if let d = df.date(from: s) { return d } }
   if s.count == 7, s.contains("-") { df.dateFormat = "yyyy-MM-dd"; return df.date(from: s + "-01") }
   return nil
  }
  
  let pts: [TLPoint] = arr.compactMap { d in
   let bucketStr = (d["bucket"] as? String) ?? (d["date"] as? String) ?? (d["bucket_start"] as? String)
   let avgAny: Any? = d["avg_compound"] ?? d["average"] ?? d["avg"] ?? d["mean"]
   let cntAny: Any? = d["count"] ?? d["n"]
   guard let bucket = bucketStr, let avgAny, let cntAny else { return nil }
   let avg = (avgAny as? NSNumber)?.doubleValue ?? (avgAny as? Double) ?? Double("\(avgAny)")
   let count = (cntAny as? NSNumber)?.intValue ?? (cntAny as? Int) ?? Int("\(cntAny)")
   guard let a = avg, a.isFinite, let c = count, c >= 0, let dt = parseBucket(bucket) else { return nil }
   return TLPoint(date: dt, avg: clamp1(a), count: c)
  }.sorted { $0.date < $1.date }
  
  timeline = pts
  allDates = pts.map { $0.date }
  
  // Ensure events are parsed and their dates included before computing default domain
  parseEvents()
  
  if xDomain == nil { xDomain = defaultXDomain }
  buildOverlays()
 }
 
 func parseEvents() {
  let arr = (meta["events"] as? [[String: Any]])
  ?? ((meta["meta"] as? [String: Any])?["events"] as? [[String: Any]])
  ?? ((meta["syn_pack"] as? [String: Any])?["events"] as? [[String: Any]])
  ?? ((meta["synopsis_pack"] as? [String: Any])?["events"] as? [[String: Any]])
  guard let arr else { events = []; return }
  
  let iso = ISO8601DateFormatter()
  iso.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withTimeZone, .withFractionalSeconds]
  let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(secondsFromGMT: 0)
  let fmts = ["yyyy-MM-dd","yyyy-MM","yyyy-MM-dd'T'HH:mm:ssXXXXX","yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"]
  func parseAny(_ s: String) -> Date? {
   if let d = iso.date(from: s) { return d }
   for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
   if let epoch = Double(s) { return Date(timeIntervalSince1970: epoch) }
   if s.count == 7, s.contains("-") { df.dateFormat = "yyyy-MM-dd"; return df.date(from: s + "-01") }
   return nil
  }
  
  events = arr.compactMap { e in
   let label = (e["label"] as? String) ?? (e["title"] as? String) ?? (e["type"] as? String) ?? ""
   if let ts = e["timestamp"] as? Double { return EventMarker(date: Date(timeIntervalSince1970: ts), title: label) }
   for key in ["timestamp","date","bucket","bucket_start"] {
    if let s = e[key] as? String, let d = parseAny(s) { return EventMarker(date: d, title: label) }
   }
   return nil
  }.sorted { $0.date < $1.date }
  
  if !events.isEmpty {
   var set = Set(allDates)
   for d in events.map(\.date) { set.insert(d) }
   allDates = Array(set).sorted()
  }
 }
 
 func buildOverlays() {
  guard !timeline.isEmpty else { visibleSeries = []; yearCompareSeries = []; yDomain = nil; yoyAvailable = false; showYearCompare = false; return }
  let visible = xDomain ?? defaultXDomain
  let bucket = currentBucket(for: visible)
  let calendar = calUTC   // was 'var', never mutated
  
  struct Bin { var sum: Double = 0; var count: Int = 0 }
  var bins: [Date: Bin] = [:]
  func bucketStart(_ d: Date) -> Date {
   switch bucket {
   case .day: return calendar.startOfDay(for: d)
   case .weekOfYear:
    let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
    return calendar.date(from: comps) ?? calendar.startOfDay(for: d)
   default:
    let comps = calendar.dateComponents([.year, .month], from: d)
    return calendar.date(from: comps) ?? calendar.startOfDay(for: d)
   }
  }
  for p in timeline {
   let k = bucketStart(p.date)
   var b = bins[k, default: Bin()]
   b.sum += p.avg * Double(p.count); b.count += p.count
   bins[k] = b
  }
  visibleSeries = bins.keys.sorted().compactMap { k in
   guard let b = bins[k], b.count > 0 else { return nil }
   return TLPoint(date: k, avg: b.sum / Double(b.count), count: b.count)
  }
  yearCompareSeries = yearCompareCompute(base: visibleSeries)
  let years = Set(timeline.map { calUTC.component(.year, from: $0.date) })
  yoyAvailable = years.count >= 2; if !yoyAvailable { showYearCompare = false }
  yDomain = computeAdaptiveYDomain()
 }
 
 func yearCompareSeriesByYearMultiPoint(excluding excludeYear: Int) -> [(key: String, value: [YearLinePoint])] {
  let grouped = Dictionary(grouping: yearCompareSeries, by: { $0.yearLabel })
  return grouped.filter { $0.key != "\(excludeYear)" }.filter { $0.value.count >= 2 }
   .sorted { $0.key < $1.key }
   .map { ($0.key, $0.value.sorted { $0.monthAligned < $1.monthAligned }) }
 }
 
 func yearCompareCompute(base: [TLPoint]) -> [YearLinePoint] {
  guard !base.isEmpty else { return [] }
  let byYear = Dictionary(grouping: base) { calUTC.component(.year, from: $0.date) }
  var out: [YearLinePoint] = []
  for (year, pts) in byYear {
   for p in pts.sorted(by: { $0.date < $1.date }) {
    let comp = calUTC.dateComponents([.month, .day], from: p.date)
    var base = DateComponents(year: 2000, month: comp.month, day: min(comp.day ?? 1, 28))
    base.hour = 12
    let aligned = calUTC.date(from: base) ?? p.date
    out.append(YearLinePoint(monthAligned: aligned, avg: p.avg, yearLabel: "\(year)"))
   }
  }
  return out
 }
 
 func mapMonthDay(_ date: Date, toYear year: Int) -> Date {
  let c = calUTC.dateComponents([.month, .day], from: date)
  let dc = DateComponents(year: year, month: c.month, day: min(c.day ?? 1, 28), hour: 12) // was 'var', never mutated
  return calUTC.date(from: dc) ?? date
 }
 
 func computeAdaptiveYDomain() -> ClosedRange<Double> {
  let ys = visibleSeries.map { $0.avg }.filter { $0.isFinite }
  guard let minY = ys.min(), let maxY = ys.max(), minY.isFinite, maxY.isFinite else { return (-1.0)...(1.0) }
  var lo = minY, hi = maxY
  if abs(hi - lo) < 0.02 { let mid = (hi + lo) / 2.0; lo = mid - 0.02; hi = mid + 0.02 }
  let span = max(hi - lo, 0.001), pad = span * 0.1
  lo = max(-1.0, lo - pad); hi = min(1.0, hi + pad)
  if (hi - lo) < 0.02 { let mid = (hi + lo) / 2.0; lo = max(-1.0, mid - 0.01); hi = min(1.0, mid + 0.01) }
  return lo...hi
 }
 
 func yTickValues(for domain: ClosedRange<Double>, xVisible: ClosedRange<Date>) -> [Double] {
  let lo = domain.lowerBound, hi = domain.upperBound
  let range = max(hi - lo, 0.001); let rawStep = max(range / 6.0, 0.001)
  let step = max(niceStep(rawStep), 0.005)
  let start = floor(lo / step) * step, end = ceil(hi / step) * step
  var ticks: [Double] = []; var v = start; var safety = 0
  while v <= end + step*0.25 && safety < 100 { let f = Double(String(format: "%.4f", v)) ?? v; if f.isFinite { ticks.append(f) }; v += step; safety += 1 }
  ticks = ticks.filter { $0 >= lo - 1e-9 && $0 <= hi + 1e-9 }
  if lo < 0, hi > 0, ticks.contains(where: { abs($0) < step/2 }) == false { if 0 >= lo - 1e-9 && 0 <= hi + 1e-9 { ticks.append(0) }; ticks.sort() }
  if ticks.isEmpty { return [-1, -0.5, 0, 0.5, 1].filter { $0 >= lo && $0 <= hi } }
  return ticks
 }
 
 func niceStep(_ x: Double) -> Double {
  guard x.isFinite && x > 0 else { return 0.1 }
  let mag = pow(10.0, floor(log10(x))), norm = x / mag, nice: Double
  if norm < 1.5 { nice = 1 } else if norm < 3 { nice = 2 } else if norm < 7 { nice = 5 } else { return 10 * mag }
  let step = nice * mag
  if step >= 0.1 { return step }
  if step >= 0.05 { return 0.05 }
  if step >= 0.02 { return 0.02 }
  if step >= 0.01 { return 0.01 }
  return 0.005
 }
 
 func volumeStats(for visibleX: ClosedRange<Date>) -> (total: Int, avgPerDay: Double, peakCount: Int, peakDate: Date)? {
  guard !visibleSeries.isEmpty else { return nil }
  let total = visibleSeries.reduce(0) { $0 + $1.count }
  let days = max(1.0, visibleX.upperBound.timeIntervalSince(visibleX.lowerBound) / 86400.0)
  let avgPerDay = Double(total) / days
  if let peak = visibleSeries.max(by: { $1.count > $0.count }) { return (total, avgPerDay, peak.count, peak.date) }
  return (total, avgPerDay, 0, visibleX.lowerBound)
 }
}
