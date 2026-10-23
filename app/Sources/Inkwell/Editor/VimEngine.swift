import AppKit

/// Modal editing with the common Vim commands.
final class VimEngine {
    enum Mode: String {
        case normal = "NORMAL"
        case insert = "INSERT"
        case visual = "VISUAL"
        case visualLine = "VISUAL LINE"
    }

    unowned let textView: EditorTextView
    private(set) var mode: Mode = .normal {
        didSet {
            NotificationCenter.default.post(name: .vimModeChanged, object: textView)
            textView.updateCaret(animated: false)
        }
    }
    /// Pending operator (d, c, y) or prefix (g, r).
    private var pending = ""
    private var count = ""
    private var register = ""
    private var registerIsLine = false
    private var visualAnchor = 0

    init(textView: EditorTextView) {
        self.textView = textView
    }

    private var ns: NSString { textView.nsString }
    private var caret: Int { textView.selectedRange().location }

    func reset() {
        mode = .normal
        pending = ""
        count = ""
    }

    /// Returns true if the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }

        if mode == .insert {
            if event.keyCode == 53 || (flags.contains(.control) && event.charactersIgnoringModifiers == "[") {
                mode = .normal
                move(to: max(lineStart(caret), caret - 1))
                return true
            }
            return false
        }

        // Normal / visual mode.
        if event.keyCode == 53 {
            pending = ""
            count = ""
            if mode != .normal {
                mode = .normal
                move(to: caret)
            }
            return true
        }
        if flags.contains(.control) {
            switch event.charactersIgnoringModifiers {
            case "r": textView.undoManager?.redo(); return true
            case "d": repeatMotion { self.moveLines(15) }; return true
            case "u": repeatMotion { self.moveLines(-15) }; return true
            default: return true
            }
        }
        // Arrow keys and other special keys behave normally.
        if [123, 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) { return false }
        guard let chars = event.characters, let key = chars.first else { return true }

        if pending == "r" {
            pending = ""
            let range = NSRange(location: caret, length: caret < ns.length ? 1 : 0)
            if range.length == 1, ns.substring(with: range) != "\n" {
                replace(range, with: String(key))
                move(to: range.location)
            }
            return true
        }

        if key.isNumber, !(key == "0" && count.isEmpty) {
            count.append(key)
            return true
        }
        let n = max(1, Int(count) ?? 1)
        count = ""

        if !pending.isEmpty, ["d", "c", "y"].contains(pending) {
            let op = pending
            pending = ""
            if String(key) == op {
                linewise(op, lines: n)
                return true
            }
            let start = caret
            if let end = motionTarget(key, count: n) {
                var range = start < end ? NSRange(location: start, length: end - start) : NSRange(location: end, length: start - end)
                if key == "e" || key == "$" { range.length += 1 }
                range.length = min(range.length, ns.length - range.location)
                apply(op, to: range, linewise: false)
            }
            return true
        }
        if pending == "g" {
            pending = ""
            if key == "g" { move(to: 0) }
            return true
        }

        if mode == .visual || mode == .visualLine {
            switch key {
            case "d", "x": apply("d", to: visualRange, linewise: mode == .visualLine); mode = .normal; return true
            case "c": apply("c", to: visualRange, linewise: false); return true
            case "y": apply("y", to: visualRange, linewise: mode == .visualLine); mode = .normal; move(to: visualRange.location); return true
            case "v": mode = .normal; move(to: caret); return true
            case "V": mode = .visualLine; extendVisual(to: caretHead); return true
            case ">": textView.shiftLines(right: true); mode = .normal; return true
            case "<": textView.shiftLines(right: false); mode = .normal; return true
            default:
                if let target = motionTarget(key, count: n) {
                    extendVisual(to: target)
                }
                return true
            }
        }

