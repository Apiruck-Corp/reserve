import Foundation
import Testing

@testable import ReserveCore

/// Automated checks need preferences of their own. A named suite leaves an
/// empty file in ~/Library/Preferences on every run, so checks use scratch
/// preferences that live, and die, in a temporary folder.
@Suite struct ScratchDefaultsTests {
  @Test func scratchPreferencesWorkAndLeaveNothingBehind() throws {
    let suite = ScratchDefaults.makeSuiteName("scratch-check")
    let folder = URL(fileURLWithPath: suite).deletingLastPathComponent()
    let preferences = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences", isDirectory: true)

    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(7, forKey: "value")
    // A second handle on the same suite sees the value, as a relaunch would.
    #expect(UserDefaults(suiteName: suite)?.integer(forKey: "value") == 7)

    ScratchDefaults.remove(suite)
    CFPreferencesAppSynchronize(suite as CFString)

    #expect(UserDefaults(suiteName: suite)?.object(forKey: "value") == nil)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: preferences.path)
      .filter { $0.contains(folder.lastPathComponent) }
    #expect(leftovers.isEmpty)
  }

  @Test func removeNeverDeletesAFolderItDidNotMake() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("not-scratch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    ScratchDefaults.remove(folder.appendingPathComponent("defaults").path)

    #expect(FileManager.default.fileExists(atPath: folder.path))
  }
}
