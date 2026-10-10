import AppKit
import ReserveCore

/// The folder chooser for an added account whose helper keeps one sign-in per
/// folder, shared by Settings and the Connect window. Hidden folders are shown
/// because helper homes are dot-folders by convention, and a folder may be
/// created on the spot: the helper fills it in at the first sign-in.
@MainActor
enum AccountFolderPicker {
  static func choose(
    for provider: ProviderID,
    current: AccountFolder?,
    from window: NSWindow?,
    completion: @escaping @MainActor (URL?) -> Void
  ) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = "Choose"
    panel.message = "Choose the \(AccountFolderCopy.helperName(provider)) folder for this account, such as \(AccountFolderCopy.example(provider))."
    panel.directoryURL = current?.url ?? FileManager.default.homeDirectoryForCurrentUser
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      completion(response == .OK ? panel.url : nil)
    }
    if let window, window.isVisible {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      finish(panel.runModal())
    }
  }
}

/// One wording for every folder-based account, so Claude, Codex and Grok read
/// the same way.
enum AccountFolderCopy {
  static func helperName(_ provider: ProviderID) -> String {
    ProviderDescriptor.forProvider(provider).loginDisplayName
  }

  static func example(_ provider: ProviderID) -> String {
    guard case .homeFolder(_, let name, _) = ProviderDescriptor.forProvider(provider).accountIsolation
    else { return "~/.account-team" }
    return "~/\(name)-team"
  }

  static func variable(_ provider: ProviderID) -> String {
    ProviderDescriptor.forProvider(provider).homeFolderEnvironmentKey ?? "its home folder"
  }
}
