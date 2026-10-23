import AppKit
import SwiftUI

/// A structured editor for .bib files, with a raw source mode.
struct BibLibraryView: View {
    @ObservedObject var document: OpenDocument
    @ObservedObject var workspace: Workspace
    @State private var entries: [BibEntry] = []
    @State private var selection: String?
    @State private var query = ""
    @State private var showSource = false
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var confirmDelete: BibEntry?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if showSource {
                EditorView(workspace: workspace)
            } else if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "books.vertical").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("No Entries").font(.headline)
                    Text("Add your first record with the + button.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    list.frame(minWidth: 200, idealWidth: 260)
                    detail.frame(minWidth: 260)
                }
            }
        }
        .onAppear(perform: reparse)
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { _ in reparse() }
        .onReceive(NotificationCenter.default.publisher(for: .documentReloaded, object: document)) { _ in reparse() }
        .sheet(isPresented: $showPaste) { pasteSheet }
        .alert("Delete “\(confirmDelete?.key ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let entry = confirmDelete { replace(entry.range, with: "") }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("The entry is removed from the .bib file.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Label("Bibliography", systemImage: "books.vertical").font(.system(size: 12, weight: .semibold))
            Spacer()
            if !showSource {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search entries", text: $query).textFieldStyle(.plain)
                }
                .padding(4)
                .frame(width: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                Menu {
                    ForEach(BibTeX.entryTypes, id: \.self) { type in
                        Button(type) { addRecord(type) }
                    }
                    Divider()
                    Button("Paste Raw BibTeX…") { showPaste = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a record")
            }
            Picker("", selection: $showSource) {
                Text("Entries").tag(false)
                Text("Source").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .labelsHidden()
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
    }

    private var filtered: [BibEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.key.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.authors.lowercased().contains(q)
        }
    }

    private var list: some View {
        List(filtered, selection: $selection) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text([entry.authors, entry.year].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.type).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    Text("@" + entry.key).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .tag(entry.key)
            .contextMenu {
                Button("Copy") { copyCitation(entry) }
                Button("Delete Record", role: .destructive) { confirmDelete = entry }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let key = selection, let entry = entries.first(where: { $0.key == key }) {
            BibEntryEditor(
                entry: entry,
                duplicateKey: { candidate in entries.filter { $0.key == candidate }.count > (candidate == entry.key ? 1 : 0) },
                commit: { updated in
                    replace(entry.range, with: updated.source)
                    selection = updated.key
                },
                copy: { copyCitation(entry) },
                delete: { confirmDelete = entry })
                .id(entry.id)
        } else {
            Text("Select an entry").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste Raw BibTeX").font(.headline)
            Text("Paste one or more entries — they're appended to the file as-is.").foregroundStyle(.secondary)
            TextEditor(text: $pasteText)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 480, height: 260)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { showPaste = false }
                Button("Add") {
                    append(pasteText.trimmingCharacters(in: .whitespacesAndNewlines))
                    pasteText = ""
                    showPaste = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: Editing

    private func reparse() {
        let parsed = BibTeX.parse(document.text)
        if parsed != entries { entries = parsed }
        if selection == nil || !entries.contains(where: { $0.key == selection }) {
            selection = entries.first?.key
        }
    }

    private func replace(_ range: NSRange, with text: String) {
        let storage = document.storage
        guard NSMaxRange(range) <= storage.length else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
        workspace.textChanged(document)
        reparse()
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        let current = document.text
        let separator = current.isEmpty ? "" : (current.hasSuffix("\n\n") ? "" : (current.hasSuffix("\n") ? "\n" : "\n\n"))
        replace(NSRange(location: document.storage.length, length: 0), with: separator + text + "\n")
    }

    private func addRecord(_ type: String) {
        var n = entries.count + 1
        var key = "key\(n)"
        while entries.contains(where: { $0.key == key }) {
            n += 1
            key = "key\(n)"
        }
        let entry = BibEntry(type: type, key: key, fields: [("author", ""), ("title", ""), ("year", "")], range: NSRange())
        append(entry.source)
        selection = key
    }

    private func copyCitation(_ entry: BibEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("@" + entry.key, forType: .string)
    }
}

/// Edits one entry's type, key and fields.
struct BibEntryEditor: View {
    let entry: BibEntry
    let duplicateKey: (String) -> Bool
    let commit: (BibEntry) -> Void
    let copy: () -> Void
    let delete: () -> Void
    @State private var type = ""
    @State private var key = ""
    @State private var fields: [EditableField] = []
    @State private var customName = ""
    @State private var showCustom = false

    struct EditableField: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $type) {
                    ForEach(Array(Set(BibTeX.entryTypes + [entry.type])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                TextField("citation key", text: $key)
                if duplicateKey(key) {
                    Label("Another entry uses this citation key", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
            }
            Section("Fields") {
                ForEach($fields) { $field in
                    HStack(alignment: .top) {
                        Text(field.name).frame(width: 80, alignment: .trailing).foregroundStyle(.secondary)
                        TextField("", text: $field.value, axis: .vertical).lineLimit(1...6)
                        Button {
                            fields.removeAll { $0.id == field.id }
                            save()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove field")
                    }
                }
                Menu("Add Field") {
                    ForEach(BibTeX.commonFields.filter { name in !fields.contains { $0.name == name } }, id: \.self) { name in
                        Button(name) { fields.append(EditableField(name: name, value: "")) }
                    }
                    Divider()
                    Button("Custom Field…") { showCustom = true }
                }
                .fixedSize()
            }
            Section {
                HStack {
                    Button("Save", action: save).keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("Copy", action: copy)
                    Spacer()
                    Button("Delete Record", role: .destructive, action: delete)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            type = entry.type
            key = entry.key
            fields = entry.fields.map { EditableField(name: $0.name, value: $0.value) }
        }
        .onSubmit(save)
        .alert("Add Custom Field", isPresented: $showCustom) {
            TextField("Field name", text: $customName)
            Button("Add") {
                let name = customName.trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty { fields.append(EditableField(name: name, value: "")) }
                customName = ""
            }
            Button("Cancel", role: .cancel) { customName = "" }
        }
    }

    private func save() {
        var updated = entry
        updated.type = type
        updated.key = key.trimmingCharacters(in: .whitespaces)
        updated.fields = fields.map { ($0.name, $0.value) }
        if updated != entry { commit(updated) }
    }
}
