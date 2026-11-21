import Foundation
import XCTest
@testable import FilerCore

final class RetrievalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ranker = FileRanker(semanticReranking: false)

    private func file(_ name: String, text: String = "", daysOld: Double = 0) -> IndexedFile {
        IndexedFile(url: URL(fileURLWithPath: "/fixtures/\(name)"), contentExcerpt: text,
                    modifiedAt: now.addingTimeInterval(-daysOld * 86_400), typeLabel: "PDF")
    }

    func testResumeRequestFindsOpaqueDocumentContentBeforeUnrelatedRecentFiles() {
        let intended = file("export_3874.pdf", text: "Resume. Education: Cornell University. Experience: software engineering intern. Skills: Python and Swift.", daysOld: 90)
        let recent = file("receipt_today.pdf", text: "Receipt for grocery shopping and household supplies.")
        let response = ranker.rank(files: [recent, intended], context: CapturedContext(text: "Hi, could you attach your CV for the software engineering role? Thanks!", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, intended.id)
        XCTAssertEqual(response.count, 1)
        XCTAssertTrue(response.first?.reason.contains("Document text") == true)
    }

    func testFilenameFallbackWorksForAnImageWithoutExtractedContents() {
        let intended = file("Robotics_assignment_2_screenshot.png")
        let irrelevant = file("vacation_photo.jpg")
        let response = ranker.rank(files: [irrelevant, intended], context: CapturedContext(text: "Please upload the robotics homework screenshot.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, intended.id)
        XCTAssertTrue(response.first?.reason.contains("Filename") == true)
    }

    func testTimestampAppendedToFilenameDoesNotHideDocumentName() {
        let intended = file("Resume202401020304.pdf", text: "Education and professional experience")
        let response = ranker.rank(files: [file("notes.pdf"), intended], context: CapturedContext(text: "Please attach your resume.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.map(\.file.id), [intended.id])
        XCTAssertTrue(response.first?.reason.contains("Filename matches “resume”") == true)
    }

    func testExplicitPDFRequestExcludesWordFileWithStrongerFilename() {
        let intended = file("export20240102.pdf", text: "Resume with software engineering experience")
        let word = file("Resume_software_engineering.docx", text: "Resume with software engineering experience")
        let context = CapturedContext(text: "Please attach my software engineering resume as a PDF.", source: "Gmail", capturedAt: now)
        let response = ranker.rank(files: [word, intended], context: context)
        XCTAssertEqual(response.map(\.file.id), [intended.id])
        XCTAssertTrue(ranker.rank(files: [word], context: context).isEmpty)
    }

    func testLetterDigitTokenizationPreservesExplicitVersionRequest() {
        let intended = file("Orion proposal v2.pdf", text: "Orion robotics proposal", daysOld: 200)
        let newer = file("Orion proposal v3.pdf", text: "Orion robotics proposal")
        let response = ranker.rank(files: [newer, intended], context: CapturedContext(text: "Please attach the latest Orion proposal v2.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, intended.id)
    }

    func testNoMatchDoesNotFallBackToRecentPrivateFiles() {
        let files = [file("Resume.pdf", text: "Software engineer"), file("Tax_2025.pdf", text: "Federal income tax return")]
        let response = ranker.rank(files: files, context: CapturedContext(text: "Please send your vaccination certificate.", source: "Gmail", capturedAt: now))
        XCTAssertTrue(response.isEmpty)
    }

    func testGenericBrowserAndAttachmentWordsDoNotCreateSuggestions() {
        let files = [file("file.pdf", text: "A document attached to a message")]
        let response = ranker.rank(files: files, context: CapturedContext(text: "Gmail Inbox Compose Attach files Open Cancel Please send the document. Thanks!", source: "Chrome", capturedAt: now))
        XCTAssertTrue(response.isEmpty)
    }

    func testSignedFilenameBeatsNewerUnsignedVersion() {
        let signed = file("Acme_contract_signed.pdf", text: "Acme consulting agreement", daysOld: 30)
        let unsigned = file("Acme_contract_unsigned.pdf", text: "Acme consulting agreement")
        let response = ranker.rank(files: [unsigned, signed], context: CapturedContext(text: "Please attach the signed Acme agreement.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, signed.id)
    }

    func testFinalRequestDownranksExplicitDraftFilename() {
        let final = file("Aurora_budget_final.pdf", text: "Aurora budget proposal", daysOld: 12)
        let draft = file("Aurora_budget_draft.pdf", text: "Aurora budget proposal")
        let response = ranker.rank(files: [draft, final], context: CapturedContext(text: "Here is the final Aurora budget.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, final.id)
    }

    func testLatestResumeRequestPrefersNewVersionDespiteOlderShorterDocument() {
        let newest = file("Alex Morgan — Resume.pdf", text: "ALEX MORGAN\nSoftware Engineer\n\nExperience\nSoftware engineering internship: built reliable backend services.\nProjects\nOn-device machine learning and native macOS productivity tools.\nSkills\nSwift, Python, model evaluation, product development.")
        let older = file("Alex Morgan — Resume 2024.pdf", text: "ALEX MORGAN\nSoftware engineering resume\n\nEducation and early coursework\nAn older resume, before the latest internship and projects.", daysOld: 730)
        let portfolio = file("Project portfolio.pdf", text: "Software engineering projects. A collection of native applications, machine learning experiments, and web tools.", daysOld: 12)
        let files = [older, newest, portfolio, file("Lecture notes.pdf", text: "Probability and statistics"), file("Travel itinerary.pdf", text: "Train tickets and hotel bookings")]
        let context = CapturedContext(text: "Could you send over your latest software engineering resume as a PDF before our conversation? I’d love to learn more about your projects and experience.", source: "Gmail", capturedAt: now)
        for useSemantics in [false, true] {
            let response = FileRanker(semanticReranking: useSemantics).rank(files: files, context: context)
            XCTAssertEqual(response.first?.file.id, newest.id, "Latest version must win with semantic reranking \(useSemantics)")
            XCTAssertTrue(response.first?.reason.contains("Most recently modified") == true)
        }
    }

    func testLatestVersionUsesRelativeRecencyEvenWhenAllVersionsAreOld() {
        let newer = file("Orion proposal v3.pdf", text: "Orion proposal for a robotics demonstration and navigation study", daysOld: 365)
        let older = file("Orion proposal v2.pdf", text: "Orion robotics proposal", daysOld: 730)
        let response = ranker.rank(files: [older, newer], context: CapturedContext(text: "Please send the newest Orion robotics proposal.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, newer.id)
    }

    func testLatestRequestDoesNotPromoteUnrelatedNewerContentInSimilarFilename() {
        let relevant = file("Research report 2024.pdf", text: "Robotics motion planning navigation algorithms and evaluation", daysOld: 100)
        let unrelated = file("Research report 2026.pdf", text: "Soil biology earthworm habitat and rainfall observations")
        let response = ranker.rank(files: [unrelated, relevant], context: CapturedContext(text: "Please attach the latest robotics motion planning report.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, relevant.id)
    }

    func testLatestRequestPreservesAnExplicitYearConstraint() {
        let intended = file("Annual budget 2024.pdf", text: "Annual budget for 2024", daysOld: 200)
        let newer = file("Annual budget 2026.pdf", text: "Annual budget for 2026")
        let response = ranker.rank(files: [newer, intended], context: CapturedContext(text: "Send the latest annual budget for 2024.", source: "Gmail", capturedAt: now))
        XCTAssertEqual(response.first?.file.id, intended.id)
    }

    func testZeroLimitAndEmptyContextReturnNothing() {
        let files = [file("Resume.pdf")]
        XCTAssertTrue(ranker.rank(files: files, context: CapturedContext(text: "", source: "Gmail")).isEmpty)
        XCTAssertTrue(ranker.rank(files: files, context: CapturedContext(text: "Resume", source: "Gmail"), limit: 0).isEmpty)
    }

    func testMatchingFolderAloneDoesNotMakeEveryDocumentRelevant() {
        let item = IndexedFile(url: URL(fileURLWithPath: "/fixtures/Resume/holiday.jpg"))
        XCTAssertTrue(ranker.rank(files: [item], context: CapturedContext(text: "Please send your resume.", source: "Gmail")).isEmpty)
    }

    func testSelectedFolderIndexExtractsPDFTextAndSkipsHiddenSecretsAndSymlinks() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("FilerCoreTests-\(UUID().uuidString)", isDirectory: true)
        let outside = manager.temporaryDirectory.appendingPathComponent("FilerOutside-\(UUID().uuidString).txt")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root); try? manager.removeItem(at: outside) }
        try "Robotics assignment odometry notes".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "do not index".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "do not index".write(to: root.appendingPathComponent("credentials.json"), atomically: true, encoding: .utf8)
        try "do not index".write(to: outside, atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: root.appendingPathComponent("outside.txt"), withDestinationURL: outside)
        let dependencies = root.appendingPathComponent("node_modules", isDirectory: true)
        try manager.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try "do not index dependency files".write(to: dependencies.appendingPathComponent("dependency.txt"), atomically: true, encoding: .utf8)
        try Data([0xff, 0xd8, 0xff]).write(to: root.appendingPathComponent("screenshot.jpg"))
        try minimalPDF("Resume Cornell software engineering experience").write(to: root.appendingPathComponent("opaque.pdf"))

        let result = await FolderIndexer().index(folder: root)
        XCTAssertEqual(Set(result.files.map(\.name)), ["notes.md", "screenshot.jpg", "opaque.pdf"])
        XCTAssertTrue(result.files.first { $0.name == "opaque.pdf" }?.contentExcerpt.contains("Cornell") == true)
        XCTAssertEqual(result.files.first { $0.name == "screenshot.jpg" }?.contentExcerpt, "")
        XCTAssertTrue(result.files.first { $0.name == "notes.md" }?.contentExcerpt.contains("odometry") == true)
    }

    func testIndexLimitIsReportedInsteadOfClaimingFullCoverage() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("FilerLimitTests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for number in 0..<4 {
            try "A fixture document".write(to: root.appendingPathComponent("file\(number).txt"), atomically: true, encoding: .utf8)
        }
        let result = await FolderIndexer(maximumFiles: 2).index(folder: root)
        XCTAssertEqual(result.files.count, 2)
        XCTAssertNotNil(result.message)
    }

    func testRootPDFIsNotCrowdedOutByNewerFilesInNestedProject() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("FilerBreadthTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("DownloadedProject", isDirectory: true)
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for number in 0..<50 {
            try "Unrelated project source".write(to: project.appendingPathComponent("source\(number).txt"), atomically: true, encoding: .utf8)
        }
        let resume = root.appendingPathComponent("Resume.pdf")
        try minimalPDF("Resume software engineering experience").write(to: resume)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: resume.path)
        let result = await FolderIndexer(maximumFiles: 3).index(folder: root)
        XCTAssertEqual(result.files.count, 3)
        XCTAssertTrue(result.files.contains { $0.url == resume })
        XCTAssertTrue(result.files.first { $0.url == resume }?.contentExcerpt.contains("engineering") == true)
        XCTAssertNotNil(result.message)
    }

    private func minimalPDF(_ text: String) -> Data {
        let content = "BT /F1 12 Tf 72 720 Td (\(text)) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
