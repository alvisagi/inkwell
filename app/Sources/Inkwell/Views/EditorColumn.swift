import AppKit
import SwiftUI
import TypstCore

/// Tabs, banners, the editor (or a media/bibliography view) and the bottom bar.
struct EditorColumn: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            if workspace.documents.count > 1 {
                EditorTabBar(workspace: workspace)
                Divider()
            }
            if let doc = workspace.activeDocument, workspace.mediaURL == nil {
                DocumentBanners(document: doc, workspace: workspace)
            }
            content
            if workspace.mediaURL == nil, workspace.activeDocument != nil {
                Divider()
                EditorBottomBar(workspace: workspace)
            }
        }
        .background(Color(nsColor: settings.theme.background))
    }

    @ViewBuilder
    private var content: some View {
        if let media = workspace.mediaURL {
            MediaView(url: media)
        } else if let doc = workspace.activeDocument {
            if doc.kind == .bibliography {
                BibLibraryView(document: doc, workspace: workspace)
            } else {
                EditorView(workspace: workspace)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("No File Open").font(.headline)
                Text("Select a file in the sidebar to start editing.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Notices about the document: conflicts with the disk version, save errors,
/// errors in this file.
struct DocumentBanners: View {
    @ObservedObject var document: OpenDocument
    @ObservedObject var workspace: Workspace
    @ObservedObject private var compilers = CompilerManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if document.externalChange {
                banner(icon: "exclamationmark.arrow.triangle.2.circlepath", tint: .orange) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(document.name)” was changed on disk").bold()
                        Text("This file was modified by another application while you were editing it. Keep your edits (they'll overwrite the on-disk version when saved), or reload the version from disk.")
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    Button("Keep My Edits") { document.keepEdits() }
                    Button("Reload from Disk") { document.reloadFromDisk() }
                }
            }
            if let error = document.saveError {
                banner(icon: "externaldrive.badge.exclamationmark", tint: .red) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn't save “\(document.name)”").bold()
                        Text("Your edits are still in Inkwell but haven't been written to disk. \(error)")
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    Button("Try again") { document.save() }
                }
            }
            if CompilerManager.shared.activeBinary != nil, document.kind == .typst {
                banner(icon: "clock.arrow.circlepath", tint: .blue) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Using an old Typst compiler (\(CompilerManager.shared.selected))").bold()
                        Text("This document is compiled with Typst \(CompilerManager.shared.selected), not the latest. Change it in Settings ▸ General ▸ Typst Compiler.")
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    Button("Use Latest") {
                        CompilerManager.shared.selected = CompilerManager.latest
                        workspace.scheduleCompile()
                    }
                }
            } else if usesDeprecatedFeatures {
                banner(icon: "exclamationmark.triangle", tint: .yellow) {
                    Text("This file uses deprecated Typst features — it may target an older version.")
                } actions: {
                    EmptyView()
                }
            }
            if let first = fileErrors.first {
                DiagnosticBanner(diagnostic: first, count: fileErrors.count) {
                    workspace.reveal(first)
                }
            }
        }
    }

    private var usesDeprecatedFeatures: Bool {
        workspace.allDiagnostics.contains { !$0.isError && $0.path == document.url.path && $0.message.contains("deprecated") }
    }

    private var fileErrors: [TypstCore.Diagnostic] {
        workspace.diagnostics.filter { $0.isError && $0.path == document.url.path }
    }

    private func banner<Content: View, Actions: View>(
        icon: String, tint: Color, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.title3)
            content().font(.callout)
            Spacer()
            HStack { actions() }.controlSize(.small)
        }
        .padding(10)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A one-line summary of the first error in the open file.
struct DiagnosticBanner: View {
    let diagnostic: TypstCore.Diagnostic
    let count: Int
    let action: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(diagnostic.message).lineLimit(expanded ? nil : 1)
                if let line = diagnostic.line {
                    Text("line \(Int(line))").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if count > 1 {
                    Text("+\(count - 1)").font(.caption).foregroundStyle(.secondary)
                }
                if !diagnostic.hints.isEmpty {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded {
                ForEach(diagnostic.hints, id: \.self) { hint in
                    Text("hint: \(hint)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Tabs for open documents.
struct EditorTabBar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.documents) { doc in
                    EditorTab(document: doc, isActive: doc.url == workspace.activeURL) {
                        workspace.mediaURL = nil
                        workspace.activeURL = doc.url
                        workspace.scheduleCompile()
                    } close: {
                        workspace.close(doc)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 32)
        .background(.bar)
    }
}

struct EditorTab: View {
    @ObservedObject var document: OpenDocument
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: document.kind.symbol).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(document.name).font(.system(size: 12)).lineLimit(1)
            ZStack {
                if hovering || isActive {
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Close Tab")
                } else if document.isDirty {
                    Circle().frame(width: 6, height: 6).foregroundStyle(.secondary)
                }
            }
            .frame(width: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

/// Formatting buttons, Vim mode and the word count.
struct EditorBottomBar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject private var settings = AppSettings.shared
    @State private var vimMode = "NORMAL"
    @State private var caretInfo = ""

    var body: some View {
        HStack(spacing: 2) {
            if settings.vimMode {
                Text(vimMode)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(vimColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(vimColor)
                    .padding(.trailing, 6)
            }
            if workspace.activeDocument?.kind == .typst {
                format("bold", "Bold") { $0.makeBold(nil) }
                format("italic", "Italic") { $0.makeItalic(nil) }
                format("underline", "Underline") { $0.makeUnderline(nil) }
                Divider().frame(height: 12).padding(.horizontal, 4)
                Menu {
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { textView?.setHeading(level: level) }
                    }
                    Divider()
                    Button("Body Text") { textView?.setHeading(level: 0) }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .help("Heading")
                format("list.bullet", "Bullet List") { $0.makeBulletList(nil) }
                format("list.number", "Numbered List") { $0.makeNumberedList(nil) }
                format("sum", "Inline Math") { $0.makeInlineMath(nil) }
            }
            Spacer()
            Text(caretInfo).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                .padding(.trailing, 8)
            if settings.showWordCount, workspace.activeDocument?.kind == .typst {
                Text(workspace.wordCount == 1 ? "1 word" : "\(Int(workspace.wordCount)) words")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(.bar)
        .onReceive(NotificationCenter.default.publisher(for: .vimModeChanged)) { note in
            if let tv = note.object as? EditorTextView { vimMode = tv.vim.mode.rawValue }
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorSelectionChanged)) { note in
            guard let tv = note.object as? EditorTextView, tv.workspace === workspace else { return }
            let sel = tv.selectedRange()
            let ns = tv.nsString
            let prefix = ns.substring(to: min(sel.location, ns.length))
            let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let column = (prefix.split(separator: "\n", omittingEmptySubsequences: false).last?.count ?? 0) + 1
            caretInfo = sel.length > 0 ? "\(sel.length) selected" : "Ln \(line), Col \(column)"
        }
    }

    private var textView: EditorTextView? { EditorRegistry.shared.textView(for: workspace) }

    private var vimColor: Color {
        switch vimMode {
        case "INSERT": .green
        case "NORMAL": .blue
        default: .orange
        }
    }

    private func format(_ symbol: String, _ help: String, _ action: @escaping (EditorTextView) -> Void) -> some View {
        Button {
            if let tv = textView { action(tv) }
        } label: {
            Image(systemName: symbol).frame(width: 22, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
