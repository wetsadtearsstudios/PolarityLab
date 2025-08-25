// PythonBridge.swift
// Full bridge with stdout/stderr echo and detailed logging.
import Foundation
import Darwin

// MARK: - Helpers ---------------------------------------------------------

/// Reads the last non-empty line from a file at the given path.
private func lastLine(_ path: String) -> String? {
 guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
 defer { try? fileHandle.close() }
 let data = (try? fileHandle.readToEnd()) ?? Data()
 guard let content = String(data: data, encoding: .utf8) else { return nil }
 return content
  .split(separator: "\n", omittingEmptySubsequences: true)
  .map { String($0) }
  .last
}

/// Location for local model/dataset caches (keeps sandbox happy/offline).
private func hfCacheDir() -> String {
 let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
 let dir = base.appendingPathComponent("HF", isDirectory: true)
 try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
 return dir.path
}

private extension Data {
 func toJSONString() -> String { String(data: self, encoding: .utf8) ?? "{}" }
}

private func fileSize(at path: String) -> UInt64? {
 (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
}

/// Order-preserving de-dupe for column names.
private func normalizeColumns(_ cols: [String]) -> [String] {
 var seen = Set<String>()
 var out: [String] = []
 for raw in cols {
  let c = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !c.isEmpty else { continue }
  if !seen.contains(c) {
   seen.insert(c)
   out.append(c)
  }
 }
 return out
}

/// Copy selected env vars from the host process into a child env if present.
private func passthroughEnv(into env: inout [String:String], keys allowlist: [String]) {
 let host = ProcessInfo.processInfo.environment
 for k in allowlist {
  if let v = host[k], !v.isEmpty {
   env[k] = v
  }
 }
}

// MARK: - Settings overrides bridge ---------------------------------------

private func manualProcessingOverrides() async -> [String:String] {
#if canImport(SwiftUI)
 let dict: [String:String] = await MainActor.run {
  guard let store = (SettingsStore.shared as SettingsStore?),
        store.processing.enabled else { return [:] }
  let p = store.processing
  var tmp: [String:String] = [:]
  if let b = p.batch     { tmp["PL_BATCH"] = String(b) }
  if let m = p.maxLen    { tmp["PL_MAXLEN"] = String(m) }
  if let c = p.chunkSize { tmp["PL_CHUNKSIZE"] = String(c) }
  if let t = p.ompThreads {
   let ts = String(t)
   tmp["OMP_NUM_THREADS"]        = ts
   tmp["MKL_NUM_THREADS"]        = ts
   tmp["OPENBLAS_NUM_THREADS"]   = ts
   tmp["VECLIB_MAXIMUM_THREADS"] = ts
   tmp["NUMEXPR_NUM_THREADS"]    = ts
  }
  tmp["PL_PERF_PROFILE"] = "manual"
  return tmp
 }
 return dict
#else
 return [:]
#endif
}

// MARK: - Template / Filter payloads passed to Python ---------------------

struct TemplatePayload: Codable {
 struct Item: Codable { let phrase: String; let score: Double }
 let vader: [Item]   // −4…+4
 let bias:  [Item]   // −1…+1
}

struct FilterPayload: Codable {
 enum Mode: String, Codable { case any, all }
 let keywords: [String]
 let mode: Mode
 let caseSensitive: Bool
 let wholeWord: Bool
}

// MARK: - Errors ----------------------------------------------------------

enum PythonBridgeError: LocalizedError {
 case executionFailed(String)
 case notInitialized
 case missingResources(String)
 case workerDied
 case badResponse(String)
 
 var errorDescription: String? {
  switch self {
  case .executionFailed(let d): return "Python execution failed: \(d)"
  case .notInitialized:         return "Python bridge not initialized"
  case .missingResources(let w):return "Missing resource: \(w)"
  case .workerDied:             return "Python worker terminated"
  case .badResponse(let d):     return "Invalid response: \(d)"
  }
 }
}

// MARK: - JSON helpers ----------------------------------------------------
private func asDouble(_ v: Any?) -> Double? {
 if let n = v as? NSNumber { return n.doubleValue }
 if let s = v as? String, let d = Double(s) { return d }
 return nil
}

// Map HF-style outputs → VADER-like row
private func normalizeScoreRow(_ obj: [String:Any]) -> [String:Any] {
 var row = obj
 
 if row["compound"] != nil || (row["pos"] != nil && row["neg"] != nil) {
  if row["final_sentiment"] == nil, let c = asDouble(row["compound"]) {
   row["final_sentiment"] = (c >= 0.05) ? "POSITIVE" : (c <= -0.05 ? "NEGATIVE" : "NEUTRAL")
  }
  if row["model_label"] == nil { row["model_label"] = row["final_sentiment"] }
  return row
 }
 
 if let labelRaw = row["label"] as? String, let score = asDouble(row["score"]) {
  let label = labelRaw.uppercased()
  let isPos = label.contains("POS")
  let isNeg = label.contains("NEG")
  let isNeu = label.contains("NEU")
  
  let compound = isPos ?  score : (isNeg ? -score : 0.0)
  let pos = isPos ? score : 0.0
  let neg = isNeg ? score : 0.0
  let neu = isNeu ? score : max(0.0, 1.0 - max(pos, neg))
  
  row["pos"] = pos
  row["neg"] = neg
  row["neu"] = neu
  row["compound"] = compound
  row["final_sentiment"] = isPos ? "POSITIVE" : (isNeg ? "NEGATIVE" : "NEUTRAL")
  row["model_label"] = row["final_sentiment"]
  row["model_confidence"] = score
  return row
 }
 
 if let scores = row["scores"] as? [[String:Any]] {
  var posScore = 0.0, negScore = 0.0, neuScore = 0.0, best = 0.0
  for e in scores {
   let lab = (e["label"] as? String ?? "").uppercased()
   let sc  = asDouble(e["score"]) ?? 0.0
   if lab.contains("POS") { posScore = max(posScore, sc) }
   else if lab.contains("NEG") { negScore = max(negScore, sc) }
   else if lab.contains("NEU") { neuScore = max(neuScore, sc) }
   best = max(best, sc)
  }
  if neuScore == 0.0 { neuScore = max(0.0, 1.0 - max(posScore, negScore)) }
  
  let compound = posScore - negScore
  let label = (posScore >= negScore && posScore >= neuScore) ? "POSITIVE"
  : (negScore >= posScore && negScore >= neuScore) ? "NEGATIVE"
  : "NEUTRAL"
  
  row["pos"] = posScore
  row["neg"] = negScore
  row["neu"] = neuScore
  row["compound"] = compound
  row["final_sentiment"] = label
  row["model_label"] = label
  row["model_confidence"] = best
  return row
 }
 
 row["pos"] = 0.0
 row["neg"] = 0.0
 row["neu"] = 1.0
 row["compound"] = 0.0
 row["final_sentiment"] = "NEUTRAL"
 row["model_label"] = "NEUTRAL"
 row["model_confidence"] = 0.0
 return row
}

private func jsonString(_ obj: Any) throws -> String {
 let data = try JSONSerialization.data(withJSONObject: obj, options: [])
 return String(data: data, encoding: .utf8) ?? "{}"
}

private func jsonObject(_ line: String) throws -> [String:Any] {
 guard let d = line.data(using: .utf8) else {
  throw PythonBridgeError.badResponse("non-utf8 line")
 }
 do {
  let any = try JSONSerialization.jsonObject(with: d, options: [])
  if let o = any as? [String:Any] { return o }
  throw PythonBridgeError.badResponse(line)
 } catch {
  let sanitized = sanitizeNonStandardJSONNumbers(line)
  if sanitized != line,
     let d2 = sanitized.data(using: .utf8),
     let any2 = try? JSONSerialization.jsonObject(with: d2, options: []),
     let o2 = any2 as? [String:Any] {
   return o2
  }
  throw PythonBridgeError.badResponse(line)
 }
}

private func canonicalizeJSON(_ s: String) -> String? {
 guard let d = s.data(using: .utf8) else { return nil }
 guard let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
 guard JSONSerialization.isValidJSONObject(obj) else { return nil }
 guard let clean = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return nil }
 return String(data: clean, encoding: .utf8)
}

