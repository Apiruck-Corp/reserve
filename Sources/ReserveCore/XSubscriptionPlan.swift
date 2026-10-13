import Foundation

/// The X Subscription (launched 2026-10-12) puts Grok, Grok Bot, Cursor and
/// X Premium on one weekly usage pool, in the tiers Free, Plus, Premium, Super
/// and Ultra. Grok's billing service and Cursor may report those tiers as a
/// bare name ("Premium"), a prefixed slug ("x_subscription_premium") or a
/// proto enum ("SUBSCRIPTION_TIER_PREMIUM").
///
/// The older standalone plans keep their own names and are not matched here:
/// "X Premium" and "X Premium+" carry an `x_` prefix, and "SuperGrok" contains
/// "super" without being the Super tier.
enum XSubscriptionPlan {
  static let tiers = ["Free", "Plus", "Premium", "Super", "Ultra"]

  /// The tier name, or nil when the value does not name an X Subscription tier.
  static func tier(from value: String) -> String? {
    var remainder = self.compact(value)
    // Strip until nothing changes, so the order of the wrapping words does not
    // matter ("plan_x_subscription_premium"). Longer words come first, so
    // "teams" is not cut down to a stray "s". Team seats are the same tiers.
    let prefixes = [
      "the", "xsubscription", "subscriptiontier", "subscription", "tier", "plan", "teams",
      "team", "individual",
    ]
    let suffixes = ["teams", "team", "individual", "plan", "tier"]
    var stripped = true
    while stripped {
      stripped = false
      for prefix in prefixes where remainder.hasPrefix(prefix) && remainder.count > prefix.count {
        remainder.removeFirst(prefix.count)
        stripped = true
      }
      for suffix in suffixes where remainder.hasSuffix(suffix) && remainder.count > suffix.count {
        remainder.removeLast(suffix.count)
        stripped = true
      }
    }
    return self.tiers.first { $0.lowercased() == remainder }
  }

  static func compact(_ value: String) -> String {
    value.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" }
  }
}