        switch key {
        case "i": mode = .insert
        case "a": mode = .insert; move(to: min(caret + 1, lineEnd(caret)))
        case "I": mode = .insert; move(to: firstNonBlank(caret))
        case "A": mode = .insert; move(to: lineEnd(caret))
        case "o":
            mode = .insert
            let end = lineEnd(caret)
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.insertNewline(nil)
        case "O":
            mode = .insert
            let start = lineStart(caret)
            replace(NSRange(location: start, length: 0), with: "\n")
            move(to: start)
        case "x":
            let len = min(n, lineEnd(caret) - caret)
            if len > 0 { apply("d", to: NSRange(location: caret, length: len), linewise: false) }
        case "X":
            let len = min(n, caret - lineStart(caret))
            if len > 0 { apply("d", to: NSRange(location: caret - len, length: len), linewise: false) }
        case "D": apply("d", to: NSRange(location: caret, length: lineEnd(caret) - caret), linewise: false)
        case "C": apply("c", to: NSRange(location: caret, length: lineEnd(caret) - caret), linewise: false)
        case "S": linewise("c", lines: n)
        case "s": apply("c", to: NSRange(location: caret, length: min(n, lineEnd(caret) - caret)), linewise: false)
        case "d", "c", "y", "g", "r": pending = String(key)
        case "p": paste(after: true)
        case "P": paste(after: false)
        case "u": for _ in 0..<n { textView.undoManager?.undo() }
        case "v": mode = .visual; visualAnchor = caret; extendVisual(to: caret)
        case "V": mode = .visualLine; visualAnchor = caret; extendVisual(to: caret)
        case "J": joinLines()
        case "~": toggleCase()
        case ">": textView.shiftLines(right: true)
        case "<": textView.shiftLines(right: false)
        case "/": textView.performFindPanelAction(NSMenuItem.findAction(.showFindInterface))
        case "n": textView.performFindPanelAction(NSMenuItem.findAction(.nextMatch))
        case "N": textView.performFindPanelAction(NSMenuItem.findAction(.previousMatch))
        default:
            if let target = motionTarget(key, count: n) { move(to: target) }
        }
        return true
    }

    private var caretHead: Int {
        let sel = textView.selectedRange()
        return sel.location == visualAnchor ? NSMaxRange(sel) - (sel.length > 0 ? 1 : 0) : sel.location
    }

    private var visualRange: NSRange {
        let sel = textView.selectedRange()
        if mode == .visualLine { return ns.lineRange(for: sel) }
        return sel
    }

    private func extendVisual(to head: Int) {
        let lo = min(visualAnchor, head), hi = max(visualAnchor, head)
        var range = NSRange(location: lo, length: min(hi + 1, ns.length) - lo)
        if mode == .visualLine { range = ns.lineRange(for: range) }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(NSRange(location: head, length: 0))
    }

    private func repeatMotion(_ body: () -> Void) { body() }

    // MARK: Motions

    private func motionTarget(_ key: Character, count: Int) -> Int? {
        var pos = mode == .visual || mode == .visualLine ? caretHead : caret
        for _ in 0..<count {
            switch key {
            case "h": pos = max(lineStart(pos), pos - 1)
            case "l": pos = min(max(lineEnd(pos) - (mode == .normal ? 1 : 0), lineStart(pos)), pos + 1)
            case "j": pos = verticalMove(pos, down: true)
            case "k": pos = verticalMove(pos, down: false)
            case "w": pos = wordForward(pos)
            case "b": pos = wordBackward(pos)
            case "e": pos = wordEnd(pos)
            case "0": pos = lineStart(pos)
            case "^": pos = firstNonBlank(pos)
            case "$": pos = max(lineStart(pos), lineEnd(pos) - 1)
            case "G": pos = lineStart(ns.length)
            case "}": pos = paragraph(pos, forward: true)
            case "{": pos = paragraph(pos, forward: false)
            default: return nil
            }
        }
        return pos
    }

    private func lineStart(_ i: Int) -> Int { ns.lineRange(for: NSRange(location: min(i, ns.length), length: 0)).location }

    private func lineEnd(_ i: Int) -> Int {
        var end = NSMaxRange(ns.lineRange(for: NSRange(location: min(i, ns.length), length: 0)))
        if end > 0, end <= ns.length, ns.character(at: end - 1) == 10 { end -= 1 }
        return end
    }

    private func firstNonBlank(_ i: Int) -> Int {
        var p = lineStart(i)
        let end = lineEnd(i)
        while p < end, [32, 9].contains(ns.character(at: p)) { p += 1 }
        return p
    }

    private func verticalMove(_ pos: Int, down: Bool) -> Int {
        let column = pos - lineStart(pos)
        let target: Int
        if down {
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: pos, length: 0)))
            guard next < ns.length || (next == ns.length && next > lineEnd(pos)) else { return pos }
            target = next
        } else {
            let start = lineStart(pos)
            guard start > 0 else { return pos }
            target = lineStart(start - 1)
        }
        return min(target + column, max(target, lineEnd(target) - (mode == .normal ? 1 : 0)))
    }

    private func moveLines(_ delta: Int) {
        var pos = caret
        for _ in 0..<abs(delta) { pos = verticalMove(pos, down: delta > 0) }
        move(to: pos)
    }

    private func isWord(_ c: unichar) -> Bool {
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || c == 95
    }

    private func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 }

    private func wordForward(_ pos: Int) -> Int {
        var p = pos
        let n = ns.length
        guard p < n else { return n }
        let startWord = isWord(ns.character(at: p))
        if !isSpace(ns.character(at: p)) {
            while p < n, !isSpace(ns.character(at: p)), isWord(ns.character(at: p)) == startWord { p += 1 }
        }
        while p < n, isSpace(ns.character(at: p)) { p += 1 }
        return p
    }

    private func wordBackward(_ pos: Int) -> Int {
        var p = pos
        guard p > 0 else { return 0 }
        p -= 1
        while p > 0, isSpace(ns.character(at: p)) { p -= 1 }
        let word = isWord(ns.character(at: p))
        while p > 0, !isSpace(ns.character(at: p - 1)), isWord(ns.character(at: p - 1)) == word { p -= 1 }
        return p
    }

    private func wordEnd(_ pos: Int) -> Int {
        var p = pos + 1
        let n = ns.length
        while p < n, isSpace(ns.character(at: p)) { p += 1 }
        guard p < n else { return max(0, n - 1) }
        let word = isWord(ns.character(at: p))
        while p + 1 < n, !isSpace(ns.character(at: p + 1)), isWord(ns.character(at: p + 1)) == word { p += 1 }
        return p
    }

    private func paragraph(_ pos: Int, forward: Bool) -> Int {
        var line = ns.lineRange(for: NSRange(location: pos, length: 0))
        while true {
            if forward {
                let next = NSMaxRange(line)
                guard next < ns.length else { return ns.length }
                line = ns.lineRange(for: NSRange(location: next, length: 0))
            } else {
                guard line.location > 0 else { return 0 }
                line = ns.lineRange(for: NSRange(location: line.location - 1, length: 0))
            }
            if ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return line.location
            }
        }
    }

    // MARK: Edits

    private func move(to pos: Int) {
        let p = max(0, min(pos, ns.length))
        textView.setSelectedRange(NSRange(location: p, length: 0))
        textView.scrollRangeToVisible(NSRange(location: p, length: 0))
    }

    private func replace(_ range: NSRange, with text: String) {
        textView.insertText(text, replacementRange: range)
    }

    private func apply(_ op: String, to range: NSRange, linewise: Bool) {
        guard range.location != NSNotFound else { return }
        register = ns.substring(with: range)
        registerIsLine = linewise
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(register, forType: .string)
        switch op {
        case "d":
            replace(range, with: "")
            move(to: min(range.location, max(0, ns.length - (linewise ? 0 : 0))))
        case "c":
            replace(range, with: "")
            move(to: range.location)
            mode = .insert
        default:
            break
        }
    }

    private func linewise(_ op: String, lines: Int) {
        var range = ns.lineRange(for: NSRange(location: caret, length: 0))
        for _ in 1..<max(1, lines) {
            let next = NSMaxRange(range)
            guard next < ns.length else { break }
            range = NSUnionRange(range, ns.lineRange(for: NSRange(location: next, length: 0)))
        }
        if op == "c" {
            // Keep the line break, change the content.
            var content = range
            if NSMaxRange(content) > 0, NSMaxRange(content) <= ns.length, ns.character(at: NSMaxRange(content) - 1) == 10 {
                content.length -= 1
            }
            apply("c", to: content, linewise: false)
            return
        }
        apply(op, to: range, linewise: true)
        if op == "d" { move(to: firstNonBlank(min(range.location, ns.length))) }
    }

    private func paste(after: Bool) {
        let text = NSPasteboard.general.string(forType: .string) ?? register
        guard !text.isEmpty else { return }
        if registerIsLine || text.hasSuffix("\n") && text == register && registerIsLine {
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            let at = after ? NSMaxRange(line) : line.location
            var insert = text
            if after, at == ns.length, !ns.substring(to: at).hasSuffix("\n") { insert = "\n" + insert.trimmingCharacters(in: .newlines) }
            replace(NSRange(location: at, length: 0), with: insert)
            move(to: at + (insert.hasPrefix("\n") ? 1 : 0))
        } else {
            let at = after ? min(caret + 1, ns.length) : caret
            replace(NSRange(location: at, length: 0), with: text)
            move(to: at + (text as NSString).length - 1)
        }
    }

    private func joinLines() {
        let end = lineEnd(caret)
        guard end < ns.length else { return }
        var next = end + 1
        while next < ns.length, [32, 9].contains(ns.character(at: next)) { next += 1 }
        replace(NSRange(location: end, length: next - end), with: " ")
        move(to: end)
    }

    private func toggleCase() {
        guard caret < ns.length else { return }
        let range = NSRange(location: caret, length: 1)
        let c = ns.substring(with: range)
        let flipped = c == c.uppercased() ? c.lowercased() : c.uppercased()
        replace(range, with: flipped)
        move(to: min(caret, lineEnd(caret)))
    }
}

extension Notification.Name {
    static let vimModeChanged = Notification.Name("InkwellVimModeChanged")
}

extension NSMenuItem {
    /// A menu item whose tag carries a find-panel action.
    static func findAction(_ action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.tag = action.rawValue
        return item
    }
}