private func sanitizeNonStandardJSONNumbers(_ s: String) -> String {
 var out = s
 out = out.replacingOccurrences(of: #"(?i)(:\s*)-Infinity"#,
                                with: "$1null",
                                options: .regularExpression)
 out = out.replacingOccurrences(of: #"(?i)(:\s*)Infinity"#,
                                with: "$1null",
                                options: .regularExpression)
 out = out.replacingOccurrences(of: #"(?i)(:\s*)NaN"#,
                                with: "$1null",
                                options: .regularExpression)
 return out
}

// MARK: - Safe process-exit description ----------------------------------

private func safeExitDesc(_ p: Process) -> String {
 if p.isRunning { return "process still running (no terminationStatus yet)" }
 let status = p.terminationStatus
 let reason = (p.terminationReason == .exit) ? "exit" : "uncaughtSignal"
 return "exit=\(status) reason=\(reason)"
}

// MARK: - Notification names ---------------------------------------------

extension Notification.Name {
 static let plProgress = Notification.Name("plProgress")
 static let plDone     = Notification.Name("plDone")
}

// MARK: - Thread-safe boxes ----------------------------------------------

private final class DataBox {
 private let q = DispatchQueue(label: "pl.databox")
 private var data = Data()
 func append(_ d: Data) { q.async { self.data.append(d) } }
 func snapshot() -> Data { q.sync { data } }
}

private final class CountersBox {
 private let q = DispatchQueue(label: "pl.counters")
 private var _chunk = 0
 private var _lastProcessed = 0
 func incChunk() { q.sync { _chunk += 1 } }
 func setLastProcessed(_ v: Int) { q.sync { _lastProcessed = v } }
 func get() -> (chunk: Int, lastProcessed: Int) { q.sync { (_chunk, _lastProcessed) } }
}

// MARK: - Persistent worker (/serve) -------------------------------------

