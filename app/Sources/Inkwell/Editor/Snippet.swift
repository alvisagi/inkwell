import Foundation

/// A completion's text with `${...}` placeholders resolved.
struct Snippet {
    var text: String
    /// Placeholder ranges in `text` (UTF-16), in order.
    var placeholders: [NSRange]

    /// Parses Typst IDE snippet syntax: `${}` and `${name}` mark tab stops.
    init(_ source: String) {
        var out = ""
        var stops: [NSRange] = []
        var chars = Array(source)
        var i = 0
        // Unescape `\$` style sequences are not used by typst-ide; keep it simple.
        while i < chars.count {
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                var j = i + 2
                var depth = 1
                var name = ""
                while j < chars.count {
                    if chars[j] == "{" { depth += 1 }
                    if chars[j] == "}" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    name.append(chars[j])
                    j += 1
                }
                let start = (out as NSString).length
                out += name
                stops.append(NSRange(location: start, length: (name as NSString).length))
                i = j + 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        chars.removeAll()
        text = out
        placeholders = stops
    }
}
