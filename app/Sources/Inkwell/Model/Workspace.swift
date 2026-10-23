import AppKit
import Combine
import CoreServices
import TypstCore

enum SidebarTab: String, CaseIterable, Identifiable {
    case files, search, outline, symbols, diagnostics
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .outline: "list.bullet.indent"
        case .symbols: "x.squareroot"
        case .diagnostics: "exclamationmark.triangle"
        }
    }
    var title: String {
        switch self {
        case .files: String(localized: "Files")
        case .search: String(localized: "Find")
        case .outline: String(localized: "Outline")
        case .symbols: String(localized: "Symbols")
        case .diagnostics: String(localized: "Diagnostics")
        }
    }
}

/// A position in the preview, in points on a 0-based page.
struct PreviewTarget: Equatable {
    var page: Int
    var point: CGPoint
    /// Whether to flash a marker there.
    var highlight: Bool
}

/// A request to move the editor's caret.
struct EditorJump: Equatable {
    var url: URL
    var offset: Int
    var length: Int = 0
    let token = UUID()
}

/// Everything behind one project window.
@MainActor
final class Workspace: ObservableObject, Identifiable {
    let id = UUID()
    let root: URL
    let project: Project
    let resources: PreviewResources
    lazy var previewStore = PreviewStore(project: project, resources: resources)
    let settings = AppSettings.shared

    /// Serial queue for all calls into the core.
    nonisolated let coreQueue = DispatchQueue(label: "inkwell.core", qos: .userInitiated)

    // Files
    @Published private(set) var tree: FileNode
    @Published var documents: [OpenDocument] = []
    @Published var activeURL: URL?
    /// A non-text file shown instead of the editor (image, PDF).
    @Published var mediaURL: URL?
    @Published var sidebarTab: SidebarTab = .files
    @Published var sidebarVisible = true

    // Compilation
    @Published private(set) var pages: [PageInfo] = []
    @Published private(set) var allDiagnostics: [TypstCore.Diagnostic] = []
    @Published private(set) var compileFailed = false
    @Published private(set) var isCompiling = false
    @Published private(set) var wordCount: UInt64 = 0
    @Published private(set) var compiledURL: URL?
    @Published var previewLock: URL?
    @Published var livePreview = true { didSet { if livePreview { scheduleCompile() } } }
    @Published var followCursor = true
    @Published var previewDetached = false
    @Published private(set) var lastCompileMs: Double = 0

    // Preview <-> editor sync
    let previewScroll = PassthroughSubject<PreviewTarget, Never>()
    @Published var editorJump: EditorJump?
    @Published var outline: [OutlineItem] = []

    // Export
    @Published var exportMessage: String?

    private var compileScheduled = false
    private var compileRunning = false
    private var compileAgain = false
    private var outlineWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?
    private var eventStream: FSEventStreamRef?
    private var cancellables: Set<AnyCancellable> = []

