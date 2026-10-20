import Foundation

/// One API account: a provider, and for an added account an instance name.
/// The provider's first account has no instance and keeps the provider's raw
/// value, so its Keychain item (`api-consumption.<provider>`) and settings
/// written before API accounts existed still name the same thing. Added
/// accounts are `provider@instance`, and their keys follow from that.
public struct APIAccountID: Hashable, Codable, Sendable, Identifiable, RawRepresentable, Comparable,
  CustomStringConvertible
{
  public let provider: APIConsumptionProvider
  public let instance: String?

  public init(provider: APIConsumptionProvider) {
    self.provider = provider
    self.instance = nil
  }

  /// Nil for an instance that is empty, too long, or not plain ASCII letters,
  /// digits and dashes: it ends up in defaults keys and Keychain names.
  public init?(provider: APIConsumptionProvider, instance: String) {
    guard !instance.isEmpty, instance.count <= ProviderID.maximumInstanceCharacters,
      instance.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else { return nil }
    self.provider = provider
    self.instance = instance
  }

  public init?(rawValue: String) {
    guard let separator = rawValue.firstIndex(of: ProviderID.instanceSeparator) else {
      guard let provider = APIConsumptionProvider(rawValue: rawValue) else { return nil }
      self.init(provider: provider)
      return
    }
    guard let provider = APIConsumptionProvider(rawValue: String(rawValue[..<separator])) else { return nil }
    self.init(provider: provider, instance: String(rawValue[rawValue.index(after: separator)...]))
  }

  public var rawValue: String {
    self.instance.map { "\(self.provider.rawValue)\(ProviderID.instanceSeparator)\($0)" }
      ?? self.provider.rawValue
  }

  public var id: String { self.rawValue }
  public var description: String { self.rawValue }
  public var isDefault: Bool { self.instance == nil }
  public var isAdded: Bool { self.instance != nil }

  public static let openAI = APIAccountID(provider: .openAI)
  public static let anthropic = APIAccountID(provider: .anthropic)
  public static let openRouter = APIAccountID(provider: .openRouter)
  public static let xAI = APIAccountID(provider: .xAI)
  public static let deepSeek = APIAccountID(provider: .deepSeek)
  public static let moonshot = APIAccountID(provider: .moonshot)

  /// Provider order first; within a provider the first account, then added
  /// accounts by name.
  public static func < (lhs: APIAccountID, rhs: APIAccountID) -> Bool {
    let order = APIConsumptionProvider.allCases
    let left = order.firstIndex(of: lhs.provider) ?? 0
    let right = order.firstIndex(of: rhs.provider) ?? 0
    if left != right { return left < right }
    switch (lhs.instance, rhs.instance) {
    case (nil, nil): return false
    case (nil, _): return true
    case (_, nil): return false
    case (let l?, let r?): return l < r
    }
  }

  /// The provider's name, with the account's label when it has one
  /// ("Anthropic · Nimbus"). An added account always carries a label, the
  /// neutral "Account 2" until the person names it.
  public var displayName: String {
    let label = APIAccountLabels.label(for: self)
    guard let label else {
      return self.isAdded ? "\(self.provider.displayName) · added account" : self.provider.displayName
    }
    return "\(self.provider.displayName) · \(label)"
  }

  public var keyKind: String { self.provider.keyKind }
  public var keyHint: String { self.provider.keyHint }
  public var keySettingsURL: URL { self.provider.keySettingsURL }
}

/// Labels of API accounts, kept here so `APIAccountID.displayName` can name
/// an account anywhere. Every label is either typed by the person or the
/// neutral "Account N", so none of them is personal information.
public enum APIAccountLabels {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var labels: [String: String] = [:]

  public static func label(for account: APIAccountID) -> String? {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.labels[account.rawValue]
  }

  public static func set(_ label: String?, for account: APIAccountID) {
    self.lock.lock()
    defer { self.lock.unlock() }
    let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let trimmed, !trimmed.isEmpty {
      self.labels[account.rawValue] = String(trimmed.prefix(64))
    } else {
      self.labels.removeValue(forKey: account.rawValue)
    }
  }
}
