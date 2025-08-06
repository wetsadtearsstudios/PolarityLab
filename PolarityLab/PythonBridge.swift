import Foundation
import PythonKit

/// Bridge between SwiftUI and the embedded Python sentiment script.
struct PythonBridge {
    private static var isInitialized = false

    /// Sets up Python runtime only once per launch.
    static func initializePython() {
        guard !isInitialized else { return }
        isInitialized = true
        guard let res = Bundle.main.resourcePath else {
            fatalError("Couldn't find Resources/")
        }

        // Point at embedded libpython
        let dylib = res + "/python310_embed/python-install/lib/libpython3.10.dylib"
        PythonLibrary.useLibrary(at: dylib)

        // Set PYTHONHOME so Python knows its home
        let pyRoot = res + "/python310_embed/python-install"
        setenv("PYTHONHOME", pyRoot, 1)

        // Inject Resources and site-packages onto sys.path
        let sys = Python.import("sys")
        sys.path.insert(0, res)
        sys.path.insert(0, pyRoot + "/lib/python3.10")
        sys.path.insert(0, pyRoot + "/lib/python3.10/site-packages")
        sys.path.insert(0, pyRoot + "/lib/python3.10/lib-dynload")
    }

    /// Runs `polarity_sentiment.py`, passing the chosen model enum to Python.
    static func runSentimentAnalysis(
        filePath: String,
        selectedCols: [String],
        skipRows: Int,
        mergeText: Bool,
        model: SentimentModel
    ) -> String {
        initializePython()

        // Debug: log which model key is passed
        print("🛠️ DEBUG Swift → passing model key: \(model.apiName)")

        // Import and invoke the Python script
        let script = Python.import("polarity_sentiment")
        let result = script.run_sentiment_analysis(
            filePath,
            selectedCols,
            skipRows,
            mergeText,
            model.apiName  // pass the clean API key, not the emoji rawValue
        )

        return String(result) ?? "[]"
    }
}

