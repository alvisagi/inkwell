import AppKit
import Combine
import SwiftUI

/// One editor per open document, kept alive so undo history and scroll
/// position survive tab switches.
@MainActor
final class EditorSession: NSObject, NSTextViewDelegate {
    let document: OpenDocument
    let scrollView: NSScrollView
    let textView: EditorTextView
    let ruler: LineNumberRuler
    let highlighter: SyntaxHighlighter
    weak var workspace: Workspace?
    private var syncWork: DispatchWorkItem?
    private var editedSinceSync = false

    init(document: OpenDocument, workspace: Workspace) {
        self.document = document
        self.workspace = workspace
        let settings = AppSettings.shared

        let layoutManager = NSTextLayoutManager()
        document.contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.textContainer = container

        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), textContainer: container)
        highlighter = SyntaxHighlighter(
            storage: document.storage, theme: settings.theme, font: settings.editorFont,
            isTypst: document.kind == .typst)
        textView.workspace = workspace
        textView.document = document
        textView.highlighter = highlighter

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        ruler = LineNumberRuler(editor: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true

        super.init()
        textView.delegate = self
        textView.configure()
        highlighter.updateNow()
        applySettings()
    }

    func applySettings() {
        let settings = AppSettings.shared
        highlighter.theme = settings.theme
        highlighter.font = settings.editorFont
        scrollView.backgroundColor = settings.theme.background
        scrollView.rulersVisible = settings.lineNumbers
        scrollView.scrollerKnobStyle = settings.theme.isDark ? .light : .dark
        textView.applySettings()
        highlighter.updateNow()
        ruler.recomputeLines()
        ruler.needsDisplay = true
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        highlighter.update()
        workspace?.textChanged(document)
        editedSinceSync = true
        scheduleSync()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        NotificationCenter.default.post(name: .editorSelectionChanged, object: textView)
        if AppSettings.shared.followMode == .caret || editedSinceSync {
            scheduleSync()
        }
    }

    private func scheduleSync() {
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let workspace = self.workspace, self.textView.window != nil else { return }
            self.editedSinceSync = false
            workspace.syncPreview(to: self.document.url, offset: self.textView.selectedRange().location, highlight: false)
        }
        syncWork = work
        // Wait for the compile triggered by an edit to land first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Only check spelling in prose, not in code.
    func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard document.kind == .typst else { return value }
        return highlighter.isProse(at: affectedCharRange.location) ? value : 0
    }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard document.kind == .typst, let name = identifier(at: charIndex),
              let route = TypstDocs.shared.route(forIdentifier: name)
        else { return menu }
        let item = NSMenuItem(title: String(localized: "Show Documentation for “\(name)”"), action: #selector(showDocs(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = route
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func showDocs(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? String else { return }
        TypstDocs.shared.pendingRoute = route
        AppActions.openWindowAction?(id: "docs")
    }

    /// The identifier (Typst allows `-` inside names) around a character.
    private func identifier(at index: Int) -> String? {
        let ns = textView.nsString
        guard index <= ns.length else { return nil }
        func isIdent(_ c: unichar) -> Bool {
            guard let scalar = UnicodeScalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || c == 45 || c == 95
        }
        var start = index, end = index
        while start > 0, isIdent(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, isIdent(ns.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}

extension Notification.Name {
    static let editorSelectionChanged = Notification.Name("InkwellEditorSelectionChanged")
}

/// Hosts the active document's editor.
final class EditorHostView: NSView {
    private var sessions: [URL: EditorSession] = [:]
    private var current: EditorSession?
    weak var workspace: Workspace?
    private var cancellables: Set<AnyCancellable> = []

    var activeTextView: EditorTextView? { current?.textView }

    func bind(_ workspace: Workspace) {
        guard self.workspace !== workspace else { return }
        self.workspace = workspace
        cancellables = []
        workspace.$activeURL.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.showActive() }
        }.store(in: &cancellables)
        workspace.$documents.receive(on: DispatchQueue.main).sink { [weak self] docs in
            self?.prune(docs)
        }.store(in: &cancellables)
        workspace.$editorJump.compactMap { $0 }.receive(on: DispatchQueue.main).sink { [weak self] jump in
            DispatchQueue.main.async { self?.perform(jump) }
        }.store(in: &cancellables)
        AppSettings.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.sessions.values.forEach { $0.applySettings() } }
        }.store(in: &cancellables)
        showActive()
    }

    private func session(for doc: OpenDocument) -> EditorSession {
        if let existing = sessions[doc.url] { return existing }
        let session = EditorSession(document: doc, workspace: workspace!)
        sessions[doc.url] = session
        return session
    }

    private func showActive() {
        guard let workspace else { return }
        guard let doc = workspace.activeDocument else {
            current?.scrollView.removeFromSuperview()
            current = nil
            return
        }
        let next = session(for: doc)
        guard next !== current else { return }
        current?.scrollView.removeFromSuperview()
        current = next
        next.scrollView.frame = bounds
        next.scrollView.autoresizingMask = [.width, .height]
        addSubview(next.scrollView)
        window?.makeFirstResponder(next.textView)
    }

    private func prune(_ docs: [OpenDocument]) {
        let open = Set(docs.map(\.url))
        for url in sessions.keys where !open.contains(url) {
            sessions[url]?.scrollView.removeFromSuperview()
            sessions[url] = nil
        }
    }

    private func perform(_ jump: EditorJump) {
        guard let session = sessions[jump.url] ?? workspace?.activeDocument.flatMap({ $0.url == jump.url ? session(for: $0) : nil }) else { return }
        if session !== current { showActive() }
        session.textView.reveal(NSRange(location: jump.offset, length: jump.length))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let current { window?.makeFirstResponder(current.textView) }
    }
}

struct EditorView: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    func makeNSView(context: Context) -> EditorHostView {
        let view = EditorHostView()
        view.bind(workspace)
        EditorRegistry.shared.register(view, for: workspace)
        return view
    }

    func updateNSView(_ view: EditorHostView, context: Context) {
        view.bind(workspace)
    }
}

/// Lets menu commands find the editor of the key window's workspace.
final class EditorRegistry {
    static let shared = EditorRegistry()
    private var hosts: [UUID: WeakBox<EditorHostView>] = [:]

    func register(_ host: EditorHostView, for workspace: Workspace) {
        hosts[workspace.id] = WeakBox(host)
    }

    func textView(for workspace: Workspace?) -> EditorTextView? {
        guard let workspace else { return nil }
        return hosts[workspace.id]?.value?.activeTextView
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