actor PythonWorker {
 private let pythonPath: String
 private let scriptPath: String
 private let resourcePath: String
 
 private var process: Process?
 private var stdinFH: FileHandle?
 private var stdoutFH: FileHandle?
 private var stderrFH: FileHandle?
 
 private var outBuf = Data()
 private var pending: [CheckedContinuation<[String:Any], Error>] = []
 private var handshake: CheckedContinuation<Void, Error>?
 
 private var isRunning = false
 
 

  private var totalRowsHint: Int? = nil
init(pythonPath: String, scriptPath: String, resourcePath: String) {
  self.pythonPath = pythonPath
  self.scriptPath = scriptPath
  self.resourcePath = resourcePath
 }
func start() async throws {
  if isRunning { return }

  let task = Process()
  task.executableURL = URL(fileURLWithPath: pythonPath)
  let args = ["-u", scriptPath, "serve"]
  task.arguments = args
  task.currentDirectoryURL = URL(fileURLWithPath: resourcePath)

  var env = ProcessInfo.processInfo.environment
  env["PYTHONIOENCODING"] = "UTF-8"
  env["PYTHONUNBUFFERED"] = "1"
  env["LC_ALL"] = "en_US.UTF-8"
  env["LANG"]   = "en_US.UTF-8"
  env["PL_DEBUG"] = "0"
  env["PL_DRIVERS"] = env["PL_DRIVERS"] ?? "1"
  env["TOKENIZERS_PARALLELISM"] = "false"
  env["TRANSFORMERS_OFFLINE"]  = "1"
  env["HF_HUB_OFFLINE"]        = "1"
  env["HF_DATASETS_OFFLINE"]   = "1"
  env["HF_HOME"]               = hfCacheDir()
  env["XDG_CACHE_HOME"]        = hfCacheDir()
  env["PYTHONWARNINGS"] = env["PYTHONWARNINGS"] ?? "ignore"
  env["HF_HUB_DISABLE_TELEMETRY"] = env["HF_HUB_DISABLE_TELEMETRY"] ?? "1"
  if env["OMP_NUM_THREADS"] == nil { env["OMP_NUM_THREADS"] = "4" }
  if env["MKL_NUM_THREADS"] == nil { env["MKL_NUM_THREADS"] = "4" }
  env["UV_THREADPOOL_SIZE"]    = env["UV_THREADPOOL_SIZE"] ?? "2"
  env["PYTHONHOME"]            = "\(resourcePath)/python310_embed/python-install"
  env["PYTHONPATH"] =
    "\(resourcePath):" +
    "\(resourcePath)/python310_embed/python-install/lib/python3.10:" +
    "\(resourcePath)/python310_embed/python-install/lib/python3.10/site-packages"
  env["PYTHONNOUSERSITE"]       = "1"
  env["PYTHONDONTWRITEBYTECODE"] = "1"
  env["PL_HIDE_PERSON_ENTITIES"] = env["PL_HIDE_PERSON_ENTITIES"] ?? "1"
  env["PL_GROUP_SIMILAR_EMOJIS"] = env["PL_GROUP_SIMILAR_EMOJIS"] ?? "1"
  env["PL_MIN_COUNT_KEYWORDS"]   = env["PL_MIN_COUNT_KEYWORDS"]   ?? "10"
  env["PL_STORE_TOKEN_TRACE"]    = env["PL_STORE_TOKEN_TRACE"]    ?? "0"

  // NEW: English-only & tolerant language handling
  env["PL_LANG"]             = env["PL_LANG"]             ?? "en"
  env["PL_EN_ONLY"]          = env["PL_EN_ONLY"]          ?? "1"
  env["PL_ALLOW_UND_AS_EN"]  = env["PL_ALLOW_UND_AS_EN"]  ?? "1"
  env["PL_ENGLISH_ONLY"]     = env["PL_ENGLISH_ONLY"]     ?? env["PL_EN_ONLY"] ?? "1"

  // Optional: thresholds & timeline prefs
  env["PL_MIN_ABS_IMPACT_KEYWORD"] = env["PL_MIN_ABS_IMPACT_KEYWORD"] ?? "0.08"
  env["PL_TIMELINE_GROUP"]         = env["PL_TIMELINE_GROUP"]         ?? "D"

  passthroughEnv(into: &env, keys: [
    "PL_PERF_PROFILE",
    "PL_SIGNATURES_ENABLED",
    "PL_USERNAME_REMOVAL",
    "PL_FORCE_SYNOPSIS",
    "PL_BATCH",
    "PL_MAXLEN",
    "PL_CHUNKSIZE",
    "OMP_NUM_THREADS",
    "MKL_NUM_THREADS",
    "UV_THREADPOOL_SIZE",
    "PL_PROGRESS_EVERY",
    "PL_PDF_OUT",
    "PL_HIDE_PERSON_ENTITIES",
    "PL_GROUP_SIMILAR_EMOJIS",
    "PL_MIN_COUNT_KEYWORDS",
    "PL_STORE_TOKEN_TRACE",
    "PL_LANG",
    "PL_EN_ONLY",
    "PL_ALLOW_UND_AS_EN",
    "PL_ENGLISH_ONLY",
    "PL_TIMELINE_GROUP",
    "PL_MIN_ABS_IMPACT_KEYWORD",
    "PL_PHRASES",
    "PL_DRIVERS",
    "PL_SIGNATURES_TRACE",
  ])
  let overrides = await manualProcessingOverrides()
  for (k, v) in overrides { env[k] = v }

  task.environment = env

  let inPipe  = Pipe()
  let outPipe = Pipe()
  let errPipe = Pipe()
  task.standardInput  = inPipe
  task.standardOutput = outPipe
  task.standardError  = errPipe

  stdinFH  = inPipe.fileHandleForWriting
  stdoutFH = outPipe.fileHandleForReading
  stderrFH = errPipe.fileHandleForReading

  // ---- NEW: proper line-buffering for stderr + explicit stdout handler ----
  var errBuf = Data()

  // Read stdout (handshake + replies) via existing parser
  stdoutFH?.readabilityHandler = { [weak self] h in
    let data = h.availableData
    guard !data.isEmpty else { return }
    Task { await self?.handleStdout(data) }
  }

  // Buffer + parse stderr line-by-line (handles split UTF-8/newlines)
  stderrFH?.readabilityHandler = { h in
    let data = h.availableData
    guard !data.isEmpty else { return }
    errBuf.append(data)
    while let nl = errBuf.firstIndex(of: 0x0A) { // '\n'
      let lineData = errBuf.subdata(in: 0..<nl)
      errBuf.removeSubrange(0...nl)
      guard !lineData.isEmpty else { continue }
      let line = String(decoding: lineData, as: UTF8.self)

      // 1) processed heartbeat: "HEARTBEAT processed=12345"
      if let r = line.range(of: "HEARTBEAT processed=") {
        let nStr = line[r.upperBound...].prefix { $0.isNumber }
        if let n = Int(nStr) {
          DispatchQueue.main.async {
            NotificationCenter.default.post(
              name: .plProgress,
              object: nil,
              userInfo: ["status": "running", "processed": n]
            )
          }
        }
      }

      // 2) total rows hint: "... rows=7287"
      if let m = line.range(of: #"rows=(\d+)"#, options: .regularExpression) {
        let token = String(line[m]).replacingOccurrences(of: "rows=", with: "")
        if let n = Int(token) {
          DispatchQueue.main.async {
            NotificationCenter.default.post(
              name: .plProgress,
              object: nil,
              userInfo: ["status": "running", "total": n]
            )
          }
        }
      }

      dlog("🐍 stderr: \(line)")
    }
  }

  task.terminationHandler = { [weak self] proc in
    guard let self = self else { return }
    // Flush any trailing partial line from stderr
    if !errBuf.isEmpty {
      let line = String(decoding: errBuf, as: UTF8.self)
      if !line.isEmpty {
        if let r = line.range(of: "HEARTBEAT processed=") {
          let nStr = line[r.upperBound...].prefix { $0.isNumber }
          if let n = Int(nStr) {
            DispatchQueue.main.async {
              NotificationCenter.default.post(
                name: .plProgress,
                object: nil,
                userInfo: ["status":"running","processed": n]
              )
            }
          }
        }
        if let m = line.range(of: #"rows=(\d+)"#, options: .regularExpression) {
          let token = String(line[m]).replacingOccurrences(of: "rows=", with: "")
          if let n = Int(token) {
            DispatchQueue.main.async {
              NotificationCenter.default.post(
                name: .plProgress,
                object: nil,
                userInfo: ["status":"running","total": n]
              )
            }
          }
        }
        dlog("🐍 stderr: \(line)")
      }
      errBuf.removeAll()
    }
    Task { await self.flushOnDeath() }
    dlog("🐍 worker loop EXIT — status=\(proc.terminationStatus) reason=\(proc.terminationReason.rawValue)")
  }

  try task.run()
  UserDefaults.standard.set(Int32(task.processIdentifier), forKey: "PL_PY_PID")
  dlog("🐍 launched: \(pythonPath) \(args.joined(separator: " ")) (cwd=\(resourcePath))")
  process = task
  isRunning = true

  try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
    self.handshake = cont
  }
}


 
 private func handleStdout(_ data: Data) {
  outBuf.append(data)
  while let nl = outBuf.firstIndex(of: 0x0A) {
   let lineData = outBuf.subdata(in: 0..<nl)
   outBuf.removeSubrange(0...nl)
   guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
   
   if let hs = handshake {
    if let obj = try? jsonObject(line), (obj["ready"] as? Bool) == true {
     dlog("🐍 handshake ok")
     handshake = nil
     hs.resume()
    } else {
     dlog("🐍 stdout(handshake-ignored): \(line)")
    }
    continue
   }
   
   guard !pending.isEmpty else {
    dlog("🐍 stdout(ignored): \(line)")
    continue
   }
   
   if let obj = try? jsonObject(line) {
    let waiter = pending.removeFirst()
    waiter.resume(returning: obj)
   } else {
    dlog("🐍 stdout(ignored-nonjson): \(line)")
   }
  }
 }
 
 private func flushOnDeath() {
  isRunning = false
  stdoutFH?.readabilityHandler = nil
  stderrFH?.readabilityHandler = nil
  if let hs = handshake {
    hs.resume(throwing: PythonBridgeError.workerDied)
    handshake = nil
  }
  // Ensure PID is cleared so killStalePythonIfAny never targets a new worker
  UserDefaults.standard.removeObject(forKey: "PL_PY_PID")
  while !pending.isEmpty {
    let w = pending.removeFirst()
    w.resume(throwing: PythonBridgeError.workerDied)
  }
}

 
 func stop() async {
  let pid = process?.processIdentifier
  process?.terminate()
  isRunning = false
  if let pid = pid {
   try? await Task.sleep(nanoseconds: 300_000_000)
   kill(pid_t(pid), SIGKILL)
   UserDefaults.standard.removeObject(forKey: "PL_PY_PID")
  } else {
   UserDefaults.standard.removeObject(forKey: "PL_PY_PID")
  }
  process = nil
  flushOnDeath()
 }
 
 /// Send a JSON payload to the running worker and await one-line JSON reply.
 func send(_ payload: [String:Any]) async throws -> [String:Any] {
  guard isRunning, let stdinFH else { throw PythonBridgeError.workerDied }
  let line = try jsonString(payload) + "\n"
  let data = line.data(using: .utf8)!
  dlog("→ send to worker: \(String(line.prefix(400)))…")
  let response: [String:Any] = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[String:Any], Error>) in
   pending.append(cont)
   do { try stdinFH.write(contentsOf: data) } catch {
    _ = pending.popLast()
    cont.resume(throwing: error)
   }
  }
  dlog("← recv from worker keys=\(response.keys.sorted())")
  return response
 }
}

// MARK: - Bridge ----------------------------------------------------------

final class PythonBridge: ObservableObject {
 static let shared = PythonBridge()
 
 @Published var isInitialized = false
 @Published var initializationError: String?
 
 private var pythonPath: String?
 private var scriptPath: String?
 private var resourcePath: String?
 
 private var worker: PythonWorker?
 private var warmed: Set<String> = []
 
 private init() {}
 
