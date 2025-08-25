import AppKit

/// Manages user-granted access to the folder that holds your CSV files.
enum CSVFolderAccess {

    // MARK: – Public API
    /// A URL that is already authorised, or `nil` if we still need to ask.
    static var authorisedFolder: URL? {
        restoredFolderURL()
    }

    /// Presents `NSOpenPanel` once, stores a security-scoped bookmark,
    /// and returns the chosen folder (or `nil` on cancel / failure).
    @discardableResult
    static func requestFolder(from window: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder that contains your CSV files"
        panel.prompt = "Choose"
        panel.canChooseFiles         = false
        panel.canChooseDirectories   = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // We *must* keep the scope open while saving the bookmark.
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }

        if let bm = try? url.bookmarkData(options: .withSecurityScope,
                                          includingResourceValuesForKeys: nil,
                                          relativeTo: nil) {
            try? bm.write(to: bookmarkFileURL())
        }
        return url
    }

    /// **Convenience** – gets (or asks for) the folder, guarantees the URL
    /// is ready for access, then calls your handler *on the main queue*.
    ///
    /// ```swift
    /// CSVFolderAccess.withFolder { folder in
    ///     // use `folder` here – remember to stopAccessing when done
    /// }
    /// ```
    static func withFolder(presenter: AnyObject? = nil,
                           _ handler: @escaping (URL) -> Void) {

        // 1️⃣ Already authorised?  Great – use it right away.
        if let url = authorisedFolder {
            DispatchQueue.main.async { handler(url) }
            return
        }

        // 2️⃣ Otherwise ask the user.  This must run on the main thread.
        DispatchQueue.main.async {
            let window =
                (presenter as? NSWindow)
                ?? (presenter as? NSViewController)?.view.window

            guard let url = requestFolder(from: window) else { return }
            // We *closed* the scope in requestFolder – reopen it for the caller.
            guard url.startAccessingSecurityScopedResource() else { return }
            handler(url)
        }
    }

    // MARK: – Internal helpers
    private static func restoredFolderURL() -> URL? {
        guard let data = try? Data(contentsOf: bookmarkFileURL()) else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              bookmarkDataIsStale: &stale),
           !stale,
           url.startAccessingSecurityScopedResource() {
            return url
        }
        return nil
    }

    private static func bookmarkFileURL() -> URL {
        let support = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
        return support.appending(path: "csvFolder.bookmark")
    }
}
