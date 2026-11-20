import Foundation
import Testing

@Suite("App mover")
struct AppMoverTests {
    private func makeApp(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appending(path: "Contents/marker"))
    }

    private func marker(in app: URL) throws -> String {
        try String(contentsOf: app.appending(path: "Contents/marker"), encoding: .utf8)
    }

    @Test func copiesIntoAnEmptyFolder() throws {
        let home = try TemporaryHome()
        let source = home.url.appending(path: "Volume/Brew Updates.app")
        let destination = home.url.appending(path: "Applications/Brew Updates.app")
        try makeApp(at: source, marker: "new")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        try AppMover(source: source, destination: destination) { try FileManager.default.removeItem(at: $0) }.move()

        #expect(try marker(in: destination) == "new")
        // The source stays (it's on a read-only disk image in real use)
        #expect(FileManager.default.fileExists(atPath: source.path))
        // No staging copy left behind
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Brew Updates.app"])
    }

    @Test func replacesAnOlderCopy() throws {
        let home = try TemporaryHome()
        let source = home.url.appending(path: "Volume/Brew Updates.app")
        let destination = home.url.appending(path: "Applications/Brew Updates.app")
        try makeApp(at: source, marker: "new")
        try makeApp(at: destination, marker: "old")
        let discarded = LockedList()

        try AppMover(source: source, destination: destination) { url in
            discarded.append(url)
            try FileManager.default.removeItem(at: url)
        }.move()

        #expect(try marker(in: destination) == "new")
        #expect(discarded.items == [destination])
    }

    @Test func failedCopyLeavesTheOldCopy() throws {
        let home = try TemporaryHome()
        let missing = home.url.appending(path: "Volume/Brew Updates.app")
        let destination = home.url.appending(path: "Applications/Brew Updates.app")
        try makeApp(at: destination, marker: "old")

        #expect(throws: (any Error).self) {
            try AppMover(source: missing, destination: destination) { try FileManager.default.removeItem(at: $0) }.move()
        }
        #expect(try marker(in: destination) == "old")
    }
}

/// Collects URLs from the `@Sendable` discard closure
private final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var items: [URL] { lock.withLock { storage } }
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
}
