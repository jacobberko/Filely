import Foundation
import NaturalLanguage

/// A local retrieval baseline: lexical candidates, optional on-device semantic reranking, then modest recency cues.
/// It deliberately returns no candidates when the context has no meaningful lexical evidence.
public struct FileRanker: Sendable {
    public let semanticReranking: Bool

    public init(semanticReranking: Bool = true) {
        self.semanticReranking = semanticReranking
    }

    public func rank(files: [IndexedFile], context: CapturedContext, limit: Int = 3) -> [FileSuggestion] {
        guard limit > 0, !files.isEmpty else { return [] }
        let rawContext = String(context.text.prefix(12_000))
        let queryTerms = Array(Set(Self.tokens(rawContext))).sorted().prefix(80)
        guard !queryTerms.isEmpty else { return [] }
        let query = Set(queryTerms)
        let lowerContext = rawContext.lowercased()
        let prefersRecent = ["latest", "newest", "updated", "current", "revised", "yesterday", "today"].contains { lowerContext.contains($0) }
        let wantsSigned = query.contains("signed") && !query.contains("unsigned")
        let wantsFinal = query.contains("final") && !query.contains("draft")
        // A direct format request is a constraint, not a tiny score bonus. This
        // finder selects existing files; it cannot convert a Word file to PDF.
        let requiresPDF = lowerContext.range(of: #"\b(?:as|in)\s+(?:a\s+)?pdf\b"#, options: .regularExpression) != nil
        let searchableFiles = requiresPDF ? files.filter { $0.url.pathExtension.lowercased() == "pdf" } : files
        guard !searchableFiles.isEmpty else { return [] }

        struct Document {
            let file: IndexedFile
            let name: Set<String>
            let body: [String: Int]
            let folder: Set<String>
            let length: Double
            var allTerms: Set<String> { Set(body.keys).union(name).union(folder) }
        }
        let documents = searchableFiles.map { file in
            let body = Self.tokens(file.contentExcerpt)
            return Document(file: file, name: Set(Self.tokens(file.name)),
                            body: Dictionary(body.map { ($0, 1) }, uniquingKeysWith: +),
                            folder: Set(Self.tokens(file.url.deletingLastPathComponent().lastPathComponent)),
                            length: Double(max(1, body.count)))
        }
        let averageLength = max(1, documents.reduce(0) { $0 + $1.length } / Double(documents.count))
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for term in query.intersection(document.allTerms) { documentFrequency[term, default: 0] += 1 }
        }

        struct Candidate {
            let file: IndexedFile
            var score: Double
            let nameMatches: [String]
            let bodyMatches: [String]
            let folderMatches: [String]
            var newestMatchingVersion = false
        }
        var candidates: [Candidate] = []
        for document in documents {
            let nameMatches = query.intersection(document.name)
            let bodyMatches = query.intersection(Set(document.body.keys))
            let folderMatches = query.intersection(document.folder)
            let directMatches = nameMatches.union(bodyMatches)
            // A shared folder alone is too weak to recommend a file without inspecting its contents.
            guard !directMatches.isEmpty else { continue }
            var score = 0.0
            for term in query {
                let count = Double(documentFrequency[term, default: 0])
                let idf = log(1 + (Double(documents.count) - count + 0.5) / (count + 0.5))
                let frequency = Double(document.body[term, default: 0])
                let normalization = frequency + 1.2 * (0.25 + 0.75 * document.length / averageLength)
                let contentScore = frequency > 0 ? frequency * 2.2 / normalization : 0
                score += idf * (contentScore + (nameMatches.contains(term) ? 3.5 : 0) + (folderMatches.contains(term) ? 0.35 : 0))
            }
            let coverage = Double(directMatches.count) / Double(query.count)
            score *= 0.7 + 0.6 * coverage

            // Penalize known contradictory versions, but never claim a document is signed based on content alone.
            if wantsSigned && document.name.contains("unsigned") { score *= 0.15 }
            if wantsFinal && document.name.contains("draft") { score *= 0.35 }
            let ageDays = max(0, context.capturedAt.timeIntervalSince(document.file.modifiedAt) / 86_400)
            score += (prefersRecent ? 0.35 : 0.08) * exp(-ageDays / 45)
            if lowerContext.contains("pdf") && document.file.url.pathExtension.lowercased() == "pdf" { score += 0.12 }
            candidates.append(Candidate(file: document.file, score: score,
                                        nameMatches: nameMatches.sorted(), bodyMatches: bodyMatches.sorted(),
                                        folderMatches: folderMatches.sorted()))
        }
        candidates.sort { $0.score > $1.score }

        // Only rerank a small lexical shortlist. This keeps inference bounded and prevents a vague embedding
        // match from bypassing the explicit no-match policy. Missing language assets simply use lexical ranking.
        if semanticReranking, !candidates.isEmpty, let embedding = NLEmbedding.sentenceEmbedding(for: .english),
           let contextVector = embedding.vector(for: String(rawContext.prefix(1_800))) {
            for index in 0..<min(candidates.count, 18) {
                let file = candidates[index].file
                let representation = String((file.name + ". " + file.contentExcerpt).prefix(1_800))
                if let vector = embedding.vector(for: representation) {
                    let similarity = Self.cosine(contextVector, vector)
                    candidates[index].score += max(0, similarity) * 0.45
                }
            }
            candidates.sort { $0.score > $1.score }
        }

        if prefersRecent {
            // An explicit request for the latest version is a constraint within a document family,
            // not a reason to promote every recently modified file. BM25 length normalization can
            // otherwise favor an old, short resume over a newer version with more experience.
            let families = Dictionary(grouping: candidates.indices) { index in
                Self.versionFamily(candidates[index].file)
            }
            let explicitVersions = query.filter { term in
                (term.count == 4 && Int(term).map { (1900...2099).contains($0) } == true) ||
                term.range(of: "^v[0-9]+$", options: .regularExpression) != nil
            }
            for (family, indices) in families where !family.isEmpty && indices.count > 1 {
                guard let bestScore = indices.map({ candidates[$0].score }).max() else { continue }
                let eligible = indices.filter { index in
                    let evidence = Set(candidates[index].nameMatches + candidates[index].bodyMatches)
                    return candidates[index].score >= bestScore * 0.72 && explicitVersions.isSubset(of: evidence)
                }
                guard eligible.count > 1,
                      let newestDate = eligible.map({ candidates[$0].file.modifiedAt }).max(),
                      let oldestDate = eligible.map({ candidates[$0].file.modifiedAt }).min(),
                      newestDate > oldestDate else { continue }
                for index in eligible {
                    let ageDifference = max(0, newestDate.timeIntervalSince(candidates[index].file.modifiedAt) / 86_400)
                    let freshness = exp(-ageDifference / 60)
                    let base = candidates[index].score
                    candidates[index].score = base + (bestScore * 1.12 - base) * freshness
                    candidates[index].newestMatchingVersion = ageDifference == 0
                }
            }
            candidates.sort { $0.score > $1.score }
        }

        guard let best = candidates.first, best.score > 0 else { return [] }
        // A low-ranked distant match should not fill an arbitrary quota of three results.
        return candidates.filter { $0.score >= best.score * 0.24 }.prefix(limit).map { candidate in
            let terms: [String]
            let location: String
            if !candidate.nameMatches.isEmpty {
                terms = candidate.nameMatches
                location = "Filename matches"
            } else {
                terms = candidate.bodyMatches
                location = "Document text matches"
            }
            let displayed = terms.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            let versionReason = candidate.newestMatchingVersion ? "Most recently modified matching version · " : ""
            return FileSuggestion(file: candidate.file, score: candidate.score, reason: "\(versionReason)\(location) \(displayed)")
        }
    }

