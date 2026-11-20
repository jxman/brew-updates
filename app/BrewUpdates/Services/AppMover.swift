import Foundation

/// Copies the app into Applications, replacing an older copy, for `AppLocation` problems.
///
/// The copy goes to a hidden name next to the destination first and is renamed into place
/// only once complete, so a failed copy (a full disk, no permission) leaves any existing
/// copy untouched. An existing copy goes to the Trash, not deleted.
struct AppMover: Sendable {
    typealias Discard = @Sendable (URL) throws -> Void

    let source: URL
    let destination: URL
    private let discard: Discard

    init(source: URL, destination: URL, discard: @escaping Discard = AppUninstaller.moveToTrash) {
        self.source = source
        self.destination = destination
        self.discard = discard
    }

    /// Copies `source` to `destination` and returns `destination`
    @discardableResult
    func move() throws -> URL {
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).moving")
        try? fileManager.removeItem(at: staging)
        // copyItem keeps the code signature and extended attributes, so macOS still
        // recognises the copy as the notarized app the user already allowed to open
        try fileManager.copyItem(at: source, to: staging)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try discard(destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return destination
    }
}
