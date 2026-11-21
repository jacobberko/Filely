import Foundation
import XCTest
@testable import FilerCore

final class IndexRefreshTests: XCTestCase {
    private let manager = FileManager.default

    private func makeFolder() throws -> URL {
        let root = manager.temporaryDirectory.appendingPathComponent("FilerRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL, modifiedAt: Date? = nil) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modifiedAt { try manager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path) }
    }

    func testMatchingMetadataReusesContentUntilAnExplicitChangeInvalidatesIt() async throws {
        let root = try makeFolder()
        defer { try? manager.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        // Subsecond filesystem timestamps can lose ~100 ns when converted
        // through Date/setAttributes. Use an exact timestamp for this fixture.
        try write("Alpha", to: file, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let indexer = FolderIndexer()
        let initial = await indexer.index(folder: root)
        let old = try XCTUnwrap(initial.files.first)

        // Some editors/import tools preserve both timestamp and byte count.
        // The watcher event is the only available indication of this change.
        try write("Bravo", to: file, modifiedAt: old.modifiedAt)
        let rewritten = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        XCTAssertEqual(rewritten.contentModificationDate, old.modifiedAt)
        XCTAssertEqual(rewritten.fileSize.map(Int64.init), old.fileSize)
        let withoutEvent = await indexer.index(folder: root, previousFiles: initial.files)
        XCTAssertEqual(withoutEvent.files.first?.contentExcerpt, "Alpha")

        let withEvent = await indexer.index(folder: root, previousFiles: initial.files,
                                            invalidatedPaths: [file.path])
        XCTAssertEqual(withEvent.files.first?.contentExcerpt, "Bravo")
    }

    func testRefreshReflectsCreatesEditsRenamesAndDeletions() async throws {
        let root = try makeFolder()
        defer { try? manager.removeItem(at: root) }
        let edited = root.appendingPathComponent("edited.txt")
        let renamed = root.appendingPathComponent("old-name.txt")
        let deleted = root.appendingPathComponent("deleted.txt")
        try write("Initial", to: edited)
        try write("Rename contents", to: renamed)
        try write("Remove contents", to: deleted)
        let indexer = FolderIndexer()
        let initial = await indexer.index(folder: root)
        let original = try XCTUnwrap(initial.files.first { $0.url == edited })

        // Same length, different modification time: metadata alone refreshes it.
        try write("Updated", to: edited, modifiedAt: original.modifiedAt.addingTimeInterval(60))
        let newName = root.appendingPathComponent("new-name.txt")
        try manager.moveItem(at: renamed, to: newName)
        try manager.removeItem(at: deleted)
        try write("New document", to: root.appendingPathComponent("created.txt"))

        let refreshed = await indexer.index(folder: root, previousFiles: initial.files)
        XCTAssertEqual(Set(refreshed.files.map(\.name)), ["edited.txt", "new-name.txt", "created.txt"])
        XCTAssertEqual(refreshed.files.first { $0.url == edited }?.contentExcerpt, "Updated")
        XCTAssertEqual(refreshed.files.first { $0.url == newName }?.contentExcerpt, "Rename contents")
    }

    func testDirectoryInvalidationCoversDescendantsWithoutInvalidatingSiblingPrefixes() async throws {
        let root = try makeFolder()
        defer { try? manager.removeItem(at: root) }
        let directory = root.appendingPathComponent("drafts", isDirectory: true)
        let neighbor = root.appendingPathComponent("drafts-other", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.createDirectory(at: neighbor, withIntermediateDirectories: true)
        let nested = directory.appendingPathComponent("notes.txt")
        let other = neighbor.appendingPathComponent("notes.txt")
        let preservedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try write("Alpha", to: nested, modifiedAt: preservedDate)
        try write("Alpha", to: other, modifiedAt: preservedDate)
        let indexer = FolderIndexer()
        let initial = await indexer.index(folder: root)
        for old in initial.files {
            try write("Bravo", to: old.url, modifiedAt: old.modifiedAt)
            let rewritten = try old.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            XCTAssertEqual(rewritten.contentModificationDate, old.modifiedAt)
            XCTAssertEqual(rewritten.fileSize.map(Int64.init), old.fileSize)
        }

        // Use the resolved path to also exercise /var versus /private/var aliases.
        let result = await indexer.index(folder: root, previousFiles: initial.files,
                                         invalidatedPaths: [directory.resolvingSymlinksInPath().path])
        XCTAssertEqual(result.files.first { $0.url == nested }?.contentExcerpt, "Bravo")
        XCTAssertEqual(result.files.first { $0.url == other }?.contentExcerpt, "Alpha")
    }

    func testMetadataOnlyCachedRecordIsReExtractedWhenContentIsAvailable() async throws {
        let root = try makeFolder()
        defer { try? manager.removeItem(at: root) }
        try write("Locally available document", to: root.appendingPathComponent("downloaded.txt"))
        let indexer = FolderIndexer()
        let initial = await indexer.index(folder: root)
        let file = try XCTUnwrap(initial.files.first)
        let metadataOnly = IndexedFile(url: file.url, contentExcerpt: "", modifiedAt: file.modifiedAt,
                                       fileSize: file.fileSize, typeLabel: file.typeLabel)
        let refreshed = await indexer.index(folder: root, previousFiles: [metadataOnly])
        XCTAssertEqual(refreshed.files.first?.contentExcerpt, "Locally available document")
    }

    func testCachedExcerptRespectsCurrentExtractionLimits() async throws {
        let root = try makeFolder()
        defer { try? manager.removeItem(at: root) }
        try write(String(repeating: "alpha ", count: 400), to: root.appendingPathComponent("large.txt"))
        let initial = await FolderIndexer().index(folder: root)
        XCTAssertGreaterThan(try XCTUnwrap(initial.files.first).contentExcerpt.count, 256)

        let shortened = await FolderIndexer(maximumTextCharacters: 256).index(folder: root, previousFiles: initial.files)
        XCTAssertLessThanOrEqual(try XCTUnwrap(shortened.files.first).contentExcerpt.count, 256)
        let oversized = await FolderIndexer(maximumContentBytes: 1_024).index(folder: root, previousFiles: initial.files)
        XCTAssertEqual(oversized.files.first?.contentExcerpt, "")
    }
}
