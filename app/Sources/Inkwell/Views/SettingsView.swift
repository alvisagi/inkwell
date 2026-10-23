import AppKit
import SwiftUI
import TypstCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EditorSettings().tabItem { Label("Editor", systemImage: "textformat") }
            PackagesSettings().tabItem { Label("Packages", systemImage: "shippingbox") }
        }
        .frame(width: 580, height: 600)
    }
}

struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var compilers = CompilerManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.language) { _, lang in
                    if lang == .system {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([lang.rawValue], forKey: "AppleLanguages")
                    }
                }
                Text("Takes effect after Inkwell restarts.").font(.caption).foregroundStyle(.secondary)
                Text("Translations were generated with the help of AI.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Live Preview") {
                Picker("Editor position", selection: $settings.editorPosition) {
                    ForEach(EditorPosition.allCases) { Text($0.title).tag($0) }
                }
                Text("Which side of the window the editor is on — the live preview takes the other side.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Ripple on click", isOn: $settings.rippleOnClick)
                Text("Bloom a soft ripple from the point you click in the preview.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Follow cursor", selection: $settings.followMode) {
                    ForEach(FollowMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Diagnostics") {
                Toggle("Ignore library warnings", isOn: $settings.ignoreLibraryWarnings)
                Text("Hide warnings coming from imported library packages (e.g. @preview/…). Warnings in your own files and all errors are still shown.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Typst Compiler") {
                CompilerRow(
                    title: "Latest (\(typstVersion()))", note: "The current Typst compiler. Recommended.",
                    builtIn: true, installed: true, selected: compilers.selected == CompilerManager.latest,
                    downloading: false, error: nil,
                    use: { compilers.selected = CompilerManager.latest }, download: {}, delete: {})
                ForEach(compilers.releases) { release in
                    CompilerRow(
                        title: release.version, note: release.note, builtIn: false,
                        installed: compilers.installedVersions.contains(release.version),
                        selected: compilers.selected == release.version,
                        downloading: compilers.downloading.contains(release.version),
                        error: compilers.errors[release.version],
                        use: { compilers.selected = release.version },
                        download: { compilers.download(release.version) },
                        delete: { compilers.delete(release.version) })
                }
                Text("Older compilers are downloaded on demand. The latest is built in and powers autocomplete, jump-to-source, and the preview regardless of the selected version.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Developer") {
                Button("Show “What's New” Window") { openWindow(id: "whats-new") }
                Text("Opens the What's New window that normally appears once after an update.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct EditorSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var fonts: [String] = []

    var body: some View {
        Form {
            Section("Editor Typography") {
                Picker("Font", selection: $settings.editorFontName) {
                    Text("System Monospaced").tag("")
                    Divider()
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Size")
                    Slider(value: $settings.editorFontSize, in: AppSettings.minFontSize...AppSettings.maxFontSize, step: 1)
                    Text("\(Int(settings.editorFontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section("Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    ForEach(EditorTheme.all) { theme in
                        ThemeCard(theme: theme, selected: settings.themeID == theme.id)
                            .onTapGesture { settings.themeID = theme.id }
                    }
                }
                .padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    ThemePreview(theme: settings.theme, font: settings.editorFont)
                }
            }
            Section("General") {
                Toggle("Animated caret", isOn: $settings.animatedCaret)
                Toggle("Rounded selection", isOn: $settings.roundedSelection)
                Toggle("Line numbers", isOn: $settings.lineNumbers)
                Toggle("Show word count", isOn: $settings.showWordCount)
                Toggle("Check spelling while typing", isOn: $settings.spellCheck)
                Picker("Auto-close", selection: $settings.autoClose) {
                    ForEach(AutoCloseMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Vim") {
                Toggle(isOn: $settings.vimMode) {
                    HStack {
                        Text("Vim key bindings")
                        Text("BETA").font(.caption2.bold()).padding(.horizontal, 4)
                            .background(Capsule().fill(Color.orange.opacity(0.3))).foregroundStyle(.orange)
                    }
                }
                Text("Modal editing with the common vim commands. The current mode (Normal, Insert, Visual) shows in the editor's bottom bar.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Relative line numbers", isOn: $settings.relativeLineNumbers)
                    .disabled(!settings.vimMode)
                Text("Gutter numbers count outward from the caret's line — the caret's line keeps its absolute number.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Typing Sounds") {
                Picker("Sound", selection: $settings.typingSound) {
                    ForEach(TypingSound.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.typingSound) { _, sound in TypingSoundPlayer.shared.preview(sound) }
                HStack {
                    Text("Volume")
                    Slider(value: $settings.typingVolume, in: 0...1) { editing in
                        if !editing { TypingSoundPlayer.shared.preview(settings.typingSound) }
                    }
                }
                Text("Plays a key sound as you type — pick your machine.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            fonts = NSFontManager.shared.availableFontFamilies.filter { family in
                guard let font = NSFont(name: family, size: 12) else { return false }
                return font.isFixedPitch || family.lowercased().contains("mono") || family.lowercased().contains("code")
            }
        }
    }
}

struct ThemeCard: View {
    let theme: EditorTheme
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(Array(theme.swatches.enumerated()), id: \.offset) { _, color in
                    Circle().fill(Color(nsColor: color)).frame(width: 9, height: 9)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: theme.background)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2.5 : 1))
            Text(theme.name).font(.system(size: 11, weight: selected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
    }
}

struct ThemePreview: View {
    let theme: EditorTheme
    let font: NSFont

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text("#let").foregroundColor(Color(nsColor: theme.keyword))
                + Text(" answer = ").foregroundColor(Color(nsColor: theme.foreground))
                + Text("42").foregroundColor(Color(nsColor: theme.number)))
            (Text("Typst").italic().foregroundColor(Color(nsColor: theme.foreground))
                + Text(" is ").foregroundColor(Color(nsColor: theme.foreground))
                + Text("awesome!").foregroundColor(Color(nsColor: theme.string)))
            (Text("= Heading").bold().foregroundColor(Color(nsColor: theme.heading))
                + Text("  // comment").foregroundColor(Color(nsColor: theme.comment)))
        }
        .font(Font(font))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: theme.background)))
    }
}

struct PackagesSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var downloaded: [DownloadedPackage] = []
    @State private var spec = "@preview/"
    @State private var downloading = false
    @State private var message: String?
    @State private var namespace = ""

    var body: some View {
        Form {
            Section {
                Text("Downloaded automatically when you `#import \"@preview/…\"`. Download one ahead of time by spec:")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $spec, prompt: Text("@preview/cetz:0.3.1"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(download)
                    Button("Download", action: download).disabled(downloading || spec.count < 12)
                }
                if downloading { ProgressView().controlSize(.small) }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if downloaded.isEmpty {
                    Text("No @preview packages downloaded yet").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                } else {
                    Text(downloaded.count == 1 ? "1 package" : "\(downloaded.count) packages").font(.caption).foregroundStyle(.secondary)
                    ForEach(downloaded, id: \.path) { pkg in
                        HStack {
                            Text("@preview/\(pkg.name)").font(.system(.body, design: .monospaced))
                            Text(pkg.version).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("#import \"@preview/\(pkg.name):\(pkg.version)\"", forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy Import Spec")
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pkg.path)])
                            } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless).help("Show in Finder")
                            Button(role: .destructive) {
                                try? deletePackage(path: pkg.path)
                                refresh()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Delete the downloaded package")
                        }
                    }
                }
            } header: {
                Label("Online packages", systemImage: "shippingbox")
            }
            Section {
                Text("Register a folder as a namespace. A folder containing `my_libs/<version>/`, registered as `personal`, imports as `@personal/my_libs:<version>`. Removing only forgets the mapping — your files stay put.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $namespace, prompt: Text("namespace (optional)")).textFieldStyle(.roundedBorder)
                    Button("Link Folder…", action: linkFolder)
                }
                let namespaces = settings.namespaces.sorted { $0.key < $1.key }
                if namespaces.isEmpty {
                    Text("No namespaces registered yet").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                ForEach(namespaces, id: \.key) { name, path in
                    HStack {
                        Text("@\(name)").font(.system(.body, design: .monospaced))
                        Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            var map = settings.namespaces
                            map[name] = nil
                            settings.namespaces = map
                            applyNamespaces()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Forget this namespace (keeps your files)")
                    }
                }
            } header: {
                Label("Local packages", systemImage: "folder")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = downloadedPackages()
            DispatchQueue.main.async { downloaded = list }
        }
    }

    private func download() {
        let value = spec.trimmingCharacters(in: .whitespaces)
        downloading = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try downloadPackage(spec: value) }
            DispatchQueue.main.async {
                downloading = false
                switch result {
                case .success: message = String(localized: "Downloaded \(value)"); spec = "@preview/"
                case let .failure(error): message = "\(error)"
                }
                refresh()
            }
        }
    }

    private func linkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Link")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var name = namespace.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty { name = url.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-") }
        var map = settings.namespaces
        map[name] = url.path
        settings.namespaces = map
        namespace = ""
        applyNamespaces()
    }

    private func applyNamespaces() {
        setNamespaces(namespaces: settings.namespaces)
    }
}

struct CompilerRow: View {
    let title: String
    let note: String
    let builtIn: Bool
    let installed: Bool
    let selected: Bool
    let downloading: Bool
    let error: String?
    let use: () -> Void
    let download: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).bold()
                    if builtIn { badge("Built-in", Color.secondary.opacity(0.2), .primary) }
                    if selected { badge("Selected", Color.accentColor.opacity(0.25), .accentColor) }
                }
                Text(note).font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if downloading {
                ProgressView().controlSize(.small)
            } else if !installed {
                Button { download() } label: { Label("Download", systemImage: "arrow.down.circle") }
            } else if !selected {
                Button("Use", action: use)
                if !builtIn {
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete this downloaded compiler")
                }
            } else if !builtIn {
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete this downloaded compiler")
            }
        }
    }

    private func badge(_ text: String, _ background: Color, _ foreground: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(background)).foregroundStyle(foreground)
    }
}
