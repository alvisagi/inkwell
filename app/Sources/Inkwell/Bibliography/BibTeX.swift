import Foundation

/// A BibTeX entry with its location in the source.
struct BibEntry: Identifiable, Equatable {
    var type: String
    var key: String
    var fields: [(name: String, value: String)]
    /// UTF-16 range of the whole entry in the file.
    var range: NSRange

    var id: String { "\(range.location)-\(key)" }

    func field(_ name: String) -> String? {
        fields.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    var title: String { field("title").map(BibTeX.clean) ?? key }
    var authors: String { field("author").map(BibTeX.clean) ?? field("editor").map(BibTeX.clean) ?? "" }
    var year: String { field("year") ?? field("date").map { String($0.prefix(4)) } ?? "" }

    static func == (a: BibEntry, b: BibEntry) -> Bool {
        a.type == b.type && a.key == b.key && a.range == b.range
            && a.fields.map(\.name) == b.fields.map(\.name) && a.fields.map(\.value) == b.fields.map(\.value)
    }

    /// Serializes the entry in a conventional layout.
    var source: String {
        var out = "@\(type){\(key)"
        for (name, value) in fields {
            out += ",\n  \(name) = {\(value)}"
        }
        out += "\n}"
        return out
    }
}

enum BibTeX {
    static let entryTypes = [
        "article", "book", "booklet", "inbook", "incollection", "inproceedings", "manual",
        "mastersthesis", "misc", "online", "phdthesis", "proceedings", "techreport", "unpublished",
    ]

    static let commonFields = [
        "author", "title", "journal", "booktitle", "year", "month", "volume", "number", "pages",
        "publisher", "address", "edition", "editor", "series", "doi", "url", "isbn", "issn", "note", "abstract",
    ]

    /// Removes braces and collapses whitespace for display.
    static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Parses entries; tolerant of malformed input.
    static func parse(_ text: String) -> [BibEntry] {
        let chars = Array(text.utf16)
        var entries: [BibEntry] = []
        var i = 0
        let n = chars.count
        func skipSpace() { while i < n, [32, 9, 10, 13].contains(chars[i]) { i += 1 } }
        func string(_ from: Int, _ to: Int) -> String { String(utf16CodeUnits: Array(chars[from..<to]), count: to - from) }

        while i < n {
            guard chars[i] == 64 else { i += 1; continue }  // '@'
            let start = i
            i += 1
            let typeStart = i
            while i < n, chars[i] != 123, chars[i] != 40, ![32, 10, 9].contains(chars[i]) { i += 1 }
            let type = string(typeStart, i).lowercased()
            skipSpace()
            guard i < n, chars[i] == 123 || chars[i] == 40 else { continue }
            let close: UInt16 = chars[i] == 123 ? 125 : 41
            i += 1
            if ["comment", "preamble", "string"].contains(type) {
                var depth = 1
                while i < n, depth > 0 {
                    if chars[i] == 123 || chars[i] == 40 { depth += 1 }
                    if chars[i] == 125 || chars[i] == 41 { depth -= 1 }
                    i += 1
                }
                continue
            }
            skipSpace()
            let keyStart = i
            while i < n, chars[i] != 44, chars[i] != close { i += 1 }
            let key = string(keyStart, i).trimmingCharacters(in: .whitespacesAndNewlines)
            var fields: [(String, String)] = []
            while i < n, chars[i] != close {
                if chars[i] == 44 { i += 1 }
                skipSpace()
                if i < n, chars[i] == close { break }
                let nameStart = i
                while i < n, chars[i] != 61, chars[i] != 44, chars[i] != close { i += 1 }
                let name = string(nameStart, i).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard i < n, chars[i] == 61 else { continue }
                i += 1
                skipSpace()
                var value = ""
                // A value is a concatenation of braced/quoted parts and bare words.
                while i < n {
                    if chars[i] == 123 {
                        var depth = 1
                        let s = i + 1
                        i += 1
                        while i < n, depth > 0 {
                            if chars[i] == 123 { depth += 1 }
                            if chars[i] == 125 { depth -= 1 }
                            i += 1
                        }
                        value += string(s, max(s, i - 1))
                    } else if chars[i] == 34 {
                        let s = i + 1
                        i += 1
                        var depth = 0
                        while i < n, !(chars[i] == 34 && depth == 0) {
                            if chars[i] == 123 { depth += 1 }
                            if chars[i] == 125 { depth -= 1 }
                            i += 1
                        }
                        value += string(s, i)
                        i += 1
                    } else {
                        let s = i
                        while i < n, chars[i] != 44, chars[i] != close, chars[i] != 35, ![32, 10, 9, 13].contains(chars[i]) { i += 1 }
                        value += string(s, i)
                    }
                    skipSpace()
                    if i < n, chars[i] == 35 {  // '#' concatenation
                        i += 1
                        skipSpace()
                        continue
                    }
                    break
                }
                if !name.isEmpty { fields.append((name, value)) }
            }
            if i < n { i += 1 }
            entries.append(BibEntry(type: type, key: key, fields: fields, range: NSRange(location: start, length: i - start)))
        }
        return entries
    }
}
