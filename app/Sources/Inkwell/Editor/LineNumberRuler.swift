import AppKit

/// Line numbers next to the editor, for TextKit 2.
final class LineNumberRuler: NSRulerView {
    weak var editor: EditorTextView?
    /// UTF-16 offsets where each line starts.
    private var lineStarts: [Int] = [0]

    init(editor: EditorTextView, scrollView: NSScrollView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 40
        NotificationCenter.default.addObserver(
            self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: editor)
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        recomputeLines()
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func textChanged() {
        recomputeLines()
        needsDisplay = true
    }

    @objc private func boundsChanged() {
        needsDisplay = true
    }

    func recomputeLines() {
        guard let editor else { return }
        let ns = editor.nsString
        var starts = [0]
        starts.reserveCapacity(starts.count)
        let length = ns.length
        var i = 0
        // Scan for newlines in chunks for speed.
        let chunk = 4096
        var buffer = [unichar](repeating: 0, count: chunk)
        while i < length {
            let n = min(chunk, length - i)
            ns.getCharacters(&buffer, range: NSRange(location: i, length: n))
            for j in 0..<n where buffer[j] == 10 {
                starts.append(i + j + 1)
            }
            i += n
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        let width = CGFloat(digits) * (editor.highlighter?.font.pointSize ?? 13) * 0.62 + 18
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
    }

    /// 0-based line index for a character offset.
    func line(at offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor, let layout = editor.textLayoutManager, let storage = editor.textContentStorage else { return }
        let theme = editor.theme
        theme.background.setFill()
        bounds.fill()

        let settings = AppSettings.shared
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(9, (editor.highlighter?.font.pointSize ?? 13) - 1), weight: .regular)
        let caretLine = line(at: editor.selectedRange().location)
        let visible = editor.visibleRect
        let origin = editor.textContainerOrigin
        let relative = settings.relativeLineNumbers && settings.vimMode

        // Start at the first fragment in view.
        let startPoint = CGPoint(x: 0, y: visible.minY - origin.y)
        let startLocation = layout.textLayoutFragment(for: startPoint)?.rangeInElement.location ?? storage.documentRange.location
        var lastLine = -1

        layout.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + origin.y > visible.maxY { return false }
            let offset = editor.offset(of: fragment.rangeInElement.location)
            let lineIndex = self.line(at: offset)
            if lineIndex != lastLine {
                lastLine = lineIndex
                let firstLine = fragment.textLineFragments.first
                let lineHeight = firstLine?.typographicBounds.height ?? frame.height
                let y = frame.minY + origin.y + (firstLine?.typographicBounds.minY ?? 0)
                let viewY = self.convert(NSPoint(x: 0, y: y), from: editor).y
                let number: Int
                if relative, lineIndex != caretLine {
                    number = abs(lineIndex - caretLine)
                } else {
                    number = lineIndex + 1
                }
                let isCurrent = lineIndex == caretLine
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: isCurrent ? NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .semibold) : font,
                    .foregroundColor: isCurrent ? theme.foreground : theme.gutter,
                ]
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                if isCurrent, editor.selectedRange().length == 0 {
                    theme.currentLine.setFill()
                    NSRect(x: 0, y: viewY, width: self.bounds.width, height: lineHeight).fill()
                }
                label.draw(
                    at: NSPoint(x: self.ruleThickness - size.width - 8, y: viewY + (lineHeight - size.height) / 2),
                    withAttributes: attributes)
            }
            return true
        }
        // The empty last line after a trailing newline.
        if editor.nsString.length == 0 || editor.nsString.hasSuffix("\n"), let rect = editor.caretRect(at: editor.nsString.length) {
            let lineIndex = lineStarts.count - 1
            if lineIndex != lastLine {
                let viewY = convert(NSPoint(x: 0, y: rect.minY), from: editor).y
                let isCurrent = lineIndex == caretLine
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: isCurrent ? theme.foreground : theme.gutter,
                ]
                let number = relative && !isCurrent ? abs(lineIndex - caretLine) : lineIndex + 1
                let label = "\(number)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: viewY + (rect.height - size.height) / 2), withAttributes: attributes)
            }
        }
    }
}
