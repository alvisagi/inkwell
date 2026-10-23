import AppKit

/// Colors for the editor and syntax highlighting.
struct EditorTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor
    let gutter: NSColor
    let currentLine: NSColor
    let selection: NSColor
    let caret: NSColor
    // Syntax
    let comment: NSColor
    let keyword: NSColor
    let function: NSColor
    let string: NSColor
    let number: NSColor
    let heading: NSColor
    let math: NSColor
    let markup: NSColor  // list markers, strong/emph accents
    let label: NSColor
    let raw: NSColor
    let link: NSColor
    let escape: NSColor
    let error: NSColor

    /// The five swatches shown on the theme card.
    var swatches: [NSColor] { [keyword, string, function, number, comment] }

    static func == (a: EditorTheme, b: EditorTheme) -> Bool { a.id == b.id }
}

private func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: alpha)
}

extension EditorTheme {
    static let xcodeDefault = EditorTheme(
        id: "xcode", name: "Xcode Default", isDark: true,
        background: hex(0x1F1F24), foreground: hex(0xDFDFE0), gutter: hex(0x747478),
        currentLine: hex(0x23252B), selection: hex(0x515B70), caret: hex(0xFFFFFF),
        comment: hex(0x7F8C98), keyword: hex(0xFF7AB2), function: hex(0x67B7A4),
        string: hex(0xFF8170), number: hex(0xD9C97C), heading: hex(0xDABAFF),
        math: hex(0x78C2B3), markup: hex(0xFFA14F), label: hex(0xACF2E4),
        raw: hex(0xFF8170), link: hex(0x6699FF), escape: hex(0xD0BF69), error: hex(0xFF4D4D))

    static let catppuccinMocha = EditorTheme(
        id: "mocha", name: "Catppuccin Mocha", isDark: true,
        background: hex(0x1E1E2E), foreground: hex(0xCDD6F4), gutter: hex(0x6C7086),
        currentLine: hex(0x2A2B3C), selection: hex(0x45475A), caret: hex(0xF5E0DC),
        comment: hex(0x7F849C), keyword: hex(0xCBA6F7), function: hex(0x89B4FA),
        string: hex(0xA6E3A1), number: hex(0xFAB387), heading: hex(0xF38BA8),
        math: hex(0x94E2D5), markup: hex(0xF9E2AF), label: hex(0x74C7EC),
        raw: hex(0xA6E3A1), link: hex(0x89DCEB), escape: hex(0xF5C2E7), error: hex(0xF38BA8))

    static let typstDefault = EditorTheme(
        id: "typst", name: "Typst Default", isDark: true,
        background: hex(0x1E1E1E), foreground: hex(0xE6E6E6), gutter: hex(0x6E6E73),
        currentLine: hex(0x2A2D35), selection: hex(0x3A4A66), caret: hex(0x4C8DFF),
        comment: hex(0x8A8A8A), keyword: hex(0xE2556B), function: hex(0x4B9FE1),
        string: hex(0x7CC77B), number: hex(0xE3A54E), heading: hex(0xE6E6E6),
        math: hex(0x5FC5C9), markup: hex(0xB28AE8), label: hex(0x59B2A1),
        raw: hex(0x9CCC8A), link: hex(0x6FA8F5), escape: hex(0x5FC5C9), error: hex(0xFF5F5F))

    static let atomOne = EditorTheme(
        id: "atom", name: "Atom One", isDark: true,
        background: hex(0x282C34), foreground: hex(0xABB2BF), gutter: hex(0x636D83),
        currentLine: hex(0x2C313C), selection: hex(0x3E4451), caret: hex(0x528BFF),
        comment: hex(0x5C6370), keyword: hex(0xC678DD), function: hex(0x61AFEF),
        string: hex(0x98C379), number: hex(0xD19A66), heading: hex(0xE06C75),
        math: hex(0x56B6C2), markup: hex(0xE5C07B), label: hex(0x56B6C2),
        raw: hex(0x98C379), link: hex(0x61AFEF), escape: hex(0x56B6C2), error: hex(0xE06C75))

    static let catppuccinLatte = EditorTheme(
        id: "latte", name: "Catppuccin Latte", isDark: false,
        background: hex(0xEFF1F5), foreground: hex(0x4C4F69), gutter: hex(0x9CA0B0),
        currentLine: hex(0xE6E9EF), selection: hex(0xBCC0CC), caret: hex(0xDC8A78),
        comment: hex(0x8C8FA1), keyword: hex(0x8839EF), function: hex(0x1E66F5),
        string: hex(0x40A02B), number: hex(0xFE640B), heading: hex(0xD20F39),
        math: hex(0x179299), markup: hex(0xDF8E1D), label: hex(0x209FB5),
        raw: hex(0x40A02B), link: hex(0x04A5E5), escape: hex(0xEA76CB), error: hex(0xD20F39))

    static let gruvbox = EditorTheme(
        id: "gruvbox", name: "Gruvbox", isDark: true,
        background: hex(0x282828), foreground: hex(0xEBDBB2), gutter: hex(0x7C6F64),
        currentLine: hex(0x32302F), selection: hex(0x504945), caret: hex(0xFE8019),
        comment: hex(0x928374), keyword: hex(0xFB4934), function: hex(0xB8BB26),
        string: hex(0xB8BB26), number: hex(0xD3869B), heading: hex(0xFABD2F),
        math: hex(0x8EC07C), markup: hex(0xFE8019), label: hex(0x83A598),
        raw: hex(0xB8BB26), link: hex(0x83A598), escape: hex(0xFE8019), error: hex(0xFB4934))

    static let nord = EditorTheme(
        id: "nord", name: "Nord", isDark: true,
        background: hex(0x2E3440), foreground: hex(0xD8DEE9), gutter: hex(0x616E88),
        currentLine: hex(0x353C4A), selection: hex(0x434C5E), caret: hex(0x88C0D0),
        comment: hex(0x616E88), keyword: hex(0x81A1C1), function: hex(0x88C0D0),
        string: hex(0xA3BE8C), number: hex(0xB48EAD), heading: hex(0x8FBCBB),
        math: hex(0x8FBCBB), markup: hex(0xEBCB8B), label: hex(0x8FBCBB),
        raw: hex(0xA3BE8C), link: hex(0x5E81AC), escape: hex(0xEBCB8B), error: hex(0xBF616A))

    static let all: [EditorTheme] = [
        .xcodeDefault, .catppuccinMocha, .typstDefault, .atomOne, .catppuccinLatte, .gruvbox, .nord,
    ]
}
