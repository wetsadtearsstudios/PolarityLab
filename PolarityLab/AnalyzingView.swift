import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
private func setClipboard(_ s: String) { UIPasteboard.general.string = s }
#elseif canImport(AppKit)
import AppKit
private func setClipboard(_ s: String) {
 let pb = NSPasteboard.general
 pb.clearContents()
 pb.setString(s, forType: .string)
}
#else
private func setClipboard(_ s: String) { /* no-op */ }
#endif

// UI lock broadcast for Sidebar/Menu while analyzing
extension Notification.Name {
 static let plUILockSidebar = Notification.Name("PL_UILockSidebar")
}

// MARK: - Progress notifications from the Python pipeline
//
// Post .plProgress as rows are emitted.
// userInfo keys:
//   processed:Int, total:Int?, chunks:Int, bytes:Int64,
//   status:String("initializing"|"running"|"final"), file:String

// MARK: - Progress model

final class AnalysisProgress: ObservableObject {
 @Published var startedAt = Date()
 @Published var lastUpdate = Date()
 
 @Published var status: String = "initializing"
 @Published var processed: Int = 0
 @Published var totalEstimate: Int? = nil
 @Published var chunks: Int = 0
 @Published var bytes: Int64 = 0
 @Published var filePath: String? = nil
 
 // Derived
 var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
 var rowsPerSec: Double { elapsed > 0 ? Double(processed) / elapsed : 0 }
 var progressFraction: Double {
  if let total = totalEstimate, total > 0 {
   return min(1, max(0, Double(processed) / Double(total)))
  }
  // graceful early-phase ramp while we learn total
  return min(0.95, 0.12 + log1p(Double(max(1, processed))) * 0.06)
 }
 
 func reset() {
  startedAt = Date()
  lastUpdate = startedAt
  status = "initializing"
  processed = 0
  totalEstimate = nil
  chunks = 0
  bytes = 0
  filePath = nil
 }
}

// MARK: - Hardware + env readout

