import AppKit
import Foundation
import PDFKit

/// Reads only a folder explicitly supplied by the app's folder picker. No network or global disk search.
public struct FolderIndexer: Sendable {
    public let maximumFiles: Int
    public let maximumTextCharacters: Int
    public let maximumContentBytes: Int

    public init(maximumFiles: Int = 3_000, maximumTextCharacters: Int = 12_000,
                maximumContentBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumFiles = max(1, maximumFiles)
        self.maximumTextCharacters = max(256, maximumTextCharacters)
        self.maximumContentBytes = max(1_024, maximumContentBytes)
    }

    /// Previous records stay in the caller's memory. Changed paths from the
    /// folder watcher override metadata reuse, including edits that preserve a
    /// file's timestamp and size. A directory path invalidates its descendants.
    public func index(folder: URL, previousFiles: [IndexedFile] = [],
                      invalidatedPaths: Set<String> = []) async -> IndexResult {
        let task = Task.detached(priority: .utility) {
            let previous = Dictionary(previousFiles.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            let invalidated = Set(invalidatedPaths.map { Self.canonicalPath(URL(fileURLWithPath: $0)) })
            return scan(folder: folder, previous: previous, invalidatedPaths: invalidated)
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func scan(folder: URL, previous: [String: IndexedFile], invalidatedPaths: Set<String>) -> IndexResult {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                       .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                       .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let root = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              root.isDirectory == true, root.isSymbolicLink != true else {
            return IndexResult(files: [], message: "Choose a readable folder to find files.")
        }

        let manager = FileManager()
        var skipped = 0
        var files: [IndexedFile] = []
        var reachedLimit = false
        var visited = 0
        // The second bound prevents a tree containing mostly folders or excluded files from running indefinitely.
        let maximumEntries = maximumFiles * 12
        var directories = [folder]
        while !directories.isEmpty {
            var nextDirectories: [URL] = []
            var levelFiles: [(url: URL, values: URLResourceValues)] = []
            directoryLoop: for directory in directories {
                guard let entries = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
                                                       errorHandler: { _, _ in skipped += 1; return true }) else {
                    if directory == folder {
                        return IndexResult(files: [], message: "This folder could not be read. Choose it again to grant access.")
                    }
                    skipped += 1
                    continue
                }
                for case let url as URL in entries {
                    if Task.isCancelled { return IndexResult(files: files, skippedCount: skipped, message: "Indexing paused.") }
                    guard visited < maximumEntries else { reachedLimit = true; break directoryLoop }
                    visited += 1
                    guard let values = try? url.resourceValues(forKeys: keys) else { skipped += 1; continue }
                    if values.isSymbolicLink == true { skipped += 1; continue }
                    if values.isDirectory == true {
                        if values.isPackage == true || Self.excludedDirectories.contains(url.lastPathComponent.lowercased()) {
                            skipped += 1
                        } else {
                            nextDirectories.append(url)
                        }
                        continue
                    }
                    guard values.isRegularFile == true, !Self.isSensitiveFile(url) else { skipped += 1; continue }
                    levelFiles.append((url, values))
                }
            }
            // Prefer the files in the folder the user selected before entering
            // downloaded project trees. Within each depth, newer files come first.
            levelFiles.sort {
                let left = $0.values.contentModificationDate ?? .distantPast
                let right = $1.values.contentModificationDate ?? .distantPast
                return left == right ? $0.url.path < $1.url.path : left > right
            }
            for (url, values) in levelFiles {
                if Task.isCancelled { return IndexResult(files: files, skippedCount: skipped, message: "Indexing paused.") }
                guard files.count < maximumFiles else { reachedLimit = true; break }
                // Do not trigger downloads of cloud-only files. Their filenames remain searchable.
                let cloudOnly = values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus == .notDownloaded
                let size = values.fileSize ?? 0
                let excerpt: String = autoreleasepool {
                    guard !cloudOnly, size <= maximumContentBytes else { return "" }
                    if let modified = values.contentModificationDate,
                       let knownSize = values.fileSize,
                       let cached = previous[url.standardizedFileURL.path],
                       cached.modifiedAt == modified, cached.fileSize == Int64(knownSize),
                       !cached.contentExcerpt.isEmpty,
                       !Self.isInvalidated(url, paths: invalidatedPaths) {
                        return cleaned(cached.contentExcerpt)
                    }
                    return text(from: url)
                }
                files.append(IndexedFile(url: url, contentExcerpt: excerpt,
                                         modifiedAt: values.contentModificationDate ?? .distantPast,
                                         fileSize: Int64(size), typeLabel: Self.typeLabel(url)))
            }
            if files.count >= maximumFiles && !nextDirectories.isEmpty { reachedLimit = true }
            if reachedLimit { break }
            directories = nextDirectories.sorted { $0.path < $1.path }
            if files.count >= maximumFiles {
                break
            }
        }
        files.sort { $0.modifiedAt == $1.modifiedAt ? $0.url.path < $1.url.path : $0.modifiedAt > $1.modifiedAt }
        let message = reachedLimit ? "Indexed the first \(files.count.formatted()) files. Choose a smaller folder for complete coverage." : nil
        return IndexResult(files: files, skippedCount: skipped, message: message)
    }

    private static func canonicalPath(_ url: URL) -> String {
        // FSEvents may report /private/var while a caller used /var. This is
        // identity normalization only; enumeration still rejects symlink files.
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isInvalidated(_ url: URL, paths: Set<String>) -> Bool {
        guard !paths.isEmpty else { return false }
        var path = canonicalPath(url)
        while true {
            if paths.contains(path) { return true }
            guard path != "/" else { return false }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path, !parent.isEmpty else { return false }
            path = parent
        }
    }

    private func text(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked else { return "" }
            var result = ""
            for page in 0..<min(document.pageCount, 16) {
                if Task.isCancelled || result.count >= maximumTextCharacters { break }
                if let pageText = document.page(at: page)?.string { result += pageText + "\n" }
            }
            return cleaned(result)
        }
        if ext == "rtf" {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                           documentAttributes: nil) else { return "" }
            return cleaned(attributed.string)
        }
        guard Self.textExtensions.contains(ext) else { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: maximumTextCharacters * 4), !bytes.contains(0),
              let value = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else { return "" }
        return cleaned(value)
    }

    private func cleaned(_ value: String) -> String {
        String(value.prefix(maximumTextCharacters))
            .replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "tex", "rst", "log"]
    private static let excludedDirectories: Set<String> = ["node_modules", "deriveddata", "venv", "__pycache__", "caches"]
    private static let sensitiveExtensions: Set<String> = ["key", "pem", "p12", "pfx", "keychain", "keychain-db", "kdbx", "mobileprovision", "provisionprofile"]
    private static func isSensitiveFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return sensitiveExtensions.contains(url.pathExtension.lowercased()) ||
            ["credentials", "credentials.json", "secrets.json", "secrets.yaml", "secrets.yml", "id_rsa", "id_dsa", "id_ed25519", "authorized_keys"].contains(name)
    }

    private static func typeLabel(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "PDF"
        case "doc", "docx": return "Word document"
        case "pages": return "Pages document"
        case "txt", "md", "markdown", "rtf": return "Text document"
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "webp": return "Image"
        case "csv", "xlsx", "xls", "numbers": return "Spreadsheet"
        case "ppt", "pptx", "key": return "Presentation"
        case "zip": return "Archive"
        default: return url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
        }
    }
}
