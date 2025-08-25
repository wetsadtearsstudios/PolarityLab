// SimpleCSV.swift
import Foundation

/// Lightweight CSV loader optimized for *preview*.
/// - Detects delimiter (comma / semicolon / tab)
/// - Handles RFC-4180 quotes (embedded commas / CRLFs)
/// - UTF-8±BOM / UTF-16 LE/BE / CP1252 / ISO-8859-1
/// - Strips basic HTML tags in cells
struct SimpleCSV {

    // Public API
    let url: URL
    let headers: [String]                 // never empty
    let previewRows: [[String: String]]   // first N rows only
    let totalRows: Int                    // total non-empty data rows

    // Back-compat alias (older code referenced `allRows`)
    var allRows: [[String: String]] { previewRows }

    /// Returns nil if header row can’t be parsed.
    init?(url: URL, maxPreview: Int = 5) {
        self.url = url

        // Security scope
        let unlocked = url.startAccessingSecurityScopedResource()
        defer { if unlocked { url.stopAccessingSecurityScopedResource() } }

        guard let rawData = try? Data(contentsOf: url) else { return nil }
        guard var text = SimpleCSV.decode(data: rawData) else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() } // strip UTF-8 BOM

        // Physical lines (keep empties)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first else { return nil }

        // Delimiter from first line
        let delimiter: Character = [",", ";", "\t"].max { a, b in
            first.filter { $0 == a }.count < first.filter { $0 == b }.count
        } ?? ","

        // Streaming parse (don’t materialize full table)
        var _headers: [String]? = nil
        var _preview: [[String:String]] = []
        var _total = 0

        var inQuotes = false
        var currentRow = [String]()
        var currentField = ""

        func sanitize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
             .replacingOccurrences(of: #"<[^>]+>"#,
                                   with: "",
                                   options: [.regularExpression, .caseInsensitive])
        }
        func endField() {
            currentRow.append(sanitize(currentField))
            currentField.removeAll(keepingCapacity: true)
        }
        func endRecord() {
            // ignore pure-empty
            if currentRow.count == 1, currentRow[0].isEmpty { currentRow.removeAll(); return }

            if _headers == nil {
                _headers = currentRow.map { $0.isEmpty ? "<empty>" : $0 }
            } else if let hdrs = _headers {
                var dict: [String:String] = [:]
                for (i, h) in hdrs.enumerated() { dict[h] = i < currentRow.count ? currentRow[i] : "" }
                if dict.values.contains(where: { !$0.isEmpty }) {
                    _total &+= 1
                    if _preview.count < maxPreview { _preview.append(dict) }
                }
            }
            currentRow.removeAll(keepingCapacity: true)
        }

        var it = lines.makeIterator()
        while let line = it.next() {
            var li = line.makeIterator()
            while let ch = li.next() {
                switch ch {
                case "\"":
                    if inQuotes, let n = li.next(), n == "\"" {
                        currentField.append("\"")
                    } else {
                        inQuotes.toggle()
                    }
                case delimiter where !inQuotes:
                    endField()
                default:
                    currentField.append(ch)
                }
            }
            if inQuotes {
                currentField.append("\n")
            } else {
                endField(); endRecord()
            }
        }

        guard let hdrs = _headers, !hdrs.isEmpty else { return nil }
        self.headers = hdrs
        self.previewRows = _preview
        self.totalRows = _total

        // Silent by default. Use dlog to avoid dumping rows.
        dlog("CSV preview headers=\(headers.count) rows=\(previewRows.count)")
    }

    private static func decode(data: Data) -> String? {
        if data.starts(with: [0xEF,0xBB,0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF,0xFE])     { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE,0xFF])     { return String(data: data, encoding: .utf16BigEndian) }
        for enc in [.utf8, .utf16LittleEndian, .utf16BigEndian, .windowsCP1252, .isoLatin1] as [String.Encoding] {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return nil
    }
}
