import Foundation
import TypstCore

/// Recognizes hand-drawn symbols with the Detypify model in the core.
final class SymbolRecognizer {
    static let shared = SymbolRecognizer()

    /// Strokes are lists of [x, y] points. Returns `sym` names, best first.
    func recognize(strokes: [[[Float]]]) -> [String] {
        let flat = strokes.filter { !$0.isEmpty }.map { $0.flatMap { $0 } }
        guard !flat.isEmpty else { return [] }
        return recognizeSymbol(strokes: flat, limit: 24)
    }
}
