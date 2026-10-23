import AppKit
import Combine

/// A text file open in an editor tab.
final class OpenDocument: ObservableObject, Identifiable {
    let url: URL
    /// The text as last written to / read from disk.
    private(set) var savedText: String
    /// The date of the version on disk we know about.
    private(set) var diskDate: Date?
    @Published private(set) var isDirty = false
    /// Set when another app changed the file while we had unsaved edits.
    @Published var externalChange = false
    @Published var saveError: String?

    /// TextKit 2 content storage; its text storage is the source of truth
    /// while the document is open.
    let contentStorage = NSTextContentStorage()
    var storage: NSTextStorage { contentStorage.textStorage! }

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var kind: FileKind { FileKind(url: url, isDirectory: false) }
    var text: String { storage.string }

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        savedText = text
        contentStorage.textStorage = NSTextStorage(string: text)
        diskDate = Self.modificationDate(url)
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func textDidChange() {
        let dirty = storage.string != savedText
        if dirty != isDirty { isDirty = dirty }
    }

    /// Writes the current text to disk.
    @discardableResult
    func save() -> Bool {
        guard isDirty || externalChange else { return true }
        let text = storage.string
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            savedText = text
            diskDate = Self.modificationDate(url)
            isDirty = false
            externalChange = false
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// Checks the disk for changes made by other apps. Returns true if the
    /// in-memory text was replaced.
    func checkDisk() -> Bool {
        guard let date = Self.modificationDate(url), date != diskDate else { return false }
        guard let data = try? Data(contentsOf: url) else { return false }
        let disk = String(decoding: data, as: UTF8.self)
        diskDate = date
        if disk == storage.string {
            savedText = disk
            isDirty = false
            return false
        }
        if isDirty {
            externalChange = true
            return false
        }
        replaceText(with: disk)
        return true
    }

    /// Discards edits and loads the on-disk version.
    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: url) else { return }
        replaceText(with: String(decoding: data, as: UTF8.self))
        diskDate = Self.modificationDate(url)
        externalChange = false
    }

    /// Keeps our edits; the next save overwrites the disk version.
    func keepEdits() {
        externalChange = false
        diskDate = Self.modificationDate(url)
    }

    private func replaceText(with text: String) {
        savedText = text
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        isDirty = false
        NotificationCenter.default.post(name: .documentReloaded, object: self)
    }
}

extension Notification.Name {
    static let documentReloaded = Notification.Name("InkwellDocumentReloaded")
}
