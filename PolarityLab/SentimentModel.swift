enum SentimentModel: String, CaseIterable, Identifiable {
    case vader      = "⚡ VADER Only"
    case social     = "📣 Social-Media Model"
    case community  = "🏘️ Community-Trained Model"

    var id: String { rawValue }

    /// Description shown under each picker row
    var description: String {
        switch self {
        case .vader:
            return "Fast & lightweight. General insights."
        case .social:
            return "Optimized for tweets, posts, comments."
        case .community:
            return "Tailored to community & forum language."
        }
    }

    /// The exact key we send to Python
    var apiName: String {
        switch self {
        case .vader:     return "vader"
        case .social:    return "social"
        case .community: return "community"
        }
    }
}
