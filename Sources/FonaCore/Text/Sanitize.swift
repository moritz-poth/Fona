import Foundation

/// The single entry point for foreign text (titles, station names, playlist titles, radio-browser fields) – PLAN S4.
/// NFC, then only letters, marks (≤ 2 per base character), numbers, punctuation, symbols and plain spaces survive.
/// Removes control, format (bidi, zero-width, tag characters), line/paragraph separators and private-use characters.
/// Result: ≤ 200 graphemes and ≤ 800 UTF-8 bytes. Show it with `Text(verbatim:)` – never as Markdown or format string.
public enum Sanitize {
    public static let maxGraphemes = 200
    public static let maxBytes = 800

    public static func display(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        var marks = 0
        var lastWasSpace = true  // also trims leading space
        for s in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .otherPunctuation,
                 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                scalars.append(s); marks = 0; lastWasSpace = false
            case .nonspacingMark, .spacingMark, .enclosingMark:
                guard !lastWasSpace, marks < 2 else { continue }  // stops "Zalgo" floods
                scalars.append(s); marks += 1
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                if !lastWasSpace { scalars.append(" "); lastWasSpace = true }
                marks = 0
            case .control where s == "\t" || s == "\n" || s == "\r":
                if !lastWasSpace { scalars.append(" "); lastWasSpace = true }
                marks = 0
            default:
                continue  // Cc, Cf (bidi, zero-width, tags), Co, Cn, Cs
            }
        }
        var text = String(scalars)
        if text.hasSuffix(" ") { text.removeLast() }
        if text.count > maxGraphemes { text = String(text.prefix(maxGraphemes)) }
        while text.utf8.count > maxBytes { text.removeLast() }
        return text
    }
}
