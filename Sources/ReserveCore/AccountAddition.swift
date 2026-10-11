import Foundation

/// What "Add Account…" does for a provider. One rule for every kind, read from
/// its descriptor, so a new provider appears in the menu with the right
/// behaviour without any code of its own here.
public enum AccountAddition: Equatable, Sendable {
  /// The kind's default account is not connected yet, so that one is used
  /// first: a second account beside an empty first one would only confuse.
  case connectDefault
  /// A new account beside the default one, kept apart by folder or key.
  case addAccount
  /// The helper keeps one sign-in per Mac and it is already in use.
  case unavailable(reason: String)

  public static func action(for kind: ProviderKind, defaultConnected: Bool) -> Self {
    guard defaultConnected else { return .connectDefault }
    guard kind.supportsAddedAccounts else {
      let helper = ProviderDescriptor.forKind(kind).loginDisplayName
      return .unavailable(reason: "\(helper) keeps one sign-in per Mac, so Reserve can track one \(kind.displayName) account.")
    }
    return .addAccount
  }

  /// Short explanation shown under each menu entry.
  public static func summary(for kind: ProviderKind) -> String {
    let descriptor = ProviderDescriptor.forKind(kind)
    switch descriptor.accountIsolation {
    case .homeFolder:
      return "Sign in with \(descriptor.loginDisplayName) · several accounts"
    case .apiKey:
      return "Paste an API key · several accounts"
    case .single:
      return descriptor.signsInFromTerminal
        ? "Sign in with \(descriptor.loginDisplayName) in Terminal · one account"
        : "Sign in with \(descriptor.loginDisplayName) · one account"
    }
  }

  /// Subscriptions signed in with a helper, then plans read with a key, each
  /// in the fixed provider order.
  public static var subscriptionKinds: [ProviderKind] {
    ProviderKind.allCases.filter { !ProviderDescriptor.forKind($0).usesAPIKey }
  }

  public static var keyPlanKinds: [ProviderKind] {
    ProviderKind.allCases.filter { ProviderDescriptor.forKind($0).usesAPIKey }
  }
}
