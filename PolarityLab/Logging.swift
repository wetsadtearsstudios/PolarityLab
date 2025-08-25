import Foundation

final class FileLogger {
 static let shared = FileLogger()
 private let q = DispatchQueue(label: "pl.filelog")
 private let url: URL
 private init() {
  let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
  let dir  = base.appendingPathComponent("Logs/PolarityLab", isDirectory: true)
  try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  url = dir.appendingPathComponent("polaritylab.log")
 }
 var path: String { url.path }
 func write(_ s: String) {
  q.async {
   guard let data = (s + "\n").data(using: .utf8) else { return }
   if FileManager.default.fileExists(atPath: self.url.path),
      let h = try? FileHandle(forWritingTo: self.url) {
    defer { try? h.close() }
    try? h.seekToEnd()
    try? h.write(contentsOf: data)
   } else {
    try? data.write(to: self.url)
   }
  }
 }
}

@inline(__always)
func dlog(_ msg: @autoclosure () -> String,
          file: String = #fileID, line: Int = #line) {
 let s = "[DLOG] \(file):\(line) — \(msg())"
 NSLog("%@", s)
 if let data = (s + "\n").data(using: .utf8) { try? FileHandle.standardError.write(contentsOf: data) }
 FileLogger.shared.write(s)
}
