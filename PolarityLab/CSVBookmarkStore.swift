//
//  CSVBookmarkedStore.swift
//  PolarityLab
//
//  Replaces the old `CSVDocument` (which conflicted with exports).
//  This is **not** a FileDocument; it’s just a helper to load/save
//  a default “data.csv” in the user-bookmarked folder.
//

import Foundation

struct CSVBookmarkedStore {
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }
}

extension CSVBookmarkedStore {

    /// Loads **data.csv** from the bookmark folder.
    /// The completion is always delivered on the main queue.
    static func loadDefault(presenter: AnyObject? = nil,
                            completion: @escaping (Result<CSVBookmarkedStore, Error>) -> Void) {
        CSVFolderAccess.withFolder(presenter: presenter) { folderURL in
            guard folderURL.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async {
                    completion(.failure(CocoaError(.fileReadNoPermission)))
                }
                return
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = folderURL.appendingPathComponent("data.csv")
                    let d = try Data(contentsOf: url)
                    DispatchQueue.main.async { completion(.success(.init(data: d))) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }

    /// Saves this store’s `data` back to **data.csv** in the bookmark folder.
    /// The completion is always delivered on the main queue.
    func saveDefault(presenter: AnyObject? = nil,
                     completion: @escaping (Result<Void, Error>) -> Void) {
        CSVFolderAccess.withFolder(presenter: presenter) { folderURL in
            guard folderURL.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async {
                    completion(.failure(CocoaError(.fileWriteNoPermission)))
                }
                return
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = folderURL.appendingPathComponent("data.csv")
                    try self.data.write(to: url, options: .atomic)
                    DispatchQueue.main.async { completion(.success(())) }
                } catch {
                    DispatchQueue.main.async { completion(.failure(error)) }
                }
            }
        }
    }
}
