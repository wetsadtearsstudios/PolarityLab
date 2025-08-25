import Foundation

// RFC-4180-ish parsing for two columns, with very light quoting support.
struct ParsedCSV {
    let headers: [String]
    let rows: [[String]]
}

func parseCSV(_ data: Data) -> ParsedCSV? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var lines = text.split(whereSeparator: \.isNewline).map(String.init)

    guard let headerLine = lines.first else { return nil }
    let headers = splitCSVLine(headerLine)
    let rows = lines.dropFirst().map { splitCSVLine($0) }
    return ParsedCSV(headers: headers, rows: rows)
}

private func splitCSVLine(_ line: String) -> [String] {
    // basic split that respects double quotes
    var fields: [String] = []
    var cur = ""
    var inQuotes = false
    var chars = Array(line)
    var i = 0
    while i < chars.count {
        let ch = chars[i]
        if ch == "\"" {
            if inQuotes, i + 1 < chars.count, chars[i+1] == "\"" {
                // escaped quote
                cur.append("\"")
                i += 2
                continue
            } else {
                inQuotes.toggle()
                i += 1
                continue
            }
        } else if ch == "," && !inQuotes {
            fields.append(cur)
            cur = ""
            i += 1
            continue
        } else {
            cur.append(ch)
            i += 1
        }
    }
    fields.append(cur)
    return fields
}

func csvLineEscape(_ s: String) -> String {
    var v = s.replacingOccurrences(of: "\"", with: "\"\"")
    if v.contains(",") || v.contains("\n") || v.contains("\r") || v.contains("\"") {
        v = "\"\(v)\""
    }
    return v
}

func makeCSVData(from entries: [LexiconEntry]) -> Data {
    var lines: [String] = ["Keywords/Phrases,Score"]
    for e in entries {
        lines.append("\(csvLineEscape(e.phrase)),\(String(format: "%.4f", e.score))")
    }
    return Data(lines.joined(separator: "\n").utf8)
}

func makeTemplatesCSVTemplateData() -> Data {
    let sample = """
Keywords/Phrases,Score
great,+1
awful,-1
"not good",-0.6
"""
    return Data(sample.utf8)
}
