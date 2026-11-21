import AppKit
import Combine
import FilelyCore

struct FolderSource: Identifiable {
    var id: String { url.path }
    let url: URL
    var fileCount: Int = 0

    init(url: URL, fileCount: Int = 0) {
        self.url = url.standardizedFileURL
        self.fileCount = fileCount
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview", folders = "Folders", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: return "sparkles"; case .folders: return "folder"; case .settings: return "slider.horizontal.3" }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .overview
    @Published var folders: [FolderSource] = []
    @Published var files: [IndexedFile] = []
    @Published var suggestions: [FileSuggestion] = []
    @Published var isIndexing = false
    @Published var isWatchingFiles = false
    @Published var lastIndexedAt: Date?
    @Published var isRanking = false
    @Published var isSelecting = false
    @Published var isTrusted = PickerMonitor.isTrusted
    @Published var isEnabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    @Published var picker: PickerSession?
    @Published var context: CapturedContext?
    @Published var status = "Ready when you are"
    @Published var connectionDetail = "Waiting for the first connection check."
    @Published var errorMessage: String?
    @Published var indexingNote: String?
    @Published var selectedSuggestion: String?
    @Published var isDemo = false
    @Published var demoSelectionName: String?
    @Published var appearance: String = UserDefaults.standard.string(forKey: "appearance") ?? "System"
    @Published var showReasons = UserDefaults.standard.object(forKey: "showReasons") as? Bool ?? true
    var showMainWindow: (() -> Void)?
    var showSuggestionWindow: ((PickerSession?) -> Void)?
    var hideSuggestionWindow: (() -> Void)?
    var showDemoWindow: (() -> Void)?
    var previewFile: ((URL) -> Void)?
    let monitor = PickerMonitor()
    private var permissionTimer: Timer?
    private var rankingTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var refreshQueue = IndexRefreshQueue()
    private var folderIndexes: [String: IndexResult] = [:]
    private lazy var folderMonitor = FolderChangeMonitor { [weak self] batch in
        self?.enqueueRefresh(roots: batch.roots, invalidatedPaths: batch.invalidatedPaths)
    }
    private var accessedURLs: [URL] = []
    private var demoFiles: [IndexedFile] = []
    private var demoContext: CapturedContext?
    private var indexRevision = 0
    private var dismissedPickerID: String?

    var isReady: Bool { isTrusted && !folders.isEmpty && !files.isEmpty }
    var readyCount: Int { (folders.isEmpty ? 0 : 1) + (isTrusted ? 1 : 0) }
    var activeSource: String { isDemo ? "Sample email" : (context?.source ?? "Gmail in Chrome") }
    var stateTitle: String {
        if !isEnabled { return "Suggestions paused" }
        if isIndexing && files.isEmpty { return "Getting your files ready" }
        if folders.isEmpty { return "Choose your first folder" }
        if !isTrusted { return "One more step" }
        if files.isEmpty { return "No files found" }
        return "Ready for your next attachment"
    }

    init() {
        restoreFolders()
        monitor.onContext = { [weak self] captured in
            guard let self, !self.isDemo else { return }
            self.context = captured
        }
        monitor.onPicker = { [weak self] session in
            guard let self, !self.isDemo else { return }
            if let session {
                let changed = self.picker?.id != session.id || self.picker?.context?.text != session.context?.text || self.picker?.context?.source != session.context?.source
                self.picker = session
                self.context = session.context
                if changed { self.errorMessage = nil; self.recommend() }
                if !self.isSelecting && self.dismissedPickerID != session.id { self.showSuggestionWindow?(session) }
            } else {
                self.picker = nil
                self.context = nil
                self.suggestions = []
                self.dismissedPickerID = nil
                self.rankingTask?.cancel()
                self.hideSuggestionWindow?()
            }
        }
        monitor.onStatus = { [weak self] message in self?.status = message }
        monitor.onDiagnostics = { [weak self] message in self?.connectionDetail = message }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        updateMonitoring()
        updateFolderMonitoring()
        enqueueRefresh(roots: folders.map(\.url))
    }

    func refreshPermission() {
        let now = PickerMonitor.isTrusted
        guard now != isTrusted else { return }
        isTrusted = now
        updateMonitoring()
    }

    func requestPermission() { monitor.requestAccess(); refreshPermission() }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        UserDefaults.standard.set(value, forKey: "enabled")
        updateMonitoring()
        if !value { context = nil; picker = nil; hideSuggestionWindow?() }
    }

