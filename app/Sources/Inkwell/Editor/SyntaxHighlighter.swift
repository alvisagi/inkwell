import AppKit
import TypstCore

/// A highlighted span in UTF-16 units.
struct HighlightSpan: Equatable {
    var location: Int
    var length: Int
    var tag: UInt8

    var range: NSRange { NSRange(location: location, length: length) }

    static let comment: UInt8 = 1, punctuation: UInt8 = 2, escape: UInt8 = 3, strong: UInt8 = 4
    static let emph: UInt8 = 5, link: UInt8 = 6, raw: UInt8 = 7, label: UInt8 = 8, ref: UInt8 = 9
    static let heading: UInt8 = 10, listMarker: UInt8 = 11, listTerm: UInt8 = 12
    static let mathDelimiter: UInt8 = 13, mathOperator: UInt8 = 14, keyword: UInt8 = 15
    static let op: UInt8 = 16, number: UInt8 = 17, string: UInt8 = 18, function: UInt8 = 19
    static let interpolated: UInt8 = 20, error: UInt8 = 21
    static let inCode: UInt8 = 0x20, inStrong: UInt8 = 0x40, inEmph: UInt8 = 0x80

    var base: UInt8 { tag & 0x1F }

    /// Whether the span is prose (as opposed to code), for spell checking.
    var isProse: Bool {
        tag & Self.inCode == 0 && [0, Self.strong, Self.emph, Self.heading, Self.listTerm].contains(base)
    }
}

/// Applies Typst syntax highlighting to a document's text storage.
final class SyntaxHighlighter {
    private static let queue = DispatchQueue(label: "inkwell.highlight", qos: .userInitiated)
    private weak var storage: NSTextStorage?
    private var generation = 0
    private(set) var spans: [HighlightSpan] = []
    var theme: EditorTheme
    var font: NSFont
    let isTypst: Bool

    init(storage: NSTextStorage, theme: EditorTheme, font: NSFont, isTypst: Bool) {
        self.storage = storage
        self.theme = theme
        self.font = font
        self.isTypst = isTypst
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: theme.foreground]
    }

    /// Re-highlights asynchronously; applies only if the text didn't change.
    func update() {
        guard let storage else { return }
        generation += 1
        let gen = generation
        let text = storage.string
        guard isTypst else {
            apply([], textLength: (text as NSString).length)
            return
        }
        Self.queue.async { [weak self] in
            let data = TypstCore.highlight(text: text)
            let spans = Self.decode(data)
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.apply(spans, textLength: (text as NSString).length)
            }
        }
    }

    /// Highlights synchronously (used when a document is first shown).
    func updateNow() {
        guard let storage else { return }
        let text = storage.string
        let spans = isTypst ? Self.decode(TypstCore.highlight(text: text)) : []
        apply(spans, textLength: (text as NSString).length)
    }

    private static func decode(_ data: Data) -> [HighlightSpan] {
        var spans: [HighlightSpan] = []
        spans.reserveCapacity(data.count / 9)
        var r = ByteReader(data)
        while r.offset + 9 <= data.count {
            spans.append(HighlightSpan(location: Int(r.u32()), length: Int(r.u32()), tag: r.u8()))
        }
        return spans
    }

    private var appliedLength = -1
    private var appliedStyle: (EditorTheme, NSFont)?

    /// Applies spans, touching only the region that changed since last time.
    private func apply(_ spans: [HighlightSpan], textLength: Int) {
        guard let storage, storage.length == textLength else { return }
        let old = self.spans
        self.spans = spans
        var region = NSRange(location: 0, length: textLength)
        let styleChanged = appliedStyle.map { $0.0 != theme || $0.1 != font } ?? true
        if !styleChanged, appliedLength >= 0 {
            let delta = textLength - appliedLength
            var i = 0
            while i < old.count, i < spans.count, old[i] == spans[i] { i += 1 }
            var j = 0
            while j < old.count - i, j < spans.count - i {
                let a = old[old.count - 1 - j], b = spans[spans.count - 1 - j]
                guard a.location + delta == b.location, a.length == b.length, a.tag == b.tag else { break }
                j += 1
            }
            if i == spans.count, j == 0, i == old.count, delta == 0 { return }
            // The changed span window, widened to whole lines.
            let lo = i < spans.count ? spans[i].location : (i < old.count ? min(old[i].location, textLength) : textLength)
            var hi = spans.count - j - 1 >= i ? NSMaxRange(spans[spans.count - j - 1].range) : lo
            if old.count - j - 1 >= i {
                hi = max(hi, min(textLength, NSMaxRange(old[old.count - j - 1].range) + delta))
            }
            let ns = storage.string as NSString
            let start = ns.lineRange(for: NSRange(location: min(lo, textLength), length: 0)).location
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: min(max(hi, lo), textLength), length: 0)))
            region = NSRange(location: start, length: max(0, end - start))
        }
        appliedLength = textLength
        appliedStyle = (theme, font)

        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: region)
        for span in spans {
            guard NSMaxRange(span.range) <= storage.length else { continue }
            let clipped = NSIntersectionRange(span.range, region)
            guard clipped.length > 0 else { continue }
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = color(for: span.base) {
                attributes[.foregroundColor] = color
            }
            let isBold = span.tag & HighlightSpan.inStrong != 0 || span.base == HighlightSpan.strong
                || span.base == HighlightSpan.heading || span.base == HighlightSpan.listTerm
            let isItalic = span.tag & HighlightSpan.inEmph != 0 || span.base == HighlightSpan.emph
            if isBold && isItalic {
                attributes[.font] = boldItalic
            } else if isBold {
                attributes[.font] = bold
            } else if isItalic {
                attributes[.font] = italic
            }
            if span.base == HighlightSpan.link {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if span.base == HighlightSpan.error {
                attributes[.underlineStyle] = NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue
                attributes[.underlineColor] = theme.error
            }
            if !attributes.isEmpty {
                storage.addAttributes(attributes, range: clipped)
            }
        }
        storage.endEditing()
    }

    func color(for tag: UInt8) -> NSColor? {
        switch tag {
        case HighlightSpan.comment: theme.comment
        case HighlightSpan.punctuation: theme.foreground.withAlphaComponent(0.75)
        case HighlightSpan.escape: theme.escape
        case HighlightSpan.link: theme.link
        case HighlightSpan.raw: theme.raw
        case HighlightSpan.label, HighlightSpan.ref: theme.label
        case HighlightSpan.heading: theme.heading
        case HighlightSpan.listMarker: theme.markup
        case HighlightSpan.mathDelimiter, HighlightSpan.mathOperator: theme.math
        case HighlightSpan.keyword: theme.keyword
        case HighlightSpan.op: theme.keyword.blended(withFraction: 0.35, of: theme.foreground)
        case HighlightSpan.number: theme.number
        case HighlightSpan.string: theme.string
        case HighlightSpan.function: theme.function
        case HighlightSpan.interpolated: theme.foreground
        case HighlightSpan.error: theme.error
        default: nil
        }
    }

    /// Whether a character offset lies in prose (spell-checkable) text.
    func isProse(at offset: Int) -> Bool {
        // Binary search the last span starting at or before offset.
        var lo = 0, hi = spans.count - 1, hit: HighlightSpan?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].location <= offset {
                if NSLocationInRange(offset, spans[mid].range) { hit = spans[mid] }
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return hit?.isProse ?? true
    }
}
