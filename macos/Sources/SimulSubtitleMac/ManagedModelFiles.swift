import Foundation

/// Model manifests list the app's payloads. Other files in the same folder belong to the user.
struct ManagedModelFiles {
    let folder: URL
    let filenames: [String]

    private var existingFiles: [URL] {
        filenames.flatMap { [$0, $0 + ".sha256"] }.map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var hasFiles: Bool { !existingFiles.isEmpty }

    @discardableResult
    func moveToTrash() throws -> [URL] {
        let manager = FileManager.default
        let files = existingFiles
        guard !files.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        // Never follow a redirected model folder or discard a directory disguised as a model.
        guard !(try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false),
              try files.allSatisfy({ try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        var moved: [(source: URL, trash: URL)] = []
        do {
            for file in files {
                var destination: NSURL?
                try manager.trashItem(at: file, resultingItemURL: &destination)
                guard let destination else { throw CocoaError(.fileWriteUnknown) }
                moved.append((file, destination as URL))
            }
        } catch {
            // If one component fails, put previously moved components back in place.
            var rollbackError: Error?
            for item in moved.reversed() {
                do { try manager.moveItem(at: item.trash, to: item.source) }
                catch { rollbackError = error }
            }
            throw rollbackError ?? error
        }
        return moved.map(\.trash)
    }
}
