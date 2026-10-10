import Foundation

enum ChatHighlightRules {
  static func keywords(from raw: String) -> [String] {
    var seen = Set<String>()
    return raw.split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap { part in
      let word = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return !word.isEmpty && seen.insert(word).inserted ? word : nil
    }
  }

  static func matches(_ message: ChatMessage, viewerLogin: String?, viewerDisplayName: String?,
                      keywords: [String]) -> Bool {
    if let reply = message.replyParentLogin, let viewerLogin, !viewerLogin.isEmpty,
      reply == viewerLogin.lowercased() { return true }
    let text = message.text.lowercased()
    for name in [viewerLogin, viewerDisplayName] {
      if let name, !name.isEmpty, containsWord(name.lowercased(), in: text) { return true }
    }
    return keywords.contains { text.contains($0) }
  }

  private static func containsWord(_ word: String, in text: String) -> Bool {
    guard !word.isEmpty else { return false }
    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: word, range: searchRange) {
      let beforeOK = found.lowerBound == text.startIndex || {
        let previous = text[text.index(before: found.lowerBound)]
        return !(previous.isLetter || previous.isNumber || previous == "_")
      }()
      let afterOK = found.upperBound == text.endIndex || {
        let next = text[found.upperBound]
        return !(next.isLetter || next.isNumber || next == "_")
      }()
      if beforeOK && afterOK { return true }
      searchRange = found.upperBound..<text.endIndex
    }
    return false
  }
}
