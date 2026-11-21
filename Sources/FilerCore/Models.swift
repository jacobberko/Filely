import Foundation

public struct IndexedFile: Identifiable, Codable, Hashable, Sendable {
    public var id: String { url.standardizedFileURL.path }
    public let url: URL
    public let name: String
    public let contentExcerpt: String
    public let modifiedAt: Date
    public let fileSize: Int64
    public let typeLabel: String

    public init(url: URL, name: String? = nil, contentExcerpt: String = "", modifiedAt: Date = .distantPast,
                fileSize: Int64 = 0, typeLabel: String = "File") {
        self.url = url.standardizedFileURL
        self.name = name ?? url.lastPathComponent
        self.contentExcerpt = contentExcerpt
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.typeLabel = typeLabel
    }
}

public struct CapturedContext: Codable, Hashable, Sendable {
    public let text: String
    public let source: String
    public let capturedAt: Date

    public init(text: String, source: String, capturedAt: Date = .now) {
        self.text = text
        self.source = source
        self.capturedAt = capturedAt
    }
}

public struct FileSuggestion: Identifiable, Sendable {
    public var id: String { file.id }
    public let file: IndexedFile
    /// A relative retrieval score, not a probability or confidence percentage.
    public let score: Double
    public let reason: String

    public init(file: IndexedFile, score: Double, reason: String) {
        self.file = file
        self.score = score
        self.reason = reason
    }
}

public struct IndexResult: Sendable {
    public let files: [IndexedFile]
    public let skippedCount: Int
    public let message: String?

    public init(files: [IndexedFile], skippedCount: Int = 0, message: String? = nil) {
        self.files = files
        self.skippedCount = skippedCount
        self.message = message
    }
}