    private func updateMonitoring() {
        if isEnabled && isTrusted && !isDemo && !folders.isEmpty { monitor.start() }
        else { monitor.stop() }
    }

    private func updateFolderMonitoring() {
        isWatchingFiles = folderMonitor.setFolders(folders.map(\.url)) && !folders.isEmpty
    }

    func chooseFolder() {
        let chooser = NSOpenPanel()
        chooser.title = "Choose a folder for Filely"
        chooser.message = "Filely searches only folders you add. Your files stay on this Mac."
        chooser.prompt = "Add Folder"
        chooser.canChooseFiles = false
        chooser.canChooseDirectories = true
        chooser.allowsMultipleSelection = true
        chooser.canCreateDirectories = false
        chooser.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in chooser.urls where !self.folders.contains(where: { $0.url == url }) {
                    _ = url.startAccessingSecurityScopedResource()
                    self.accessedURLs.append(url)
                    self.folders.append(FolderSource(url: url))
                }
                self.persistFolders()
                self.updateFolderMonitoring()
                self.enqueueRefresh(roots: self.folders.map(\.url))
                self.updateMonitoring()
            }
        }
    }

    func removeFolder(_ source: FolderSource) {
        folders.removeAll { $0.id == source.id }
        // Cancel publication from the old folder selection. A queued event from
        // a removed root cannot put its records back in the index.
        indexTask?.cancel()
        indexTask = nil
        indexRevision += 1
        refreshQueue.clear()
        folderIndexes.removeValue(forKey: source.id)
        publishIndex()
        source.url.stopAccessingSecurityScopedResource()
        accessedURLs.removeAll { $0 == source.url }
        persistFolders()
        updateFolderMonitoring()
        enqueueRefresh(roots: folders.map(\.url))
        if folders.isEmpty { isIndexing = false; lastIndexedAt = nil }
        if !isSelecting { recommend() }
        updateMonitoring()
    }

    func reindex() {
        updateFolderMonitoring()
        let roots = folders.map(\.url)
        // Manual Refresh also retries previously unreadable content, even if its
        // metadata did not change. Automatic updates invalidate just changed paths.
        enqueueRefresh(roots: roots, invalidatedPaths: Set(roots.map(\.path)))
    }

    private func enqueueRefresh(roots: [URL], invalidatedPaths: Set<String> = []) {
        refreshQueue.enqueue(roots: roots, invalidatedPaths: invalidatedPaths)
        startNextRefresh()
    }

    private func startNextRefresh() {
        guard indexTask == nil else { return }
        let work = refreshQueue.take(allowedRoots: folders.map(\.url))
        guard !work.isEmpty else { isIndexing = false; return }
        let revision = indexRevision
        isIndexing = true
        indexTask = Task { [weak self] in
            for batch in work {
                guard let self, !Task.isCancelled, self.indexRevision == revision,
                      let root = batch.roots.first else { return }
                let previous = self.folderIndexes[root.path]?.files ?? []
                let result = await FolderIndexer().index(folder: root, previousFiles: previous,
                                                        invalidatedPaths: batch.invalidatedPaths)
                guard !Task.isCancelled, self.indexRevision == revision else { return }
                self.folderIndexes[root.path] = result
                self.publishIndex()
            }
            guard let self, !Task.isCancelled, self.indexRevision == revision else { return }
            self.lastIndexedAt = .now
            self.indexTask = nil
            if self.picker != nil && !self.isSelecting && !self.isDemo { self.recommend() }
            self.startNextRefresh()
        }
    }

    private func publishIndex() {
        var seen = Set<String>()
        files = folders.flatMap { folderIndexes[$0.id]?.files ?? [] }.filter { seen.insert($0.id).inserted }
        folders = folders.map { FolderSource(url: $0.url, fileCount: folderIndexes[$0.id]?.files.count ?? 0) }
        let notes = folders.compactMap { folderIndexes[$0.id]?.message }
        indexingNote = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    func recommend() {
        rankingTask?.cancel()
        let captured = isDemo ? demoContext : picker?.context
        guard let captured, !captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            suggestions = []; isRanking = false; return
        }
        let candidates = isDemo ? demoFiles : files
        isRanking = true
        rankingTask = Task { [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) {
                FileRanker().rank(files: candidates, context: captured, limit: 3)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.suggestions = ranked
            self.selectedSuggestion = ranked.first?.id
            self.isRanking = false
        }
    }

    func select(_ suggestion: FileSuggestion) {
        guard !isSelecting else { return }
        if isDemo {
            selectedSuggestion = suggestion.id
            demoSelectionName = suggestion.file.name
            NotificationCenter.default.post(name: .filelyDemoSelected, object: suggestion.file.url)
            return
        }
        guard let picker else { return }
        isSelecting = true
        errorMessage = nil
        // Relinquish the nonactivating panel's keyboard focus before Chrome's
        // native picker receives navigation keys.
        hideSuggestionWindow?()
        monitor.select(fileURL: suggestion.file.url, in: picker) { [weak self] result in
            guard let self else { return }
            self.isSelecting = false
            switch result {
            case .success: self.hideSuggestionWindow?()
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                if self.picker?.id == picker.id && self.isEnabled {
                    self.recommend()
                    self.showSuggestionWindow?(self.picker)
                }
            }
        }
    }

    func dismissSuggestions() {
        if isDemo { endDemo() }
        else { dismissedPickerID = picker?.id; hideSuggestionWindow?() }
    }

    func beginDemo(files: [IndexedFile], text: String) {
        isDemo = true
        demoSelectionName = nil
        monitor.stop()
        demoFiles = files
        demoContext = CapturedContext(text: text, source: "Sample email", capturedAt: Date())
        context = demoContext
        errorMessage = nil
        recommend()
        showSuggestionWindow?(nil)
    }

    func endDemo() {
        isDemo = false; demoFiles = []; demoContext = nil
        demoSelectionName = nil
        context = nil; suggestions = []; picker = nil
        hideSuggestionWindow?()
        updateMonitoring()
    }

    func moveSelection(_ offset: Int) {
        guard !suggestions.isEmpty else { return }
        let current = suggestions.firstIndex { $0.id == selectedSuggestion } ?? 0
        let next = min(max(current + offset, 0), suggestions.count - 1)
        selectedSuggestion = suggestions[next].id
        demoSelectionName = nil
    }

    func changeAppearance(_ value: String) {
        appearance = value
        UserDefaults.standard.set(value, forKey: "appearance")
        NSApp.appearance = value == "Light" ? NSAppearance(named: .aqua) : value == "Dark" ? NSAppearance(named: .darkAqua) : nil
    }

    func saveReasons() { UserDefaults.standard.set(showReasons, forKey: "showReasons") }

    private func persistFolders() {
        let bookmarks = folders.compactMap { try? $0.url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        UserDefaults.standard.set(bookmarks, forKey: "folderBookmarks")
    }

    private func restoreFolders() {
        let bookmarks = UserDefaults.standard.array(forKey: "folderBookmarks") as? [Data] ?? []
        for bookmark in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: url.path) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            accessedURLs.append(url)
            folders.append(FolderSource(url: url))
        }
    }
}

extension Notification.Name {
    static let filelyDemoSelected = Notification.Name("filely.demo.selected")
}
