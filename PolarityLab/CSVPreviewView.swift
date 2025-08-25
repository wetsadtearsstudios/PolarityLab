import SwiftUI
import Foundation

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Cross-platform background color
extension Color {
 static var platformBackground: Color {
#if canImport(AppKit)
  return Color(NSColor.windowBackgroundColor)
#else
  return Color(UIColor.systemBackground)
#endif
 }
}

// MARK: - Flow layout for chips (wraps to new lines when narrow)
struct FlowLayout: Layout {
 var hSpacing: CGFloat = 8
 var vSpacing: CGFloat = 8
 func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
  let maxW = proposal.width ?? .infinity
  var lines: [[CGSize]] = [[]]; var curW: CGFloat = 0
  for v in subviews {
   let s = v.sizeThatFits(.unspecified)
   if curW > 0 && curW + hSpacing + s.width > maxW { lines.append([]); curW = 0 }
   lines[lines.count-1].append(s); curW += (curW == 0 ? 0 : hSpacing) + s.width
  }
  let h = lines.enumerated().reduce(CGFloat(0)) { acc, p in
   acc + (p.element.map(\.height).max() ?? 0) + (p.offset == 0 ? 0 : vSpacing)
  }
  let w = lines.map { $0.reduce(0){$0+$1.width} + CGFloat(max(0,$0.count-1))*hSpacing }.max() ?? 0
  return .init(width: min(maxW, w), height: h)
 }
 func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
  var x = b.minX, y = b.minY, lineH: CGFloat = 0
  for (i,v) in subviews.enumerated() {
   let s = v.sizeThatFits(.unspecified)
   if x > b.minX && x + s.width > b.maxX { x = b.minX; y += lineH + vSpacing; lineH = 0 }
   subviews[i].place(at: .init(x: x, y: y), anchor: .topLeading, proposal: .init(width: s.width, height: s.height))
   x += s.width + hSpacing; lineH = max(lineH, s.height)
  }
 }
}

// MARK: - Toolbar chip (modern pill; non-squishing)
private struct ToolChip: View {
 let title: String
 let summary: String
 let action: () -> Void
 var body: some View {
  Button(action: action) {
   HStack(spacing: 10) {
    Text(title).font(.headline.weight(.semibold))
    Text(summary).font(.callout).foregroundStyle(.secondary)
   }
   .lineLimit(1)
   .fixedSize(horizontal: true, vertical: false)
   .padding(.vertical, 9).padding(.horizontal, 14)
   .background(Capsule().fill(Color.secondary.opacity(0.15)))
  }
  .buttonStyle(.plain)
  .contentShape(Capsule())
 }
}

// MARK: - Column chip
private struct ColumnChip: View {
 let title: String
 let isSelected: Bool
 let action: () -> Void
 var body: some View {
  Button(action: action) {
   Text(title)
    .font(.callout.weight(.semibold))
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .padding(.vertical, 6).padding(.horizontal, 12)
    .foregroundColor(isSelected ? .white : .primary)
    .background(Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.25)))
  }
  .buttonStyle(.plain)
 }
}

// MARK: - Templates persistence (read-only)
enum TemplateStore { static func load() -> [UnifiedLexiconTemplate] { TemplatesStore.shared.load() } }
extension Notification.Name { static let templatesUpdated = Notification.Name("UnifiedLexiconTemplatesUpdated") }

// MARK: - DTOs
struct DateFilterPayload: Codable { let column: String; let start: String?; let end: String? }
enum TimeframePreset: String, CaseIterable, Identifiable {
 case allTime = "All time", last7 = "Last 7 days", last30 = "Last 30 days", last90 = "Last 90 days",
      thisQ = "This quarter", lastQ = "Last quarter", thisY = "This year", lastY = "Last year", custom = "Custom…"
 var id: String { rawValue }
}

// === Icon-led checklist (visual summary) =====================================
struct ChecklistRow: View {
 enum Status { case on, off, warn }
 let icon: String
 let title: String
 let detail: String?
 let color: Color
 let status: Status
 
