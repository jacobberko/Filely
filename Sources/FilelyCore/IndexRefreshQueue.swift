import Foundation

/// Changes received during a scan become one follow-up scan, not cancellation
/// of useful work already in progress. Removed roots never leave this queue.
public struct IndexRefreshQueue {
    private var pending: [URL: Set<String>] = [:]

    public init() {}

    public mutating func enqueue(roots: [URL], invalidatedPaths: Set<String> = []) {
        for root in roots.map(\.standardizedFileURL) {
            var paths = pending[root, default: []]
            paths.formUnion(invalidatedPaths)
            // A sustained burst is bounded in memory. A root invalidation is a
            // conservative substitute for retaining thousands of child paths.
            if paths.count > 512 { paths = [root.path] }
            pending[root] = paths
        }
    }

    public mutating func take(allowedRoots: [URL]) -> [FolderChangeBatch] {
        let work = allowedRoots.map(\.standardizedFileURL).compactMap { root in
            pending[root].map { FolderChangeBatch(roots: [root], invalidatedPaths: $0) }
        }
        pending.removeAll()
        return work
    }

    public mutating func clear() { pending.removeAll() }
}
