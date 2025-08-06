// CSVDocument.swift

import SwiftUI
import UniformTypeIdentifiers

/// A simple CSV wrapper so we can both import and export CSV files.
struct CSVDocument: FileDocument {
    // 1) Declare the content types we support
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }

    // 2) The raw data of the CSV
    var data: Data

    // 3) Init from disk (import)
    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = fileData
    }

    // 4) Init by hand (export)
    init(data: Data) {
        self.data = data
    }

    // 5) Export handler
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return .init(regularFileWithContents: data)
    }
}
