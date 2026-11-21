import CoreServices
import Foundation

/// A coalesced change to explicitly selected folders. Paths identify files or
/// entire directory subtrees whose in-memory extracted content must be refreshed.
public struct FolderChangeBatch: Sendable {
    public let roots: [URL]
    public let invalidatedPaths: Set<String>

    public init(roots: [URL], invalidatedPaths: Set<String>) {
        self.roots = roots
        self.invalidatedPaths = invalidatedPaths
    }
}

/// Watches only folders supplied by the app. FSEvents and filtering run on a
/// utility queue; the app receives one notification after a burst of changes.
@MainActor
public final class FolderChangeMonitor {
    private let debounceInterval: TimeInterval
    private let onChange: @MainActor (FolderChangeBatch) -> Void
    private var worker: FolderChangeWorker?
    private var folders: [URL] = []
    private var generation = 0

    public init(debounceInterval: TimeInterval = 0.8,
                onChange: @escaping @MainActor (FolderChangeBatch) -> Void) {
        self.debounceInterval = max(0.05, debounceInterval)
        self.onChange = onChange
    }

    /// Returns false if monitoring could not start. An empty selection succeeds
    /// and stops monitoring. Reapplying the same active selection is a no-op.
    @discardableResult
    public func setFolders(_ urls: [URL]) -> Bool {
        let selection = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        if selection == folders, worker != nil || selection.isEmpty { return true }
        stop()
        guard !selection.isEmpty else { return true }
        let currentGeneration = generation
        let next = FolderChangeWorker(debounceInterval: debounceInterval) { [weak self] batch in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.onChange(batch)
            }
        }
        guard next.start(folders: selection) else { return false }
        folders = selection
        worker = next
        return true
    }

    public func stop() {
        generation += 1
        worker?.stop()
        worker = nil
        folders = []
    }

    deinit { worker?.stop() }
}

private final class FolderChangeWorker: @unchecked Sendable {
    private struct Root {
        let url: URL
        let path: String
    }

    /// The stream retains this context, but never the worker that owns it.
    private final class StreamContext {
        weak var owner: FolderChangeWorker?
        init(owner: FolderChangeWorker) { self.owner = owner }
    }

