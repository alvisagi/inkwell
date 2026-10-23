import Foundation

/// Recently opened project folders, most recent first.
final class RecentProjects: ObservableObject {
    static let shared = RecentProjects()

    @Published private(set) var urls: [URL] = []
    private let key = "recentProjects"

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        urls = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && !Self.isTemporary($0) }
    }

    /// Scratch folders (e.g. from self-tests) don't belong in the list.
    static func isTemporary(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return path.hasPrefix(temp) || path.hasPrefix("/private/var/folders/") || path.hasPrefix("/var/folders/")
    }

    func add(_ url: URL) {
        guard !Self.isTemporary(url), ProcessInfo.processInfo.environment["INKWELL_SELFTEST"] == nil else { return }
        urls.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(20))
        persist()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
    }
}
