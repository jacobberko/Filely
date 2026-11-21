import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(FilerStyle.separator).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    switch model.section {
                    case .overview: overview
                    case .folders: folderPage
                    case .settings: settingsPage
                    }
                }
                .frame(maxWidth: 650, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 51).padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 780, minHeight: 570)
        .tint(FilerStyle.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                FilerMark(size: 35)
                Text("Filer").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.7)
            }.padding(.horizontal, 22).padding(.top, 52).padding(.bottom, 33)
            VStack(spacing: 5) {
                ForEach(AppSection.allCases) { section in
                    Button { model.section = section } label: {
                        HStack(spacing: 11) {
                            Image(systemName: section.symbol).font(.system(size: 15)).frame(width: 20)
                            Text(section.rawValue).font(.system(size: 13, weight: model.section == section ? .semibold : .regular))
                            Spacer()
                            if section == .folders && !model.folders.isEmpty {
                                Text("\(model.folders.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal, 12).frame(height: 36)
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                            .background(model.section == section ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 12)
            Spacer(minLength: 40)
            VStack(alignment: .leading, spacing: 10) {
                QuietLabel(title: "Only on your Mac", symbol: "lock.shield")
                Text("Filer 0.1 · Prototype").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(24)
        }.frame(width: 192).frame(maxHeight: .infinity).background(.ultraThinMaterial)
    }

    private var overview: some View {
        Group {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(active: model.isReady && model.isEnabled)
                    Text(model.isReady ? (model.isEnabled ? "READY WHEN YOU ARE" : "PAUSED") : "A LITTLE SETUP. A LOT LESS SEARCHING.")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                }
                Text("The right file.\nRight here.")
                    .font(.system(size: 35, weight: .semibold)).tracking(-1.2).fixedSize(horizontal: false, vertical: true)
                Text("Helpful suggestions, right beside your attachment picker.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
            }
            if model.isReady { readyCard } else { setupCard }
            demoCard
            HStack(spacing: 18) {
                QuietLabel(title: "Gmail in Chrome", symbol: "envelope")
                QuietLabel(title: "Local matching", symbol: "checkmark.shield")
            }.frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var setupCard: some View {
        Surface {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Make yourself at home").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("\(model.readyCount) of 2").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                setupRow(number: 1, complete: !model.folders.isEmpty, title: "Choose your files", subtitle: model.folders.isEmpty ? "Add a folder with your resumes, PDFs, or other documents." : "\(model.folders.count) folder\(model.folders.count == 1 ? "" : "s") added · \(model.files.count) files", button: model.folders.isEmpty ? "Choose Folder…" : "Manage", action: {
                    if model.folders.isEmpty { model.chooseFolder() } else { model.section = .folders }
                })
                Divider().opacity(0.6)
                setupRow(number: 2, complete: model.isTrusted, title: "Connect to your workflow", subtitle: "Allow Accessibility so Filer can read Gmail context and select your chosen file.", button: model.isTrusted ? "Enabled" : "Enable…", action: model.requestPermission)
                if model.isIndexing {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your files on this Mac…").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if !model.folders.isEmpty && !model.isTrusted {
                    Text("In System Settings → Privacy & Security → Accessibility, turn on Filer. This window updates automatically.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func setupRow(number: Int, complete: Bool, title: String, subtitle: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(complete ? FilerStyle.accent.opacity(0.11) : Color.primary.opacity(0.05))
                if complete { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(FilerStyle.accent) }
                else { Text("\(number)").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary) }
            }.frame(width: 27, height: 27)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(2)
            }
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small).buttonStyle(.glass).disabled(complete && number == 2)
        }
    }

    private var readyCard: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(FilerStyle.accent).font(.system(size: 23))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.stateTitle).font(.system(size: 14, weight: .semibold))
                        Text("\(model.files.count.formatted()) files in \(model.folders.count) folder\(model.folders.count == 1 ? "" : "s")")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Suggestions", isOn: Binding(get: { model.isEnabled }, set: model.setEnabled)).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Divider()
                Text("Open one Gmail compose draft in Chrome, then click the paperclip. Filer will look for files that fit your draft.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }
        }
    }

    private var demoCard: some View {
        Button { model.showDemoWindow?() } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(FilerStyle.accent.opacity(0.08)).frame(width: 47, height: 47)
                    Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 20)).foregroundStyle(FilerStyle.accent)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("See it in action").font(.system(size: 13, weight: .semibold))
                    Text("Try a sample email and files. No setup needed.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").foregroundStyle(.secondary).font(.system(size: 12, weight: .medium))
            }.padding(17).contentShape(RoundedRectangle(cornerRadius: 17))
                .background(FilerStyle.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(FilerStyle.accent.opacity(0.11), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private var folderPage: some View {
        Group {
            pageHeading("Your folders", subtitle: "A smaller search space. A better starting point.")
            if model.folders.isEmpty {
                Surface {
                    VStack(spacing: 15) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(FilerStyle.accent)
                        Text("Start with one familiar folder").font(.system(size: 15, weight: .semibold))
                        Text("Your resumes, coursework, or Downloads are a good place to start.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Choose Folder…", action: model.chooseFolder).buttonStyle(.glassProminent).controlSize(.large)
                    }.frame(maxWidth: .infinity).padding(.vertical, 28)
                }
            } else {
                Surface {
                    VStack(spacing: 14) {
                        ForEach(model.folders) { folder in
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill").font(.system(size: 27)).foregroundStyle(.blue.gradient)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(folder.url.lastPathComponent).font(.system(size: 13, weight: .medium))
                                    Text(folder.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(model.isIndexing && folder.fileCount == 0 ? "Reading…" : "\(folder.fileCount.formatted()) files").font(.system(size: 11)).foregroundStyle(.secondary)
                                SmallIconButton(symbol: "minus.circle", help: "Remove folder from Filer") { model.removeFolder(folder) }
                            }
                            if folder.id != model.folders.last?.id { Divider() }
                        }
                    }
                }
                HStack {
                    Button("Add Folder…", systemImage: "plus", action: model.chooseFolder).buttonStyle(.glass)
                    Spacer()
                    if model.isIndexing { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise", action: model.reindex).buttonStyle(.glass).disabled(model.isIndexing)
                }
                if !model.folders.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: model.isWatchingFiles ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.isWatchingFiles ? Color.accentColor : .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.isWatchingFiles ? "Updates automatically" : "Automatic updates unavailable")
                                .font(.system(size: 11, weight: .medium))
                            if model.isIndexing {
                                Text(model.files.isEmpty ? "Reading your files…" : "Updating in the background…")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            } else if !model.isWatchingFiles {
                                Text("Use Refresh to try again and check for changed files.")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            } else if let updated = model.lastIndexedAt {
                                Text("Last checked \(updated.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("Your files stay yours", systemImage: "lock.shield").font(.system(size: 13, weight: .medium))
                Text("Filer reads only folders you add. PDF and text document contents help with matching; other files can be found by name. Indexing stays on this Mac. Choosing a suggestion attaches that file to your draft.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Text("Added, edited, renamed, and removed files update in the background while Filer is running. Scanned PDFs and image contents aren’t read in this prototype.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                if let note = model.indexingNote { Text(note).font(.system(size: 11)).foregroundStyle(.orange) }
            }.padding(.horizontal, 3)
        }
    }

    private var settingsPage: some View {
        Group {
            pageHeading("A few preferences", subtitle: "Quiet by default. There when you need it.")
            Surface {
                VStack(spacing: 19) {
                    Toggle(isOn: Binding(get: { model.isEnabled }, set: model.setEnabled)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Automatic suggestions").font(.system(size: 13, weight: .medium))
                            Text("Appear beside Chrome’s attachment picker.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).controlSize(.small)
                    Divider()
                    Toggle(isOn: $model.showReasons) {
                        Text("Show why a file matches").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).controlSize(.small).onChange(of: model.showReasons) { model.saveReasons() }
                    Divider()
                    HStack {
                        Text("Appearance").font(.system(size: 13))
                        Spacer()
                        Picker("Appearance", selection: Binding(get: { model.appearance }, set: model.changeAppearance)) {
                            Text("System").tag("System"); Text("Light").tag("Light"); Text("Dark").tag("Dark")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                }
            }
            Surface {
                HStack(spacing: 13) {
                    Image(systemName: "hand.raised").font(.system(size: 23)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Accessibility").font(.system(size: 13, weight: .medium))
                        Text(model.isTrusted ? "Connected to your workflow" : "Needed for automatic suggestions")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.isTrusted ? "Manage…" : "Enable…", action: model.requestPermission).buttonStyle(.glass).controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                StatusDot(active: model.context != nil)
                Text(model.isTrusted ? model.status : "Waiting for Accessibility access")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            DisclosureGroup("Connection details") {
                Text(model.connectionDetail).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Text("This prototype uses local matching. Gmail context is held briefly in memory and is never saved. Choosing a suggestion selects an attachment; Filer never sends your email.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
        }
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.7)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }.padding(.bottom, 7)
    }
}