    private let queue = DispatchQueue(label: "app.filely.folder-changes", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable (FolderChangeBatch) -> Void
    private var stream: FSEventStreamRef?
    private var roots: [Root] = []
    private var pendingPaths = Set<String>()
    private var pendingRoots = Set<String>()
    private var pendingWork: DispatchWorkItem?
    private var burstStarted: DispatchTime?

    init(debounceInterval: TimeInterval, onChange: @escaping @Sendable (FolderChangeBatch) -> Void) {
        self.debounceInterval = debounceInterval
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    func start(folders: [URL]) -> Bool {
        sync {
            stopOnQueue()
            for folder in folders {
                guard folder.isFileURL,
                      let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { return false }
            }
            for folder in folders {
                guard let path = Self.physicalPath(folder) else { roots = []; return false }
                roots.append(Root(url: folder, path: path))
            }
            let box = StreamContext(owner: self)
            var context = FSEventStreamContext(version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { pointer in
                    guard let pointer else { return nil }
                    _ = Unmanaged<StreamContext>.fromOpaque(pointer).retain()
                    return pointer
                },
                release: { pointer in
                    if let pointer { Unmanaged<StreamContext>.fromOpaque(pointer).release() }
                }, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            guard let created = FSEventStreamCreate(kCFAllocatorDefault,
                { _, info, count, rawPaths, flags, _ in
                    guard let info else { return }
                    let context = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue()
                    guard let owner = context.owner else { return }
                    let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                    for index in 0..<count {
                        owner.receive(path: String(cString: paths[index]), flags: flags[index])
                    }
                    owner.scheduleDelivery()
                }, &context, Array(Set(roots.map(\.path))).sorted() as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                min(0.25, debounceInterval), flags) else {
                roots = []
                return false
            }
            stream = created
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                stopOnQueue()
                return false
            }
            return true
        }
    }

    func stop() { sync { stopOnQueue() } }

    private func stopOnQueue() {
        pendingWork?.cancel()
        pendingWork = nil
        pendingPaths.removeAll()
        pendingRoots.removeAll()
        burstStarted = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        roots = []
    }

    private func receive(path: String, flags: FSEventStreamEventFlags) {
        guard stream != nil else { return }
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
        if flags & dropped != 0 {
            for root in roots { record(root: root, path: root.path) }
            return
        }
        // FSEvents already supplies physical absolute paths. Standardizing here
        // changes /private/var to /var only while the item exists, which would
        // silently discard deletes and the old side of rename events.
        let path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let affected = roots.filter { Self.isWithin(path, root: $0.path) }
        for root in affected {
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                record(root: root, path: root.path)
                continue
            }
            let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            guard !Self.isExcluded(path, root: root.path, isDirectory: isDirectory) else { continue }
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                record(root: root, path: path)
                continue
            }
            let structural = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated |
                kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed)
            // FileEvents identifies child changes. Parent directory metadata
            // alone must not invalidate every cached excerpt beneath that root.
            if isDirectory && flags & structural == 0 { continue }
            let relevant = structural | FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified |
                kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemFinderInfoMod |
                kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod)
            guard flags & relevant != 0 else { continue }
            record(root: root, path: path)
        }
    }

    private func record(root: Root, path: String) {
        pendingRoots.insert(root.path)
        pendingPaths.insert(path)
    }

    private func scheduleDelivery() {
        guard !pendingRoots.isEmpty else { return }
        pendingWork?.cancel()
        let now = DispatchTime.now()
        if burstStarted == nil { burstStarted = now }
        // Constant writes still produce a bounded refresh cadence.
        let elapsed = Double(now.uptimeNanoseconds - (burstStarted ?? now).uptimeNanoseconds) / 1_000_000_000
        let remaining = max(0, max(3, debounceInterval) - elapsed)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stream != nil, !self.pendingRoots.isEmpty else { return }
            let batch = FolderChangeBatch(
                roots: self.roots.filter { self.pendingRoots.contains($0.path) }.map(\.url),
                invalidatedPaths: self.pendingPaths)
            self.pendingWork = nil
            self.pendingRoots.removeAll()
            self.pendingPaths.removeAll()
            self.burstStarted = nil
            self.onChange(batch)
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + min(debounceInterval, remaining), execute: work)
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func physicalPath(_ url: URL) -> String? {
        // Foundation preserves the /var alias even when resolving symlinks;
        // FSEvents uses the physical /private/var path, including after deletion.
        url.withUnsafeFileSystemRepresentation { path in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    private static func isExcluded(_ path: String, root: String, isDirectory: Bool) -> Bool {
        guard path != root else { return false }
        let relative = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { return true }
        var ancestor = URL(fileURLWithPath: root, isDirectory: true)
        for (index, part) in parts.enumerated() {
            ancestor.appendPathComponent(part)
            let values = try? ancestor.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isAncestor = index < parts.count - 1
            if isAncestor || isDirectory || values?.isDirectory == true {
                if excludedDirectories.contains(part.lowercased()) || values?.isPackage == true { return true }
            }
            // Removed package descendants can no longer expose resource values.
            if isAncestor && packageExtensions.contains(ancestor.pathExtension.lowercased()) { return true }
        }
        guard !isDirectory else { return false }
        let url = URL(fileURLWithPath: path)
        return sensitiveExtensions.contains(url.pathExtension.lowercased()) ||
            sensitiveNames.contains(url.lastPathComponent.lowercased())
    }

    // Keep these aligned with FolderIndexer; excluded trees must not cause
    // refresh storms when a dependency install or build touches thousands of files.
    private static let excludedDirectories: Set<String> = ["node_modules", "deriveddata", "venv", "__pycache__", "caches"]
    private static let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "xcassets", "xcodeproj", "xcworkspace"]
    private static let sensitiveExtensions: Set<String> = ["key", "pem", "p12", "pfx", "keychain", "keychain-db", "kdbx", "mobileprovision", "provisionprofile"]
    private static let sensitiveNames: Set<String> = ["credentials", "credentials.json", "secrets.json", "secrets.yaml", "secrets.yml", "id_rsa", "id_dsa", "id_ed25519", "authorized_keys"]

    private func sync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return operation() }
        return queue.sync(execute: operation)
    }

    deinit { stop() }
}
