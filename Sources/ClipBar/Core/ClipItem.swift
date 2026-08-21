import AppKit
import UniformTypeIdentifiers

enum ClipKind: String {
    case text, code, link, image, file, color, rtf
}

struct ClipItem: Identifiable {
    var id: Int64?
    var kind: ClipKind
    var title: String?
    /// Plain-text rendering: what the card shows and what search matches on.
    var preview: String
    var fingerprint: String
    /// Relative path inside the blob store, for images and files.
    var blobPath: String?
    var byteSize: Int
    var charCount: Int
    var sourceBundleID: String?
    var sourceName: String?
    var createdAt: Date
    var lastUsedAt: Date?
    var pinboardID: Int64?
    /// True when the user named this with ⌘R, as opposed to the title we derive
    /// at capture. The card shows a type label unless the name is really theirs.
    var titleIsCustom: Bool = false
    /// Optional metadata fetched for links. These fields are separate from the
    /// user's title so a web page can never overwrite a name they chose.
    var linkTitle: String? = nil
    var linkImagePath: String? = nil
    var linkDomain: String? = nil
}

extension ClipKind {
    /// Cheap heuristics — good enough to colour a card and filter a search.
    static func infer(fromText text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.count < 2048, !trimmed.contains(where: \.isWhitespace),
           let url = URL(string: trimmed), let scheme = url.scheme,
           ["http", "https", "ftp", "mailto"].contains(scheme.lowercased()) {
            return .link
        }

        if isColor(trimmed) { return .color }
        if looksLikeCode(trimmed) { return .code }
        return .text
    }

    private static func isColor(_ text: String) -> Bool {
        if text.hasPrefix("#"), text.count == 4 || text.count == 7 || text.count == 9 {
            return text.dropFirst().allSatisfy(\.isHexDigit)
        }
        let lower = text.lowercased()
        return lower.hasPrefix("rgb(") || lower.hasPrefix("rgba(") || lower.hasPrefix("hsl(")
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        guard text.contains("\n") else {
            // A single line still reads as code if it's clearly a statement.
            return text.contains(";") && text.contains("(")
        }
        let markers = ["{", "}", "();", "=>", "func ", "def ", "class ", "import ",
                       "const ", "let ", "var ", "return ", "</", "/>", "#include"]
        let hits = markers.filter { text.contains($0) }.count
        let indented = text.split(separator: "\n")
            .filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        return hits >= 2 || indented >= 2
    }
}
