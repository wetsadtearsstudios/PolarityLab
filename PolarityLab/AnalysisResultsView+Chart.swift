// AnalysisResultsView+Chart.swift
import SwiftUI
import Charts

extension AnalysisResultsView {
 func chartCard() -> some View {
  if visibleSeries.isEmpty || allDates.isEmpty {
   return AnyView(
    SectionCard("Sentiment Over Time", subtitle: "No timeline data available.") {
     Text("Nothing to chart yet.")
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(height: 120)
    }
   )
  }
  
  // Snapshot to keep type-checking fast
  let s = Array(visibleSeries)
  let pairs = yearCompareSeriesByYearMultiPoint(excluding: refYear)
  let visX = visibleX
  let evtsVisible = events.filter { $0.date >= visX.lowerBound && $0.date <= visX.upperBound }
  
  let yDom = adaptiveY
  let yLower = yDom.lowerBound
  let yUpper = yDom.upperBound
  let yTicksLocal = yTicks
  
  let maxCount = max(s.map(\.count).max() ?? 1, 1)
  let span = max(yUpper - yLower, 0.0001)
  
  func mapCount(_ c: Int) -> Double {
   let r = Double(c) / Double(maxCount)
   return yLower + r * span
  }
  
  let vals = s.map(\.avg)
  let mu = vals.reduce(0, +) / Double(max(vals.count, 1))
  let variance = vals.reduce(0.0) { acc, v in
   let d = v - mu
   return acc + d * d
  } / Double(max(vals.count, 1))
  let sigma = sqrt(max(variance, 0))
  
  // --- Helper: keep scroll anchor valid whenever you zoom or data domain changes ---
  func clampScrollCenter() {
   // If we haven't zoomed in (visible == full range), no clamping needed.
   let full = defaultXDomain
   let total = full.upperBound.timeIntervalSince(full.lowerBound)
   let window = min(total, max(visibleSpan, 86_400)) // seconds
   let half = window / 2.0
   
   // Allowed range for the *center* position when zoomed.
   let centerMin = full.lowerBound.addingTimeInterval(half)
   let centerMax = full.upperBound.addingTimeInterval(-half)
   
   // If window >= total, just center on the middle of the domain.
   if centerMin > centerMax {
    let mid = full.lowerBound.addingTimeInterval(total / 2.0)
    if scrollX != mid { scrollX = mid }
    return
   }
   let cur = scrollX ?? centerMin
   let clamped = min(max(cur, centerMin), centerMax)
   if scrollX != clamped { scrollX = clamped }
  }
  
  let chart = Chart {
   if showVolumeBand {
    ForEach(0..<s.count, id: \.self) { i in
     let p = s[i]
     BarMark(
      x: .value("Date", p.date),
      yStart: .value("VolumeBase", yLower),
      yEnd: .value("VolumeScaled", mapCount(p.count))
     )
     .opacity(0.25)
     .foregroundStyle(Color.secondary)
    }
   }
   
   // Sentiment line (linear prevents left-edge skew/overshoot)
   ForEach(0..<s.count, id: \.self) { i in
    let p = s[i]
    LineMark(
     x: .value("Date", p.date),
     y: .value("Sentiment", p.avg)
    )
    .interpolationMethod(.linear)
    .lineStyle(StrokeStyle(lineWidth: 2))
    .foregroundStyle(Color.accentColor)
    .opacity(0.95)
   }
   
   // Year-compare overlay
   if showYearCompare && yoyAvailable {
    ForEach(0..<pairs.count, id: \.self) { i in
     let entry = pairs[i]
     let ys = entry.value
     ForEach(0..<ys.count, id: \.self) { j in
      let y = ys[j]
      LineMark(
       x: .value("Date", mapMonthDay(y.monthAligned, toYear: refYear)),
       y: .value("Avg", y.avg),
       series: .value("Year", entry.key)
      )
      .interpolationMethod(.linear)
      .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [6, 3]))
      .foregroundStyle(.secondary)
      .opacity(0.85)
     }
    }
   }
   