 var body: some View {
  HStack(spacing: 12) {
   Image(systemName: icon)
    .foregroundStyle(.white)
    .padding(8)
    .background(Circle().fill(color))
   VStack(alignment: .leading, spacing: 2) {
    Text(title).font(.headline)
    if let d = detail, !d.isEmpty {
     Text(d).font(.subheadline).foregroundStyle(.secondary)
    }
   }
   Spacer()
   switch status {
   case .on:  Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
   case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
   case .off: Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
   }
  }
  .padding(12)
  .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
 }
}

struct TextFeatureChecklist: View {
 let modelName: String
 let templateName: String?          // NEW: show selected template name
 let keywordsDetail: String         // UPDATED: show the actual keywords entered
 let signatures: Bool
 let usernames: Bool
 let namesNER: Bool
 let dateSummary: String?           // summary string for the date range
 let postIDOn: Bool
 let postIDColumn: String?
 
 var body: some View {
  VStack(alignment: .leading, spacing: 10) {
   ChecklistRow(icon:"brain.head.profile", title:"Model", detail:modelName, color:.blue, status:.on)
   ChecklistRow(icon:"slider.horizontal.3", title:"Templates",
                detail: templateName ?? "None",
                color:.indigo, status: (templateName == nil ? .off : .on))
   ChecklistRow(icon:"line.3.horizontal.decrease.circle", title:"Keyword Filter",
                detail: keywordsDetail.isEmpty ? "None" : keywordsDetail,
                color:.purple, status: keywordsDetail.isEmpty ? .off : .on)
   ChecklistRow(icon:"wand.and.stars", title:"Cleaning",
                detail: [signatures ? "Signatures" : nil,
                         usernames ? "@usernames" : nil,
                         namesNER ? "Names (NER)" : nil].compactMap{$0}.joined(separator:" · "),
                color:.teal, status: (signatures || usernames || namesNER) ? .on : .off)
   ChecklistRow(icon:"calendar", title:"Date Window",
                detail: dateSummary ?? "Required",
                color:.orange, status: dateSummary == nil ? .warn : .on)
   ChecklistRow(icon:"number", title:"Post ID",
                detail: postIDOn ? (postIDColumn ?? "Select a column") : "Off",
                color:.pink, status: postIDOn ? (postIDColumn == nil ? .warn : .on) : .off)
  }
  .padding(14)
  .background(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2)))
 }
}
// ============================================================================

struct CSVPreviewView: View {
 // Input
 let csv: SimpleCSV
 @Binding var selectedColumns: [String]
 @Binding var selectedModel: SentimentModel
 
 // Callback to parent
 let onAnalyze: (_ template: UnifiedLexiconTemplate?,
                 _ filter: FilterPayload?,
                 _ date: DateFilterPayload?,
                 _ synopsis: Bool,
                 _ postIDColumn: String?,
                 _ signatureRemoval: Bool,
                 _ usernameRemoval: Bool,
                 _ includePhrases: Bool) -> Void
 
 // State
 @State private var templates: [UnifiedLexiconTemplate] = TemplateStore.load()
 @State private var selectedTemplateID: UUID?
 private var selectedTemplate: UnifiedLexiconTemplate? { templates.first { $0.id == selectedTemplateID } }
 
 // Keywords
 @State private var keywordsText = ""
 @State private var filterMode: FilterPayload.Mode = .any
 @State private var filterWholeWord = false
 @State private var filterCaseSensitive = false
 private var currentFilter: FilterPayload? {
  let kws = keywordsArray
  guard !kws.isEmpty else { return nil }
  return .init(keywords: kws, mode: filterMode, caseSensitive: filterCaseSensitive, wholeWord: filterWholeWord)
 }
 
 // Date (REQUIRED)
 @State private var selectedDateColumn: String? = nil
 @State private var timeframe: TimeframePreset = .allTime
 @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
 @State private var customEnd: Date = Date()
 private var currentDatePayload: DateFilterPayload? {
  guard let col = selectedDateColumn else { return nil }
  let (s, e) = computeRange(for: timeframe, customStart: customStart, customEnd: customEnd)
  return .init(column: col, start: s?.iso8601Z(), end: e?.iso8601Z())
 }
 
