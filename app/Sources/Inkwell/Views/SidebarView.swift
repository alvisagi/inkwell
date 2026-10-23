import AppKit
import SwiftUI
import TypstCore

struct SidebarView: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .padding(.top, 6)
                .padding(.bottom, 8)
            Group {
                switch workspace.sidebarTab {
                case .files: FileTreeView(workspace: workspace)
                case .search: ProjectSearchView(workspace: workspace)
                case .outline: OutlineSidebar(workspace: workspace)
                case .symbols: SymbolsSidebar(workspace: workspace)
                case .diagnostics: DiagnosticsList(workspace: workspace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var tabPicker: some View {
        HStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                Button {
                    workspace.sidebarTab = tab
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 22)
                            .foregroundStyle(workspace.sidebarTab == tab ? Color.white : Color.secondary)
                            .background(
                                Capsule().fill(workspace.sidebarTab == tab ? Color.accentColor : Color.clear))
                        if tab == .diagnostics, workspace.errorCount > 0 {
                            Circle().fill(.red).frame(width: 6, height: 6).offset(x: -2, y: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.7)))
    }
}

// MARK: - Files

struct FileTreeView: View {
    @ObservedObject var workspace: Workspace
    @State private var selection: Set<URL> = []
    @State private var renaming: URL?
    @State private var renameText = ""
    @State private var confirmDelete: URL?

    var body: some View {
        List(selection: $selection) {
            OutlineGroup(workspace.tree.children ?? [], children: \.children) { node in
                row(node)
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, new in
            if new.count == 1, let url = new.first, let node = workspace.tree.find(url), !node.isDirectory {
                workspace.open(url)
            }
        }
        .onChange(of: workspace.activeURL) { _, url in
            if let url, !selection.contains(url), workspace.mediaURL == nil { selection = [url] }
        }
        .onAppear {
            if let url = workspace.mediaURL ?? workspace.activeURL { selection = [url] }
        }
        .contextMenu {
            folderMenu(workspace.root)
        }
        .alert("Delete “\(confirmDelete?.lastPathComponent ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let url = confirmDelete { workspace.moveToTrash(url) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
    }

    @ViewBuilder
    private func row(_ node: FileNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : node.kind.symbol)
                .foregroundStyle(iconColor(node))
                .frame(width: 16)
            if renaming == node.url {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        workspace.rename(node.url, to: renameText)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Text(node.name).lineLimit(1)
                if workspace.previewLock == node.url {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let doc = workspace.documents.first(where: { $0.url == node.url }), doc.isDirty {
                    Circle().frame(width: 5, height: 5).foregroundStyle(.secondary)
                }
            }
        }
        .tag(node.url)
        .contextMenu {
            if node.isDirectory {
                folderMenu(node.url)
                Divider()
            } else {
                Button("Open in New Tab") { workspace.openInNewTab(node.url) }
                if node.kind == .typst {
                    Button(workspace.previewLock == node.url ? "Unlock Preview" : "Lock Preview to This File") {
                        workspace.previewLock = workspace.previewLock == node.url ? nil : node.url
                        workspace.scheduleCompile()
                    }
                }
                Divider()
            }
            Button("Rename") {
                renameText = node.name
                renaming = node.url
            }
            Button("Duplicate") { workspace.duplicate(node.url) }
            if selection.count > 1 {
                Button("New Folder from Selection") { workspace.newFolder(from: Array(selection)) }
            }
            Button("Show in Finder") { workspace.showInFinder(node.url) }
            Divider()
            Button("Move to Trash", role: .destructive) { confirmDelete = node.url }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: URL) -> some View {
        Button("New File") { workspace.newFile(in: folder) }
        Button("New File from Clipboard") { workspace.newFileFromClipboard(in: folder) }
        Button("New Folder") { workspace.newFolder(in: folder) }
    }

    private func iconColor(_ node: FileNode) -> Color {
        switch node.kind {
        case .typst: .teal
        case .folder: .accentColor
        case .bibliography: .orange
        case .image: .purple
        case .pdf: .red
        default: .secondary
        }
    }
}

// MARK: - Outline

struct OutlineSidebar: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        if workspace.outline.isEmpty {
            Text("No headings")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(Array(workspace.outline.enumerated()), id: \.offset) { _, item in
                Button {
                    if let url = workspace.activeURL {
                        workspace.editorJump = EditorJump(url: url, offset: Int(item.offset))
                        workspace.syncPreview(to: url, offset: Int(item.offset) + Int(item.level) + 1, highlight: true)
                    }
                } label: {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.system(size: 12, weight: item.level == 1 ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.leading, CGFloat(item.level - 1) * 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsList: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        let diagnostics = workspace.diagnostics
        if diagnostics.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 26)).foregroundStyle(.green)
                Text("No problems").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(Array(diagnostics.enumerated()), id: \.offset) { _, diag in
                Button {
                    workspace.reveal(diag)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: diag.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(diag.isError ? .red : .yellow)
                            Text(diag.message).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                        if let path = diag.path {
                            Text(location(path, diag))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 20)
                        }
                        ForEach(diag.hints, id: \.self) { hint in
                            Text("hint: \(hint)").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 20)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }

    private func location(_ path: String, _ diag: TypstCore.Diagnostic) -> String {
        let name: String
        if path.hasPrefix(workspace.root.path + "/") {
            name = String(path.dropFirst(workspace.root.path.count + 1))
        } else {
            name = URL(fileURLWithPath: path).lastPathComponent
        }
        if let line = diag.line { return "\(name):\(line):\(diag.column ?? 1)" }
        return name
    }
}