 // Resolve bundle paths if caller skipped initializePython()
 private func resolvePathsIfNeeded() {
  if resourcePath == nil {
   resourcePath = Bundle.main.resourcePath
   dlog("resolvePaths: resourcePath=\(resourcePath ?? "nil")")
  }
  if pythonPath == nil, let res = resourcePath {
   pythonPath = "\(res)/python310_embed/python-install/bin/python3.10"
   dlog("resolvePaths: pythonPath=\(pythonPath!) exists=\(FileManager.default.fileExists(atPath: pythonPath!))")
  }
  if scriptPath == nil, let res = resourcePath {
   if let p = Bundle.main.path(forResource: "polarity_sentiment", ofType: "py") {
    scriptPath = p
   } else {
    let fm = FileManager.default
    if let en = fm.enumerator(atPath: res) {
     while let obj = en.nextObject() as? String {
      if obj.hasSuffix("/polarity_sentiment.py") || obj == "polarity_sentiment.py" {
       scriptPath = (res as NSString).appendingPathComponent(obj)
       break
      }
     }
    }
   }
   dlog("resolvePaths: scriptPath=\(scriptPath ?? "nil") exists=\(scriptPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)")
  }
 }
 
 // Locate resources and start the worker once.
 func initializePython() async {
  if isInitialized { return }
  
  guard let res = Bundle.main.resourcePath else {
   await MainActor.run { self.initializationError = "Could not locate app Resources directory" }
   dlog("initializePython: missing resourcePath")
   return
  }
  resourcePath = res
  pythonPath   = "\(res)/python310_embed/python-install/bin/python3.10"
  
  var sp: String?
  if let p = Bundle.main.path(forResource: "polarity_sentiment", ofType: "py") {
   sp = p
  } else {
   let fm = FileManager.default
   if let en = fm.enumerator(atPath: res) {
    while let obj = en.nextObject() {
     if let item = obj as? String {
      if item.hasSuffix("/polarity_sentiment.py") || item == "polarity_sentiment.py" {
       sp = (res as NSString).appendingPathComponent(item)
       break
      }
     }
    }
   }
  }
  
  dlog("initializePython: res=\(res)")
  dlog("initializePython: python=\(pythonPath ?? "nil") exists=\(pythonPath.map { FileManager.default.fileExists(atPath: $0) } ?? false)")
  dlog("initializePython: script=\(sp ?? "nil") exists=\(sp.map { FileManager.default.fileExists(atPath: $0) } ?? false)")
  
  guard let py = pythonPath, FileManager.default.fileExists(atPath: py) else {
   await MainActor.run { self.initializationError = "Python executable not found" }
   return
  }
  guard let script = sp, FileManager.default.fileExists(atPath: script) else {
   await MainActor.run { self.initializationError = "Python script not found" }
   return
  }
  
  scriptPath = script
  
  do {
   let w = PythonWorker(pythonPath: py, scriptPath: script, resourcePath: res)
   try await w.start()
   await MainActor.run {
    self.worker = w
    self.isInitialized = true
    self.initializationError = nil
   }
   dlog("initializePython: worker started")
  } catch {
   let msg = "Python initialization failed: \(error.localizedDescription)"
   dlog(msg)
   await MainActor.run { self.initializationError = msg }
  }
 }
 
 // Prewarm models via serve-loop (optional)
 func prewarmAll(startWith first: SentimentModel) async {
  guard await ensureWorker() else { return }
  let order: [String] = {
   let all = ["vader","social","community"]
   let f = first.apiName
   return [f] + all.filter { $0 != f }
  }()
  for m in order {
   if warmed.contains(m) { continue }
   do {
    dlog("prewarm model \(m)")
    _ = try await worker!.send(["op":"warmup","model": m])
    warmed.insert(m)
   } catch {
    dlog("prewarm \(m) failed: \(error.localizedDescription)")
   }
  }
 }
 
 func ensureReady(for model: SentimentModel) async {
  guard await ensureWorker() else { return }
  let m = model.apiName
  if warmed.contains(m) { return }
  do {
   dlog("ensureReady warmup \(m)")
   _ = try await worker!.send(["op":"warmup","model": m])
   warmed.insert(m)
  } catch {
   dlog("ensureReady \(m) failed: \(error.localizedDescription)")
  }
 }
 
 private func looksLikeSentiment(_ obj: [String:Any]) -> Bool {
  if obj["error"] != nil { return true }
  let k = obj.keys
  if k.contains("compound") || k.contains("pos") || k.contains("neg") || k.contains("neu")
      || k.contains("final_sentiment") || k.contains("label") || k.contains("scores") { return true }
  if let rows = obj["rows"] as? [[String:Any]], let r0 = rows.first {
   let rk = r0.keys
   return rk.contains("compound") || rk.contains("pos") || rk.contains("neg") || rk.contains("neu")
   || rk.contains("final_sentiment") || rk.contains("label") || rk.contains("scores")
  }
  return false
 }
 
