import AppKit
import SwiftUI
import TypstCore

/// Pick a Typst Universe template and create a project from it.
struct TemplateGalleryView: View {
    @ObservedObject private var index = PackageIndex.shared
    @State private var query = ""
    @State private var category = "All"
    @State private var selection: UniversePackage?
    @State private var creating = false
    @State private var error: String?
    @State private var customSpec = ""
    @Environment(\.dismissWindow) private var dismissWindow

    private var categories: [String] {
        ["All"] + Array(Set(index.templates.flatMap(\.categories))).sorted()
    }

    private var filtered: [UniversePackage] {
        let q = query.lowercased()
        return index.templates.filter { pkg in
            (category == "All" || pkg.categories.contains(category))
                && (q.isEmpty || pkg.name.lowercased().contains(q) || (pkg.description ?? "").lowercased().contains(q)
                    || pkg.keywords.contains { $0.lowercased().contains(q) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a Template").font(.title2.bold())
                Spacer()
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search templates", text: $query).textFieldStyle(.plain)
                }
                .padding(6)
                .frame(width: 240)
                .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
            }
            .padding(16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(categories, id: \.self) { cat in
                        Button(cat.capitalized) { category = cat }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(category == cat ? Color.accentColor : Color.primary.opacity(0.07)))
                            .foregroundStyle(category == cat ? .white : .primary)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { index.load() }
    }

    @ViewBuilder
    private var content: some View {
        if index.isLoading && index.packages.isEmpty {
            ProgressView("Loading templates…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = index.error, index.packages.isEmpty {
            VStack(spacing: 8) {
                Text("Couldn't load templates").font(.headline)
                Text(error).foregroundStyle(.secondary)
                Button("Try again") { index.load(force: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            Text("No templates match “\(query)”").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 18) {
                    ForEach(filtered, id: \.name) { pkg in
                        TemplateCard(package: pkg, selected: selection?.name == pkg.name)
                            .onTapGesture { selection = pkg }
                            .onTapGesture(count: 2) {
                                selection = pkg
                                create()
                            }
                    }
                }
                .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TextField("Any template package published on typst.app/universe.", text: $customSpec)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .help("Add a template from Typst Universe — e.g. charged-ieee")
            if let error { Text(error).foregroundStyle(.red).font(.caption).lineLimit(2) }
            Spacer()
            if creating { ProgressView().controlSize(.small) }
            Button("Cancel") { dismissWindow(id: "templates") }
            Button("Create…", action: create)
                .keyboardShortcut(.defaultAction)
                .disabled(creating || (selection == nil && customSpec.isEmpty))
        }
        .padding(14)
    }

    private func create() {
        var target = selection
        let spec = customSpec.trimmingCharacters(in: .whitespaces)
        if !spec.isEmpty {
            let name = spec.replacingOccurrences(of: "@preview/", with: "").split(separator: ":").first.map(String.init) ?? spec
            target = index.packages.first { $0.name == name }
            if target?.templatePath == nil {
                error = String(localized: "“\(name)” is not a template package.")
                return
            }
        }
        guard let pkg = target, let templatePath = pkg.templatePath, let entry = pkg.templateEntrypoint else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "New Project from Template")
        panel.nameFieldStringValue = pkg.name
        panel.prompt = String(localized: "Create")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        creating = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try createFromTemplate(name: pkg.name, version: pkg.version, templatePath: templatePath, entrypoint: entry, destination: dest.path)
            }
            DispatchQueue.main.async {
                creating = false
                switch result {
                case let .success(path):
                    AppActions.open(URL(fileURLWithPath: path))
                    dismissWindow(id: "templates")
                case let .failure(err):
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Couldn’t Create Project")
                    alert.informativeText = "\(err)"
                    alert.runModal()
                }
            }
        }
    }
}

struct TemplateCard: View {
    let package: UniversePackage
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc.richtext").font(.system(size: 30)).foregroundStyle(.gray)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            Text(package.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(package.description ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        .contentShape(Rectangle())
        .onAppear {
            PackageIndex.shared.thumbnail(for: package) { image = $0 }
        }
    }
}
