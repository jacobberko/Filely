import AppKit
import SwiftUI
import QuickLookUI

@main
struct FilerApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FilerAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class FilerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @preconcurrency QLPreviewPanelDataSource {
    private var model: AppModel!
    private var mainWindow: NSWindow!
    private var suggestionPanel: FilerPanel!
    private var demoWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var previewURL: URL?
    private var demoController: DemoController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        model = AppModel()
        model.changeAppearance(model.appearance)
        model.showMainWindow = { [weak self] in self?.openMainWindow() }
        model.showSuggestionWindow = { [weak self] session in self?.presentSuggestions(beside: session?.frame) }
        model.hideSuggestionWindow = { [weak self] in self?.suggestionPanel?.orderOut(nil) }
        model.showDemoWindow = { [weak self] in self?.openDemo() }
        model.previewFile = { [weak self] url in self?.preview(url) }
        createMainWindow()
        createSuggestionPanel()
        createStatusItem()
        if CommandLine.arguments.contains("--demo") { openDemo() }
        else { openMainWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow(); return true
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === demoWindow {
            demoController?.close()
            model.endDemo()
        }
        if notification.object as? NSWindow === mainWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Filer")
        appMenu.addItem(withTitle: "About Filer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let overview = appMenu.addItem(withTitle: "Open Filer", action: #selector(openOverview), keyEquivalent: "0")
        overview.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Filer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Filer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func createMainWindow() {
        mainWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        mainWindow.title = "Filer"
        mainWindow.titleVisibility = .hidden
        mainWindow.titlebarAppearsTransparent = true
        mainWindow.titlebarSeparatorStyle = .none
        mainWindow.isReleasedWhenClosed = false
        mainWindow.delegate = self
        mainWindow.minSize = NSSize(width: 780, height: 590)
        mainWindow.contentView = NSHostingView(rootView: MainView(model: model))
        mainWindow.center()
        mainWindow.setFrameAutosaveName("FilerMainWindow")
    }

    private func createSuggestionPanel() {
        suggestionPanel = FilerPanel(contentRect: NSRect(x: 0, y: 0, width: 348, height: 508), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        suggestionPanel.isFloatingPanel = true
        suggestionPanel.level = .floating
        suggestionPanel.hidesOnDeactivate = false
        suggestionPanel.isReleasedWhenClosed = false
        suggestionPanel.backgroundColor = .clear
        suggestionPanel.isOpaque = false
        suggestionPanel.hasShadow = true
        suggestionPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        suggestionPanel.animationBehavior = .utilityWindow
        suggestionPanel.title = "Filer Suggestions"
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 348, height: 508))
        glass.style = .regular
        glass.cornerRadius = 23
        let hosting = NSHostingView(rootView: SuggestionsView(model: model))
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []
        glass.contentView = hosting
        suggestionPanel.contentView = glass
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Filer")
            button.image?.isTemplate = true
            button.toolTip = "Filer — your next attachment, right here"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuView(model: model))
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func openMainWindow() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentSuggestions(beside axFrame: CGRect?) {
        let size = suggestionPanel.frame.size
        let anchor: CGRect
        if let axFrame {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            anchor = CGRect(x: axFrame.minX, y: top - axFrame.maxY, width: axFrame.width, height: axFrame.height)
        } else if let demoWindow { anchor = demoWindow.frame }
        else { anchor = mainWindow.frame }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.maxX + 12
        if x + size.width > bounds.maxX - 12 { x = anchor.minX - size.width - 12 }
        x = min(max(x, bounds.minX + 12), bounds.maxX - size.width - 12)
        let y = min(max(anchor.maxY - size.height, bounds.minY + 12), bounds.maxY - size.height - 12)
        suggestionPanel.setFrameOrigin(NSPoint(x: x, y: y))
        if !suggestionPanel.isVisible {
            suggestionPanel.alphaValue = 0
            suggestionPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                suggestionPanel.animator().alphaValue = 1
            }
        }
        if axFrame == nil { suggestionPanel.makeKeyAndOrderFront(nil) }
    }

    @objc private func openSettings() { model.section = .settings; openMainWindow() }
    @objc private func openOverview() { model.section = .overview; openMainWindow() }

    private func openDemo() {
        popover.performClose(nil)
        if demoWindow == nil {
            let controller = DemoController(model: model)
            demoController = controller
            demoWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 510), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            demoWindow?.title = "Filer — Sample email"
            demoWindow?.titlebarAppearsTransparent = true
            demoWindow?.titleVisibility = .hidden
            demoWindow?.isReleasedWhenClosed = false
            demoWindow?.delegate = self
            demoWindow?.contentView = NSHostingView(rootView: DemoView(controller: controller))
            demoWindow?.center()
            if let frame = demoWindow?.frame { demoWindow?.setFrameOrigin(NSPoint(x: frame.minX - 130, y: frame.minY)) }
        }
        mainWindow.orderOut(nil)
        NSApp.setActivationPolicy(.regular)
        demoWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func preview(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }
}

final class FilerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