fileprivate struct HardwareInfo {
 let ramGB: Int
 let cores: Int
 let profile: String
 let envBatch: String?
 let envMaxLen: String?
 let envChunk: String?
 
 init() {
  let pi = ProcessInfo.processInfo
  cores = max(1, pi.processorCount)
  ramGB = Int(floor(Double(pi.physicalMemory) / 1_000_000_000.0))
  let env = pi.environment
  profile  = env["PL_PERF_PROFILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "auto"
  envBatch = env["PL_BATCH"]
  envMaxLen = env["PL_MAXLEN"]
  envChunk = env["PL_CHUNKSIZE"]
 }
 
 var summaryLine: String {
  var parts: [String] = []
  parts.append("Using \(cores) CPU cores • \(ramGB) GB RAM • profile=\(profile)")
  if let b = envBatch { parts.append("BATCH=\(b)") }
  if let m = envMaxLen { parts.append("MAXLEN=\(m)") }
  if let c = envChunk  { parts.append("CHUNKSIZE=\(c)") }
  return parts.joined(separator: " • ")
 }
 
 var hint: String { "Performance auto-tunes to your hardware. You can override in Settings." }
}

// MARK: - Analyzing view

struct AnalyzingView: View {
 var onCancel: (() -> Void)? = nil
 @Environment(\.dismiss) private var dismiss
 @StateObject var prog = AnalysisProgress()
@State private var finalized: Bool = false
 private let hw = HardwareInfo()
 
 @State private var stale: Bool = false
 private let heartbeatGrace: TimeInterval = 6.0
 private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
 
 var body: some View {
  ZStack {
   Color.black.opacity(0.55).ignoresSafeArea()
   VStack(spacing: 18) {
    headerBlock
    warningBanner
    progressSection
    hardwareRow
   }
   .foregroundColor(.white)
   .padding(.horizontal, 20)
  }
  .onAppear {
   prog.reset()
   // Lock sidebar/menu while analyzing
   NotificationCenter.default.post(name: .plUILockSidebar, object: nil, userInfo: ["lock": true])
  }
  .onDisappear {
   // Unlock when the overlay is dismissed (user cancels or completes flow)
   NotificationCenter.default.post(name: .plUILockSidebar, object: nil, userInfo: ["lock": false])
  }
  .onReceive(timer) { _ in stale = (Date().timeIntervalSince(prog.lastUpdate) > heartbeatGrace) }
  // Ensure main-thread delivery to avoid “Publishing changes from background threads…” warnings.
  .onReceive(NotificationCenter.default.publisher(for: .plProgress).receive(on: RunLoop.main)) { note in
   guard !finalized else { return }
   guard let u = note.userInfo else { return }
   if let n = u["processed"] as? Int { prog.processed = n }
   if let t = u["total"] as? Int { prog.totalEstimate = t }
   if let c = u["chunks"] as? Int { prog.chunks = c }
   if let b = (u["bytes"] as? Int64) ?? (u["bytes"] as? NSNumber)?.int64Value { prog.bytes = b }
   if let s = u["status"] as? String { prog.status = s }
   if let f = u["file"] as? String { prog.filePath = f }
   prog.lastUpdate = Date()
  
  }
  .onReceive(NotificationCenter.default.publisher(for: .plDone).receive(on: RunLoop.main)) { _ in
   finalized = true
   prog.status = "final"
   prog.lastUpdate = Date()
   // Always unlock the UI once analysis is finished
   NotificationCenter.default.post(name: .plUILockSidebar, object: nil, userInfo: ["lock": false])
   // Best effort: align processed with total if known
   if let t = prog.totalEstimate { prog.processed = max(prog.processed, t) }
   // Close the overlay if it is presented as a sheet
   dismiss()
 }

  // Opportunistically discover total rows early from JSONL meta if bridge hasn't provided it yet.
  .task(id: prog.filePath) {
   guard let path = prog.filePath, prog.totalEstimate == nil else { return }
   if let total = await probeTotalRows(fromJSONL: path) {
    prog.totalEstimate = total
   }
  }
  // Retry probing if we still don't know the total after a few seconds.
  .task(id: stale) {
   if stale, prog.totalEstimate == nil, let path = prog.filePath {
    if let total = await probeTotalRows(fromJSONL: path) {
     prog.totalEstimate = total
    }
   }
  }
  .transition(.opacity)
 }
 
 // MARK: Sections
 
 private var headerBlock: some View {
  VStack(spacing: 10) {
   Image(systemName: "brain.head.profile")
    .font(.system(size: 108, weight: .semibold)) // 2x
    .symbolEffect(.pulse, options: .repeating, value: prog.processed)
    .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 8)
    .accessibilityHidden(true)
   
   Text(titleText)
    .font(.system(size: 34, weight: .semibold)) // 2x
    .multilineTextAlignment(.center)
   
   Text(subtitleText) // includes elapsed time
    .font(.system(size: 26, weight: .regular)) // 2x
    .foregroundStyle(.secondary)
    .multilineTextAlignment(.center)
    .lineLimit(2)
  }
  .frame(maxWidth: .infinity)
 }
 
 // Centered yellow warning banner
 private var warningBanner: some View {
  HStack(spacing: 10) {
   Image(systemName: "exclamationmark.triangle.fill")
    .foregroundStyle(Color.yellow)
   Text("Analysis running — Menu bar is disabled until analysis is complete.")
    .font(.footnote.weight(.semibold))
    .multilineTextAlignment(.center)
  }
  .padding(.vertical, 8)
  .padding(.horizontal, 12)
  .background(
   RoundedRectangle(cornerRadius: 10)
    .fill(Color.yellow.opacity(0.16))
  )
  .overlay(
   RoundedRectangle(cornerRadius: 10)
    .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
  )
  .frame(maxWidth: 720)                                   // fixed width banner
  .frame(maxWidth: .infinity, alignment: .center)         // centered on screen
 }
 
 private var progressSection: some View {
  VStack(spacing: 8) {
   ProgressView(value: prog.progressFraction)
    .progressViewStyle(.linear)
    .frame(maxWidth: 620)
  }
 }
 
 private var hardwareRow: some View {
  VStack(spacing: 2) {
   Text(hw.summaryLine)
    .font(.footnote)
    .foregroundStyle(.secondary)
    .lineLimit(2)
   Text(hw.hint)
    .font(.caption2)
    .foregroundStyle(.secondary.opacity(0.9))
  }
  .frame(maxWidth: 700)
 }
 // MARK: - Strings
 
 private var titleText: String {
  switch prog.status.lowercased() {
  case "initializing": return "Warming up models…"
  case "running":      return "Analyzing data…"
  case "final":        return "Wrapping up…"
  default:             return "Analyzing data…"
  }
 }
 
 private var subtitleText: String {
  let e = timeString(prog.elapsed)
  if let total = prog.totalEstimate, total > 0 {
   return "Elapsed \(e) • \(prog.processed) / \(total) rows"
  } else {
   return "Elapsed \(e) • \(prog.processed) rows"
  }
 }
 
 // MARK: - Helpers
 
 private func timeString(_ t: TimeInterval) -> String {
  let s = Int(t.rounded())
  let h = s / 3600
  let m = (s % 3600) / 60
  let sec = s % 60
  if h > 0 { return String(format: "%dh %dm", h, m) }
  if m > 0 { return String(format: "%dm %ds", m, sec) }
  return String(format: "%ds", sec)
 }
 
 /// Try to extract a total row count early from the streamed JSONL by scanning the tail for a meta heartbeat/final trailer.
 private func probeTotalRows(fromJSONL path: String) async -> Int? {
  await withCheckedContinuation { cont in
   DispatchQueue.global(qos: .utility).async {
    guard let fh = FileHandle(forReadingAtPath: path) else { cont.resume(returning: nil); return }
    defer { try? fh.close() }
    let end = (try? fh.seekToEnd()) ?? 0
    let back: UInt64 = 128 * 1024
    let start = end > back ? end - back : 0
    do { try fh.seek(toOffset: start) } catch { cont.resume(returning: nil); return }
    let blob = (try? fh.readToEnd()) ?? Data()
    guard !blob.isEmpty, let s = String(data: blob, encoding: .utf8) else { cont.resume(returning: nil); return }
    // Look for last line with "__meta__": true
    for raw in s.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
     let line = String(raw)
     if !line.contains(#""__meta__": true"#) { continue }
     if let d = line.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      let meta = (obj["meta"] as? [String: Any]) ?? [:]
      // Try common keys
      if let t = meta["total"] as? Int { cont.resume(returning: t); return }
      if let t = meta["total_rows"] as? Int { cont.resume(returning: t); return }
      if let t = meta["rows_total"] as? Int { cont.resume(returning: t); return }
      if let t = meta["rows"] as? Int { cont.resume(returning: t); return }
      if let t = (meta["total"] as? NSNumber)?.intValue { cont.resume(returning: t); return }
     }
     break
    }
    cont.resume(returning: nil)
   }
  }
 }
}
