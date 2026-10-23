import AppKit
import SwiftUI
import TypstCore

/// The preview toolbar and pages.
struct PreviewColumn: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: PreviewState
    var detached = false

    var body: some View {
        VStack(spacing: 0) {
            PreviewToolbar(workspace: workspace, state: state, detached: detached)
            Divider()
            ZStack {
                PreviewRepresentable(workspace: workspace, state: state)
                if workspace.pages.isEmpty {
                    emptyState
                }
                if !workspace.livePreview {
                    VStack {
                        Spacer()
                        Button {
                            workspace.livePreview = true
                        } label: {
                            Label("Live preview off — click to resume", systemImage: "pause.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if workspace.compileFailed {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Can’t render preview").font(.headline)
                Text("Fix the errors in the document to see the preview.").foregroundStyle(.secondary)
            }
        } else if workspace.isCompiling {
            ProgressView("Compiling…")
        } else if workspace.mainURL == nil {
            Text("Open a .typ file to see its preview.").foregroundStyle(.secondary)
        }
    }
}

struct PreviewToolbar: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var state: PreviewState
    @ObservedObject private var settings = AppSettings.shared
    var detached: Bool
    @State private var editingZoom = false
    @State private var zoomText = ""
    @State private var showPagePicker = false
    @State private var pageText = ""
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 6) {
            Button(action: state.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom Out")
            if editingZoom {
                TextField("", text: $zoomText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .onSubmit {
                        if let value = Double(zoomText.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) {
                            state.setZoom(value / 100)
                        }
                        editingZoom = false
                    }
            } else {
                Text("\(Int((state.magnification * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 38)
                    .onTapGesture(count: 2) {
                        zoomText = "\(Int((state.magnification * 100).rounded()))"
                        editingZoom = true
                    }
                    .help("Double-click to edit zoom")
            }
            Button(action: state.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom In")
            Button(action: state.fit) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .foregroundStyle(state.fitLocked ? Color.accentColor : Color.primary)
            }
            .help(state.fitLocked ? "Unlock zoom" : "Fit to window (click again to lock)")
            Button {
                state.galleryMode.toggle()
            } label: {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(state.galleryMode ? Color.accentColor : Color.primary)
            }
            .help("Gallery Mode")

            Spacer()
            Button {
                pageText = "\(state.currentPage + 1)"
                showPagePicker = true
            } label: {
                Text(workspace.pages.isEmpty ? "" : "Page \(state.currentPage + 1) of \(workspace.pages.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .help("Click to jump to a page")
            .popover(isPresented: $showPagePicker) {
                HStack {
                    Text("Page")
                    TextField("", text: $pageText).frame(width: 50)
                        .onSubmit {
                            if let page = Int(pageText), page >= 1, page <= workspace.pages.count {
                                state.goToPage(page - 1)
                            }
                            showPagePicker = false
                        }
                    Text("of \(workspace.pages.count)")
                }
                .padding(10)
            }
            Spacer()

            Button {
                workspace.previewDetached.toggle()
                if detached { dismissWindow(id: "preview") }
            } label: {
                Image(systemName: detached ? "rectangle.portrait.and.arrow.forward" : "macwindow.on.rectangle")
            }
            .help(detached ? "Return preview to the main window" : "Open preview in a separate window")

            Button {
                workspace.previewLock = workspace.previewLock == nil ? workspace.mainURL : nil
                workspace.scheduleCompile()
            } label: {
                Image(systemName: workspace.previewLock == nil ? "lock.open" : "lock.fill")
                    .foregroundStyle(workspace.previewLock == nil ? Color.primary : Color.accentColor)
            }
            .help(workspace.previewLock.map { "Preview locked to \($0.lastPathComponent)" } ?? "Lock Preview to This File")

            Button {
                workspace.followCursor.toggle()
            } label: {
                Image(systemName: "scope")
                    .foregroundStyle(workspace.followCursor ? Color.accentColor : Color.primary)
            }
            .help("Follow editing in preview — right-click to choose when it follows")
            .contextMenu {
                Picker("Sync", selection: $settings.followMode) {
                    ForEach(FollowMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            }

            Button {
                workspace.livePreview.toggle()
            } label: {
                Image(systemName: workspace.livePreview ? "bolt.fill" : "bolt.slash")
                    .foregroundStyle(workspace.livePreview ? Color.accentColor : Color.secondary)
            }
            .help(workspace.livePreview ? "Live preview on — click to pause" : "Live preview off — click to resume")

            Menu {
                Button("Export PDF…") { workspace.exportPDFWithPanel(window: NSApp.keyWindow) }
                Button("Export PDF in Place") { workspace.exportPDFInPlace() }
                Divider()
                Button("Show in Finder") { workspace.showInFinder(workspace.compiledURL) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export PDF (⌘E)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.bar)
    }
}

/// The preview in its own window.
struct DetachedPreviewView: View {
    let root: URL
    @StateObject private var state = PreviewState()

    var body: some View {
        Group {
            if let workspace = WindowRegistry.shared.workspace(for: root)?.1 {
                PreviewColumn(workspace: workspace, state: state, detached: true)
                    .navigationTitle("Preview — \(workspace.displayName)")
                    .onDisappear { workspace.previewDetached = false }
            } else {
                Text("No project").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 360, minHeight: 400)
    }
}
