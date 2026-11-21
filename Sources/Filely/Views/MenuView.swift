import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                FilelyMark(size: 31)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Filely").font(.system(size: 15, weight: .semibold))
                    Text("A little less searching.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Automatic suggestions", isOn: Binding(get: { model.isEnabled }, set: model.setEnabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    StatusDot(active: model.isReady && model.isEnabled)
                    Text(model.stateTitle).font(.system(size: 12, weight: .medium))
                }
                Text(model.isReady ? "Click Attach in Gmail. Filely takes it from there." : "Finish setup to get suggestions in Gmail.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)
                if !model.files.isEmpty {
                    Text("\(model.files.count.formatted()) files · \(model.folders.count) folder\(model.folders.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 3)
                }
            }
            Button(model.isReady ? "Open Filely" : "Finish Setup") { model.showMainWindow?() }
                .buttonStyle(.glass).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                QuietLabel(title: "On your Mac", symbol: "lock.shield")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(19).frame(width: 300).tint(FilelyStyle.accent)
    }
}