    private static func versionFamily(_ file: IndexedFile) -> String {
        let name = file.url.deletingPathExtension().lastPathComponent
        let versionWords: Set<String> = ["final", "draft", "signed", "unsigned", "old", "older", "backup", "copy",
                                         "january", "february", "march", "april", "may", "june", "july", "august",
                                         "september", "october", "november", "december", "jan", "feb", "mar", "apr",
                                         "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let terms = tokens(name).filter { term in
            !versionWords.contains(term) && Int(term) == nil &&
                term.range(of: "^v[0-9]+$", options: .regularExpression) == nil
        }
        guard !terms.isEmpty else { return "" }
        return file.url.pathExtension.lowercased() + ":" + terms.sorted().joined(separator: " ")
    }

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var product = 0.0, leftMagnitude = 0.0, rightMagnitude = 0.0
        for (left, right) in zip(lhs, rhs) {
            product += left * right
            leftMagnitude += left * left
            rightMagnitude += right * right
        }
        let denominator = sqrt(leftMagnitude * rightMagnitude)
        return denominator > 0 ? product / denominator : 0
    }

    private static func tokens(_ text: String) -> [String] {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let source = normalized as NSString
        return tokenExpression.matches(in: normalized, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }
            .filter { $0.count > 1 && !stopWords.contains($0) }
            .map { synonyms[$0] ?? $0 }
    }

    // Dates appended to names (Resume20260929) should not hide the name. Keep
    // explicit v2/v3-style version tokens intact for version constraints.
    private static let tokenExpression = try! NSRegularExpression(pattern: #"\bv[0-9]+\b|[\p{L}]+|[\p{N}]+"#)

    private static let synonyms: [String: String] = [
        "cv": "resume", "résumé": "resume", "resumes": "resume", "curriculum": "resume", "vitae": "resume",
        "invoices": "invoice", "agreements": "contract", "agreement": "contract", "contracts": "contract",
        "homework": "assignment", "assignments": "assignment", "coursework": "assignment", "hw": "assignment",
        "syllabi": "syllabus", "receipts": "receipt", "slides": "presentation", "deck": "presentation",
        "screenshots": "screenshot", "photographs": "photo", "photos": "photo", "pictures": "photo", "picture": "photo"
    ]
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "has", "had", "are", "was", "were", "will", "would",
        "could", "can", "you", "your", "yours", "our", "ours", "their", "they", "them", "its", "into", "onto", "out", "about",
        "just", "also", "some", "any", "all", "not", "but", "when", "where", "which", "what", "who", "how", "there", "here",
        "then", "than", "very", "been", "being", "does", "did", "get", "got", "let", "know", "want", "need", "needs",
        "please", "thanks", "thank", "hello", "hi", "hey", "regards", "best", "cheers", "looking", "look", "find", "help",
        "send", "sending", "sent", "attach", "attached", "attachment", "attachments", "upload", "uploading", "select", "choose",
        "file", "files", "document", "documents", "copy", "version", "latest", "newest", "updated", "current", "revised",
        "today", "yesterday", "tomorrow", "email", "mail", "gmail", "chrome", "google", "inbox", "compose", "drafts", "search",
        "reply", "forward", "subject", "recipient", "recipients", "message", "messages", "button", "dialog", "window", "open",
        "cancel", "save", "close", "more", "less", "menu", "toolbar", "navigation", "settings", "account", "accounts",
        "http", "https", "www", "com", "org", "edu", "net", "pdf", "doc", "docx", "txt", "md", "rtf", "png", "jpg", "jpeg",
        "of", "to", "in", "on", "at", "by", "as", "is", "it", "an", "or", "be", "we", "us", "my", "me", "if", "so", "do", "up", "cc", "bcc"
    ]
}