 func scoreSentence(
  _ text: String,
  model: SentimentModel,
  template: TemplatePayload? = nil,
  explain: Bool = false
 ) async -> String {
  do {
   guard await ensureWorker() else { throw PythonBridgeError.notInitialized }
   await ensureReady(for: model)
   
   var payload: [String: Any] = [
"op": "score",
    "text": text,
    "model": model.apiName,
    "explain": explain
   ]
   if let template, let t = try? JSONEncoder().encode(template).toJSONString() {
    payload["template"] = t
   }
   
   var last: [String:Any] = [:]
   for attempt in 1...3 {
    let resp = try await worker!.send(payload)
    dlog("scoreSentence attempt \(attempt) keys=\(resp.keys.sorted())")
    
    if let rows = resp["rows"] as? [[String:Any]], let r0 = rows.first {
     let norm = normalizeScoreRow(r0)
     return try jsonString(["rows": [norm]])
    }
    if looksLikeSentiment(resp) {
     let norm = normalizeScoreRow(resp)
     return try jsonString(["rows": [norm]])
    }
    last = resp
    try await Task.sleep(nanoseconds: UInt64(50_000_000 * attempt))
   }
   let fallback = (try? jsonString(last)) ?? "{}"
   return "{\"error\":\"no sentiment fields in response\",\"raw\":\(fallback)}"
  } catch {
   dlog("scoreSentence error: \(error.localizedDescription)")
   return "{\"error\":\"\(error.localizedDescription)\"}"
  }
 }
func runSentimentAnalysis(
  fileURL: URL,
  selectedCols rawSelectedCols: [String],
  skipRows: Int,
  mergeText: Bool,
  model: SentimentModel,
  template: TemplatePayload? = nil,
  filter: FilterPayload? = nil,
  date: DateFilterPayload? = nil,
  synopsis: Bool = false,
  explain: Bool = false,
  signatureRemoval: Bool = true,
  usernameRemoval: Bool = true,
  includePhrases: Bool = false
) async -> String {
  enum AnalysisPathError: Error { case serveUnknownOp }
  // Preflight CSV readability to catch sandbox issues early
  let readable = FileManager.default.isReadableFile(atPath: fileURL.path)
  var firstBytes = 0
  if let fh = try? FileHandle(forReadingFrom: fileURL) {
    let data = try? fh.read(upToCount: 1024)
    firstBytes = data?.count ?? 0
    try? fh.close()
  }
  dlog("CSV preflight: readable=\(readable) firstBytes=\(firstBytes) path=\(fileURL.path)")

  // Helpers scoped to this call
  func lastMetaLine(_ path: String) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    let fileLen: UInt64 = (try? fh.seekToEnd()) ?? 0
    if fileLen == 0 { return nil }
    let chunk: UInt64 = 64 * 1024
    var offset: Int64 = Int64(fileLen)
    var carry = Data()
    while offset > 0 {
      let step = Int64(min(chunk, UInt64(offset)))
      offset -= step
      try? fh.seek(toOffset: UInt64(offset))
      let data = (try? fh.read(upToCount: Int(step))) ?? Data()
      var buf = Data()
      buf.append(data)
      buf.append(carry)
      if let s = String(data: buf, encoding: .utf8) {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        for line in lines.reversed() {
          if line.contains(#""__meta__": true"#) { return line }
        }
        if let firstNL = s.firstIndex(of: "\n") {
          let head = String(s[..<firstNL])
          carry = Data(head.utf8)
        } else {
          carry = buf
        }
      } else {
        carry.insert(contentsOf: data, at: 0)
      }
    }
    return nil
  }

  /// Parse tolerant meta trailer; returns status/processed/total/chunks if present.
  /// UPDATED: recognize filtered totals so keyword filters drive the reported total.
  func parseMeta(_ path: String) -> (status: String?, processed: Int?, total: Int?, chunks: Int?) {
    guard let line = lastMetaLine(path), let d = line.data(using: .utf8) else { return (nil, nil, nil, nil) }
    guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          (o["__meta__"] as? Bool) == true else { return (nil, nil, nil, nil) }
    let meta = (o["meta"] as? [String: Any]) ?? [:]

    func intValue(_ any: Any?) -> Int? {
      if let n = any as? NSNumber { return n.intValue }
      if let i = any as? Int { return i }
      if let s = any as? String, let v = Int(s) { return v }
      return nil
    }

    // processed candidates (rows emitted so far)
    let processedKeys = ["processed","rows","rows_emitted","emitted","processed_rows","count","n"]
    var processed: Int? = nil
    for k in processedKeys {
      if let v = intValue(meta[k]) { processed = v; break }
    }

    // total candidates — include filtered totals so keyword filters affect "total"
    let totalKeys = ["total","rows_total","total_rows","expected_rows",
                     "total_emitted","emitted_total","rows_after_filter",
                     "filtered_total","rows_filtered_total"]
    var total: Int? = nil
    for k in totalKeys {
      if let v = intValue(meta[k]) { total = v; break }
    }

    // chunks candidates (flat or nested in "progress")
    let chunksKeys = ["chunks","chunk","emitted_chunks","chunks_emitted","total_chunks","completed_chunks","progress_chunks"]
    var chunks: Int? = nil
    for k in chunksKeys {
      if let v = intValue(meta[k]) { chunks = v; break }
    }
    if chunks == nil, let prog = meta["progress"] as? [String: Any] {
      chunks = intValue(prog["chunks"]) ?? intValue(prog["chunk"])
    }

    let status = (o["status"] as? String) ?? (meta["status"] as? String)
    return (status, processed, total, chunks)
  }

  func jsonlStatus(_ path: String) -> String? { parseMeta(path).status }

  let postProgress: @Sendable (String, Int?, Int?, Int, Int64, String) -> Void = { status, processed, total, chunks, bytes, file in
    DispatchQueue.main.async {
      var info: [String: Any] = [
        "status": status,
        "chunks": chunks,
        "bytes": NSNumber(value: bytes),
        "file": file
      ]
      if let processed { info["processed"] = processed }
      if let total { info["total"] = total }
      NotificationCenter.default.post(name: .plProgress, object: nil, userInfo: info)
    }
  }
  let postDone: @Sendable () -> Void = {
    DispatchQueue.main.async { NotificationCenter.default.post(name: .plDone, object: nil) }
  }

  // Shared CLI fallback (original subprocess path)
  func runAnalysisViaCLI(workingCSV: URL,
                         selectedCols: [String],
                         outURL: URL,
                         pdfOutPath: String) async throws -> String {
    resolvePathsIfNeeded()
    guard let res = resourcePath,
          let py = pythonPath,
          let script = scriptPath
    else { throw PythonBridgeError.notInitialized }

    var args: [String] = [
      script, "analysis",
      "--file", workingCSV.path,
      "--columns", selectedCols.joined(separator: ","),
      "--model", model.apiName
    ]
    if skipRows > 0 { args += ["--skip", String(skipRows)] }
    if mergeText { args += ["--merge"] }
    if explain   { args += ["--explain"] }
    args += ["--synopsis"] // ensure synopsis available for export
    args += ["--pdf-out", pdfOutPath]
    if let template, let t = try? JSONEncoder().encode(template).toJSONString() { args += ["--template", t] }
    if let filter,   let f = try? JSONEncoder().encode(filter).toJSONString()   { args += ["--filt", f] }
    if let date,     let d = try? JSONEncoder().encode(date).toJSONString()     { args += ["--datecfg", d] }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: py)
    p.arguments = ["-u"] + args
    p.qualityOfService = .userInitiated
    p.currentDirectoryURL = URL(fileURLWithPath: res)

    var env = ProcessInfo.processInfo.environment
    var additions: [String: String] = [
      "PL_OUT": outURL.path,
      "PL_SIGNATURES_ENABLED": signatureRemoval ? "1" : "0",
      "PL_USERNAME_REMOVAL":   usernameRemoval  ? "1" : "0",
      "PL_PROGRESS_EVERY":     ProcessInfo.processInfo.environment["PL_PROGRESS_EVERY"] ?? "500",

      // Ensure names are not scored and keyword filter is enforced in totals
      "PL_HIDE_PERSON_ENTITIES": "1",
      "PL_FILTER_ENFORCE": "1",

      "PL_PHRASES": includePhrases ? "1" : "0",
      "PL_DRIVERS": "1",
      "PL_SIGNATURES_TRACE": "1",
      "PL_FORCE_SYNOPSIS": "1",
      "PL_DEBUG": "0",
      "PYTHONIOENCODING": "UTF-8",
      "PYTHONUNBUFFERED": "1",
      "LC_ALL": "en_US.UTF-8",
      "LANG": "en_US.UTF-8",
      "PL_CHUNKSIZE": "64000",
      "TOKENIZERS_PARALLELISM": "false",
      "TRANSFORMERS_OFFLINE": "1",
      "HF_HUB_OFFLINE": "1",
      "HF_DATASETS_OFFLINE": "1",
      "HF_HOME": hfCacheDir(),
      "XDG_CACHE_HOME": hfCacheDir(),
      "OMP_NUM_THREADS": env["OMP_NUM_THREADS"] ?? "4",
      "MKL_NUM_THREADS": env["MKL_NUM_THREADS"] ?? "4",
      "UV_THREADPOOL_SIZE": env["UV_THREADPOOL_SIZE"] ?? "2",
      "PYTHONHOME": "\(res)/python310_embed/python-install",
      "PYTHONPATH": "\(res):\(res)/python310_embed/python-install/lib/python3.10:\(res)/python310_embed/python-install/lib/python3.10/site-packages",
      "PYTHONNOUSERSITE": "1",
      "PYTHONDONTWRITEBYTECODE": "1",
      "PL_GROUP_SIMILAR_EMOJIS": "1",
      "PL_MIN_COUNT_KEYWORDS": "10",
      "PL_STORE_TOKEN_TRACE": "0",
      "PYTHONWARNINGS": env["PYTHONWARNINGS"] ?? "ignore",
      "HF_HUB_DISABLE_TELEMETRY": env["HF_HUB_DISABLE_TELEMETRY"] ?? "1"
    ]
    let overrides = await manualProcessingOverrides()
    for (k, v) in overrides { additions[k] = v }
    passthroughEnv(into: &additions, keys: [
      "PL_PERF_PROFILE",
      "PL_SIGNATURES_ENABLED",
      "PL_USERNAME_REMOVAL",
      "PL_FORCE_SYNOPSIS",
      "PL_BATCH",
      "PL_MAXLEN",
      "PL_CHUNKSIZE",
      "OMP_NUM_THREADS",
      "MKL_NUM_THREADS",
      "UV_THREADPOOL_SIZE",
      "PL_PROGRESS_EVERY",
      "PL_PDF_OUT",
      "PL_HIDE_PERSON_ENTITIES",
      "PL_GROUP_SIMILAR_EMOJIS",
      "PL_MIN_COUNT_KEYWORDS",
      "PL_STORE_TOKEN_TRACE",
      "PL_PHRASES",
      "PL_DRIVERS",
      "PL_SIGNATURES_TRACE",
    ])
    additions["PL_PDF_OUT"] = pdfOutPath
    for (k, v) in additions { env[k] = v }
    p.environment = env

    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError  = errPipe

    let outFH = outPipe.fileHandleForReading
    let errFH = errPipe.fileHandleForReading

    let outBox = DataBox()
    let errBox = DataBox()
    let counters = CountersBox()

    outFH.readabilityHandler = { fh in
      let d = fh.availableData
      if !d.isEmpty {
        outBox.append(d)
        if let s = String(data: d, encoding: .utf8), !s.isEmpty {
          for line in s.split(separator: "\n") { dlog("🐍 stdout: \(line)") }
        }
      }
    }

    errFH.readabilityHandler = { [outPath = outURL.path] fh in
      let d = fh.availableData
      guard !d.isEmpty, let s = String(data: d, encoding: .utf8), !s.isEmpty else { return }
      errBox.append(d)
      for line in s.split(separator: "\n") {
        if line.contains("chunk_done") {
          counters.incChunk()
          var processedGuess = counters.get().lastProcessed
          if let m = line.range(of: #"total_emitted=(\d+)"#, options: .regularExpression) {
            let num = String(line[m]).replacingOccurrences(of: "total_emitted=", with: "")
            processedGuess = Int(num) ?? processedGuess
          } else if let m2 = line.range(of: #"rows=(\d+)"#, options: .regularExpression) {
            let num = String(line[m2]).replacingOccurrences(of: "rows=", with: "")
            processedGuess += (Int(num) ?? 0)
          }
          counters.setLastProcessed(processedGuess)
          let bytesNow: Int64 = (try? FileManager.default.attributesOfItem(atPath: outPath)[.size] as? NSNumber)?.int64Value ?? 0
          let (chunksNow, _) = counters.get()
          postProgress("running",
                       processedGuess,
                       nil,
                       chunksNow,
                       bytesNow,
                       outPath)
          dlog("stderr chunk_done: chunks=\(chunksNow) processed≈\(processedGuess) bytes=\(bytesNow)")
        } else {
          dlog("🐍 stderr: \(line)")
        }
      }
    }

    try p.run()
    dlog("🐍 analysis launched (CLI): \(py) \((["-u"] + args).joined(separator: " "))")
    dlog("PL_OUT=\(outURL.path) waiting for file…")

    let createDeadline = Date().addingTimeInterval(20.0)
    while Date() < createDeadline {
      if FileManager.default.fileExists(atPath: outURL.path) { break }
      if !p.isRunning { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    if FileManager.default.fileExists(atPath: outURL.path) {
      let bytesNow: Int64 = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.int64Value ?? 0
      postProgress("initializing", 0, nil, 0, bytesNow, outURL.path)
      dlog("PL_OUT created (\(bytesNow) bytes)")
    } else {
      let capturedOut = String(data: outBox.snapshot(), encoding: .utf8) ?? ""
      let capturedErr = String(data: errBox.snapshot(), encoding: .utf8) ?? ""
      dlog("PL_OUT NOT created within 20s (CLI). stdout=\(capturedOut) stderr=\(capturedErr)")
    }

    let finalDeadline = Date().addingTimeInterval(3600)
    var lastProcessedLogged = -1
    var lastBytesPosted: Int64 = 0
    while Date() < finalDeadline {
      let meta = parseMeta(outURL.path)
      let status = (meta.status ?? "running").lowercased()
      let processed = meta.processed ?? counters.get().lastProcessed
      let bytesNow: Int64 = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.int64Value ?? 0

      if status == "final" {
        let chunksNow = meta.chunks ?? counters.get().chunk
        postProgress("final", processed, meta.total, chunksNow, bytesNow, outURL.path)
        dlog("JSONL final trailer detected (CLI). processed=\(processed) bytes=\(bytesNow) chunks=\(chunksNow)")
        break
      }
      if status == "running", processed != lastProcessedLogged {
        lastProcessedLogged = processed
        let chunksNow = meta.chunks ?? counters.get().chunk
        postProgress("running", processed, meta.total, chunksNow, bytesNow, outURL.path)
        dlog("📈 progress heartbeat (CLI) — processed=\(processed) bytes=\(bytesNow) chunks=\(chunksNow)")
      }

      if FileManager.default.fileExists(atPath: outURL.path) {
        if bytesNow > lastBytesPosted {
          lastBytesPosted = bytesNow
          let chunksNow = meta.chunks ?? counters.get().chunk
          postProgress("running", processed, meta.total, chunksNow, bytesNow, outURL.path)
        }
      }
      if !p.isRunning {
        try await Task.sleep(nanoseconds: 300_000_000)
        if let s = jsonlStatus(outURL.path), s.lowercased() == "final" { break }
        throw PythonBridgeError.executionFailed("Process exited without FINAL trailer. \(safeExitDesc(p))")
      }
      try await Task.sleep(nanoseconds: 600_000_000)
    }

    outFH.readabilityHandler = nil
    errFH.readabilityHandler = nil
    await Task.detached { p.waitUntilExit() }.value
    try? outFH.close(); try? errFH.close()

    guard FileManager.default.fileExists(atPath: outURL.path) else {
      throw PythonBridgeError.executionFailed("No PL_OUT written. \(safeExitDesc(p))")
    }
    guard let status = jsonlStatus(outURL.path), status.lowercased() == "final" else {
      if let raw = try? String(contentsOf: outURL, encoding: .utf8) {
        dlog("RAW JSONL (no final meta): first 800 bytes:\n\(raw.prefix(800))")
      }
      throw PythonBridgeError.executionFailed("PL_OUT missing final meta trailer. \(safeExitDesc(p))")
    }

    postDone()
    let bytes = fileSize(at: outURL.path) ?? 0
    let result: [String: Any] = [
      "ok": true,
      "streamed": true,
      "out_path": outURL.path,
      "bytes": NSNumber(value: bytes)
    ]
    dlog("Returning streamed result bytes=\(bytes)")
    return try jsonString(result)
  }

  do {
    resolvePathsIfNeeded()
    guard await ensureWorker() else { throw PythonBridgeError.notInitialized }
    await ensureReady(for: model)

    var hadAccess = false
    var workingCSV = fileURL
    if !fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
      hadAccess = fileURL.startAccessingSecurityScopedResource()
      dlog("startAccessingSecurityScopedResource=\(hadAccess)")
      let tmpCSV = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pl_work_\(UUID().uuidString)_\(fileURL.lastPathComponent)")
      do {
        if FileManager.default.fileExists(atPath: tmpCSV.path) {
          try? FileManager.default.removeItem(at: tmpCSV)
        }
        try FileManager.default.copyItem(at: fileURL, to: tmpCSV)
        workingCSV = tmpCSV
        dlog("CSV copied to sandbox tmp: \(workingCSV.path)")
      } catch {
        dlog("CSV tmp copy failed (\(error.localizedDescription)). Using original path.")
      }
    }
    defer { if hadAccess { fileURL.stopAccessingSecurityScopedResource(); dlog("stopAccessingSecurityScopedResource()") } }

    var selectedCols = rawSelectedCols
    if let dc = date?.column { selectedCols.append(dc) }
    selectedCols = normalizeColumns(selectedCols)

    dlog("""
                          runSentimentAnalysis (serve, non-blocking):
                            csvPath=\(workingCSV.path) exists=\(FileManager.default.fileExists(atPath: workingCSV.path))
                            selectedCols=\(selectedCols)
                            model=\(model.apiName) synopsis=\(synopsis) explain=\(explain)
                            sigRemoval=\(signatureRemoval) userRemoval=\(usernameRemoval) phrases=\(includePhrases)
                          """)

    let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("pl_result_\(UUID().uuidString).jsonl")
    let pdfOutPath = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("PolarityLab_Report_\(UUID().uuidString).pdf")
    FileManager.default.createFile(atPath: outURL.path, contents: Data(), attributes: nil)

    var payload: [String: Any] = [
      "op": "analyze",
      "file": workingCSV.path,
      "columns": selectedCols,
      "model": model.apiName,
      "skip_rows": max(0, skipRows),
      "skip": max(0, skipRows),
      "merge_text": mergeText,
      "merge": mergeText,
      "explain": explain,
      "synopsis": synopsis,
      "phrases": includePhrases,
      "pdf_out": pdfOutPath,
      "env": [
        "PL_OUT": outURL.path,
        "PL_PDF_OUT": pdfOutPath,
        "PL_SIGNATURES_ENABLED": signatureRemoval ? "1" : "0",
        "PL_USERNAME_REMOVAL":   usernameRemoval  ? "1" : "0",

        // Ensure names are not scored and keyword filter is enforced (affects totals)
        "PL_HIDE_PERSON_ENTITIES": "1",
        "PL_FILTER_ENFORCE": "1",

        // Keep timeline zoom behavior predictable (uses existing default if set)
        "PL_TIMELINE_GROUP": ProcessInfo.processInfo.environment["PL_TIMELINE_GROUP"] ?? "D",
      ]
    ]
    if let template, let t = try? JSONEncoder().encode(template).toJSONString() { payload["template"] = t }
    if let filter,   let f = try? JSONEncoder().encode(filter).toJSONString()   { payload["filt"]     = f }
    if let date,     let d = try? JSONEncoder().encode(date).toJSONString()     { payload["datecfg"]  = d }

    dlog("→ send to worker (analysis) keys=\(payload.keys.sorted())")

    // Fire-and-monitor: write request now, but don't await the reply.
    // This avoids UI hang while Python streams to PL_OUT.
    let sendTask = Task<[String: Any], Error> { [w = self.worker] in
      guard let w = w else { throw PythonBridgeError.notInitialized }
      return try await w.send(payload)
    }

    let outPath = outURL.path
    postProgress("initializing", 0, nil, 0, 0, outPath)
    dlog("PL_OUT target=\(outPath) waiting for file…")

    // Wait up to 60s for PL_OUT to appear; if not, fall back to CLI.
    let createDeadline = Date().addingTimeInterval(60)
    while Date() < createDeadline {
      if FileManager.default.fileExists(atPath: outPath) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    if !FileManager.default.fileExists(atPath: outPath) {
      dlog("PL_OUT NOT created within 60s (serve). Falling back to CLI.")
      // try to cancel the in-flight send (best-effort)
      sendTask.cancel()
      return try await runAnalysisViaCLI(workingCSV: workingCSV,
                                         selectedCols: selectedCols,
                                         outURL: outURL,
                                         pdfOutPath: pdfOutPath as String)
    }

    let finalDeadline = Date().addingTimeInterval(3600)
    var lastProcessedLogged = -1
    var lastBytesPosted: Int64 = 0
    while Date() < finalDeadline {
      let meta = parseMeta(outPath)
      let status = (meta.status ?? "running").lowercased()
      let processed = meta.processed ?? 0
      let bytesNow: Int64 = (try? FileManager.default
                              .attributesOfItem(atPath: outPath)[.size] as? NSNumber)?.int64Value ?? 0

      if status == "final" {
        postProgress("final", processed, meta.total, meta.chunks ?? 0, bytesNow, outPath)
        dlog("JSONL final trailer detected. processed=\(processed) bytes=\(bytesNow) chunks=\(meta.chunks ?? 0)")
        break
      }
      if processed != lastProcessedLogged {
        lastProcessedLogged = processed
        postProgress("running", processed, meta.total, meta.chunks ?? 0, bytesNow, outPath)
        dlog("📈 progress heartbeat — processed=\(processed) bytes=\(bytesNow) chunks=\(meta.chunks ?? 0)")
      }
      if bytesNow > lastBytesPosted {
        lastBytesPosted = bytesNow
        postProgress("running", processed, meta.total, meta.chunks ?? 0, bytesNow, outPath)
      }
      try await Task.sleep(nanoseconds: 600_000_000)
    }

    guard FileManager.default.fileExists(atPath: outPath),
          (jsonlStatus(outPath)?.lowercased() == "final") else {
      if let raw = try? String(contentsOfFile: outPath, encoding: .utf8) {
        dlog("RAW JSONL (no final meta): first 800 bytes:\n\(raw.prefix(800))")
      }
      // ensure sendTask is awaited (best-effort) before fallback
      _ = try? await sendTask.value
      return try await runAnalysisViaCLI(workingCSV: workingCSV,
                                         selectedCols: selectedCols,
                                         outURL: outURL,
                                         pdfOutPath: pdfOutPath as String)
    }

    postDone()
    // Await send completion to drain worker response (ignore result)
    _ = try? await sendTask.value

    let bytes = fileSize(at: outPath) ?? 0
    let result: [String: Any] = [
      "ok": true,
      "streamed": true,
      "out_path": outPath,
      "bytes": NSNumber(value: bytes)
    ]
    dlog("Returning streamed result bytes=\(bytes)")
    return try jsonString(result)

  } catch {
    dlog("runSentimentAnalysis error: \(error.localizedDescription)")
    return "{\"error\":\"\(error.localizedDescription)\"}"
  }
}


 
 /// Read the streamed JSONL (rows + final/meta lines) produced by Python.
  /// Read the streamed JSONL (rows + final/meta lines) produced by Python.
 /// Read the streamed JSONL (rows + final/meta lines) produced by Python.
/// Read the streamed JSONL (rows + final/meta lines) produced by Python.
        /// Read the streamed JSONL (rows + final/meta lines) produced by Python.
      /// Read the streamed JSONL (rows + final/meta lines) produced by Python.
     /// Read the streamed JSONL (rows + final/meta lines) produced by Python.
    /// Read the streamed JSONL (rows + final/meta lines) produced by Python.
/// Read the streamed JSONL (rows + final/meta lines) produced by Python.
func readStreamedJSONL(
 at path: String,
 onProgress: ((Int) -> Void)? = nil
) async -> (
 rows: [[String: Any]],
 headers: [String],
 keywords: [[String: Any]],
 meta: [String: Any]
) {
 var rows = [[String: Any]]()
 var headers = [String]()
 var keywords = [[String: Any]]()
 var meta = [String: Any]()
 var signaturesTrace = [[String: Any]]()
 
 var keywordStats = [[String: Any]]()
 var coverageDict = [String: Any]()
 var settingsUsed = [String: Any]()
 
 var pendingRowArrays = [[Any]]()
 
 @inline(__always)
 func mapRowArray(_ arr: [Any], using hdrs: [String]) -> [String: Any] {
  var obj: [String: Any] = [:]
  let n = min(arr.count, hdrs.count)
  if n > 0 {
   for i in 0..<n { obj[hdrs[i]] = arr[i] }
  } else {
   for (i, v) in arr.enumerated() { obj["c\(i)"] = v }
  }
  return obj
 }
 
 guard let blob = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let s = String(data: blob, encoding: .utf8) else {
  dlog("readStreamedJSONL: cannot decode file at \(path)")
  return (rows, headers, keywords, meta)
 }
 
 let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
 let lastIdx = max(0, lines.count - 1)
 
 for (idx, line) in lines.enumerated() {
  let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { continue }
  if idx == lastIdx && !trimmed.hasSuffix("}") { continue }
  
  guard let data = trimmed.data(using: .utf8) else { continue }
  guard let objAny = try? JSONSerialization.jsonObject(with: data),
        let obj = objAny as? [String: Any] else {
   if idx != lastIdx { dlog("readStreamedJSONL decode error on line: \(trimmed.prefix(200))") }
   continue
  }
  
  if let p = obj["pl_out"] as? String { meta["pl_out"] = p }
  
  if let rh = obj["row_headers"] as? [String], !rh.isEmpty {
   headers = rh
   if !pendingRowArrays.isEmpty {
    for arr in pendingRowArrays { rows.append(mapRowArray(arr, using: headers)) }
    pendingRowArrays.removeAll()
   }
  }
  
  if let arr = obj["row"] as? [Any] {
   if !headers.isEmpty {
    rows.append(mapRowArray(arr, using: headers))
   } else {
    pendingRowArrays.append(arr)
   }
   continue
  }
  
  if obj["pos"] != nil || obj["compound"] != nil || obj["final_sentiment"] != nil {
   rows.append(obj)
   continue
  }
  
  if let rs = obj["rows"] as? [[String: Any]], !rs.isEmpty {
   rows.append(contentsOf: rs)
  }
  
  if let kcArr = obj["keywords_comp"] as? [[String: Any]], !kcArr.isEmpty { keywords = kcArr }
  
  if (obj["__meta__"] as? Bool) == true || obj["meta"] != nil || obj["status"] != nil {
   let m = (obj["meta"] as? [String: Any]) ?? [:]
   let status = (obj["status"] as? String) ?? (m["status"] as? String) ?? "running"
   if status.lowercased() == "running",
      let n = (m["processed"] as? Int) ?? (m["rows"] as? Int) {
    onProgress?(n)
   }
   for (k, v) in m { meta[k] = v }
   if meta["status"] == nil { meta["status"] = status }
   
   if headers.isEmpty, let rh = m["row_headers"] as? [String], !rh.isEmpty {
    headers = rh
    if !pendingRowArrays.isEmpty {
     for arr in pendingRowArrays { rows.append(mapRowArray(arr, using: headers)) }
     pendingRowArrays.removeAll()
    }
   }
   
   // Carry through stats/coverage/settings if present
   if let ks = obj["keyword_stats"] as? [[String: Any]] { keywordStats = ks }
   if let ks = m["keyword_stats"]   as? [[String: Any]], keywordStats.isEmpty { keywordStats = ks }
   if let cv = obj["coverage"]      as? [String: Any]   { coverageDict = cv }
   if let su = obj["settings_used"] as? [String: Any]   { settingsUsed = su }
   if let cv = m["coverage"]        as? [String: Any], coverageDict.isEmpty { coverageDict = cv }
   if let su = m["settings_used"]   as? [String: Any], settingsUsed.isEmpty { settingsUsed = su }
   
   // EVENTS: pass through from either top-level or nested meta
   if let ev = obj["events"] as? [[String: Any]], !ev.isEmpty {
    meta["events"] = ev
   }
   if let ev = m["events"] as? [[String: Any]],
      (meta["events"] as? [[String: Any]] ?? []).isEmpty {
    meta["events"] = ev
   }
  }
 }
 
 if headers.isEmpty, let first = rows.first {
  headers = Array(first.keys)
 }
 
 if !keywordStats.isEmpty { meta["keyword_stats"] = keywordStats }
 if !coverageDict.isEmpty { meta["coverage"]      = coverageDict }
 if !settingsUsed.isEmpty { meta["settings_used"] = settingsUsed }
 
 if meta["label_counts"] == nil {
  if let pc = (meta["pos_count"] as? Int) ?? (meta["positive"] as? Int),
     let nc = (meta["neg_count"] as? Int) ?? (meta["negative"] as? Int),
     let zc = (meta["neu_count"] as? Int) ?? (meta["neutral"] as? Int) {
   meta["label_counts"] = ["POSITIVE": pc, "NEGATIVE": nc, "NEUTRAL": zc]
  } else {
   var pos = 0, neg = 0, neu = 0
   for r in rows {
    let lab = ((r["final_sentiment"] as? String)
               ?? (r["model_label"] as? String)
               ?? (r["label"] as? String) ?? "NEUTRAL").uppercased()
    if lab.contains("POS") { pos += 1 }
    else if lab.contains("NEG") { neg += 1 }
    else { neu += 1 }
   }
   meta["label_counts"] = ["POSITIVE": pos, "NEGATIVE": neg, "NEUTRAL": neu]
  }
 }
 if meta["processed"] == nil { meta["processed"] = rows.count }
 if meta["total"]     == nil { meta["total"]     = rows.count }
 
 if meta["unavailable_reasons"] == nil { meta["unavailable_reasons"] = [] as [Any] }
 if meta["timeline"] == nil            { meta["timeline"] = [] as [Any] }
 if meta["status"] == nil              { meta["status"] = "final" }
 if meta["events"] == nil              { meta["events"] = [] as [Any] }
 
 dlog("readStreamedJSONL: rows=\(rows.count) headers=\(headers.count) kw=\(keywords.count) metaKeys=\(meta.keys.count) file=\(path) size=\(fileSize(at: path) ?? 0)")
 return (rows, headers, keywords, meta)
}

    // Internals
    private func ensureWorker() async -> Bool {
      if !isInitialized { await initializePython() }
      guard isInitialized, worker != nil else { return false }
      return true
    }


    func cancelActiveAnalysis() async {
      if let w = worker { await w.stop() }
      await MainActor.run {
        self.worker = nil
        self.isInitialized = false
      }
    }

    /// Gracefully stop the Python worker once results are shown.
    func shutdownWorkerAfterResults() {
      Task {
        await worker?.stop()
        await MainActor.run {
          self.worker = nil
          self.isInitialized = false
        }
      }
    }


    func killStalePythonIfAny() {
      if let pid = UserDefaults.standard.value(forKey: "PL_PY_PID") as? Int32 {
        _ = kill(pid_t(pid), SIGKILL)
        UserDefaults.standard.removeObject(forKey: "PL_PY_PID")
      }
    }
}
