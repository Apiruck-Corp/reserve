import Foundation

/// Finds the browser sign-in link in `cursor-agent login` output.
///
/// Cursor's link (`https://cursor.com/loginDeepControl?challenge=…&uuid=…&mode=login&redirectTarget=cli…`)
/// is long enough that the CLI's terminal renderer wraps it across lines when
/// its output goes to a pipe, and a pipe read can also stop partway through it.
/// Opening the first fragment sends the browser to Cursor's "This sign-in link
/// is incomplete or has expired" page, so a link is returned only once it is
/// whole: wrapped lines are joined, a link that reaches the end of the output
/// so far waits for the next read, and the PKCE challenge and session UUID it
/// carries must both be complete.
public enum CursorLoginLink {
  static let loginPath = "/loginDeepControl"

  /// Characters a URL may contain without percent-encoding (RFC 3986).
  private static let urlPunctuation = Set("-._~:/?#[]@!$&'()*+,;=%")
  /// Padding a renderer can draw around a wrapped line: spaces and box edges.
  private static let framing = CharacterSet.whitespaces.union(
    CharacterSet(charactersIn: "│┃|╎╏┆┇┊┋"))

  /// The complete, trusted sign-in link, or nil while none has been printed
  /// in full yet.
  public static func url(in output: String, trustedHosts: Set<String>) -> URL? {
    let text = CursorProvider.strippingTerminalCodes(output)
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (index, line) in lines.enumerated() {
      for start in Self.linkStarts(in: line) {
        guard let candidate = Self.joinedLink(from: start, lineIndex: index, lines: lines),
          let url = Self.validated(candidate, trustedHosts: trustedHosts)
        else { continue }
        return url
      }
    }
    return nil
  }

  static func isURLCharacter(_ character: Character) -> Bool {
    character.isASCII
      && (character.isLetter || character.isNumber || Self.urlPunctuation.contains(character))
  }

  /// Where a link begins: at `https://`, or at a bare `cursor.com/` host that
  /// some Cursor builds print without a scheme.
  private static func linkStarts(in line: Substring) -> [Substring.Index] {
    var starts: [Substring.Index] = []
    var searchStart = line.startIndex
    while let range = line.range(of: "https://", options: .caseInsensitive, range: searchStart..<line.endIndex) {
      starts.append(range.lowerBound)
      searchStart = range.upperBound
    }
    searchStart = line.startIndex
    while let range = line.range(of: "cursor.com/", options: .caseInsensitive, range: searchStart..<line.endIndex) {
      var lowerBound = range.lowerBound
      // Include a subdomain such as `www.` that is part of the same host.
      while lowerBound > line.startIndex {
        let previous = line.index(before: lowerBound)
        guard line[previous].isLetter || line[previous].isNumber || line[previous] == "."
          || line[previous] == "-"
        else { break }
        lowerBound = previous
      }
      let precededByScheme = lowerBound > line.startIndex
        && line[line.index(before: lowerBound)] == "/"
      if !precededByScheme { starts.append(lowerBound) }
      searchStart = range.upperBound
    }
    return starts.sorted()
  }

  /// The link text starting at `start`, with any wrapped continuation lines
  /// appended. Nil while the link may still be arriving.
  private static func joinedLink(
    from start: Substring.Index, lineIndex: Int, lines: [Substring]
  ) -> String? {
    let line = lines[lineIndex]
    let run = line[start...].prefix(while: Self.isURLCharacter)
    var candidate = String(run)
    let rest = line[run.endIndex...].trimmingCharacters(in: Self.framing)
    guard rest.isEmpty else { return candidate }

    // The link runs to the end of its line. The last element of `lines` has
    // no line break after it yet, so more of the link may still be coming.
    guard lineIndex < lines.count - 1 else { return nil }
    var next = lineIndex + 1
    while next < lines.count {
      let piece = lines[next].trimmingCharacters(in: Self.framing)
      // A wrapped piece of the link is all URL characters; prose has spaces.
      guard !piece.isEmpty, piece.allSatisfy(Self.isURLCharacter) else { break }
      guard next < lines.count - 1 else { return nil }
      candidate += piece
      next += 1
    }
    return candidate
  }

  private static func validated(_ candidate: String, trustedHosts: Set<String>) -> URL? {
    var text = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "'(),.;"))
    if !text.lowercased().hasPrefix("https://") { text = "https://" + text }
    guard let components = URLComponents(string: text),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(), trustedHosts.contains(host),
      components.path == Self.loginPath,
      let items = components.queryItems
    else { return nil }
    func value(_ name: String) -> String? {
      let matches = items.filter { $0.name == name }
      guard matches.count == 1, let value = matches[0].value, !value.isEmpty else { return nil }
      return value
    }
    // A PKCE S256 challenge is 43 base64url characters (RFC 7636); a cut-off
    // one is shorter. The session UUID must parse in full.
    guard let challenge = value("challenge"), challenge.count >= 43,
      challenge.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
      let uuid = value("uuid"), UUID(uuidString: uuid) != nil
    else { return nil }
    return components.url
  }
}
