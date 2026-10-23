import AppKit
import SwiftUI

/// The menu bar.
struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    private var textView: EditorTextView? { EditorRegistry.shared.textView(for: workspace) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Welcome Window") { openWindow(id: "welcome") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New File") { workspace?.newFile() }
                .keyboardShortcut("n")
                .disabled(workspace == nil)
            Button("New Project from Template…") { openWindow(id: "templates") }
            Divider()
            Button("Open Folder…") { AppActions.openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Open File…") { AppActions.openFilePanel() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.save() }
                .keyboardShortcut("s")
                .disabled(workspace == nil)
            Button("Save All") { workspace?.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("Close") {
                // Like a browser: close the editor tab, then the window.
                if let workspace, workspace.documents.count > 1, NSApp.keyWindow?.representedURL == workspace.root {
                    workspace.closeActiveTab()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
            Divider()
            Button("Export PDF…") { workspace?.exportPDFWithPanel(window: NSApp.keyWindow) }
                .keyboardShortcut("e")
                .disabled(workspace == nil)
            Button("Export PDF in Place") { workspace?.exportPDFInPlace() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Button("Show in Finder") { workspace?.showInFinder() }
                .disabled(workspace == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Project…") {
                workspace?.sidebarTab = .search
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(workspace == nil)
        }
        CommandMenu("Editor") {
            Button("Bold") { textView?.makeBold(nil) }.keyboardShortcut("b")
            Button("Italic") { textView?.makeItalic(nil) }.keyboardShortcut("i")
            Button("Underline") { textView?.makeUnderline(nil) }.keyboardShortcut("u")
            Button("Heading") { textView?.makeHeading(nil) }.keyboardShortcut("h", modifiers: [.command, .option])
            Button("Bullet List") { textView?.makeBulletList(nil) }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Numbered List") { textView?.makeNumberedList(nil) }.keyboardShortcut("l", modifiers: [.command, .option, .shift])
            Button("Inline Math") { textView?.makeInlineMath(nil) }.keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
            Button("Toggle Comment") { textView?.toggleComment(nil) }.keyboardShortcut("/")
            Button("Duplicate Line") { textView?.duplicateLine(nil) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Increase Font Size") { textView?.increaseFontSize(nil) ?? bumpFont(1) }.keyboardShortcut("+")
            Button("Decrease Font Size") { textView?.decreaseFontSize(nil) ?? bumpFont(-1) }.keyboardShortcut("-")
            Button("Reset Font Size") { AppSettings.shared.editorFontSize = AppSettings.defaultFontSize }.keyboardShortcut("0")
        }
        CommandMenu("Preview") {
            Button(workspace?.previewLock == nil ? "Lock Preview to This File" : "Unlock Preview") {
                guard let workspace else { return }
                workspace.previewLock = workspace.previewLock == nil ? workspace.mainURL : nil
                workspace.scheduleCompile()
            }
            .keyboardShortcut("l", modifiers: [.command, .control])
            .disabled(workspace == nil)
            Toggle("Live Preview", isOn: Binding(
                get: { workspace?.livePreview ?? true },
                set: { workspace?.livePreview = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .control])
                .disabled(workspace == nil)
            Toggle("Follow Cursor in Preview", isOn: Binding(
                get: { workspace?.followCursor ?? true },
                set: { workspace?.followCursor = $0 }))
                .disabled(workspace == nil)
            Button(workspace?.previewDetached == true ? "Return Preview to Window" : "Detach Preview") {
                workspace?.previewDetached.toggle()
            }
            .disabled(workspace == nil)
            Divider()
            Button("Reload Fonts") { workspace?.reloadFonts() }
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Welcome to Inkwell") { openWindow(id: "welcome") }
            Button("What's New") { openWindow(id: "whats-new") }
            Button("Typst Documentation") { openWindow(id: "docs") }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("New Project from Template") { openWindow(id: "templates") }
            Divider()
            Button("Show Previous Tab") { workspace?.showNextTab(-1) }
                .keyboardShortcut("{", modifiers: [.command, .shift])
            Button("Show Next Tab") { workspace?.showNextTab(1) }
                .keyboardShortcut("}", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Typst Documentation") { openWindow(id: "docs") }
            Button("What's New in Inkwell") { openWindow(id: "whats-new") }
        }
        CommandGroup(replacing: .sidebar) {
            Button("Show Files") { workspace?.sidebarTab = .files }.keyboardShortcut("1")
            Button("Show Find") { workspace?.sidebarTab = .search }.keyboardShortcut("2")
            Button("Show Outline") { workspace?.sidebarTab = .outline }.keyboardShortcut("3")
            Button("Show Symbols") { workspace?.sidebarTab = .symbols }.keyboardShortcut("4")
            Button("Show Diagnostics") { workspace?.sidebarTab = .diagnostics }.keyboardShortcut("5")
        }
    }

    private func bumpFont(_ delta: Double) {
        let s = AppSettings.shared
        s.editorFontSize = max(AppSettings.minFontSize, min(AppSettings.maxFontSize, s.editorFontSize + delta))
    }
}
