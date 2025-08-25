import SwiftUI
import os
import Darwin

@main
struct PolarityLabApp: App {
 @StateObject private var settings = SettingsStore.shared
 private let log = Logger(subsystem: "ca.polaritylab.app", category: "lifecycle")
 
 init() {
  // Force-create log file + hard markers (always)
  let bid = Bundle.main.bundleIdentifier ?? "nil"
  let pid = getpid()
  let logPath = FileLogger.shared.path
  dlog("APP INIT — pid=\(pid) bid=\(bid)")
  dlog("LOG FILE → \(logPath)")
  FileLogger.shared.write("--- APP INIT MARKER ---")
  
  // Keep user-controlled flag (optional OSLog noise)
  if UserDefaults.standard.object(forKey: "verboseLogs") == nil {
   UserDefaults.standard.set(false, forKey: "verboseLogs")
  }
  if UserDefaults.standard.bool(forKey: "verboseLogs") {
   log.info("🚀 PolarityLabApp launched")
  }
  
  // Theme application
  DispatchQueue.main.async {
   SettingsStore.shared.applyTheme()
  }
 }
 
 var body: some Scene {
  WindowGroup {
   MainView()
    .environmentObject(settings)
    .onAppear {
     settings.applyTheme()
     dlog("MainView onAppear")
    }
  }
 }
}