 // Cleaning, Post ID
 @State private var usePostID = false
 @State private var selectedIDColumn: String?
 @State private var removeSignatures = true
 @State private var removeUsernames = true
 @State private var hideNames = true   // PERSON masking toggle (spaCy NER)
 
 // Popovers
 @State private var showModel = false
 @State private var showKeywords = false
 @State private var showDate = false
 @State private var showTemplates = false
 @State private var showCleaning = false
 @State private var showPostID = false
 
 private let maxContentWidth: CGFloat = 1400
 
 private var postIDNeedsAttention: Bool { usePostID && (selectedIDColumn == nil) }
 private var analyzeDisabled: Bool { (selectedDateColumn == nil) || selectedColumns.isEmpty || postIDNeedsAttention }
 
 // ==== Attached summaries used by chips AND checklist ======================
 private var modelSummary: String { selectedModel.rawValue }
 private var keywordsSummary: String {
  guard let f = currentFilter else { return "" }
  var parts = ["\(f.keywords.count) • \(f.mode == .any ? "Any" : "All")"]
  if f.wholeWord { parts.append("Whole") }
  if f.caseSensitive { parts.append("Case") }
  return parts.joined(separator: " • ")
 }
 // NEW: actual keywords list for checklist detail
 private var keywordsDetail: String {
  let list = keywordsArray.joined(separator: ", ")
  return list
 }
 // helper to parse keywords input into array
 private var keywordsArray: [String] {
  keywordsText
   .split(whereSeparator: { ",\n".contains($0) })
   .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
   .filter { !$0.isEmpty }
 }
 private var dateSummary: String? {
  guard let col = selectedDateColumn else { return nil }
  let (s, e) = computeRange(for: timeframe, customStart: customStart, customEnd: customEnd)
  let df = DateFormatter(); df.timeZone = .init(secondsFromGMT: 0); df.dateFormat = "yyyy-MM-dd"
  if timeframe == .allTime { return "\(col) • All time" }
  let name: String = (timeframe == .custom ? "Custom" : timeframe.rawValue)
  let sStr = s.map { df.string(from: $0) } ?? "…"
  let eStr = e.map { df.string(from: $0) } ?? "…"
  return "\(col) • \(name) (\(sStr) → \(eStr))"
 }
 private var cleaningSummary: String {
  let flags = [
   removeSignatures ? "Signatures" : nil,
   removeUsernames ? "@user" : nil,
   hideNames ? "Names" : nil
  ].compactMap { $0 }
  return flags.isEmpty ? "Off" : flags.joined(separator: " + ")
 }
 private var postIDSummary: String {
  if usePostID {
   let base = (selectedIDColumn ?? "Select…")
   return postIDNeedsAttention ? base + " ⚠︎" : base
  }
  return "Off"
 }
 // ========================================================================
 
