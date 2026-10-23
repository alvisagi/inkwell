import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The bundled Typst documentation site and its search index.
final class TypstDocs: ObservableObject {
    static let shared = TypstDocs()

    struct Item: Decodable, Hashable {
        let kind: String
        let title: String
        let route: String
    }

    let root: URL? = Bundle.main.resourceURL?.appendingPathComponent("TypstDocs")
    private(set) lazy var items: [Item] = {
        guard let root,
              let data = try? Data(contentsOf: root.appendingPathComponent("assets/search.json")),
              let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return [] }
        return index.items
    }()

    /// Page requested by other windows (e.g. "Show Documentation").
    @Published var pendingRoute: String?

    private struct Index: Decodable { let items: [Item] }

    var isAvailable: Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
    }

    func search(_ query: String, limit: Int = 40) -> [Item] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Item)] = []
        for item in items {
            let title = item.title.lowercased()
            let score: Int
            if title == q { score = 0 }
            else if title.hasPrefix(q) { score = 1 }
            else if title.contains(q) { score = 2 }
            else if item.route.lowercased().contains(q) { score = 3 }
            else { continue }
            let kindBonus = item.kind == "Function" || item.kind == "Type" ? 0 : (item.kind.hasPrefix("Parameter") ? 2 : 1)
            scored.append((score * 4 + kindBonus, item))
        }
        return scored.sorted { $0.0 < $1.0 }.prefix(limit).map(\.1)
    }

    /// The route documenting a function or type, e.g. `text` -> /reference/text/text/.
    func route(forIdentifier name: String) -> String? {
        let candidates = items.filter { ($0.kind == "Function" || $0.kind == "Type") }
        return candidates.first { $0.route.split(separator: "/").last.map(String.init) == name }?.route
            ?? candidates.first { $0.title.lowercased() == name.lowercased() }?.route
    }
}

/// Serves the docs site from the app bundle under `typst-docs://local/`.
final class DocsSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "typst-docs"

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = TypstDocs.shared.root else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var path = url.path
        if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
        var file = root.appendingPathComponent(String(path.drop { $0 == "/" }))
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue {
            file.appendPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: file) else {
            let body = Data("<html><body style='font-family:-apple-system;padding:40px'><h2>Page Not Found</h2></body></html>".utf8)
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!)
            task.didReceive(body)
            task.didFinish()
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class DocsWebModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var title = "Typst Documentation"
    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(DocsSchemeHandler(), forURLScheme: DocsSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.canGoBack) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
            webView.observe(\.title) { [weak self] wv, _ in self?.title = wv.title ?? "Typst Documentation" },
        ]
        open("/")
    }

    /// Converts the page's main content to Markdown and copies it.
    func copyAsMarkdown() {
        webView.evaluateJavaScript(Self.markdownScript) { result, _ in
            guard let markdown = result as? String, !markdown.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        }
    }

    private static let markdownScript: String = {
        guard let url = Bundle.main.url(forResource: "docs-markdown", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8)
        else { return "''" }
        return script
    }()

    func open(_ route: String) {
        guard let url = URL(string: "\(DocsSchemeHandler.scheme)://local\(route.hasPrefix("/") ? route : "/" + route)") else { return }
        webView.load(URLRequest(url: url))
    }

    var currentRoute: String {
        guard let url = webView.url else { return "/" }
        return url.path + (url.fragment.map { "#" + $0 } ?? "")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == DocsSchemeHandler.scheme || url.scheme == "about" {
            decisionHandler(.allow)
        } else {
            // External links open in the browser.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

struct DocsWebView: NSViewRepresentable {
    let model: DocsWebModel
    func makeNSView(context: Context) -> WKWebView { model.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The documentation window.
struct DocsBrowserView: View {
    @StateObject private var model = DocsWebModel()
    @ObservedObject private var docs = TypstDocs.shared
    @State private var query = ""
    @State private var showResults = false

    var body: some View {
        Group {
            if docs.isAvailable {
                DocsWebView(model: model)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "book.closed").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Documentation Unavailable").font(.headline)
                    Text("The bundled Typst documentation could not be loaded.").foregroundStyle(.secondary)
                    Button("Open on typst.app") { NSWorkspace.shared.open(URL(string: "https://typst.app/docs/")!) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.title.replacingOccurrences(of: " - Typst Documentation", with: ""))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack).help("Back")
                Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward).help("Forward")
                Button { model.open("/") } label: { Image(systemName: "house") }.help("Overview")
            }
            ToolbarItem(placement: .primaryAction) {
                TextField("Search Documentation", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onChange(of: query) { _, q in showResults = !q.isEmpty }
                    .onSubmit {
                        if let first = docs.search(query).first { go(first.route) }
                    }
                    .popover(isPresented: $showResults, arrowEdge: .bottom) {
                        results
                    }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.copyAsMarkdown()
                } label: { Image(systemName: "doc.on.clipboard") }
                    .help("Copy as Markdown")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let route = model.currentRoute
                    NSWorkspace.shared.open(URL(string: "https://typst.app/docs\(route)")!)
                } label: { Image(systemName: "safari") }
                    .help("Open on typst.app")
            }
        }
        .onReceive(docs.$pendingRoute.compactMap { $0 }) { route in
            model.open(route)
            docs.pendingRoute = nil
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private var results: some View {
        let hits = docs.search(query)
        return Group {
            if hits.isEmpty {
                Text("No results for “\(query)”").foregroundStyle(.secondary).padding()
            } else {
                List(hits, id: \.self) { item in
                    Button {
                        go(item.route)
                    } label: {
                        HStack {
                            Text(item.title).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(item.kind).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 340, height: 360)
            }
        }
    }

    private func go(_ route: String) {
        showResults = false
        query = ""
        model.open(route)
    }
}
