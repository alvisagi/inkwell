import AppKit
import TypstCore

/// The code editor: a TextKit 2 text view with Typst-aware editing.
final class EditorTextView: NSTextView {
    weak var workspace: Workspace?
    var document: OpenDocument!
    var highlighter: SyntaxHighlighter!
    let completion = CompletionController()
    lazy var vim = VimEngine(textView: self)
    var settings: AppSettings { AppSettings.shared }
    var theme: EditorTheme { settings.theme }

    /// Our own caret, so it can glide and turn into a block in Vim mode.
    private let caretLayer = CALayer()
    private var tooltipTimer: Timer?
    private var tooltipPopover: NSPopover?
    private var lastMouseOffset: Int?
    private var placeholders: [NSRange] = []
    private var completionRequest = 0

    // MARK: Setup

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFontPanel = false
        drawsBackground = true
        textContainerInset = NSSize(width: 4, height: 8)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 6

        wantsLayer = true
        caretLayer.zPosition = 10
        layer?.addSublayer(caretLayer)

        completion.textView = self
        completion.onAccept = { [weak self] item, from in self?.applyCompletion(item, from: from) }
        applySettings()
    }

    func applySettings() {
        let theme = self.theme
        backgroundColor = theme.background
        insertionPointColor = settings.animatedCaret ? .clear : theme.caret
        isContinuousSpellCheckingEnabled = settings.spellCheck && document.kind != .text
        selectedTextAttributes = settings.roundedSelection
            ? [.backgroundColor: NSColor.clear]
            : [.backgroundColor: theme.selection]
        typingAttributes = highlighter.baseAttributes
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        defaultParagraphStyle = paragraph
        caretLayer.backgroundColor = theme.caret.cgColor
        caretLayer.isHidden = !settings.animatedCaret && !settings.vimMode
        updateCaret(animated: false)
        needsDisplay = true
    }

    // MARK: Geometry

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let storage = textContentStorage,
              let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    func offset(of location: NSTextLocation) -> Int {
        guard let storage = textContentStorage else { return 0 }
        return storage.offset(from: storage.documentRange.location, to: location)
    }

    /// Rects (in view coordinates) covering a character range.
    func segmentRects(_ range: NSRange, type: NSTextLayoutManager.SegmentType = .standard) -> [CGRect] {
        guard let layout = textLayoutManager, let textRange = textRange(range) else { return [] }
        var rects: [CGRect] = []
        let origin = textContainerOrigin
        layout.enumerateTextSegments(in: textRange, type: type, options: [.rangeNotRequired]) { _, rect, _, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return rects
    }

    /// The caret's rect in view coordinates.
    func caretRect(at offset: Int) -> CGRect? {
        segmentRects(NSRange(location: offset, length: 0), type: .selection).first
    }

    /// The line fragment rect (full width) containing a character offset.
    func lineRect(at offset: Int) -> CGRect? {
        guard let layout = textLayoutManager, let range = textRange(NSRange(location: offset, length: 0)) else { return nil }
        guard let fragment = layout.textLayoutFragment(for: range.location) else {
            // At the very end of the document, fall back to the caret.
            return caretRect(at: offset).map { CGRect(x: 0, y: $0.minY, width: bounds.width, height: $0.height) }
        }
        let frame = fragment.layoutFragmentFrame
        // Pick the line within a wrapped paragraph that holds the caret.
        let caret = caretRect(at: offset)
        var lineFrame = CGRect(x: 0, y: frame.minY, width: bounds.width, height: frame.height)
        for line in fragment.textLineFragments {
            let r = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY + textContainerOrigin.y)
            if let caret, caret.midY >= r.minY, caret.midY <= r.maxY {
                lineFrame = CGRect(x: 0, y: r.minY, width: bounds.width, height: r.height)
                return lineFrame
            }
        }
        lineFrame.origin.y += textContainerOrigin.y
        return lineFrame
    }

    var caretOffset: Int { selectedRange().location + (selectedRange().length > 0 && selectionAffinity == .downstream ? selectedRange().length : 0) }

    var nsString: NSString { string as NSString }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let sel = selectedRange()
        // Current line.
        if sel.length == 0, let line = lineRect(at: sel.location) {
            theme.currentLine.setFill()
            line.fill()
        }
        // Rounded selection.
        if settings.roundedSelection {
            let color = window?.firstResponder === self ? theme.selection : theme.selection.withAlphaComponent(0.5)
            color.setFill()
            for value in selectedRanges {
                let range = value.rangeValue
                guard range.length > 0 else { continue }
                for r in segmentRects(range) where r.intersects(rect) {
                    NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
                }
            }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        updateCaret(animated: true)
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateCaret(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Positions the custom caret layer.
    func updateCaret(animated: Bool) {
        let useLayer = settings.animatedCaret || (settings.vimMode && vim.mode != .insert)
        insertionPointColor = useLayer ? .clear : theme.caret
        caretLayer.isHidden = !useLayer || selectedRange().length > 0 && !(settings.vimMode && vim.mode == .visual)
        guard useLayer, let rect = caretRect(at: caretOffset) else { return }
        var frame = CGRect(x: rect.minX - 0.5, y: rect.minY, width: 2, height: rect.height)
        if settings.vimMode && vim.mode != .insert {
            // Block cursor as wide as the character under it.
            let next = NSRange(location: caretOffset, length: caretOffset < nsString.length ? 1 : 0)
            let width = segmentRects(next).first?.width ?? 0
            frame.size.width = max(width, highlighter.font.maximumAdvancement.width * 0.6)
            caretLayer.opacity = 0.55
        } else {
            caretLayer.opacity = 1
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || !settings.animatedCaret)
        CATransaction.setAnimationDuration(0.09)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        caretLayer.frame = frame
        caretLayer.cornerRadius = 1
        CATransaction.commit()
        restartBlink()
    }

    private func restartBlink() {
        caretLayer.removeAnimation(forKey: "blink")
        guard window?.firstResponder === self else {
            caretLayer.opacity = 0
            return
        }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        let on = caretLayer.opacity == 0 ? 1 : caretLayer.opacity
        blink.values = [on, on, 0, 0, on]
        blink.keyTimes = [0, 0.5, 0.55, 0.95, 1]
        blink.duration = 1.1
        blink.beginTime = CACurrentMediaTime() + 0.5
        blink.repeatCount = .infinity
        caretLayer.add(blink, forKey: "blink")
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        caretLayer.opacity = 1
        updateCaret(animated: false)
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        completion.hide()
        caretLayer.removeAnimation(forKey: "blink")
        caretLayer.opacity = 0
        needsDisplay = true
        return ok
    }

    // MARK: Key handling

    override func keyDown(with event: NSEvent) {
        if completion.isVisible {
            switch event.keyCode {
            case 125: completion.move(1); return  // down
            case 126: completion.move(-1); return  // up
            case 36, 76, 48: completion.acceptSelected(); return  // return, enter, tab
            case 53: completion.hide(); return  // escape
            default: break
            }
        }
        if event.keyCode == 48, !placeholders.isEmpty, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            jumpToNextPlaceholder()
            return
        }
        // Ctrl-Space: explicit completion.
        if event.keyCode == 49, event.modifierFlags.contains(.control) {
            requestCompletion(explicit: true)
            return
        }
        if settings.vimMode, vim.handle(event) {
            return
        }
        TypingSoundPlayer.shared.play(for: event)
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = string as? String else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        if replacementRange.location == NSNotFound, text.count == 1, handleAutoClose(text) {
            afterTyping(text)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
        afterTyping(text)
    }

    private func afterTyping(_ text: String) {
        guard document.kind == .typst, let last = text.last else { return }
        if last.isLetter || last.isNumber || "#.@$<(:,/\"".contains(last) {
            requestCompletion(explicit: false)
        } else if completion.isVisible {
            completion.hide()
        }
    }

    override func insertNewline(_ sender: Any?) {
        // Keep indentation and continue list markers.
        let ns = nsString
        let caret = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        var insertion = "\n" + indent
        let trimmed = line.dropFirst(indent.count)
        if document.kind == .typst {
            for marker in ["- ", "+ ", "/ "] where trimmed.hasPrefix(marker) {
                if trimmed == marker {
                    // An empty item ends the list.
                    let markerRange = NSRange(location: lineRange.location + indent.utf16.count, length: marker.utf16.count)
                    insertText("", replacementRange: markerRange)
                    return
                }
                insertion += marker
            }
            if trimmed.last.map({ "([{".contains($0) }) == true {
                insertion += "  "
            }
        }
        super.insertText(insertion, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        if sel.length > 0 {
            shiftLines(right: true)
        } else {
            insertText("  ", replacementRange: sel)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLines(right: false)
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        let ns = nsString
        if settings.autoClose != .off, sel.length == 0, sel.location > 0, sel.location < ns.length {
            let before = ns.substring(with: NSRange(location: sel.location - 1, length: 1))
            let after = ns.substring(with: NSRange(location: sel.location, length: 1))
            if let close = Self.pairs[before], close == after {
                insertText("", replacementRange: NSRange(location: sel.location - 1, length: 2))
                return
            }
        }
        super.deleteBackward(sender)
        if completion.isVisible { requestCompletion(explicit: false) }
    }

    static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "$": "$"]

    /// Auto-closes brackets and types over closing characters.
    private func handleAutoClose(_ text: String) -> Bool {
        let mode = settings.autoClose
        guard mode != .off, document.kind != .text || "([{\"".contains(text) else { return false }
        let sel = selectedRange()
        let ns = nsString
        let next = sel.location < ns.length ? ns.substring(with: NSRange(location: sel.location, length: 1)) : ""
        // Type over an existing closing character.
        if sel.length == 0, Self.pairs.values.contains(text), next == text {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return true
        }
        guard mode == .immediately, let close = Self.pairs[text] else { return false }
        if sel.length > 0 {
            // Wrap the selection.
            let inner = ns.substring(with: sel)
            super.insertText(text + inner + close, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1, length: (inner as NSString).length))
            return true
        }
        // Only auto-close before whitespace or closing characters.
        let allowed = next.isEmpty || next.first!.isWhitespace || ")]}".contains(next)
        if text == "\"" || text == "$" {
            let prev = sel.location > 0 ? ns.substring(with: NSRange(location: sel.location - 1, length: 1)) : " "
            guard allowed, !(prev.first?.isLetter ?? false) else { return false }
        }
        guard allowed else { return false }
        super.insertText(text + close, replacementRange: sel)
        setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        return true
    }

    // MARK: Completion

    func requestCompletion(explicit: Bool) {
        guard document.kind == .typst, let workspace else { return }
        completionRequest += 1
        let request = completionRequest
        let path = document.url.path
        let caret = selectedRange().location
        let project = workspace.project
        workspace.coreQueue.async { [weak self] in
            let result = project.complete(path: path, offset: UInt64(caret), explicit: explicit)
            DispatchQueue.main.async {
                guard let self, request == self.completionRequest, self.selectedRange().location == caret else { return }
                guard let result, !result.items.isEmpty, let window = self.window else {
                    self.completion.hide()
                    return
                }
                let from = Int(result.from)
                guard from <= caret else { return }
                let prefix = self.nsString.substring(with: NSRange(location: from, length: caret - from))
                let caretRect = self.caretRect(at: caret) ?? .zero
                let screen = window.convertToScreen(self.convert(caretRect, to: nil))
                self.completion.show(result.items, from: from, prefix: prefix, at: screen, in: window)
            }
        }
    }

    private func applyCompletion(_ item: CompletionItem, from: Int) {
        let caret = selectedRange().location
        guard from <= caret else { return }
        let snippet = Snippet(item.apply ?? item.label)
        let range = NSRange(location: from, length: caret - from)
        insertText(snippet.text, replacementRange: range)
        placeholders = snippet.placeholders.map { NSRange(location: $0.location + from, length: $0.length) }
        if !placeholders.isEmpty {
            jumpToNextPlaceholder()
        } else {
            setSelectedRange(NSRange(location: from + (snippet.text as NSString).length, length: 0))
        }
        // Completing e.g. `#text(` may open further completions.
        if snippet.text.hasSuffix("(") || snippet.text.hasSuffix(".") {
            requestCompletion(explicit: false)
        }
    }

    private func jumpToNextPlaceholder() {
        guard !placeholders.isEmpty else { return }
        let next = placeholders.removeFirst()
        // Later placeholders shift by however much text was typed into earlier ones; keep it simple.
        setSelectedRange(next)
    }

    // MARK: Line operations

    /// The range of whole lines touched by the selection.
    var selectedLinesRange: NSRange {
        nsString.lineRange(for: selectedRange())
    }

    func replaceLines(_ transform: ([String]) -> [String]) {
        let range = selectedLinesRange
        var text = nsString.substring(with: range)
        let hadNewline = text.hasSuffix("\n")
        if hadNewline { text.removeLast() }
        let lines = text.components(separatedBy: "\n")
        var result = transform(lines).joined(separator: "\n")
        if hadNewline { result += "\n" }
        if shouldChangeText(in: range, replacementString: result) {
            textStorage?.replaceCharacters(in: range, with: result)
            didChangeText()
        }
        setSelectedRange(NSRange(location: range.location, length: (result as NSString).length - (hadNewline ? 1 : 0)))
    }

    func shiftLines(right: Bool) {
        replaceLines { lines in
            lines.map { line in
                if right { return "  " + line }
                if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
                if line.hasPrefix("\t") || line.hasPrefix(" ") { return String(line.dropFirst()) }
                return line
            }
        }
    }

    @objc func toggleComment(_ sender: Any?) {
        replaceLines { lines in
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let commented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            return lines.map { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                let rest = line.dropFirst(indent.count)
                if commented {
                    var body = rest.dropFirst(2)
                    if body.hasPrefix(" ") { body = body.dropFirst() }
                    return indent + body
                }
                return indent + "// " + rest
            }
        }
    }

    @objc func duplicateLine(_ sender: Any?) {
        let range = selectedLinesRange
        var text = nsString.substring(with: range)
        if !text.hasSuffix("\n") { text = "\n" + text }
        let insertAt = NSMaxRange(range)
        insertText(text, replacementRange: NSRange(location: insertAt, length: 0))
    }

    // MARK: Markup commands

    /// Wraps the selection (or the word at the caret) in markers.
    func wrap(_ open: String, _ close: String) {
        var sel = selectedRange()
        if sel.length == 0 {
            sel = selectionRange(forProposedRange: sel, granularity: .selectByWord)
            if sel.length > 0, nsString.substring(with: sel).trimmingCharacters(in: .alphanumerics).isEmpty == false {
                sel = selectedRange()
            }
        }
        let inner = nsString.substring(with: sel)
        // Toggle off if already wrapped.
        let o = (open as NSString).length, c = (close as NSString).length
        if sel.location >= o, NSMaxRange(sel) + c <= nsString.length,
           nsString.substring(with: NSRange(location: sel.location - o, length: o)) == open,
           nsString.substring(with: NSRange(location: NSMaxRange(sel), length: c)) == close
        {
            insertText(inner, replacementRange: NSRange(location: sel.location - o, length: sel.length + o + c))
            setSelectedRange(NSRange(location: sel.location - o, length: sel.length))
            return
        }
        insertText(open + inner + close, replacementRange: sel)
        setSelectedRange(NSRange(location: sel.location + o, length: sel.length))
    }

    @objc func makeBold(_ sender: Any?) { wrap("*", "*") }
    @objc func makeItalic(_ sender: Any?) { wrap("_", "_") }
    @objc func makeUnderline(_ sender: Any?) { wrap("#underline[", "]") }
    @objc func makeInlineMath(_ sender: Any?) { wrap("$", "$") }

    /// Cycles the heading level of the current line(s).
    @objc func makeHeading(_ sender: Any?) {
        setLinePrefix(heading: true)
    }

    func setHeading(level: Int) {
        replaceLines { lines in
            lines.map { line in
                let stripped = line.drop { $0 == "=" }.drop { $0 == " " }
                return level == 0 ? String(stripped) : String(repeating: "=", count: level) + " " + stripped
            }
        }
    }

    @objc func makeBulletList(_ sender: Any?) { toggleLinePrefix("- ") }
    @objc func makeNumberedList(_ sender: Any?) { toggleLinePrefix("+ ") }

    private func setLinePrefix(heading: Bool) {
        replaceLines { lines in
            lines.map { line in
                let level = line.prefix { $0 == "=" }.count
                let body = line.drop { $0 == "=" }.drop { $0 == " " }
                let next = level >= 6 ? 0 : level + 1
                return next == 0 ? String(body) : String(repeating: "=", count: next) + " " + body
            }
        }
    }

    private func toggleLinePrefix(_ prefix: String) {
        replaceLines { lines in
            let all = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) || $0.isEmpty }
            return lines.map { line in
                guard !line.isEmpty else { return line }
                let indent = String(line.prefix { $0 == " " })
                let rest = line.dropFirst(indent.count)
                if all { return indent + rest.dropFirst(prefix.count) }
                let stripped = rest.hasPrefix("- ") || rest.hasPrefix("+ ") ? rest.dropFirst(2) : rest
                return indent + prefix + stripped
            }
        }
    }

    // MARK: Font size

    @objc func increaseFontSize(_ sender: Any?) {
        settings.editorFontSize = min(AppSettings.maxFontSize, settings.editorFontSize + 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        settings.editorFontSize = max(AppSettings.minFontSize, settings.editorFontSize - 1)
    }

    @objc func resetFontSize(_ sender: Any?) {
        settings.editorFontSize = AppSettings.defaultFontSize
    }

    // MARK: Mouse: tooltips and go-to-definition

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        tooltipTimer?.invalidate()
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        if offset == lastMouseOffset { return }
        lastMouseOffset = offset
        tooltipPopover?.close()
        guard document.kind == .typst, !completion.isVisible else { return }
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.showTooltip(at: offset, point: point)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tooltipTimer?.invalidate()
        lastMouseOffset = nil
    }

    private func showTooltip(at offset: Int, point: CGPoint) {
        guard let workspace, offset < nsString.length else { return }
        // Only over actual text.
        guard let rect = segmentRects(NSRange(location: offset, length: 1)).first,
              rect.insetBy(dx: -2, dy: -2).contains(point)
        else { return }
        let path = document.url.path
        let project = workspace.project
        workspace.coreQueue.async { [weak self] in
            let tip = project.tooltip(path: path, offset: UInt64(offset))
            DispatchQueue.main.async {
                guard let self, let tip, self.lastMouseOffset == offset, self.window?.isKeyWindow == true else { return }
                self.presentTooltip(tip, at: rect)
            }
        }
    }

    private func presentTooltip(_ tip: TooltipInfo, at rect: CGRect) {
        let label = NSTextField(wrappingLabelWithString: tip.text)
        label.font = tip.isCode ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = 420
        label.isSelectable = true
        let controller = NSViewController()
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        controller.view = container
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = false
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        tooltipPopover = popover
    }

    override func mouseDown(with event: NSEvent) {
        tooltipPopover?.close()
        completion.hide()
        if event.modifierFlags.contains(.command), let workspace, document.kind == .typst {
            let offset = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let path = document.url.path
            let project = workspace.project
            workspace.coreQueue.async {
                let target = project.definition(path: path, offset: UInt64(offset))
                DispatchQueue.main.async {
                    guard let target else { return }
                    let url = URL(fileURLWithPath: target.path)
                    workspace.open(url)
                    workspace.editorJump = EditorJump(url: url, offset: Int(target.offset))
                }
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["inkwell"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: ["inkwell": true]))
    }

    // MARK: Menu validation

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return super.validateMenuItem(menuItem)
    }

    /// Selects a range and scrolls it into view.
    func reveal(_ range: NSRange) {
        let clamped = NSRange(location: min(range.location, nsString.length), length: min(range.length, max(0, nsString.length - range.location)))
        setSelectedRange(clamped)
        scrollRangeToVisible(clamped)
        window?.makeFirstResponder(self)
        showFindIndicator(for: clamped)
    }
}
