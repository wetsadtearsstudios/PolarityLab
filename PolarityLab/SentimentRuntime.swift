import SwiftUI

@MainActor
final class SentimentRuntime: ObservableObject {
    static let shared = SentimentRuntime()

    enum Status: Equatable {
        case idle
        case warming(model: SentimentModel, index: Int, total: Int)
        case ready(Set<SentimentModel>)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    private var ready: Set<SentimentModel> = []
    private var warming = false

    func ensureReady(for model: SentimentModel) async {
        if ready.contains(model) { return }
        if warming { return } // already warming all
        await prewarmAll(startWith: model)
    }

    func prewarmAll(startWith first: SentimentModel) async {
        if warming { return }
        warming = true
        let order = [first] + SentimentModel.allCases.filter { $0 != first }
        let total = order.count

        for (i, m) in order.enumerated() {
            status = .warming(model: m, index: i + 1, total: total)
            await PythonBridge.shared.ensureReady(for: m) // ← Void; just await it
            ready.insert(m)
        }

        status = .ready(ready)
        warming = false
    }

    func isModelReady(_ m: SentimentModel) -> Bool { ready.contains(m) }
}
