import SwiftUI
import Charts
import UniformTypeIdentifiers
import Foundation
#if canImport(AppKit)
import AppKit
import CoreText
import CoreGraphics
#endif

@MainActor
struct AnalysisResultsView: View {
 // Inputs
 let keywords: [(String, Double)]
 let exportSourcePath: String
 let headers: [String]
 let meta: [String: Any]
 let hasNeutral: Bool
 @Binding var showingExporter: Bool
 let onReset: () -> Void
 let synopsis: String?
 let appliedFilterSummary: String?
 let appliedDateSummary: String?
 let keywordOverrides: [String: Double]?
 
 // State
 @State var xDomain: ClosedRange<Date>? = nil
 @State var yDomain: ClosedRange<Double>? = nil
 @State var timeline: [TLPoint] = []
 @State var visibleSeries: [TLPoint] = []
 @State var allDates: [Date] = []
 @State var pieCounts: [PieSlice] = []
 @State var yearCompareSeries: [YearLinePoint] = []
 @State var events: [EventMarker] = []
 @State var yoyAvailable: Bool = false
 @State var keywordCounts: [String: Int] = [:]
 @State var scrollX: Date = Date()
 @State var visibleSpan: TimeInterval = 86_400
 @State var hoverPoint: TLPoint? = nil
 
 // Toggles
 @AppStorage("showVolumeBand")  var showVolumeBand: Bool  = true
 @AppStorage("showYearCompare") var showYearCompare: Bool = false
 @AppStorage("showEventMarkers") var showEventMarkers: Bool = false
 @AppStorage("neutralBandWidth") var neutralBandWidth: Double = 0.05
 
 // Layout constants (instance-level so extensions can access)
 var tableSpacing: CGFloat { 16 }
 var pieWidth: CGFloat { 320 }
 var sectionSpacing: CGFloat { 16 }
 
 // Calendar (internal so extensions in other files can access it)
 var calUTC: Calendar {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(secondsFromGMT: 0)!
  return c
 }
 
 var body: some View {
  GeometryReader { geo in
   let inset: CGFloat = 16
   let minContentWidth: CGFloat = 980
   let available = geo.size.width - inset * 2
   let contentWidth = max(minContentWidth, available)
   
   ScrollView([.vertical, .horizontal]) {
    VStack(spacing: sectionSpacing) {
     header(contentWidth: contentWidth)
     chartCard().frame(width: contentWidth)
     overlayToggleBar.frame(width: contentWidth).padding(.top, 2)
     kpAndPieRow(contentWidth: contentWidth)
     statsSection(contentWidth: contentWidth)
     exportBar(contentWidth: contentWidth)
    }
    .frame(minWidth: contentWidth, maxWidth: .infinity)
    .padding(.vertical, 8)
    .padding(.horizontal, inset)
   }
   .frame(width: geo.size.width, height: geo.size.height)
   .onAppear {
    // Order ensures derived values (visibleRange/xDomain) are valid before overlays & counts.
    buildTimeline()
    setVisibleToFullRange()
    xDomain = visibleRange
    buildOverlays()
    rebuildKeywordsFromMeta()   // provided by +Scanning.swift
    parseEvents()
    buildPieCounts()
   }
  }
  .onChange(of: scrollX) { _ in
   xDomain = visibleRange
   buildOverlays()
   rebuildKeywordsFromMeta()
  }
  .onChange(of: visibleSpan) { _ in
   xDomain = visibleRange
   buildOverlays()
   rebuildKeywordsFromMeta()
  }
 }

    // Lightweight, zero-rescan keyword counts built from export meta only.
    // This keeps the UI fully responsive: no dataset reloads on scroll/zoom.
    func rebuildKeywordsFromMeta() {
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
            return keywords
        }

        let pairs = extractPairs()
        if pairs.isEmpty {
            keywordCounts = [:]
            return
        }

        func keep(_ w: String) -> Bool {
            if w.isEmpty { return false }
            if w.count < 2 || w.count > 24 { return false }
            if w.contains("_") { return false }
            if w.rangeOfCharacter(from: CharacterSet.letters) == nil { return false }
            if w.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) { return false }
            return true
        }

        var filtered: [(String, Double)] = []
        var seen = Set<String>()
        for (w, s) in pairs {
            let k = w.trimmingCharacters(in: .whitespacesAndNewlines)
            if k.isEmpty { continue }
            let lk = k.lowercased()
            if keep(k), s.isFinite, seen.insert(lk).inserted {
                filtered.append((k, s))
            }
        }
        if filtered.isEmpty {
            keywordCounts = [:]
            return
        }

        filtered.sort { a, b in
            let ia = abs(a.1), ib = abs(b.1)
            if ia == ib { return a.1 == b.1 ? (a.0 < b.0) : (a.1 > b.1) }
            return ia > ib
        }

        let maxN = min(filtered.count, 200)
        let top = Array(filtered.prefix(maxN))
        let hi = abs(top.first?.1 ?? 1.0)
        let lo = abs(top.last?.1 ?? 0.0)
        let denom = max(hi - lo, 0.001)

        var out: [String: Int] = [:]
        for (w, s) in top {
            let t = (abs(s) - lo) / denom
            let count = Int(30 + round(t * 70)) // 30..100
            out[w] = max(count, 1)
        }
        keywordCounts = out
    }

}
