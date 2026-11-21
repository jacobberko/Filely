import SwiftUI
import AppKit

enum FilelyStyle {
    static let accent = Color(red: 0.08, green: 0.47, blue: 0.59)
    static let separator = Color.primary.opacity(0.07)
}

struct FilelyMark: View {
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.26, green: 0.70, blue: 0.79), FilelyStyle.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
            Image(systemName: "paperclip")
                .font(.system(size: size * 0.53, weight: .medium))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-8))
        }
        .frame(width: size, height: size)
        .shadow(color: FilelyStyle.accent.opacity(0.15), radius: size * 0.16, y: size * 0.07)
        .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    var active: Bool
    var body: some View {
        Circle().fill(active ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
    }
}

struct QuietLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(FilelyStyle.separator, lineWidth: 1))
    }
}

struct NativeFileIcon: View {
    let url: URL
    var size: CGFloat = 38
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SmallIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
        }.buttonStyle(.plain).foregroundStyle(.secondary).help(help).accessibilityLabel(help)
    }
}
