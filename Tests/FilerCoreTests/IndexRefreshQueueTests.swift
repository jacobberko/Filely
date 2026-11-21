import XCTest
@testable import FilerCore

final class IndexRefreshQueueTests: XCTestCase {
    func testChangesDuringScanSurviveAsOneFollowUp() {
        let root = URL(fileURLWithPath: "/tmp/selected")
        var queue = IndexRefreshQueue()
        queue.enqueue(roots: [root])
        XCTAssertEqual(queue.take(allowedRoots: [root]).count, 1)
        queue.enqueue(roots: [root], invalidatedPaths: ["/tmp/selected/a.txt"])
        queue.enqueue(roots: [root], invalidatedPaths: ["/tmp/selected/b.txt"])
        let next = queue.take(allowedRoots: [root])
        XCTAssertEqual(next.count, 1)
        XCTAssertEqual(next.first?.invalidatedPaths, ["/tmp/selected/a.txt", "/tmp/selected/b.txt"])
        XCTAssertTrue(queue.take(allowedRoots: [root]).isEmpty)
    }

    func testRemovedFoldersCannotBeRefreshedByQueuedEvents() {
        let removed = URL(fileURLWithPath: "/tmp/removed")
        let kept = URL(fileURLWithPath: "/tmp/kept")
        var queue = IndexRefreshQueue()
        queue.enqueue(roots: [removed, kept])
        XCTAssertEqual(queue.take(allowedRoots: [kept]).flatMap(\.roots), [kept])
        XCTAssertTrue(queue.take(allowedRoots: [removed]).isEmpty)
    }

    func testLargeBurstFallsBackToRootInvalidation() {
        let root = URL(fileURLWithPath: "/tmp/selected")
        var queue = IndexRefreshQueue()
        queue.enqueue(roots: [root], invalidatedPaths: Set((0..<600).map { root.path + "/\($0).txt" }))
        XCTAssertEqual(queue.take(allowedRoots: [root]).first?.invalidatedPaths, [root.path])
    }
}
