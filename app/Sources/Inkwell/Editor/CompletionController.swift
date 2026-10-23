import AppKit
import TypstCore

/// The autocompletion popup shown under the caret.
final class CompletionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private(set) var items: [CompletionItem] = []
    private var allItems: [CompletionItem] = []
    private(set) var from = 0
    weak var textView: EditorTextView?
    var onAccept: ((CompletionItem, Int) -> Void)?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.level = .popUpMenu

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        let stack = NSStackView(views: [scroll, detail])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    /// Shows completions; `prefix` filters labels.
    func show(_ completions: [CompletionItem], from: Int, prefix: String, at screenRect: NSRect, in window: NSWindow) {
        allItems = completions
        self.from = from
        filter(prefix: prefix)
        guard !items.isEmpty else {
            hide()
            return
        }
        let visibleRows = min(items.count, 10)
        let height = CGFloat(visibleRows) * table.rowHeight + 8 + (detail.stringValue.isEmpty ? 0 : 40)
        let origin = NSPoint(x: screenRect.minX - 24, y: screenRect.minY - height - 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 380, height: height)), display: true)
        if panel.parent == nil {
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func filter(prefix: String) {
        let lower = prefix.lowercased()
        if lower.isEmpty {
            items = allItems
        } else {
            let scored = allItems.compactMap { item -> (Int, CompletionItem)? in
                let label = item.label.lowercased()
                if label.hasPrefix(lower) { return (0, item) }
                if label.contains(lower) { return (1, item) }
                if Self.fuzzy(lower, label) { return (2, item) }
                return nil
            }
            items = scored.sorted { $0.0 < $1.0 }.map(\.1)
        }
        table.reloadData()
        if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateDetail()
    }

    private static func fuzzy(_ needle: String, _ hay: String) -> Bool {
        var it = hay.makeIterator()
        outer: for c in needle {
            while let h = it.next() {
                if h == c { continue outer }
            }
            return false
        }
        return true
    }

    func hide() {
        if let parent = panel.parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateDetail()
    }

    func acceptSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        hide()
        onAccept?(item, from)
    }

    @objc private func doubleClicked() {
        acceptSelected()
    }

    private func updateDetail() {
        let row = table.selectedRow
        detail.stringValue = row >= 0 && row < items.count ? (items[row].detail ?? "") : ""
        detail.isHidden = detail.stringValue.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(for: item.kind), accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Self.tint(for: item.kind)
        let label = NSTextField(labelWithString: item.symbol.map { "\($0)  \(item.label)" } ?? item.label)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        let kind = NSTextField(labelWithString: item.kind)
        kind.font = .systemFont(ofSize: 10)
        kind.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [icon, label, NSView(), kind])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetail()
    }

    static func symbol(for kind: String) -> String {
        switch kind {
        case "function": "f.cursive"
        case "type": "t.square"
        case "param": "p.square"
        case "constant": "c.square"
        case "path": "doc"
        case "package": "shippingbox"
        case "label": "tag"
        case "font": "textformat"
        case "symbol": "character"
        default: "curlybraces"
        }
    }

    static func tint(for kind: String) -> NSColor {
        switch kind {
        case "function": .systemBlue
        case "type": .systemPurple
        case "param": .systemTeal
        case "constant": .systemOrange
        case "label": .systemGreen
        case "symbol": .systemPink
        default: .secondaryLabelColor
        }
    }
}
