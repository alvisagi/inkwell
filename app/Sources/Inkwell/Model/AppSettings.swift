import AppKit
import Combine
import SwiftUI

/// Which side of the window the editor sits on.
enum EditorPosition: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? String(localized: "Left") : String(localized: "Right") }
}

/// How brackets and quotes are auto-closed.
enum AutoCloseMode: String, CaseIterable, Identifiable {
    case off
    case immediately
    case overtypeOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .immediately: String(localized: "Close immediately (VS Code)")
        case .overtypeOnly: String(localized: "Type over closing characters only")
        }
    }
}

/// When the preview follows the caret.
enum FollowMode: String, CaseIterable, Identifiable {
    case caret
    case editsOnly
    var id: String { rawValue }
    var title: String { self == .caret ? String(localized: "Sync with caret position") : String(localized: "Sync on edits only") }
}

enum TypingSound: String, CaseIterable, Identifiable {
    case off, normal, soft, creamy, retro, typewriter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .normal: String(localized: "Normal")
        case .soft: String(localized: "Soft")
        case .creamy: String(localized: "Creamy")
        case .retro: String(localized: "Retro computer")
        case .typewriter: String(localized: "Typewriter")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, de, es, fr, it, nl, pt, zh
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .en: "English"
        case .de: "Deutsch"
        case .es: "Español"
        case .fr: "Français"
        case .it: "Italiano"
        case .nl: "Nederlands"
        case .pt: "Português"
        case .zh: "简体中文"
        }
    }
}

/// All user preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // General
    @Published var language: AppLanguage { didSet { Self.store(language, "language") } }
    @Published var editorPosition: EditorPosition { didSet { Self.store(editorPosition, "editorPosition") } }
    @Published var rippleOnClick: Bool { didSet { Self.store(rippleOnClick, "rippleOnClick") } }
    @Published var ignoreLibraryWarnings: Bool { didSet { Self.store(ignoreLibraryWarnings, "ignoreLibraryWarnings") } }

    // Editor typography
    @Published var editorFontName: String { didSet { Self.store(editorFontName, "editorFontName") } }
    @Published var editorFontSize: Double { didSet { Self.store(editorFontSize, "editorFontSize") } }
    @Published var themeID: String { didSet { Self.store(themeID, "theme") } }

    // Editor behavior
    @Published var animatedCaret: Bool { didSet { Self.store(animatedCaret, "animatedCaret") } }
    @Published var roundedSelection: Bool { didSet { Self.store(roundedSelection, "roundedSelection") } }
    @Published var lineNumbers: Bool { didSet { Self.store(lineNumbers, "lineNumbers") } }
    @Published var showWordCount: Bool { didSet { Self.store(showWordCount, "showWordCount") } }
    @Published var spellCheck: Bool { didSet { Self.store(spellCheck, "spellCheck") } }
    @Published var autoClose: AutoCloseMode { didSet { Self.store(autoClose, "autoClose") } }
    @Published var vimMode: Bool { didSet { Self.store(vimMode, "vimMode") } }
    @Published var relativeLineNumbers: Bool { didSet { Self.store(relativeLineNumbers, "relativeLineNumbers") } }

    // Sounds
    @Published var typingSound: TypingSound { didSet { Self.store(typingSound, "typingSound") } }
    @Published var typingVolume: Double { didSet { Self.store(typingVolume, "typingVolume") } }

    // Preview
    @Published var followMode: FollowMode { didSet { Self.store(followMode, "followMode") } }

    // Packages: namespace -> folder path, stored as JSON.
    @Published var namespacesJSON: String { didSet { Self.store(namespacesJSON, "namespaces") } }

    private init() {
        language = Self.load("language", .system)
        editorPosition = Self.load("editorPosition", .left)
        rippleOnClick = Self.load("rippleOnClick", true)
        ignoreLibraryWarnings = Self.load("ignoreLibraryWarnings", true)
        editorFontName = Self.load("editorFontName", "")  // empty = system monospaced
        editorFontSize = Self.load("editorFontSize", 13.0)
        themeID = Self.load("theme", EditorTheme.typstDefault.id)
        animatedCaret = Self.load("animatedCaret", true)
        roundedSelection = Self.load("roundedSelection", true)
        lineNumbers = Self.load("lineNumbers", true)
        showWordCount = Self.load("showWordCount", true)
        spellCheck = Self.load("spellCheck", true)
        autoClose = Self.load("autoClose", .immediately)
        vimMode = Self.load("vimMode", false)
        relativeLineNumbers = Self.load("relativeLineNumbers", false)
        typingSound = Self.load("typingSound", .off)
        typingVolume = Self.load("typingVolume", 0.6)
        followMode = Self.load("followMode", .caret)
        namespacesJSON = Self.load("namespaces", "{}")
    }

    var namespaces: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(namespacesJSON.utf8))) ?? [:] }
        set {
            namespacesJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    var theme: EditorTheme { EditorTheme.all.first { $0.id == themeID } ?? .typstDefault }

    var editorFont: NSFont {
        if !editorFontName.isEmpty, let font = NSFont(name: editorFontName, size: editorFontSize) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    static let minFontSize = 9.0
    static let maxFontSize = 32.0
    static let defaultFontSize = 13.0
}

// MARK: - Persistence

protocol SettingValue {
    static func load(_ any: Any) -> Self?
    var stored: Any { get }
}

extension Bool: SettingValue {
    static func load(_ any: Any) -> Bool? { any as? Bool }
    var stored: Any { self }
}

extension Double: SettingValue {
    static func load(_ any: Any) -> Double? { any as? Double }
    var stored: Any { self }
}

extension String: SettingValue {
    static func load(_ any: Any) -> String? { any as? String }
    var stored: Any { self }
}

extension SettingValue where Self: RawRepresentable, RawValue == String {
    static func load(_ any: Any) -> Self? { (any as? String).flatMap(Self.init(rawValue:)) }
    var stored: Any { rawValue }
}

extension EditorPosition: SettingValue {}
extension AutoCloseMode: SettingValue {}
extension FollowMode: SettingValue {}
extension TypingSound: SettingValue {}
extension AppLanguage: SettingValue {}

extension AppSettings {
    fileprivate static func load<T: SettingValue>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key).flatMap(T.load) ?? fallback
    }

    fileprivate static func store<T: SettingValue>(_ value: T, _ key: String) {
        UserDefaults.standard.set(value.stored, forKey: key)
    }
}
