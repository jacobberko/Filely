import AppKit
import SwiftUI
import CoreText
import FilelyCore

@MainActor
final class DemoController: ObservableObject {
    @Published var isLoading = false
    @Published var selectedName: String?
    @Published var errorMessage: String?
    private let model: AppModel
    private var listener: NSObjectProtocol?
    static let email = "Could you send over your latest software engineering resume as a PDF before our conversation? I’d love to learn more about your projects and experience."

    init(model: AppModel) {
        self.model = model
        listener = NotificationCenter.default.addObserver(forName: .filelyDemoSelected, object: nil, queue: .main) { [weak self] note in
            guard let url = note.object as? URL else { return }
            Task { @MainActor in self?.selectedName = url.lastPathComponent }
        }
    }

    func showSuggestions() {
        isLoading = true
        selectedName = nil
        errorMessage = nil
        Task {
            do {
                let folder = try makeSampleFiles()
                let result = await FolderIndexer().index(folder: folder)
                model.beginDemo(files: result.files, text: Self.email)
            } catch { errorMessage = "Couldn’t create the sample files. \(error.localizedDescription)" }
            isLoading = false
        }
    }

    func close() { model.endDemo() }

    private func makeSampleFiles() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Filely-Sample-Files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let documents = [
            ("Alex Morgan — Resume.pdf", "ALEX MORGAN\nSoftware Engineer\n\nExperience\nSoftware engineering internship: built reliable backend services.\nProjects\nOn-device machine learning and native macOS productivity tools.\nSkills\nSwift, Python, model evaluation, product development.", 0.0),
            ("Alex Morgan — Resume 2024.pdf", "ALEX MORGAN\nSoftware engineering resume\n\nEducation and early coursework\nAn older resume, before the latest internship and projects.", 730.0),
            ("Project portfolio.pdf", "PROJECT PORTFOLIO\nSoftware engineering projects\n\nA collection of native applications, machine learning experiments,\nand web tools. Includes project descriptions and architecture notes.", 12.0),
            ("Lecture notes.pdf", "COURSE NOTES\nProbability and statistics\n\nConditional probability, distributions, and hypothesis testing.", 1.0),
            ("Travel itinerary.pdf", "WEEKEND ITINERARY\n\nTrain tickets, hotel check-in, and restaurant bookings.", 2.0)
        ]
        for (name, text, days) in documents {
            let url = folder.appendingPathComponent(name)
            try writePDF(text: "FILER DEMO · SAMPLE DOCUMENT\n\n" + text, to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: url.path)
        }
        return folder
    }

    private func writePDF(text: String, to url: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
            throw NSError(domain: "FilelyDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF creation failed."])
        }
        context.beginPDFPage(nil)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: index < 3 ? 16 : 12), .foregroundColor: NSColor.black])
            context.textPosition = CGPoint(x: 54, y: 730 - index * 25)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
    }
}

struct DemoView: View {
    @ObservedObject var controller: DemoController
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 9) {
                Image(systemName: "envelope.open").font(.system(size: 17)).foregroundStyle(FilelyStyle.accent)
                Text("A little preview").font(.system(size: 18, weight: .semibold))
                Spacer()
                Text("SAMPLE EMAIL").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 6).background(Color.primary.opacity(0.04), in: Capsule())
            }
            Surface {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Text("J").font(.system(size: 15, weight: .medium)).foregroundStyle(FilelyStyle.accent).frame(width: 33, height: 33).background(FilelyStyle.accent.opacity(0.09), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Jamie · Recruiting").font(.system(size: 12, weight: .semibold))
                            Text("To you").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    Text("Your resume for our conversation").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
                    Text("Hi Alex,\n\n" + DemoController.email + "\n\nThanks,\nJamie")
                        .font(.system(size: 13)).lineSpacing(4).foregroundStyle(.primary.opacity(0.8))
                }
            }
            if let name = controller.selectedName {
                Label(name, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(FilelyStyle.accent)
            }
            if let error = controller.errorMessage { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Button(action: controller.showSuggestions) {
                    Label(controller.isLoading ? "Finding files…" : "Show file suggestions", systemImage: "paperclip")
                        .padding(.vertical, 4)
                }.buttonStyle(.glassProminent).tint(FilelyStyle.accent).disabled(controller.isLoading)
                Spacer()
                Text("Sample files. No email is sent.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(30).padding(.top, 20).frame(width: 540, height: 510).background(Color(nsColor: .windowBackgroundColor))
    }
}
