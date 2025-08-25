import SwiftUI
import Combine

// Warm-up notification to preload models when Playground opens.
extension Notification.Name {
 static let plRequestPreload = Notification.Name("PLRequestPreload")
}

enum SidebarItem: String, CaseIterable, Identifiable {
 case sentiment = "Sentiment Analysis"
 case vader     = "Sentiment Playground"
 case templates = "Templates"
 case settings  = "Settings"
 
 var id: String { rawValue }
 var icon: String {
  switch self {
  case .sentiment: return "waveform.path.ecg"
  case .vader:     return "book"
  case .templates: return "square.grid.2x2"
  case .settings:  return "gearshape"
  }
 }
}

// Compact tile with a clear outline
private struct SidebarTile: View {
 let item: SidebarItem
 let selected: Bool
 let disabled: Bool
 
 var body: some View {
  VStack(spacing: 6) {
   Image(systemName: item.icon)
    .font(.system(size: 22, weight: .semibold))
   Text(item.rawValue)
    .font(.system(size: 12, weight: .medium))
    .multilineTextAlignment(.center)
    .lineLimit(2)
    .minimumScaleFactor(0.85)
  }
  .padding(10)
  .frame(maxWidth: .infinity, minHeight: 88)
  .background(
   RoundedRectangle(cornerRadius: 12, style: .continuous)
    .fill(.ultraThinMaterial)
  )
  .overlay(
   RoundedRectangle(cornerRadius: 12, style: .continuous)
    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.35),
            lineWidth: selected ? 2 : 1)
  )
  .opacity(disabled ? 0.6 : 1.0)
  .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
 }
}

struct MainView: View {
 @State private var selection: SidebarItem? = .sentiment
 @State private var isRunning = false   // disables nav while analysis runs
 @State private var uiLocked = false    // lock from AnalyzingView
 
 private var versionString: String {
  let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
  let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
  return b.isEmpty ? "v\(v)" : "v\(v) (\(b))"
 }
 
 var body: some View {
  NavigationSplitView {
   sidebar
  } detail: {
   detail
    .frame(minWidth: 600, minHeight: 400)
  }
  // Keep original pipeline wiring
  .onReceive(NotificationCenter.default.publisher(for: .plProgress)) { note in
   if let s = note.userInfo?["status"] as? String {
    isRunning = (s == "initializing" || s == "running")
   }
  }
  .onReceive(NotificationCenter.default.publisher(for: .plDone)) { _ in
   isRunning = false
  }
  // Listen for UI lock/unlock from AnalyzingView overlay
  .onReceive(NotificationCenter.default.publisher(for: .plUILockSidebar)) { note in
    let lock = (note.userInfo?["lock"] as? Bool) ?? true
    uiLocked = lock
    if !lock { isRunning = false }
  }
  // Warm up models exactly when Playground is selected
  .onChange(of: selection) { newValue in
   if newValue == .vader {
    NotificationCenter.default.post(name: .plRequestPreload, object: nil)
   }
  }
  // Narrower column so there is less gray on sides
  .navigationSplitViewColumnWidth(min: 144, ideal: 150)
 }
 
 // MARK: - Sidebar (tight; minimal side gray)
 @ViewBuilder private var sidebar: some View {
  VStack(spacing: 0) {
   ScrollView {
    VStack(spacing: 8) { // small gap BETWEEN tiles only
     ForEach(SidebarItem.allCases) { item in
      Button {
       if !(isRunning || uiLocked) { selection = item }
       if item == .vader {
        NotificationCenter.default.post(name: .plRequestPreload, object: nil)
       }
      } label: {
       SidebarTile(item: item, selected: selection == item, disabled: (isRunning || uiLocked))
      }
      .buttonStyle(.plain)
     }
    }
    // remove default scroll margins and keep a very small edge inset
#if os(macOS)
    .contentMargins(.horizontal, 0, for: .scrollContent)
#endif
    .padding(.horizontal, 6) // less gray on either side
    .padding(.top, 8)
    .padding(.bottom, 8)
   }
   .disabled(isRunning || uiLocked)
   .frame(minWidth: 144)
   
   Spacer(minLength: 0)
   Divider()
   
   VStack(spacing: 4) {
    Link("Contact Support", destination: URL(string: "mailto:polaritylab@icloud.com")!)
    Link("Help Documents", destination: URL(string: "https://polaritylab.notion.site/Help-Documents-24bd373f4da2802d9ab1dd202f57a328?pvs=73")!)
    Link("Legal & Compliance", destination: URL(string: "https://polaritylab.notion.site/Legal-Compliance-24bd373f4da280a4849ffd580b9e838a")!)
    Link("Give Feedback or Report a Bug",
         destination: URL(string: "https://docs.google.com/forms/d/e/1FAIpQLScovQIGPVX10SZSFmpFMtOdpq29_ceGS1fpsKl4a2iSHFoGHA/viewform?usp=dialog")!)
   }
   .font(.footnote)
   .padding(.bottom, 12)
   
   VStack(spacing: 6) {
    Image("AppLogo")
     .resizable()
     .scaledToFit()
     .frame(width: 90, height: 90)
    Text(versionString)
     .font(.caption)
     .foregroundStyle(.secondary)
   }
   .padding(.bottom, 16)
  }
 }
 
 // MARK: - Detail
 @ViewBuilder private var detail: some View {
  switch selection {
  case .sentiment:
   SentimentAnalysisView()
  case .vader:
   LexiconView()                 // rename if your playground view has a different type name
  case .templates:
   CustomTemplatesView()
  case .settings:
   SettingsView()
  case .none:
   Text("Select a section").foregroundStyle(.secondary)
  }
 }
}

struct MainView_Previews: PreviewProvider {
 static var previews: some View {
  MainView()
 }
}