 var body: some View {
  GeometryReader { geo in
   let inset: CGFloat = 16
   let contentW = min(maxContentWidth, geo.size.width - inset * 2)
   let colsForPreview = selectedColumns.isEmpty ? csv.headers : selectedColumns
   let colW = max(160, (contentW - 24) / CGFloat(max(colsForPreview.count, 1)))
   
   ScrollView {
    VStack(spacing: 12) {
     // Title
     HStack {
      Text("Preview (\(csv.previewRows.count) of \(csv.allRows.count) rows)").font(.largeTitle.bold())
      Spacer()
     }
     .frame(width: contentW)
     .padding(.top, inset)
     
     // Toolbar chips (summaries shown in-chip)
     HStack { Spacer()
      FlowLayout(hSpacing: 10, vSpacing: 8) {
       ToolChip(title: "Model", summary: modelSummary) { showModel.toggle() }
        .popover(isPresented: $showModel, arrowEdge: .bottom) { modelPopover }
       
       ToolChip(title: "Keywords", summary: keywordsSummary.ifEmpty("None")) { showKeywords.toggle() }
        .popover(isPresented: $showKeywords, arrowEdge: .bottom) { keywordsPopover }
       
       ToolChip(title: "Date (required)", summary: dateSummary ?? "Choose…") { showDate.toggle() }
        .popover(isPresented: $showDate, arrowEdge: .bottom) { datePopover }
       
       ToolChip(title: "Templates", summary: selectedTemplate?.name ?? "None") { showTemplates.toggle() }
        .popover(isPresented: $showTemplates, arrowEdge: .bottom) { templatesPopover }
       
       ToolChip(title: "Cleaning", summary: cleaningSummary) { showCleaning.toggle() }
        .popover(isPresented: $showCleaning, arrowEdge: .bottom) { cleaningPopover }
       
       ToolChip(title: "Post ID", summary: postIDSummary) { showPostID.toggle() }
        .popover(isPresented: $showPostID, arrowEdge: .bottom) { postIDPopover }
      }
      Spacer()
     }
     .frame(width: contentW)
     
     // ✅ ATTACHED CHECKLIST (visible, fed by live summaries)
     TextFeatureChecklist(
      modelName: modelSummary,
      templateName: selectedTemplate?.name,
      keywordsDetail: keywordsDetail,
      signatures: removeSignatures,
      usernames: removeUsernames,
      namesNER: hideNames,
      dateSummary: dateSummary,
      postIDOn: usePostID,
      postIDColumn: selectedIDColumn
     )
     .frame(width: contentW)
     
     Divider().frame(width: contentW)
     
     // Columns chips (centered)
     HStack { Spacer()
      FlowLayout(hSpacing: 8, vSpacing: 8) {
       ForEach(csv.headers, id: \.self) { col in
        ColumnChip(title: col, isSelected: selectedColumns.contains(col)) { toggle(col) }
       }
      }
      Spacer()
     }
     .frame(width: contentW)
     
     // Table (no horizontal bleed)
     table(colsForPreview: colsForPreview, columnW: colW)
      .frame(width: contentW)
      .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
     
     // Analyze button -> bubble up to parent
     Button {
      onAnalyze(
       selectedTemplate,
       currentFilter,
       currentDatePayload,
       true,                            // synopsis
       usePostID ? selectedIDColumn : nil,
       removeSignatures,
       removeUsernames,
       true                             // includePhrases
      )
     } label: {
      HStack(spacing: 12) {
       Image(systemName: "bolt.fill").font(.title2)
       Text("Analyze").font(.title3.bold())
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 34)
      .background(RoundedRectangle(cornerRadius: 12).fill(analyzeDisabled ? Color.gray.opacity(0.6) : Color.accentColor))
      .foregroundColor(.white)
     }
     .buttonStyle(.plain)
     .disabled(analyzeDisabled)
     .padding(.bottom, 16)
    }
    .frame(maxWidth: .infinity)
   }
   .frame(width: geo.size.width, height: geo.size.height)
   .onAppear {
    reloadTemplates()
    if selectedDateColumn == nil, let guess = guessDateColumn(from: csv.headers) {
     selectedDateColumn = guess
    }
   }
   .onReceive(NotificationCenter.default.publisher(for: .templatesUpdated)) { _ in reloadTemplates() }
  }
 }
 
 // MARK: - Popovers
 private var modelPopover: some View {
  VStack(alignment: .leading, spacing: 8) {
   Text("Sentiment Model").font(.headline)
   Picker("", selection: $selectedModel) {
    ForEach(SentimentModel.allCases) { Text($0.rawValue).tag($0) }
   }
   .labelsHidden()
   .pickerStyle(.radioGroup)
  }
  .padding(12)
  .frame(width: 320)
 }
 
 private var keywordsPopover: some View {
  VStack(alignment: .leading, spacing: 8) {
   Text("Keyword Filter").font(.headline)
   TextField("comma or newline separated", text: $keywordsText, axis: .vertical)
    .textFieldStyle(.roundedBorder)
    .lineLimit(1...2)
   HStack {
    Picker("Match", selection: $filterMode) {
     Text("Any").tag(FilterPayload.Mode.any)
     Text("All").tag(FilterPayload.Mode.all)
    }
    .pickerStyle(.segmented)
    .frame(width: 160)
    Toggle("Whole", isOn: $filterWholeWord)
    Toggle("Case", isOn: $filterCaseSensitive)
    Spacer()
   }
   .font(.callout)
  }
  .padding(12)
  .frame(width: 420)
 }
 
