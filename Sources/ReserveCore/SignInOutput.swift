import Foundation

public enum SignInOutput {
  /// The last line a sign-in helper printed before exiting with an error,
  /// without terminal colours, prompts or links (a sign-in link carries its
  /// one-time state and says nothing about the failure).
  public static func failureReason(in output: String) -> String? {
    let escape = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    let plain = escape.map {
      $0.stringByReplacingMatches(
        in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
    } ?? output
    let line = plain.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { line in
        !line.isEmpty && !line.localizedCaseInsensitiveContains("http")
          && !line.hasPrefix("Paste code") && !line.hasPrefix("Opening browser")
      }
    guard let line else { return nil }
    return line.count > 200 ? String(line.prefix(199)) + "…" : line
  }
}
