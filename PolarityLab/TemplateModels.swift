import Foundation
import UniformTypeIdentifiers

// MARK: - Modes

enum TemplateEditorModel: String, Codable, CaseIterable, Identifiable {
    case vader       // scores in [-4, +4]
    case domainBias  // scores in [-1, +1]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vader: return "VADER Lexicon"
        case .domainBias: return "Domain Keyword Bias"
        }
    }

    var shortName: String {
        switch self {
        case .vader: return "VADER"
        case .domainBias: return "Bias"
        }
    }

    var scoreRange: ClosedRange<Double> {
        switch self {
        case .vader: return -4.0...4.0
        case .domainBias: return -1.0...1.0
        }
    }
}

// MARK: - Data models

struct LexiconEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var phrase: String
    var score: Double
}

struct LexiconTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var mode: TemplateEditorModel
    var items: [LexiconEntry]

    var displayName: String { name.isEmpty ? "Untitled" : name }
}

// MARK: - Validation & mapping

enum TemplateValidationError: Error, LocalizedError {
    case invalidHeaders
    case outOfRange(phrase: String, value: Double, allowed: ClosedRange<Double>)
    case invalidNumber(phrase: String, raw: String)

    var errorDescription: String? {
        switch self {
        case .invalidHeaders:
            return "CSV must include exactly two headers: “Keywords/Phrases” and “Score”."
        case let .outOfRange(phrase, value, allowed):
            return "Score for “\(phrase)” is \(value). Allowed range is \(allowed.lowerBound) to \(allowed.upperBound)."
        case let .invalidNumber(phrase, raw):
            return "Score for “\(phrase)” is not a valid number: “\(raw)”."
        }
    }
}

// Map score across modes
func mapScore(_ score: Double, from src: TemplateEditorModel, to dst: TemplateEditorModel) -> Double {
    if src == dst { return score }
    switch (src, dst) {
    case (.vader, .domainBias):
        return min(max(score / 4.0, -1.0), 1.0)
    case (.domainBias, .vader):
        return min(max(score * 4.0, -4.0), 4.0)
    default:
        return score
    }
}