 private var datePopover: some View {
  VStack(alignment: .leading, spacing: 8) {
   Text("Date & Timeframe").font(.headline)
   Picker("Date column", selection: Binding<String>(
    get: { selectedDateColumn ?? (csv.headers.first ?? "") },
    set: { selectedDateColumn = $0 }
   )) {
    ForEach(csv.headers, id: \.self) { Text($0).tag($0) }
   }
   .pickerStyle(.menu)
   .frame(maxWidth: .infinity, alignment: .leading)
   
   HStack {
    Menu(timeframe.rawValue) {
     ForEach(TimeframePreset.allCases) { tf in Button(tf.rawValue) { timeframe = tf } }
    }
    .disabled(selectedDateColumn == nil)
    Spacer()
   }
   
   if timeframe == .custom && selectedDateColumn != nil {
    HStack(spacing: 10) {
     DatePicker("From", selection: $customStart, displayedComponents: .date).datePickerStyle(.compact)
     DatePicker("To", selection: $customEnd, displayedComponents: .date).datePickerStyle(.compact)
    }
   }
  }
  .padding(12)
  .frame(width: 420)
 }
 
 private var templatesPopover: some View {
  VStack(alignment: .leading, spacing: 8) {
   Text("Templates").font(.headline)
   HStack {
    Menu {
     if templates.isEmpty { Button("No templates") { }.disabled(true) }
     else {
      ForEach(templates) { t in Button(t.name) { selectedTemplateID = t.id } }
      Divider(); Button("Reload") { reloadTemplates() }
     }
    } label: {
     HStack(spacing: 8) {
      Image(systemName: "slider.horizontal.3")
      Text(selectedTemplate?.name ?? (templates.isEmpty ? "No templates" : "Choose template"))
     }
     .padding(.vertical, 6).padding(.horizontal, 10)
     .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
    }
    .disabled(templates.isEmpty).opacity(templates.isEmpty ? 0.5 : 1)
    if let t = selectedTemplate { Text("(\(t.items.count))").foregroundStyle(.secondary) }
    Spacer()
   }
  }
  .padding(12)
  .frame(width: 420)
 }
 
 private var cleaningPopover: some View {
  VStack(alignment: .leading, spacing: 8) {
   Text("Cleaning").font(.headline)
   Toggle("Remove signatures", isOn: $removeSignatures)
   Toggle("Remove @usernames", isOn: $removeUsernames)
   Toggle("Hide names (PERSON via NER)", isOn: $hideNames)
  }
  .padding(12)
  .frame(width: 320)
 }
 
 private var postIDPopover: some View {
  VStack(alignment: .leading, spacing: 8) {
   Text("Post Identification").font(.headline)
   Toggle("Use Post ID column", isOn: $usePostID)
   if usePostID {
    Picker("Column", selection: Binding<String?>(get: { selectedIDColumn }, set: { selectedIDColumn = $0 })) {
     Text("None").tag(Optional<String>.none) // prevents 'nil' selection warning
     ForEach(csv.headers, id: \.self) { Text($0).tag(Optional($0)) }
    }
    .pickerStyle(.menu)
   }
  }
  .padding(12)
  .frame(width: 320)
 }
 