    init(root: URL) {
        self.root = root.canonical
        project = Project(root: self.root.path)
        resources = PreviewResources(project: project)
        var budget = 5000
        tree = FileNode.load(self.root, budget: &budget)
        startWatching()
        applyNamespaces()
        settings.$ignoreLibraryWarnings.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        CompilerManager.shared.$selected.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleCompile()
        }.store(in: &cancellables)
        PackageIndex.shared.$packages.sink { [weak self] packages in
            guard let self, !packages.isEmpty else { return }
            coreQueue.async { self.project.setPackageIndex(entries: packages) }
        }.store(in: &cancellables)
    }

    deinit {
        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    var activeDocument: OpenDocument? {
        documents.first { $0.url == activeURL }
    }

    var diagnostics: [TypstCore.Diagnostic] {
        guard settings.ignoreLibraryWarnings else { return allDiagnostics }
        return allDiagnostics.filter { $0.isError || !$0.inPackage }
    }

    var errorCount: Int { diagnostics.filter(\.isError).count }
    var warningCount: Int { diagnostics.filter { !$0.isError }.count }

    var displayName: String { root.lastPathComponent }

    // MARK: Files

    func reloadTree() {
        var budget = 5000
        tree = FileNode.load(root, budget: &budget)
    }

    /// The file opened when a project is first shown.
    func openInitialFile(preferred: URL? = nil) {
        if let preferred, FileManager.default.fileExists(atPath: preferred.path) {
            open(preferred)
            return
        }
        let files = tree.allFiles
        let candidates = ["main.typ", "index.typ", "document.typ"]
        if let main = files.first(where: { candidates.contains($0.name) && $0.url.deletingLastPathComponent() == root })
            ?? files.first(where: { $0.kind == .typst })
        {
            open(main.url)
        }
    }

    /// Opens a file: text files in a tab, images and PDFs in the media view.
    func open(_ url: URL) {
        let url = url.canonical
        let kind = FileKind(url: url, isDirectory: false)
        if kind.isEditable {
            if !documents.contains(where: { $0.url == url }) {
                guard let doc = try? OpenDocument(url: url) else { return }
                documents.append(doc)
                observe(doc)
            }
            mediaURL = nil
            activeURL = url
            documentActivated()
        } else {
            mediaURL = url
        }
    }

    func openInNewTab(_ url: URL) {
        open(url)
    }

    func close(_ doc: OpenDocument) {
        doc.save()
        guard let index = documents.firstIndex(where: { $0.url == doc.url }) else { return }
        documents.remove(at: index)
        coreQueue.async { [project] in project.clearText(path: doc.url.path) }
        if activeURL == doc.url {
            activeURL = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].url
            documentActivated()
        }
    }

    func closeActiveTab() {
        if let doc = activeDocument { close(doc) }
    }

    func showNextTab(_ delta: Int) {
        guard let index = documents.firstIndex(where: { $0.url == activeURL }), documents.count > 1 else { return }
        let next = (index + delta + documents.count) % documents.count
        activeURL = documents[next].url
        documentActivated()
    }

    private func observe(_ doc: OpenDocument) {
        NotificationCenter.default.publisher(for: .documentReloaded, object: doc)
            .sink { [weak self] _ in self?.textChanged(doc) }
            .store(in: &cancellables)
    }

    private func documentActivated() {
        refreshOutline()
        scheduleCompile()
    }

    /// Called by the editor on every edit.
    func textChanged(_ doc: OpenDocument) {
        doc.textDidChange()
        let text = doc.text
        coreQueue.async { [project] in project.setText(path: doc.url.path, text: text) }
        if doc.url == activeURL { refreshOutline() }
        scheduleAutosave()
        scheduleCompile()
    }

    func save(_ doc: OpenDocument? = nil) {
        (doc ?? activeDocument)?.save()
    }

    func saveAll() {
        documents.forEach { $0.save() }
    }

    private func scheduleAutosave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveAll() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func refreshOutline() {
        outlineWork?.cancel()
        guard let doc = activeDocument, doc.kind == .typst else {
            outline = []
            return
        }
        let text = doc.text
        let work = DispatchWorkItem { [weak self] in
            let items = TypstCore.outline(text: text)
            DispatchQueue.main.async { self?.outline = items }
        }
        outlineWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: File operations

    func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    @discardableResult
    func newFile(in folder: URL? = nil, contents: String = "") -> URL? {
        let url = uniqueURL(in: folder ?? root, base: "untitled", ext: "typ")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8)) else { return nil }
        reloadTree()
        open(url)
        return url
    }

    func newFileFromClipboard(in folder: URL? = nil) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        newFile(in: folder, contents: text)
    }

    @discardableResult
    func newFolder(in folder: URL? = nil) -> URL? {
        let url = uniqueURL(in: folder ?? root, base: "untitled folder", ext: "")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        reloadTree()
        return url
    }

    /// Moves the given files into a new folder.
    func newFolder(from urls: [URL]) {
        guard let first = urls.first else { return }
        let parent = first.deletingLastPathComponent()
        guard let folder = newFolder(in: parent) else { return }
        for url in urls {
            try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
        }
        reloadTree()
    }

    func rename(_ url: URL, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        // Reopen renamed documents under their new URL.
        if let doc = documents.first(where: { $0.url == url }) {
            let wasActive = activeURL == url
            doc.save()
            documents.removeAll { $0.url == url }
            if wasActive { open(target) }
        }
        reloadTree()
    }

    func duplicate(_ url: URL) {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent + " copy"
        let target = uniqueURL(in: url.deletingLastPathComponent(), base: base, ext: ext)
        try? FileManager.default.copyItem(at: url, to: target)
        reloadTree()
    }

    func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        for doc in documents where doc.url.path.hasPrefix(url.path) {
            documents.removeAll { $0.url == doc.url }
        }
        if let active = activeURL, !documents.contains(where: { $0.url == active }) {
            activeURL = documents.first?.url
        }
        if mediaURL?.path.hasPrefix(url.path) == true { mediaURL = nil }
        reloadTree()
        scheduleCompile()
    }

    func showInFinder(_ url: URL? = nil) {
        NSWorkspace.shared.activateFileViewerSelecting([url ?? activeURL ?? root])
    }

    // MARK: Compilation

    /// The file that is compiled: the locked one, else the active Typst file.
    var mainURL: URL? {
        if let previewLock { return previewLock }
        if let active = activeURL, active.pathExtension.lowercased() == "typ" { return active }
        return compiledURL
    }

    func scheduleCompile() {
        guard livePreview, !compileScheduled else { return }
        compileScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.compileScheduled = false
            self?.compileNow()
        }
    }

    func compileNow() {
        guard let main = mainURL else { return }
        if compileRunning {
            compileAgain = true
            return
        }
        compileRunning = true
        isCompiling = true
        if let binary = CompilerManager.shared.activeBinary {
            compileLegacy(binary: binary, main: main)
            return
        }
        let project = project
        coreQueue.async { [weak self] in
            do {
                try project.setMain(path: main.path)
            } catch {}
            let report = project.compile()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(report, main: main)
                self.compileRunning = false
                if self.compileAgain {
                    self.compileAgain = false
                    self.compileNow()
                } else {
                    self.isCompiling = false
                }
            }
        }
    }

    /// Compiles with a downloaded older Typst CLI. It reads files from disk,
    /// so unsaved edits are written first.
    private func compileLegacy(binary: URL, main: URL) {
        saveAll()
        let root = root
        let store = previewStore
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let start = Date()
            let output = LegacyCompiler.compile(binary: binary, root: root, main: main)
            DispatchQueue.main.async {
                guard let self else { return }
                for page in output.pages { store.setLegacyImage(page.image, for: page.info.hash) }
                self.allDiagnostics = output.diagnostics
                self.compileFailed = !output.success
                self.lastCompileMs = Date().timeIntervalSince(start) * 1000
                if output.success {
                    self.pages = output.pages.map(\.info)
                    self.compiledURL = main
                }
                self.compileRunning = false
                if self.compileAgain {
                    self.compileAgain = false
                    self.compileNow()
                } else {
                    self.isCompiling = false
                }
            }
        }
    }

    private func apply(_ report: CompileReport, main: URL) {
        allDiagnostics = report.diagnostics
        compileFailed = !report.success
        lastCompileMs = report.durationMs
        if report.success {
            if pages != report.pages { pages = report.pages }
            wordCount = report.wordCount
            compiledURL = main
        }
    }

    func reloadFonts() {
        coreQueue.async { [weak self] in
            TypstCore.reloadFonts()
            DispatchQueue.main.async { self?.scheduleCompile() }
        }
    }

    func applyNamespaces() {
        let namespaces = settings.namespaces
        coreQueue.async { TypstCore.setNamespaces(namespaces: namespaces) }
    }

    // MARK: Sync

    /// Asks the preview to show where the caret's text ended up.
    func syncPreview(to url: URL, offset: Int, highlight: Bool) {
        guard followCursor, url == compiledURL || url.pathExtension == "typ" else { return }
        let project = project
        coreQueue.async { [weak self] in
            let positions = project.cursorPositions(path: url.path, offset: UInt64(offset))
            guard let first = positions.first else { return }
            DispatchQueue.main.async {
                self?.previewScroll.send(PreviewTarget(page: Int(first.page), point: CGPoint(x: first.x, y: first.y), highlight: highlight))
            }
        }
    }

    /// Handles a click in the preview.
    func previewClicked(page: Int, point: CGPoint) {
        let project = project
        coreQueue.async { [weak self] in
            let target = project.click(page: UInt32(page), x: point.x, y: point.y)
            DispatchQueue.main.async {
                guard let self, let target else { return }
                switch target {
                case let .source(path, offset):
                    let url = URL(fileURLWithPath: path)
                    if url.path.hasPrefix(self.root.path) {
                        self.open(url)
                        self.editorJump = EditorJump(url: url, offset: Int(offset))
                    }
                case let .url(url):
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                case let .position(page, x, y):
                    self.previewScroll.send(PreviewTarget(page: Int(page), point: CGPoint(x: x, y: y), highlight: true))
                }
            }
        }
    }

    /// Jumps the editor to a diagnostic.
    func reveal(_ diagnostic: TypstCore.Diagnostic) {
        guard let path = diagnostic.path else { return }
        let url = URL(fileURLWithPath: path)
        guard url.path.hasPrefix(root.path) else { return }
        open(url)
        if let start = diagnostic.start {
            let end = diagnostic.end ?? start
            editorJump = EditorJump(url: url, offset: Int(start), length: Int(end - start))
        }
    }

    // MARK: Export

    func exportPDF(to destination: URL) {
        let project = project
        coreQueue.async { [weak self] in
            let message: String?
            do {
                try project.exportPdf(destination: destination.path)
                message = nil
            } catch {
                message = "\(error)"
            }
            DispatchQueue.main.async {
                if let message {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Export Failed")
                    alert.informativeText = message
                    alert.runModal()
                } else {
                    self?.exportMessage = String(localized: "Exported \(destination.lastPathComponent)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.exportMessage = nil }
                }
            }
        }
    }

    /// Writes the PDF next to the compiled file.
    func exportPDFInPlace() {
        guard let main = compiledURL ?? mainURL else { return }
        exportPDF(to: main.deletingPathExtension().appendingPathExtension("pdf"))
    }

    func exportPDFWithPanel(window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (compiledURL ?? mainURL)?.deletingPathExtension().lastPathComponent ?? displayName
        panel.nameFieldStringValue = base + ".pdf"
        panel.directoryURL = (compiledURL ?? root).deletingLastPathComponent()
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.exportPDF(to: url)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    // MARK: File watching

    private func startWatching() {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let workspace = Unmanaged<Workspace>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { workspace.filesChangedOnDisk() }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func filesChangedOnDisk() {
        reloadTree()
        for doc in documents {
            _ = doc.checkDisk()  // a reload notifies via .documentReloaded
        }
        coreQueue.async { [project] in project.invalidateFiles() }
        scheduleCompile()
    }
}
