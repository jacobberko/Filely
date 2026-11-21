import SwiftUI
import FilerCore

struct SuggestionsView: View {
    @ObservedObject var model: AppModel
    @FocusState private var keyboardFocus: Bool

    private var selected: FileSuggestion? {
        model.suggestions.first { $0.id == model.selectedSuggestion } ?? model.suggestions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FilerMark(size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Right here").font(.system(size: 16, weight: .semibold)).tracking(-0.3)
                    Text(model.isDemo ? "Filer · Sample email" : "Filer · Gmail in Chrome").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                SmallIconButton(symbol: "xmark", help: "Dismiss suggestions", action: model.dismissSuggestions)
            }.padding(.bottom, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    suggestionContent
                }
                .onChange(of: model.selectedSuggestion) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: model.errorMessage) { _, error in
                    if error != nil { proxy.scrollTo("selection-error", anchor: .bottom) }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 18)
            if let selected {
                Button {
                    model.select(selected)
                } label: {
                    HStack(spacing: 8) {
                        if model.isSelecting { ProgressView().controlSize(.small) }
                        else { Image(systemName: model.demoSelectionName == nil ? "paperclip" : "checkmark") }
                        Text(model.isDemo ? (model.demoSelectionName == nil ? "Choose sample file" : "Selected for sample email") : (model.isSelecting ? "Selecting…" : "Attach selected file"))
                        Spacer()
                        Image(systemName: "return").font(.system(size: 11)).opacity(0.6)
                    }.font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
                }.buttonStyle(.glassProminent).tint(FilerStyle.accent).disabled(model.isSelecting)
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 12)
            }
            HStack(spacing: 5) {
                Image(systemName: model.isDemo ? "play.circle" : "lock").font(.system(size: 9))
                Text(model.isDemo ? "Demo · sample files only" : "Matched privately on your Mac").font(.system(size: 10))
                Spacer()
                Button { model.showMainWindow?() } label: { Image(systemName: "gearshape").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Open Filer")
            }.foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 348, height: 508)
        .tint(FilerStyle.accent)
        .focusable().focusEffectDisabled().focused($keyboardFocus)
        .onAppear { keyboardFocus = true }
        .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
        .onKeyPress(.space) { if let selected { model.previewFile?(selected.file.url) }; return .handled }
        .onExitCommand(perform: model.dismissSuggestions)
    }

    private var suggestionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let context = model.context, !context.text.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Label(model.isDemo ? "SAMPLE CONTEXT" : "FROM YOUR EMAIL", systemImage: "text.bubble")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                    Text(context.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12)).lineLimit(3).lineSpacing(2).foregroundStyle(.primary.opacity(0.8))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 17)
            }

            if (model.isRanking && model.suggestions.isEmpty) || (model.isIndexing && model.files.isEmpty && !model.isDemo) {
                emptyState("Finding a good fit", detail: "Matching this email with your files…", symbol: "sparkle.magnifyingglass", loading: true)
            } else if model.context == nil {
                emptyState("A little more context", detail: "Open one Gmail compose draft before clicking Attach. If Chrome hasn’t shared its text yet, close the picker and try again.", symbol: "text.bubble")
            } else if model.files.isEmpty && !model.isDemo {
                emptyState("Add your files first", detail: "Choose a folder for Filer to search, then try this attachment again.", symbol: "folder.badge.plus")
                Button("Choose a folder…") { model.showMainWindow?(); model.chooseFolder() }.buttonStyle(.glass).frame(maxWidth: .infinity)
            } else if model.suggestions.isEmpty {
                emptyState("No close match yet", detail: "You can keep browsing in the file picker. Filer won’t guess when it can’t find a good fit.", symbol: "doc.text.magnifyingglass")
            } else {
                HStack {
                    Text("SUGGESTED FOR YOU").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.suggestions.count) files").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 2).padding(.bottom, 9)
                VStack(spacing: 7) {
                    ForEach(model.suggestions) { suggestion in
                        suggestionRow(suggestion).id(suggestion.id)
                    }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14).id("selection-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionRow(_ suggestion: FileSuggestion) -> some View {
        let isSelected = selected?.id == suggestion.id
        return HStack(spacing: 10) {
            NativeFileIcon(url: suggestion.file.url, size: 35)
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if model.showReasons {
                    Text(suggestion.reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(suggestion.file.typeLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(suggestion.file.url.deletingLastPathComponent().lastPathComponent)
                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 9) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? FilerStyle.accent : Color.secondary.opacity(0.25)).font(.system(size: 14))
                Button { model.previewFile?(suggestion.file.url) } label: {
                    Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Preview \(suggestion.file.name)").accessibilityLabel("Preview \(suggestion.file.name)")
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .background(isSelected ? FilerStyle.accent.opacity(0.10) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(isSelected ? FilerStyle.accent.opacity(0.24) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture { model.selectedSuggestion = suggestion.id; model.demoSelectionName = nil; keyboardFocus = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(suggestion.file.name), \(suggestion.reason)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private func emptyState(_ title: String, detail: String, symbol: String, loading: Bool = false) -> some View {
        VStack(spacing: 13) {
            if loading { ProgressView().controlSize(.regular).padding(10) }
            else { Image(systemName: symbol).font(.system(size: 33, weight: .light)).foregroundStyle(.secondary) }
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
        }.frame(maxWidth: .infinity).padding(.horizontal, 10).padding(.vertical, 20)
    }
}
