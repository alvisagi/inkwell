import AppKit
import TypstCore

/// Scripted checks of editor behavior, run with `INKWELL_SELFTEST=1`.
/// Results go to stderr; the app quits when done.
@MainActor
enum SelfTest {
    static var mode: String? { ProcessInfo.processInfo.environment["INKWELL_SELFTEST"] }
    static var enabled: Bool { mode != nil }

    private static var failures = 0

    static func start() {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            switch mode {
            case "legacy": runLegacy()
            case "network": runNetwork()
            default: run()
            }
        }
    }

    private static func check(_ condition: Bool, _ name: String) {
        if !condition { failures += 1 }
        FileHandle.standardError.write(Data("SELFTEST \(condition ? "PASS" : "FAIL") \(name)\n".utf8))
    }

    private static func wait(_ seconds: Double, _ then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: then)
    }

    /// Polls `condition` every 0.25 s for up to `timeout` seconds.
    private static func waitFor(_ timeout: Double, _ condition: @escaping () -> Bool, then: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() > deadline { then() } else { wait(0.25, poll) }
        }
        poll()
    }

    private static func run() {
        guard let workspace = WindowRegistry.shared.keyWorkspace ?? NSApp.windows.compactMap({ $0.representedURL }).first.flatMap({ WorkspaceStore.shared.existing(for: $0) }) else {
            wait(1) { run() }
            return
        }
        waitFor(15, { !workspace.pages.isEmpty && EditorRegistry.shared.textView(for: workspace) != nil }) { runChecks(workspace) }
    }

    private static func runChecks(_ workspace: Workspace) {
        guard let tv = EditorRegistry.shared.textView(for: workspace) else {
            check(false, "found editor")
            finish()
            return
        }
        check(!workspace.pages.isEmpty, "preview has pages")
        let original = tv.string
        // Append at the end.
        tv.setSelectedRange(NSRange(location: tv.nsString.length, length: 0))
        for ch in "\n#tex" { tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        waitFor(5, { tv.completion.items.contains { $0.label == "text" } }) {
            check(tv.completion.isVisible, "completion popup visible")
            check(tv.completion.items.contains { $0.label == "text" }, "completion offers text")
            if let index = tv.completion.items.firstIndex(where: { $0.label == "text" }) {
                tv.completion.move(index)
                tv.completion.acceptSelected()
            }
            check(tv.string.hasSuffix("#text()") || tv.string.hasSuffix("#text("), "completion applied")

            // Auto-close and type-over.
            tv.setSelectedRange(NSRange(location: tv.nsString.length, length: 0))
            tv.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
            tv.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
            check(tv.string.hasSuffix("[]"), "auto-close bracket")
            tv.insertText("]", replacementRange: NSRange(location: NSNotFound, length: 0))
            check(tv.string.hasSuffix("[]") && tv.selectedRange().location == tv.nsString.length, "type over closing bracket")

            // Toggle comment on the current line.
            tv.toggleComment(nil)
            let line = tv.nsString.substring(with: tv.nsString.lineRange(for: tv.selectedRange()))
            check(line.hasPrefix("// "), "toggle comment")

            // Bold wraps the selection.
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.insertText("word ", replacementRange: NSRange(location: 0, length: 0))
            tv.setSelectedRange(NSRange(location: 0, length: 4))
            tv.makeBold(nil)
            check(tv.string.hasPrefix("*word* "), "bold wraps selection")

            // Outline reflects headings.
            check(workspace.outline.contains { $0.title == "Introduction" }, "outline has headings")

            // Restore the file.
            tv.insertText(original, replacementRange: NSRange(location: 0, length: tv.nsString.length))
            wait(1.0) {
                check(!workspace.compileFailed, "restored document compiles")
                workspace.saveAll()

                // Export in place.
                let pdf = workspace.root.appendingPathComponent("main.pdf")
                try? FileManager.default.removeItem(at: pdf)
                workspace.exportPDFInPlace()

                // Detach the preview into its own window.
                workspace.previewDetached = true
                wait(1.5) {
                    check(FileManager.default.fileExists(atPath: pdf.path), "export PDF in place")
                    check(NSApp.windows.contains { $0.title.hasPrefix("Preview") && $0.isVisible }, "detached preview window")
                    workspace.previewDetached = false

                    // Bibliography parsing.
                    let bib = BibTeX.parse("@article{knuth84, author = {Donald Knuth}, title = \"Literate {P}rogramming\", year = 1984}")
                    check(bib.count == 1 && bib[0].key == "knuth84" && bib[0].year == "1984" && bib[0].title == "Literate Programming", "bibtex parse")

                    // Symbol recognition.
                    let line = (0..<40).map { [Float($0) * 5, 50] }
                    check(!SymbolRecognizer.shared.recognize(strokes: [line]).isEmpty, "draw recognition")
                    finish()
                }
            }
        }
    }

    /// Downloads Typst 0.13.1 and compiles the open project with it.
    private static func runLegacy() {
        guard let workspace = NSApp.windows.compactMap({ $0.representedURL }).first.flatMap({ WorkspaceStore.shared.existing(for: $0) }) else {
            check(false, "found workspace")
            finish()
            return
        }
        let compilers = CompilerManager.shared
        compilers.download("0.13.1")
        func poll(_ tries: Int) {
            if compilers.installedVersions.contains("0.13.1") {
                check(true, "downloaded 0.13.1")
                compilers.selected = "0.13.1"
                wait(4) {
                    check(!workspace.pages.isEmpty && workspace.pages[0].hash.hasPrefix("legacy-"), "legacy compile produced pages")
                    check(workspace.previewStore.legacyImage(workspace.pages.first?.hash ?? "") != nil, "legacy page image loaded")
                    compilers.selected = CompilerManager.latest
                    wait(2) {
                        check(!(workspace.pages.first?.hash.hasPrefix("legacy-") ?? true), "back on built-in compiler")
                        finish()
                    }
                }
            } else if tries > 120 || compilers.errors["0.13.1"] != nil {
                check(false, "download 0.13.1: \(compilers.errors["0.13.1"] ?? "timeout")")
                finish()
            } else {
                wait(0.5) { poll(tries + 1) }
            }
        }
        poll(0)
    }

    /// Fetches Typst Universe and creates a project from a template.
    private static func runNetwork() {
        let index = PackageIndex.shared
        index.load(force: true)
        func poll(_ tries: Int) {
            if !index.packages.isEmpty {
                check(index.templates.count > 20, "universe templates loaded (\(index.templates.count))")
                guard let pkg = index.templates.first(where: { $0.name == "charged-ieee" }) ?? index.templates.first,
                      let path = pkg.templatePath, let entry = pkg.templateEntrypoint else { finish(); return }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("inkwell-template-\(UUID().uuidString)")
                do {
                    let file = try createFromTemplate(name: pkg.name, version: pkg.version, templatePath: path, entrypoint: entry, destination: dest.path)
                    check(FileManager.default.fileExists(atPath: file), "template entrypoint created")
                    let project = Project(root: dest.path)
                    try project.setMain(path: file)
                    let report = project.compile()
                    check(report.success && !report.pages.isEmpty, "template compiles (\(report.pages.count) pages)")
                } catch {
                    check(false, "create from template: \(error)")
                }
                try? FileManager.default.removeItem(at: dest)
                finish()
            } else if tries > 60 || index.error != nil {
                check(false, "universe index: \(index.error ?? "timeout")")
                finish()
            } else {
                wait(0.5) { poll(tries + 1) }
            }
        }
        poll(0)
    }

    private static func finish() {
        FileHandle.standardError.write(Data("SELFTEST DONE failures=\(failures)\n".utf8))
        exit(failures == 0 ? 0 : 1)
    }
}
