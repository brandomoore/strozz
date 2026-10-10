import Foundation
import OSLog

struct ChatGIF: Hashable, Sendable {
    /// Twitch's inclusive code-point offsets become a half-open Unicode scalar range.
    let range: Range<Int>
    let name: String
    let url: URL

    static func parse(_ tag: String?, in text: String, offset: Int = 0) -> [Self] {
        guard let tag, !tag.isEmpty else { return [] }
        let scalars = Array(text.unicodeScalars)
        var attachments: [Self] = []
        var invalid = false
        for entry in tag.split(separator: ",", omittingEmptySubsequences: false) {
            let fields = entry.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[2].isEmpty else {
                invalid = true
                continue
            }
            let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
            let id = fields[1]
            guard bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]),
                  offset >= 0, first >= offset, last >= first,
                  last - offset < scalars.count, !id.isEmpty, id.utf8.count <= 128,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
                  let url = URL(string: "https://media.giphy.com/media/\(id)/200w.gif") else {
                invalid = true
                continue
            }
            let range = (first - offset)..<(last - offset + 1)
            let name = String(String.UnicodeScalarView(scalars[range]))
            // Use the small provider rendition, never the tag's arbitrary URL or tracking query.
            attachments.append(Self(range: range, name: name, url: url))
        }
        attachments.sort { $0.range.lowerBound < $1.range.lowerBound }
        var end = 0
        let result = attachments.filter { attachment in
            guard attachment.range.lowerBound >= end else {
                invalid = true
                return false
            }
            end = attachment.range.upperBound
            return true
        }
        if invalid {
            Logger(subsystem: "com.thatcube.Strozz", category: "Chat")
                .debug("Ignored malformed native GIF metadata; retaining message text")
        }
        return result
    }
}
