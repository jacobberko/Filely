import Foundation
import XCTest
@testable import FilerCore

final class FolderChangeMonitorTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilerWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Use physical paths so expected deleted paths retain their identity.
        let resolved = try XCTUnwrap(root.path.withCString { realpath($0, nil) })
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Timed out waiting for a folder event", file: file, line: line)
    }

    private func path(_ url: URL) -> String { url.path }

    @MainActor
    func testRecursiveCreateEditRenameAndDeleteInvalidateExactFiles() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("work/drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        var changes: [FolderChangeBatch] = []
        let monitor = FolderChangeMonitor(debounceInterval: 0.15) { changes.append($0) }
        XCTAssertTrue(monitor.setFolders([root]))
        defer { monitor.stop() }
        let file = nested.appendingPathComponent("resume.txt")
        try write("Original resume", to: file)
        // Applying an unchanged selection must not discard a pending change.
        XCTAssertTrue(monitor.setFolders([root]))
        try await waitUntil { changes.contains { $0.invalidatedPaths.contains(self.path(file)) } }
        XCTAssertTrue(changes.allSatisfy { $0.roots == [root.standardizedFileURL] })
        changes.removeAll()

        try write("Updated resume", to: file)
        try await waitUntil { changes.contains { $0.invalidatedPaths.contains(self.path(file)) } }
        XCTAssertFalse(changes.contains { $0.invalidatedPaths.contains(self.path(root)) },
                       "A file edit should not invalidate all cached content in the selected root")
        changes.removeAll()

        let renamed = nested.appendingPathComponent("resume-final.txt")
        try FileManager.default.moveItem(at: file, to: renamed)
        try await waitUntil {
            let invalidated = changes.reduce(into: Set<String>()) { $0.formUnion($1.invalidatedPaths) }
            return invalidated.contains(self.path(file)) && invalidated.contains(self.path(renamed))
        }
        changes.removeAll()

        try FileManager.default.removeItem(at: renamed)
        try await waitUntil { changes.contains { $0.invalidatedPaths.contains(self.path(renamed)) } }
    }

    @MainActor
    func testDirectoryRenameInvalidatesItsSubtreeAndBurstIsCoalesced() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("Inside directory", to: directory.appendingPathComponent("notes.txt"))
        var changes: [FolderChangeBatch] = []
        let monitor = FolderChangeMonitor(debounceInterval: 0.3) { changes.append($0) }
        XCTAssertTrue(monitor.setFolders([root]))
        defer { monitor.stop() }
        let renamed = root.appendingPathComponent("new", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: renamed)
        let files = (0..<15).map { renamed.appendingPathComponent("document-\($0).txt") }
        for file in files { try write("New file", to: file) }
        try await waitUntil {
            changes.contains { batch in
                batch.invalidatedPaths.contains(self.path(directory)) &&
                batch.invalidatedPaths.contains(self.path(renamed))
            }
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(changes.count, 1, "A short burst should produce one refresh")
    }

    @MainActor
    func testStopAndSelectionReplacementSuppressOldCallbacks() async throws {
        let first = try makeFolder()
        let second = try makeFolder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        var changes: [FolderChangeBatch] = []
        let monitor = FolderChangeMonitor(debounceInterval: 0.3) { changes.append($0) }
        XCTAssertTrue(monitor.setFolders([first]))
        try write("Queued before stopping", to: first.appendingPathComponent("pending.txt"))
        try await Task.sleep(for: .milliseconds(100))
        monitor.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(changes.isEmpty)

        XCTAssertTrue(monitor.setFolders([first]))
        try write("Queued before replacement", to: first.appendingPathComponent("old.txt"))
        XCTAssertTrue(monitor.setFolders([second]))
        defer { monitor.stop() }
        try write("Old root after replacement", to: first.appendingPathComponent("ignored.txt"))
        let current = second.appendingPathComponent("current.txt")
        try write("Current root", to: current)
        try await waitUntil { changes.contains { $0.invalidatedPaths.contains(self.path(current)) } }
        XCTAssertTrue(changes.allSatisfy { $0.roots == [second.standardizedFileURL] })
        XCTAssertTrue(monitor.setFolders([]))
        changes.removeAll()
        try write("Stopped with an empty selection", to: current)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(changes.isEmpty)
    }

    @MainActor
    func testHiddenAndDependencyChangesDoNotCauseRefreshes() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".build", isDirectory: true)
        let dependency = root.appendingPathComponent("project/node_modules", isDirectory: true)
        for directory in [hidden, dependency] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var changes: [FolderChangeBatch] = []
        let monitor = FolderChangeMonitor(debounceInterval: 0.15) { changes.append($0) }
        XCTAssertTrue(monitor.setFolders([root]))
        defer { monitor.stop() }
        // FSEvents can still deliver the setup directory creation that was
        // queued before the stream started. Drain it before testing exclusions.
        try await Task.sleep(for: .milliseconds(600))
        changes.removeAll()
        try write("Generated output", to: hidden.appendingPathComponent("output.txt"))
        try write("Dependency output", to: dependency.appendingPathComponent("output.txt"))
        try write("Excluded credential", to: root.appendingPathComponent("credentials.json"))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertTrue(changes.isEmpty)
        let visible = root.appendingPathComponent("notes.txt")
        try write("Visible", to: visible)
        try await waitUntil { changes.contains { $0.invalidatedPaths.contains(self.path(visible)) } }
    }

    @MainActor
    func testRemovingSelectedRootInvalidatesThatRoot() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Indexed before removal", to: root.appendingPathComponent("notes.txt"))
        var changes: [FolderChangeBatch] = []
        let monitor = FolderChangeMonitor(debounceInterval: 0.15) { changes.append($0) }
        XCTAssertTrue(monitor.setFolders([root]))
        defer { monitor.stop() }
        let selectedRoot = root.standardizedFileURL
        try FileManager.default.removeItem(at: root)
        try await waitUntil { changes.contains { $0.invalidatedPaths.contains(self.path(root)) } }
        XCTAssertTrue(changes.allSatisfy { $0.roots == [selectedRoot] })
    }

    @MainActor
    func testMissingAndSymlinkRootsReturnFailure() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = FolderChangeMonitor { _ in XCTFail("No invalid root should be monitored") }
        XCTAssertFalse(monitor.setFolders([root.appendingPathComponent("missing")]))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertFalse(monitor.setFolders([link]))
        XCTAssertTrue(monitor.setFolders([]))
    }
}
