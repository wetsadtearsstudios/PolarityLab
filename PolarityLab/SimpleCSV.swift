import Foundation

/// Loads a CSV without full quoted-comma support, but robustly handles Excel exports.
/// Prints detailed debug info on failures, and supports sandbox security-scoped URLs.
struct SimpleCSV {
    let url: URL
    let headers: [String]
    let previewRows: [[String:String]]
    let allRows: [[String:String]]

    /// - Parameters:
    ///   - url: file URL to the CSV (security-scoped if sandboxed)
    ///   - maxPreview: how many data rows to grab for preview
    init?(url: URL, maxPreview: Int = 5) {
        self.url = url
        print("🔍 SimpleCSV: Attempting to load \(url.path)")

        // 0️⃣ Start security scope if needed
        let didStart = url.startAccessingSecurityScopedResource()
        if !didStart {
            print("❌ SimpleCSV: couldn’t start security scope for \(url.path)")
            return nil
        }
        defer {
            url.stopAccessingSecurityScopedResource()
        }

        // 1️⃣ Read raw data
        let rawData: Data
        do {
            rawData = try Data(contentsOf: url)
            print("✅ SimpleCSV: Read \(rawData.count) bytes")
        } catch {
            print("❌ SimpleCSV: could not read data at \(url): \(error)")
            return nil
        }

        // 2️⃣ Try UTF-8, then UTF-16
        let text: String
        if let s = String(data: rawData, encoding: .utf8) {
            text = s
            print("✅ SimpleCSV: decoded as UTF-8")
        } else if let s = String(data: rawData, encoding: .utf16) {
            text = s
            print("✅ SimpleCSV: decoded as UTF-16")
        } else {
            print("❌ SimpleCSV: unsupported text encoding for \(url).")
            return nil
        }

        // 3️⃣ Strip BOM if present
        let bom = "\u{FEFF}"
        let stripped = text.hasPrefix(bom)
            ? String(text.dropFirst())
            : text
        if text.hasPrefix(bom) {
            print("ℹ️ SimpleCSV: dropped UTF-8 BOM")
        }

        // 4️⃣ Split into non-empty lines
        let rawLines = stripped
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        print("ℹ️ SimpleCSV: found \(rawLines.count) non-empty lines")

        guard rawLines.count > 1 else {
            print("❌ SimpleCSV: not enough lines (\(rawLines.count)) in \(url).")
            return nil
        }

        // 5️⃣ Detect delimiter
        let headerLine = rawLines[0]
        let delimiter: String
        if headerLine.contains(",") {
            delimiter = ","
        } else if headerLine.contains(";") {
            delimiter = ";"
        } else {
            print("❌ SimpleCSV: could not detect delimiter in header: “\(headerLine)”")
            return nil
        }
        print("✅ SimpleCSV: using delimiter “\(delimiter)”")

        // 6️⃣ Parse headers
        let cols = headerLine.components(separatedBy: delimiter)
        guard !cols.isEmpty else {
            print("❌ SimpleCSV: parsed zero columns from header.")
            return nil
        }
        headers = cols
        print("✅ SimpleCSV: headers = \(headers)")

        // 7️⃣ Helper to map a line into [header:value]
        func parseLine(_ line: String) -> [String:String] {
            let values = line.components(separatedBy: delimiter)
            var dict = [String:String]()
            for (i, header) in cols.enumerated() {
                dict[header] = i < values.count ? values[i] : ""
            }
            return dict
        }

        // 8️⃣ Build rows
        let dataLines = rawLines.dropFirst()
        allRows     = dataLines.map(parseLine)
        previewRows = Array(allRows.prefix(maxPreview))
        print("✅ SimpleCSV: parsed \(allRows.count) rows, previewing \(previewRows.count)")
    }
}
