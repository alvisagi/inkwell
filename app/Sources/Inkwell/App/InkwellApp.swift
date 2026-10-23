import AppKit
import SwiftUI
import TypstCore

@main
struct InkwellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Welcome to Inkwell", id: "welcome") {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        WindowGroup("Project", id: "project", for: URL.self) { $url in
            if let url {
                ProjectWindowHost(root: url)
            }
        }
        .defaultSize(width: 1400, height: 880)
        .commands { AppCommands() }

        WindowGroup("Preview", id: "preview", for: URL.self) { $url in
            if let url { DetachedPreviewView(root: url) }
        }
        .defaultSize(width: 700, height: 900)
        .restorationBehavior(.disabled)

        Window("New Project from Template", id: "templates") {
            TemplateGalleryView()
        }
        .defaultSize(width: 900, height: 640)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("Typst Documentation", id: "docs") {
            DocsBrowserView()
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(.suppressed)

        Window("What's New in Inkwell", id: "whats-new") {
            WhatsNewView()
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
        }
    }
}

/// Creates the workspace for a project window once.
struct ProjectWindowHost: View {
    let root: URL
    var body: some View {
        ProjectWindowView(workspace: WorkspaceStore.shared.workspace(for: root))
    }
}

/// Keeps one workspace per project root alive while its window exists.
@MainActor
final class WorkspaceStore {
    static let shared = WorkspaceStore()
    private var workspaces: [URL: Workspace] = [:]
    /// A file to open once the project's window appears.
    var pendingFiles: [URL: URL] = [:]

    func workspace(for root: URL) -> Workspace {
        let key = root.canonical
        if let existing = workspaces[key] { return existing }
        let workspace = Workspace(root: key)
        workspaces[key] = workspace
        workspace.openInitialFile(preferred: pendingFiles.removeValue(forKey: key))
        return workspace
    }

    func existing(for root: URL) -> Workspace? {
        workspaces[root.canonical]
    }

    func remove(_ root: URL) {
        workspaces[root.canonical] = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        // Warm up fonts in the background so the first compile is fast.
        DispatchQueue.global(qos: .utility).async { _ = fontFamilies() }
        PackageIndex.shared.load()
        WhatsNew.showIfUpdated()
        MainActor.assumeIsolated { SelfTest.start() }
        // When project windows were restored, the welcome window isn't needed.
        for delay in stride(from: 0.4, through: 4.0, by: 0.4) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { AppDelegate.closeWelcomeIfNeeded() }
        }
    }

    static func closeWelcomeIfNeeded() {
        let hasProject = NSApp.windows.contains { $0.representedURL != nil && $0.isVisible }
        guard hasProject else { return }
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("welcome") == true {
            window.orderOut(nil)
            window.close()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let hasProject = NSApp.windows.contains { $0.representedURL != nil && $0.isVisible }
        if !flag && !hasProject {
            MainActor.assumeIsolated { AppActions.showWelcome() }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            for window in NSApp.windows {
                if let url = window.representedURL, let ws = WorkspaceStore.shared.existing(for: url) {
                    ws.saveAll()
                }
            }
        }
    }

    /// Files opened from Finder: a .typ file opens its folder as the project.
    /// Requests arriving during launch wait until restored windows exist.
    func application(_ application: NSApplication, open urls: [URL]) {
        let delay = launchDate.timeIntervalSinceNow > -1.5 ? 0.8 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for url in urls {
                MainActor.assumeIsolated { AppActions.open(url) }
            }
        }
    }

    private let launchDate = Date()
}

/// App-wide actions reachable from menus and windows.
@MainActor
enum AppActions {
    static var openWindowAction: OpenWindowAction?

    static func showWelcome() {
        openWindowAction?(id: "welcome")
    }

    /// Opens a folder as a project, or a file within its folder.
    static func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        let url = url.canonical
        let root = isDir.boolValue ? url : url.deletingLastPathComponent()
        let file: URL? = isDir.boolValue ? nil : url
        if let (window, workspace) = WindowRegistry.shared.workspace(for: root) {
            window.makeKeyAndOrderFront(nil)
            if let file { workspace.open(file) }
            return
        }
        if let workspace = WorkspaceStore.shared.existing(for: root) {
            // A window for it is being restored right now.
            if let file { workspace.open(file) }
            return
        }
        if let file { WorkspaceStore.shared.pendingFiles[root.canonical] = file }
        RecentProjects.shared.add(root)
        openWindowAction?(id: "project", value: root.canonical)
        // Close the welcome window once a project opens.
        for window in NSApp.windows where window.identifier?.rawValue.contains("welcome") == true {
            window.close()
        }
    }

    static func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    static func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "typ") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.message = String(localized: "Opening a file opens its folder as the project.")
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
}
