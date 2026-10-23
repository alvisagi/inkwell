import SwiftUI

/// Find and replace across the project's text files.
struct ProjectSearchView: View {
    @ObservedObject var workspace: Workspace
    @State private var query = ""
    @State private var replacement = ""
    @State private var replaceMode = false
    @State private var matchKind: MatchKind = .containing
    @State private var matchCase = false
    @State private var results: [FileMatches] = []
    @State private var truncated = false
    @State private var searchWork: DispatchWorkItem?

    enum MatchKind: String, CaseIterable, Identifiable {
        case containing = "Containing"
        case matchingWord = "Matching Word"
        case startingWith = "Starting With"
        case regex = "Regular Expression"
        var id: String { rawValue }
    }

    struct Match: Identifiable {
        let id = UUID()
        let range: NSRange
        let line: Int
        let preview: AttributedString
    }

    struct FileMatches: Identifiable {
        let url: URL
        var matches: [Match]
        var id: URL { url }
    }

    static let maxResults = 1000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Menu(replaceMode ? "Replace" : "Find") {
                    Button("Find") { replaceMode = false }
                    Button("Replace") { replaceMode = true }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                Menu(matchKind.rawValue) {
                    ForEach(MatchKind.allCases) { kind in
                        Button(kind.rawValue) {
                            matchKind = kind
                            search()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Toggle(isOn: $matchCase) {
                    Text("Aa").font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Match Case")
                .onChange(of: matchCase) { _, _ in search() }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(search)
                    .onChange(of: query) { _, _ in scheduleSearch() }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
            .padding(.horizontal, 10)

            if replaceMode {
                HStack {
                    Image(systemName: "arrow.2.squarepath").foregroundStyle(.secondary)
                    TextField("Replace", text: $replacement).textFieldStyle(.plain)
                    Button("Replace All", action: replaceAll)
                        .controlSize(.small)
                        .disabled(results.isEmpty)
                        .help("Replace all matches in the project")
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                .padding(.horizontal, 10)
            }

            if !query.isEmpty {
                let total = results.reduce(0) { $0 + $1.matches.count }
                Group {
                    if total == 0 {
                        Text("No results")
                    } else if truncated {
                        Text("\(total) results in \(results.count) files — limited, refine your search")
                    } else if results.count == 1 {
                        Text(total == 1 ? "1 result in 1 file" : "\(total) results in 1 file")
                    } else {
                        Text("\(total) results in \(results.count) files")
                    }
                }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            List {
                ForEach(results) { file in
                    Section {
                        ForEach(file.matches) { match in
                            Button {
                                workspace.open(file.url)
                                workspace.editorJump = EditorJump(url: file.url, offset: match.range.location, length: match.range.length)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(match.line)").font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                                        .frame(minWidth: 22, alignment: .trailing)
                                    Text(match.preview).font(.system(size: 11)).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label(relative(file.url), systemImage: FileKind(url: file.url, isDirectory: false).symbol)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func relative(_ url: URL) -> String {
        let root = workspace.root.path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.lastPathComponent
    }

    private func scheduleSearch() {
        searchWork?.cancel()
        let work = DispatchWorkItem { search() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func regex() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var pattern: String
        switch matchKind {
        case .containing: pattern = NSRegularExpression.escapedPattern(for: query)
        case .matchingWord: pattern = "\\b" + NSRegularExpression.escapedPattern(for: query) + "\\b"
        case .startingWith: pattern = "\\b" + NSRegularExpression.escapedPattern(for: query)
        case .regex: pattern = query
        }
        if pattern.isEmpty { pattern = "(?!)" }
        return try? NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
    }

    /// The text of a file: the open (possibly unsaved) version if any.
    private func text(of url: URL) -> String? {
        if let doc = workspace.documents.first(where: { $0.url == url }) { return doc.text }
        guard let data = try? Data(contentsOf: url), data.count < 5_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func search() {
        guard let regex = regex() else {
            results = []
            return
        }
        var out: [FileMatches] = []
        var count = 0
        truncated = false
        for node in workspace.tree.allFiles where node.kind.isEditable {
            guard let text = text(of: node.url) else { continue }
            let ns = text as NSString
            var matches: [Match] = []
            for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                count += 1
                if count > Self.maxResults {
                    truncated = true
                    break
                }
                let lineRange = ns.lineRange(for: result.range)
                let line = ns.substring(to: result.range.location).filter { $0 == "\n" }.count + 1
                let lineText = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
                var preview = AttributedString(lineText.trimmingCharacters(in: .whitespaces))
                let lead = lineText.prefix { $0 == " " || $0 == "\t" }.utf16.count
                let start = result.range.location - lineRange.location - lead
                if start >= 0, let r = Range(NSRange(location: start, length: result.range.length), in: String(preview.characters)) {
                    if let ar = Range(r, in: preview) {
                        preview[ar].font = .system(size: 11, weight: .bold)
                        preview[ar].backgroundColor = .yellow.opacity(0.35)
                    }
                }
                matches.append(Match(range: result.range, line: line, preview: preview))
            }
            if !matches.isEmpty { out.append(FileMatches(url: node.url, matches: matches)) }
            if truncated { break }
        }
        results = out
    }

    private func replaceAll() {
        guard let regex = regex() else { return }
        let template = matchKind == .regex ? replacement : NSRegularExpression.escapedTemplate(for: replacement)
        for file in results {
            if let doc = workspace.documents.first(where: { $0.url == file.url }) {
                let text = doc.text
                let replaced = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
                if let tv = EditorRegistry.shared.textView(for: workspace), tv.document === doc {
                    tv.insertText(replaced, replacementRange: NSRange(location: 0, length: (text as NSString).length))
                } else {
                    doc.storage.replaceCharacters(in: NSRange(location: 0, length: doc.storage.length), with: replaced)
                    workspace.textChanged(doc)
                }
            } else if let text = text(of: file.url) {
                let replaced = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
                try? Data(replaced.utf8).write(to: file.url, options: .atomic)
            }
        }
        search()
    }
}
