import Foundation
import UniformTypeIdentifiers

/// A file or folder in the project tree.
struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    var kind: FileKind { FileKind(url: url, isDirectory: isDirectory) }

    /// Folders and files we never show.
    static let ignored: Set<String> = [".git", ".DS_Store", "node_modules", ".build", "target"]

    /// Reads a folder recursively (bounded, to stay responsive on huge trees).
    static func load(_ url: URL, depth: Int = 0, budget: inout Int) -> FileNode {
        var node = FileNode(url: url, isDirectory: true, children: [])
        guard depth < 12, budget > 0 else { return node }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return node }
        var children: [FileNode] = []
        for entry in entries where !ignored.contains(entry.lastPathComponent) {
            budget -= 1
            if budget <= 0 { break }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                children.append(load(entry, depth: depth + 1, budget: &budget))
            } else {
                children.append(FileNode(url: entry, isDirectory: false, children: nil))
            }
        }
        children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        node.children = children
        return node
    }

    /// All files below this node, depth-first.
    var allFiles: [FileNode] {
        guard let children else { return [self] }
        return children.flatMap { $0.allFiles }
    }

    func find(_ target: URL) -> FileNode? {
        if url == target { return self }
        for child in children ?? [] {
            if let hit = child.find(target) { return hit }
        }
        return nil
    }
}

enum FileKind {
    case typst, bibliography, image, pdf, text, folder, other

    init(url: URL, isDirectory: Bool) {
        if isDirectory {
            self = .folder
            return
        }
        switch url.pathExtension.lowercased() {
        case "typ": self = .typst
        case "bib": self = .bibliography
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tiff", "bmp": self = .image
        case "pdf": self = .pdf
        case "txt", "md", "csv", "json", "toml", "yaml", "yml", "xml", "cbor", "html", "css", "tex", "lua", "py", "rs", "swift", "js":
            self = .text
        default: self = .other
        }
    }

    /// Whether the file opens in the text editor.
    var isEditable: Bool { self == .typst || self == .text || self == .bibliography }

    var symbol: String {
        switch self {
        case .typst: "t.square"
        case .bibliography: "books.vertical"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .text: "doc.text"
        case .folder: "folder"
        case .other: "doc"
        }
    }
}

extension URL {
    /// Symlinks resolved and standardized, so paths from the core compare equal.
    var canonical: URL { resolvingSymlinksInPath().standardizedFileURL }
}
