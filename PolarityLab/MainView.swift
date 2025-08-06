import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case sentiment = "Sentiment Analysis"
    case vader     = "VADER Lexicon"
    case templates = "Custom Lexicon Templates"
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

struct MainView: View {
    @State private var selection: SidebarItem? = .sentiment

    var body: some View {
        NavigationSplitView {
            VStack {
                // ─── Nav items ─────────────────────────────────
                List(selection: $selection) {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(item)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 200)

                Spacer()

                // ─── Support links ─────────────────────────────
                VStack(spacing: 4) {
                    Link("Contact Support", destination: URL(string: "mailto:support@yourapp.com")!)
                    Link("Help Documents",   destination: URL(string: "https://yourapp.com/help")!)
                    Link("Give Feedback",    destination: URL(string: "https://yourapp.com/feedback")!)
                }
                .font(.footnote)
                .padding(.bottom, 12)

                // ─── App logo ──────────────────────────────────
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 100)
                    .padding(.bottom, 16)
            }
        } detail: {
            Group {
                switch selection {
                case .sentiment:
                    SentimentAnalysisView()
                case .vader:
                    LexiconView()
                case .templates:
                    CustomTemplatesView()
                case .settings:
                    SettingsView()
                case .none:
                    Text("Select a section")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
    }
}

struct MainView_Previews: PreviewProvider {
    static var previews: some View {
        MainView()
    }
}
