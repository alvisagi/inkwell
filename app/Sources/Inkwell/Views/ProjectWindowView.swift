import AppKit
import SwiftUI
import TypstCore

struct WorkspaceKey: FocusedValueKey {
    typealias Value = Workspace
}

extension FocusedValues {
    var workspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }
}

/// A project window: sidebar, editor and live preview.
struct ProjectWindowView: View {
    @StateObject var workspace: Workspace
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var previewState = PreviewState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showDiagnostics = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 420)
        } detail: {
            detail
        }
        .navigationTitle(workspace.activeDocument?.name ?? workspace.mediaURL?.lastPathComponent ?? workspace.displayName)
        .navigationSubtitle("")
        .toolbar { toolbar }
        .focusedSceneValue(\.workspace, workspace)
        .background(WindowAccessor { window in
            // One window per project: a restored duplicate closes itself.
            if let (other, _) = WindowRegistry.shared.workspace(for: workspace.root), other !== window {
                other.makeKeyAndOrderFront(nil)
                window.close()
                return
            }
            window.tabbingIdentifier = "InkwellProject"
            window.representedURL = workspace.root
            WindowRegistry.shared.register(window, workspace: workspace)
            WelcomeWindow.closeIfProjectsOpen()
        })
        .onAppear {
            AppActions.openWindowAction = openWindow
            RecentProjects.shared.add(workspace.root)
            PackageIndex.shared.load()
        }
        .onDisappear {
            workspace.saveAll()
            WorkspaceStore.shared.remove(workspace.root)
        }
        .onChange(of: workspace.previewDetached) { _, detached in
            if detached { openWindow(id: "preview", value: workspace.root) }
        }
        .preferredColorScheme(nil)
    }

    @ViewBuilder
    private var detail: some View {
        let editor = EditorColumn(workspace: workspace)
            .frame(minWidth: 280)
        if workspace.previewDetached {
            editor
        } else {
            let preview = PreviewColumn(workspace: workspace, state: previewState)
                .frame(minWidth: 240)
            HSplitView {
                if settings.editorPosition == .left {
                    editor
                    preview
                } else {
                    preview
                    editor
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            CompileStatusPill(workspace: workspace)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let message = workspace.exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                showDiagnostics.toggle()
            } label: {
                DiagnosticsBadge(errors: workspace.errorCount, warnings: workspace.warningCount)
            }
            .help("Diagnostics")
            .popover(isPresented: $showDiagnostics, arrowEdge: .bottom) {
                DiagnosticsList(workspace: workspace)
                    .frame(width: 420, height: 320)
            }
            Button {
                workspace.previewDetached.toggle()
            } label: {
                Image(systemName: workspace.previewDetached ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
            }
            .help(workspace.previewDetached ? "Return preview to the main window" : "Open preview in a separate window")
        }
    }
}

/// Shows compile state at the leading edge of the toolbar.
struct CompileStatusPill: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        HStack(spacing: 5) {
            if workspace.isCompiling {
                ProgressView().controlSize(.mini)
                Text("Compiling…")
            } else if workspace.compileFailed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(workspace.errorCount == 1 ? "1 error" : "\(workspace.errorCount) errors")
            } else if !workspace.pages.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if workspace.lastCompileMs >= 1 {
                    Text(String(format: "%.0f ms", workspace.lastCompileMs))
                }
            } else {
                Text(workspace.displayName)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

struct DiagnosticsBadge: View {
    let errors: Int
    let warnings: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: errors > 0 ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(errors > 0 ? Color.red : (warnings > 0 ? Color.yellow : Color.secondary))
            if errors + warnings > 0 {
                Text("\(errors + warnings)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
        }
    }
}

// MARK: - Window plumbing

/// Gives access to the hosting NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    final class AccessorView: NSView {
        var configure: ((NSWindow) -> Void)?
        private var done = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !done else { return }
            done = true
            let configure = configure
            DispatchQueue.main.async { configure?(window) }
        }
    }

    func makeNSView(context: Context) -> AccessorView {
        let view = AccessorView()
        view.configure = configure
        return view
    }

    func updateNSView(_ view: AccessorView, context: Context) {}
}

/// Maps windows to workspaces so menu commands and file opening can find them.
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var entries: [(window: WeakBox<NSWindow>, workspace: WeakBox<Workspace>)] = []

    func register(_ window: NSWindow, workspace: Workspace) {
        entries.removeAll { $0.window.value == nil || $0.window.value === window }
        entries.append((WeakBox(window), WeakBox(workspace)))
    }

    func workspace(for root: URL) -> (NSWindow, Workspace)? {
        for entry in entries {
            if let w = entry.window.value, let ws = entry.workspace.value, ws.root == root.canonical, w.isVisible {
                return (w, ws)
            }
        }
        return nil
    }

    var keyWorkspace: Workspace? {
        entries.first { $0.window.value?.isKeyWindow == true }?.workspace.value
    }
}
