// /Users/trevor/Documents/PolarityLab/PolarityLab/AnalysisResultsView+Layout.swift
import SwiftUI
import Charts

extension AnalysisResultsView {
 // Header
 @ViewBuilder func header(contentWidth: CGFloat) -> some View {
  HStack(spacing: 12) {
   Text("Results").font(.largeTitle.bold()); Spacer()
   if let s = appliedFilterSummary { chip("Filter: \(s)") }
   if let d = appliedDateSummary { chip("Date: \(d)") }
  }
  .frame(width: contentWidth)
 }
 
 // Three side-by-side cards: Pos Keywords • Neg Keywords • Sentiment Pie
 // All same size, filling the same horizontal space as the timeline.
 @ViewBuilder func kpAndPieRow(contentWidth: CGFloat) -> some View {
  let gap: CGFloat = 16
  let cardH: CGFloat = 320
  let colW: CGFloat = max(300, (contentWidth - gap*2) / 3)
  
  HStack(spacing: gap) {
   // Positive keywords
   TableCard("Top Positive Keywords") {
    let rows = Array(topPosKeywords.sorted { $0.1 > $1.1 }.prefix(12))
     .map { (t, s) in (t, s, keywordCounts[t] ?? 0) }
    KeywordTable(rows: rows)
   }
   .frame(width: colW, height: cardH, alignment: .topLeading)
   
   // Negative keywords
   TableCard("Top Negative Keywords") {
    let rows = Array(topNegKeywords.sorted { abs($0.1) > abs($1.1) }.prefix(12))
     .map { (t, s) in (t, s, keywordCounts[t] ?? 0) }
    KeywordTable(rows: rows)
   }
   .frame(width: colW, height: cardH, alignment: .topLeading)
   
   // Pie – same size as the keyword cards
   SectionCard("Sentiment Distribution") {
    let slices = Array(pieCounts)
    Chart {
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
    .chartForegroundStyleScale(["Positive": .green, "Neutral": .gray, "Negative": .red])
    .frame(maxWidth: .infinity, maxHeight: .infinity)
   }
   .frame(width: colW, height: cardH, alignment: .center)
  }
  .frame(width: contentWidth, height: cardH, alignment: .center)
  .padding(.bottom, 8)
 }
 
 // Stats
 @ViewBuilder func statsSection(contentWidth: CGFloat) -> some View {
  SectionCard("Stats", subtitle: "Counts are row volume. Peak = highest bucketed day/week/month in view.") {
   let vs = volumeStats(for: visibleX)
   HStack {
    Spacer()
    if let vs {
     VStack(alignment: .trailing, spacing: 4) {
      Text("Total rows \(vs.total.formatted())")
      Text("Avg/day \(Int(vs.avgPerDay.rounded()).formatted())")
      Text("Peak bucket \(vs.peakCount.formatted()) on \(vs.peakDate, style: .date)")
     }
     .font(.system(size: 15, weight: .semibold))
     .padding(.vertical, 8).padding(.horizontal, 10)
     .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 6))
    } else {
     Text("No stats available").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
    }
    Spacer()
   }
   .frame(minHeight: 84)
  }
  .frame(width: contentWidth)
 }
 
 // Toggle bar
 @ViewBuilder var overlayToggleBar: some View {
  VStack(spacing: 6) {
   HStack(spacing: 10) {
    ToggleButton(isOn: $showVolumeBand,  label: "Volume", icon: "chart.bar.doc.horizontal")
    ToggleButton(isOn: $showYearCompare, label: "Year Compare", icon: "calendar")
     .disabled(!yoyAvailable).opacity(yoyAvailable ? 1 : 0.5)
    ToggleButton(isOn: $showEventMarkers, label: "Events", icon: "flag")
   }
   .frame(maxWidth: .infinity, alignment: .center)
   Text("Volume uses the left axis. Sentiment uses the right axis. Zoom to change bucket size.")
    .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
  }
 }
}

// MARK: - Scrollable keyword table with header
private struct KeywordTable: View {
 let rows: [(String, Double, Int)]  // (term, score, count)
 
 var body: some View {
  VStack(spacing: 6) {
   // Column headers
   HStack {
    Text("Term").font(.caption.weight(.semibold))
    Spacer()
    Text("Count").font(.caption2).foregroundStyle(.secondary)
     .frame(width: 56, alignment: .trailing)
    Text("Score").font(.caption2).foregroundStyle(.secondary)
     .frame(width: 64, alignment: .trailing)
   }
   Divider()
   
   // Scrollable rows
   ScrollView {
    LazyVStack(alignment: .leading, spacing: 8) {
     ForEach(rows.indices, id: \.self) { i in
      let r = rows[i]
      HStack(spacing: 12) {
       Text(r.0)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
       Text(r.2.formatted())
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 56, alignment: .trailing)
       Text(String(format: r.1 >= 0 ? "+%.3f" : "%.3f", r.1))
        .monospacedDigit()
        .foregroundStyle(r.1 >= 0 ? .green : .red)
        .frame(width: 64, alignment: .trailing)
      }
     }
    }
    .padding(.vertical, 4)
   }
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  .clipped()
 }
}
