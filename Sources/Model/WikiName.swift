import Foundation

/// Logseq page-name <-> filename conversion.
/// Logseq (`:file/name-format :triple-lowbar`) maps `/` in page names to `___`
/// and percent-encodes other filename-hostile characters.
enum WikiName {
    private static let invalidCharacters = ":%\\?*<>|\"#[]^"

    static func fileName(for pageName: String) -> String {
        var out = ""
        for ch in pageName {
            switch ch {
            case "/":
                out += "___"
            case "%":
                out += "%25"
            default:
                let isInvalid = String(ch).rangeOfCharacter(
                    from: CharacterSet(charactersIn: invalidCharacters)) != nil
                let isOddWhitespace = ch != " " && ch.isWhitespace
                if isInvalid || isOddWhitespace {
                    let encoded = String(ch).data(using: .utf8)!
                        .map { String(format: "%%%02X", $0) }
                        .joined()
                    out += encoded
                } else {
                    out.append(ch)
                }
            }
        }
        return out + ".md"
    }

    static func pageName(for fileName: String) -> String {
        let name = (fileName as NSString).deletingPathExtension
        return name
            .replacingOccurrences(of: "___", with: "/")
            .removingPercentEncoding ?? name
    }

    /// File names that may hold the given page, most likely first.
    static func candidateFileNames(for pageName: String) -> [String] {
        [fileName(for: pageName), pageName + ".md"]
    }
}
