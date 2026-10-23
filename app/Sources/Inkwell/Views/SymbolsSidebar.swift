import AppKit
import SwiftUI
import TypstCore

/// Browse `sym` and `emoji` symbols, or draw one to find it.
struct SymbolsSidebar: View {
    @ObservedObject var workspace: Workspace
    @State private var mode = 0
    @State private var query = ""
    @State private var copied: String?
    /// `sym` first, then emoji, each in definition order.
    private static let all: [SymbolEntry] = {
        let symbols = TypstCore.symbols().filter { !$0.deprecated }
        return symbols.filter { $0.module == "sym" } + symbols.filter { $0.module != "sym" }
    }()

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                Text("Text").tag(0)
                Text("Draw").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .controlSize(.small)

            if mode == 0 {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search symbols", text: $query).textFieldStyle(.plain)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                .padding(.horizontal, 10)
                grid(filtered)
            } else {
                DrawSymbolView { names in
                    grid(names.compactMap { name in Self.all.first { $0.name == name } })
                }
            }
        }
    }

    private var filtered: [SymbolEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Self.all }
        return Self.all.filter { $0.name.lowercased().contains(q) || $0.value == q }
    }

    private func grid(_ symbols: [SymbolEntry]) -> some View {
        ScrollView {
            if symbols.isEmpty {
                Text("No symbols match.").foregroundStyle(.secondary).padding(.top, 20)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(symbols, id: \.name) { symbol in
                    SymbolCell(symbol: symbol, copied: copied == symbol.name) {
                        let name = (symbol.module == "emoji" ? "emoji." : "") + symbol.name
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(name, forType: .string)
                        copied = symbol.name
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if copied == symbol.name { copied = nil }
                        }
                    } insert: {
                        insert(symbol)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    private func insert(_ symbol: SymbolEntry) {
        guard let tv = EditorRegistry.shared.textView(for: workspace) else { return }
        let prefix = symbol.module == "emoji" ? "#emoji." : "#sym."
        tv.insertText(prefix + symbol.name, replacementRange: tv.selectedRange())
        tv.window?.makeFirstResponder(tv)
    }
}

struct SymbolCell: View {
    let symbol: SymbolEntry
    let copied: Bool
    let copy: () -> Void
    let insert: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(symbol.value)
            .font(.system(size: 17))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
            .overlay {
                if copied {
                    Text("Copied").font(.system(size: 8, weight: .bold)).padding(2)
                        .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white)
                        .offset(y: 13)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: copy)
            .onHover { hovering = $0 }
            .help("\(symbol.name) — Click to copy the name")
            .contextMenu {
                Button("Insert") { insert() }
                Button("Copy Name") { copy() }
                Button("Copy Symbol") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(symbol.value, forType: .string)
                }
            }
    }
}

/// A canvas to draw a symbol; recognized candidates are shown below it.
struct DrawSymbolView<Results: View>: View {
    @ViewBuilder let results: ([String]) -> Results
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var candidates: [String] = []

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Canvas { ctx, _ in
                    for stroke in strokes + [current] where stroke.count > 1 {
                        var path = Path()
                        path.addLines(stroke)
                        ctx.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { current.append($0.location) }
                    .onEnded { _ in
                        strokes.append(current)
                        current = []
                        recognize()
                    })
                Button("Clear") {
                    strokes = []
                    candidates = []
                }
                .controlSize(.small)
                .padding(6)
            }
            .frame(height: 200)
            .padding(.horizontal, 10)
            if strokes.isEmpty {
                Text("Draw a symbol above").font(.caption).foregroundStyle(.secondary)
            }
            results(candidates)
        }
    }

    private func recognize() {
        let input = strokes.map { $0.map { [Float($0.x), Float($0.y)] } }
        DispatchQueue.global(qos: .userInitiated).async {
            let names = SymbolRecognizer.shared.recognize(strokes: input)
            DispatchQueue.main.async { candidates = names }
        }
    }
}
