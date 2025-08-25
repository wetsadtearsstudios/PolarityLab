//
//  FileDocuments.swift
//  PolarityLab
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Canonical CSV file document

/// Single, canonical CSV document you should use everywhere.
struct AppCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.commaSeparatedText]
    static var writableContentTypes: [UTType] = [.commaSeparatedText]

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        if let d = configuration.file.regularFileContents {
            self.data = d
        } else {
            self.data = Data()
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Canonical JSON file document (for templates/exports)

struct TemplateJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.json]
    static var writableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        if let d = configuration.file.regularFileContents {
            self.data = d
        } else {
            self.data = Data()
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