   // Events (only those inside the visible range)
   if showEventMarkers {
    ForEach(0..<evtsVisible.count, id: \.self) { i in
     let e = evtsVisible[i]
     RuleMark(x: .value("Event", e.date))
      .foregroundStyle(.secondary)
      .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
      .opacity(0.75)
     
     PointMark(
      x: .value("Event", e.date),
      y: .value("Sentiment", yUpper - max(0.05, span * 0.05))
     )
     .symbol(.diamond)
     .symbolSize(70)
     .foregroundStyle(.secondary)
    }
   }
  }
   .chartYScale(domain: yLower...yUpper)
   .chartYAxis {
    AxisMarks(position: .trailing, values: yTicksLocal) {
     AxisGridLine(); AxisTick(); AxisValueLabel()
    }
    AxisMarks(position: .leading, values: yTicksLocal) { v in
     AxisGridLine(); AxisTick()
     AxisValueLabel {
      if let yy = v.as(Double.self) {
       let ratio = (yy - yLower) / span
       let c = max(0, Int(round(ratio * Double(maxCount))))
       Text("\(c)")
      }
     }
    }
   }
   .chartXAxis {
    let days = max(1.0, visX.upperBound.timeIntervalSince(visX.lowerBound) / 86400.0)
    if days <= 31 {
     AxisMarks(values: .stride(by: .day)) {
      AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month().day())
     }
    } else if days <= 180 {
     AxisMarks(values: .stride(by: .weekOfYear)) {
      AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month().day())
     }
    } else if days <= 800 {
     AxisMarks(values: .stride(by: .month)) {
      AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.year().month())
     }
    } else {
     AxisMarks(values: .stride(by: .year)) {
      AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.year())
     }
    }
   }
   .chartXScale(domain: defaultXDomain)                 // full data domain
   .chartScrollableAxes(.horizontal)                    // enable horizontal scroll
   .chartXVisibleDomain(length: max(visibleSpan, 86_400)) // zoom window (>= 1 day)
   .chartScrollPosition(x: $scrollX)                    // bind center for scrolling
   .frame(height: 320)
   .chartOverlay { proxy in
    GeometryReader { geo in
     let plotAnchor = proxy.plotAreaFrame
     let plotRect = geo[plotAnchor]
     
     // Hover without breaking horizontal scroll
     Rectangle().fill(.clear).contentShape(Rectangle())
      .simultaneousGesture(                              // don't steal scroll
       DragGesture(minimumDistance: 0)
        .onChanged { value in
         let xInPlot = value.location.x - plotRect.origin.x
         if let d: Date = proxy.value(atX: xInPlot) {
          var nearest: TLPoint? = nil
          var best: TimeInterval = .infinity
          for p in s {
           let delta = abs(p.date.timeIntervalSince(d))
           if delta < best { best = delta; nearest = p }
          }
          hoverPoint = nearest
         }
        }
        .onEnded { _ in hoverPoint = nil }
      )
     
     if let p = hoverPoint {
      let xPos = (proxy.position(forX: p.date) ?? 0) + plotRect.origin.x
      let yPos = (proxy.position(forY: p.avg)  ?? 0) + plotRect.origin.y
      let z = (p.avg - mu) / (sigma > 0 ? sigma : 1)
      let neutral = abs(p.avg) < neutralBandWidth
      VStack(alignment: .leading, spacing: 4) {
       Text(dateTooltip(p.date)).font(.caption.weight(.semibold))
       Text(String(format: "Volume: %d", p.count)).font(.caption2)
       Text(String(format: "Mean: %+.3f", p.avg)).font(.caption2)
       Text(String(format: "Z-score: %+.2f", z)).font(.caption2)
       Text(neutral ? "Neutral: Yes" : "Neutral: No").font(.caption2)
      }
      .padding(6)
      .background(.thinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .position(
       x: min(max(xPos, plotRect.origin.x + plotRect.size.width * 0.12),
              plotRect.origin.x + plotRect.size.width * 0.88),
       y: max(yPos - 36, 20)
      )
     }
    }
   }
  // Keep the scroll anchor valid as the domain/zoom changes, so panning stays enabled.
   .onAppear { clampScrollCenter() }
   .onChange(of: visibleSpan) { _ in clampScrollCenter() }
   .onChange(of: defaultXDomain) { _ in clampScrollCenter() }
  
  let legend = HStack(spacing: 12) {
   Rectangle().frame(width: 10, height: 12).foregroundStyle(Color.secondary.opacity(0.25))
   Text("Volume").font(.footnote)
   Rectangle().frame(width: 18, height: 3).foregroundStyle(Color.accentColor).cornerRadius(2)
   Text("Sentiment (line)").font(.footnote)
   Spacer()
  }
   .padding(.top, 2)
  
  let zoomBar = HStack(spacing: 8) {
   Button { zoom(factor: 0.8) }  label: { Label("Zoom In",  systemImage: "plus.magnifyingglass") }
    .buttonStyle(.borderedProminent)
   Button { zoom(factor: 1.25) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
    .buttonStyle(.bordered)
   Button {
    setVisibleToFullRange()
    yDomain = nil
    buildOverlays()
   } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
    .buttonStyle(.bordered)
   Spacer(minLength: 0)
  }
   .padding(.top, 2)
  
  return AnyView(
   VStack(alignment: .leading, spacing: 0) {
    chart
    legend
    zoomBar
   }
  )
 }
}