 // MARK: - Table (header + rows share horizontal scroll; no bleed)
 @ViewBuilder
 private func table(colsForPreview: [String], columnW: CGFloat) -> some View {
  let tableWidth = CGFloat(max(colsForPreview.count, 1)) * columnW
  
  VStack(spacing: 0) {
   ScrollView(.horizontal, showsIndicators: true) {
    VStack(spacing: 0) {
     // Header
     HStack(spacing: 0) {
      ForEach(colsForPreview, id: \.self) { col in
       Text(col)
        .font(.headline)
        .frame(width: columnW, alignment: .leading)
        .padding(.vertical, 6)
        .lineLimit(1)
        .truncationMode(.tail)
      }
     }
     .frame(width: tableWidth, alignment: .leading)
     .background(Color.secondary.opacity(0.05))
     
     Divider()
     
     // Rows
     ScrollView(.vertical, showsIndicators: true) {
      LazyVStack(spacing: 0) {
       ForEach(0..<csv.previewRows.count, id: \.self) { i in
        HStack(spacing: 0) {
         ForEach(colsForPreview, id: \.self) { col in
          Text(csv.previewRows[i][col] ?? "")
           .font(.callout)
           .frame(width: columnW, alignment: .leading)
           .padding(.vertical, 5)
           .lineLimit(2)
           .truncationMode(.tail)
         }
        }
        .frame(width: tableWidth, alignment: .leading)
        
        if i < csv.previewRows.count - 1 {
         Divider().background(Color.secondary.opacity(0.1))
        }
       }
      }
     }
     .frame(height: 360)
    }
   }
   .clipped()
  }
  .background(
   RoundedRectangle(cornerRadius: 8).fill(Color.platformBackground)
  )
  .overlay(
   RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1)
  )
 }
 
 // MARK: - Helpers
 private func reloadTemplates() {
  templates = TemplateStore.load()
  if let sel = selectedTemplateID, !templates.contains(where: { $0.id == sel }) { selectedTemplateID = nil }
 }
 private func toggle(_ col: String) {
  if let i = selectedColumns.firstIndex(of: col) { selectedColumns.remove(at: i) } else { selectedColumns.append(col) }
 }
 private func guessDateColumn(from headers: [String]) -> String? {
  let lc = headers.map { ($0, $0.lowercased()) }
  if let m = lc.first(where: { $0.1.contains("date") || $0.1.contains("time") || $0.1.contains("timestamp") }) { return m.0 }
  return headers.first
 }
 private func computeRange(for tf: TimeframePreset, customStart: Date, customEnd: Date) -> (Date?, Date?) {
  let tz = TimeZone(secondsFromGMT: 0)!
  var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
  let now = Date()
  switch tf {
  case .allTime: return (nil, nil)
  case .last7:   return (cal.date(byAdding: .day, value: -7, to: now), now)
  case .last30:  return (cal.date(byAdding: .day, value: -30, to: now), now)
  case .last90:  return (cal.date(byAdding: .day, value: -90, to: now), now)
  case .thisQ:
   let q = cal.component(.quarter, from: now), y = cal.component(.year, from: now)
   let (s, e) = quarterBounds(year: y, quarter: q, cal: cal); return (s, min(e ?? now, now))
  case .lastQ:
   var c = cal.dateComponents([.year, .quarter], from: now); var q = c.quarter ?? 1; var y = c.year ?? cal.component(.year, from: now)
   q -= 1; if q < 1 { q = 4; y -= 1 }
   return quarterBounds(year: y, quarter: q, cal: cal)
  case .thisY:
   let y = cal.component(.year, from: now)
   let s = cal.date(from: DateComponents(timeZone: tz, year: y, month: 1, day: 1))
   return (s, now)
  case .lastY:
   let y = cal.component(.year, from: now) - 1
   let s = cal.date(from: DateComponents(timeZone: tz, year: y, month: 1, day: 1))
   let e = cal.date(from: DateComponents(timeZone: tz, year: y, month: 12, day: 31, hour: 23, minute: 59, second: 59))
   return (s, e)
  case .custom:
   return (min(customStart, customEnd), max(customStart, customEnd))
  }
 }
 private func quarterBounds(year: Int, quarter: Int, cal: Calendar) -> (Date?, Date?) {
  let mStart = [1,4,7,10][max(0, min(quarter-1, 3))]
  let start = cal.date(from: DateComponents(timeZone: cal.timeZone, year: year, month: mStart, day: 1))
  let mEnd = mStart + 2
  let monthStart = cal.date(from: DateComponents(timeZone: cal.timeZone, year: year, month: mEnd, day: 1))
  let end = cal.date(byAdding: DateComponents(month: 1, day: -1, hour: 23, minute: 59, second: 59), to: monthStart ?? start ?? Date())
  return (start, end)
 }
}

// MARK: - utils
private extension String { func ifEmpty(_ repl: String) -> String { isEmpty ? repl : self } }
private extension Date {
 func iso8601Z() -> String {
  let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; f.timeZone = .init(secondsFromGMT: 0)
  return f.string(from: self)
 }
}
