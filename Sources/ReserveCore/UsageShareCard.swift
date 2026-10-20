import Foundation

/// One account's live limits as the app holds them. The builder decides what
/// of it may leave the Mac.
public struct UsageShareAccount: Sendable {
  public var provider: ProviderID
  public var planName: String?
  public var windows: [UsageWindow]
  /// When the limits were read. Nil must not look like "just now".
  public var checkedAt: Date?

  public init(provider: ProviderID, planName: String?, windows: [UsageWindow], checkedAt: Date?) {
    self.provider = provider
    self.planName = planName
    self.windows = windows
    self.checkedAt = checkedAt
  }
}

/// What the person chose to put on the card.
public struct UsageShareOptions: Equatable, Sendable {
  public static let periods = [1, 7, 30]

  public var periodDays: Int
  /// Nil shares every account with something to show.
  public var provider: ProviderID?
  public var includesLimits: Bool
  public var includesCost: Bool
  public var includesModels: Bool

  public init(
    periodDays: Int = 7,
    provider: ProviderID? = nil,
    includesLimits: Bool = true,
    includesCost: Bool = true,
    includesModels: Bool = true
  ) {
    self.periodDays = Self.periods.contains(periodDays) ? periodDays : 7
    self.provider = provider
    self.includesLimits = includesLimits
    self.includesCost = includesCost
    self.includesModels = includesModels
  }
}

/// The only model the share card may render.
///
/// Every string is either a fixed Reserve phrase, a catalog name, or a model
/// name built from public product words. Emails, organization names, account
/// labels, paths, raw errors, sources, and identifiers have no field to land in.
public struct UsageShareModel: Equatable, Sendable {
  public enum Pace: Equatable, Sendable {
    case underPace, onPace, overPace, exhausted

    public var label: String {
      switch self {
      case .underPace: "Under pace"
      case .onPace: "On pace"
      case .overPace: "May run out early"
      case .exhausted: "Exhausted"
      }
    }
  }

  public struct Limit: Equatable, Sendable {
    public var label: String
    public var remainingPercent: Double
    public var resetsAt: Date?
    /// Nil while a forecast would not be honest: too early, stale or unknown.
    public var pace: Pace?
    public var projectedRemainingAtResetPercent: Double?
  }

  public struct Plan: Equatable, Sendable {
    public var kind: ProviderKind
    /// The kind's name, or "Claude · Account 2" for an added account.
    public var name: String
    /// A known catalog plan, or nil when the reported name is not on that list.
    public var planName: String?
    public var limits: [Limit]
    public var checkedAt: Date?
  }

  public enum Metric: Equatable, Sendable { case cost, tokens }

  public struct Line: Equatable, Sendable {
    public var name: String
    public var kind: ProviderKind?
    public var tokens: Int64
    /// Nil unless every sample behind the line is priced and cost is shared.
    public var costUSD: Double?
    /// Fraction of the period total in the usage metric.
    public var share: Double?
  }

  public struct Segment: Equatable, Sendable {
    public var kind: ProviderKind
    public var value: Double
  }

  /// One day, or one hour of today. A bar with no segments had no sample.
  public struct Bar: Equatable, Sendable {
    public var label: String
    public var segments: [Segment]
    public var total: Double { self.segments.reduce(0) { $0 + $1.value } }
  }

  public struct Mix: Equatable, Sendable {
    public var cacheRead: Int64
    public var uncachedInput: Int64
    public var cacheWrite: Int64
    public var output: Int64
    public var total: Int64 { InsightReport.sum([self.cacheRead, self.uncachedInput, self.cacheWrite, self.output]) }
  }

  public struct Usage: Equatable, Sendable {
    public var periodDays: Int
    /// "Today", "Last 7 days", "Last 30 days".
    public var periodLabel: String
    /// "Oct 14 – Oct 20, 2026".
    public var rangeLabel: String
    public var metric: Metric
    public var tokens: Int64
    /// API-price estimate for the fully priced providers. Never an invoice.
    public var costUSD: Double?
    /// Providers left out of `costUSD` because some of their usage has no price.
    public var unpricedNames: [String]
    public var activeDays: Int
    /// In `metric`. Nil for a single day.
    public var averagePerActiveDay: Double?
    /// "Peak day" or "Busiest hour", in `metric`.
    public var peakTitle: String?
    public var peakLabel: String?
    public var peakValue: Double?
    public var bars: [Bar]
    public var barsAreHourly: Bool
    public var providers: [Line]
    public var models: [Line]
    /// Named usage whose model is outside the public product names, or below the top rows.
    public var otherModelTokens: Int64
    /// Usage no record names a model for.
    public var unattributedTokens: Int64
    public var tokenMix: Mix?
    public var tokenMixIsPartial: Bool
    public var cacheSavingsUSD: Double?
    public var cacheSavingsIsPartial: Bool
    public var checkedAt: Date?

    public var hasUsage: Bool { self.tokens > 0 }
  }

  public var plans: [Plan]
  /// Nil when the period has no recorded usage. Never a card of zeros.
  public var usage: Usage?
  public var includesCost: Bool
  public var generatedAt: Date

  public var isEmpty: Bool { self.plans.isEmpty && self.usage == nil }

  /// When the oldest limit on the card was read.
  public var limitsCheckedAt: Date? { self.plans.compactMap(\.checkedAt).min() }

  /// Text and PNG both start here. The wording states the estimate plainly.
  public func plainText() -> String {
    let format = UsageShareFormat.self
    var lines = ["Reserve usage"]
    if !self.plans.isEmpty {
      lines.append("")
      lines.append("Plan limits" + (self.limitsCheckedAt.map { " (as of \(format.moment($0)))" } ?? ""))
      for plan in self.plans {
        lines.append(format.planTitle(plan))
        for limit in plan.limits {
          var parts = ["\(format.percent(limit.remainingPercent)) left"]
          if let reset = limit.resetsAt { parts.append("resets \(format.reset(reset))") }
          if let pace = limit.pace { parts.append(pace.label.lowercased()) }
          lines.append("  \(limit.label): " + parts.joined(separator: ", "))
        }
      }
    }
    if let usage {
      lines.append("")
      lines.append("Usage · \(usage.periodLabel) (\(usage.rangeLabel))")
      do {
        if let cost = usage.costUSD, usage.metric == .cost {
          lines.append("  Estimated API equivalent: \(format.money(cost)). Not an actual charge.")
        }
        var tokens = "  Tokens: \(format.tokens(usage.tokens))"
        if usage.periodDays > 1 {
          tokens += " · \(usage.activeDays) of \(usage.periodDays) days active"
        }
        lines.append(tokens)
        if !usage.unpricedNames.isEmpty, usage.metric == .cost {
          lines.append("  No API price for \(format.list(usage.unpricedNames)), not included in the estimate")
        }
        if let average = usage.averagePerActiveDay {
          lines.append("  Average per active day: \(format.value(average, metric: usage.metric))")
        }
        if let title = usage.peakTitle, let label = usage.peakLabel, let value = usage.peakValue {
          lines.append("  \(title): \(label) · \(format.value(value, metric: usage.metric))")
        }
        if !usage.providers.isEmpty {
          let rows = usage.providers.map { line in
            var text = "\(line.name) \(format.lineValue(line, metric: usage.metric))"
            if let share = line.share, usage.providers.count > 1 { text += " (\(format.share(share)))" }
            return text
          }
          lines.append("  By provider: " + rows.joined(separator: ", "))
        }
        if let mix = usage.tokenMix {
          let parts = format.mixParts(mix).map { "\($0.label.lowercased()) \(format.tokens($0.tokens))" }
          lines.append("  Token mix: " + parts.joined(separator: ", ")
            + (usage.tokenMixIsPartial ? " (some days have no token types)" : ""))
        }
        if let savings = usage.cacheSavingsUSD, savings > 0 {
          lines.append("  Caching saved ≈ \(format.money(savings))\(usage.cacheSavingsIsPartial ? " or more" : "")")
        }
        if !usage.models.isEmpty {
          lines.append("  Top models:")
          for (index, line) in usage.models.enumerated() {
            var text = "    \(index + 1). \(line.name) · \(format.lineValue(line, metric: usage.metric))"
            if let share = line.share { text += " (\(format.share(share)))" }
            lines.append(text)
          }
        }
        if usage.otherModelTokens > 0 {
          lines.append("  Other models: \(format.tokens(usage.otherModelTokens)) tokens")
        }
        if usage.unattributedTokens > 0 {
          lines.append("  No model recorded: \(format.tokens(usage.unattributedTokens)) tokens")
        }
      }
      if let checked = usage.checkedAt { lines.append("  Usage as of \(format.moment(checked))") }
    }
    if self.isEmpty {
      lines.append("No usage or limits recorded for this selection")
    }
    lines.append("")
    lines.append(format.disclaimer(includesCost: self.includesCost && self.usage?.metric == .cost))
    return lines.joined(separator: "\n")
  }
}

/// Formatting shared by the card and its text, so both say the same thing.
public enum UsageShareFormat {
  public static func tokens(_ value: Int64) -> String {
    let number = Double(value)
    if value >= 1_000_000_000_000 { return compact(number / 1_000_000_000_000, suffix: "T") }
    if value >= 1_000_000_000 { return compact(number / 1_000_000_000, suffix: "B") }
    if value >= 1_000_000 { return compact(number / 1_000_000, suffix: "M") }
    if value >= 1_000 { return compact(number / 1_000, suffix: "K") }
    return String(max(0, value))
  }

  public static func money(_ value: Double) -> String {
    guard value.isFinite else { return "unavailable" }
    let value = max(0, value)
    if value >= 1_000_000 { return "$" + compact(value / 1_000_000, suffix: "M") }
    if value >= 10_000 { return "$" + compact(value / 1_000, suffix: "K") }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = value < 100 ? 2 : 0
    formatter.minimumFractionDigits = value < 100 ? 2 : 0
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
  }

  public static func value(_ value: Double, metric: UsageShareModel.Metric) -> String {
    metric == .cost ? self.money(value) : self.tokens(Int64(min(Double(Int64.max - 1024), max(0, value))))
  }

  /// A priced line shows its estimate; an unpriced one shows what is known, its tokens.
  public static func lineValue(_ line: UsageShareModel.Line, metric: UsageShareModel.Metric) -> String {
    if metric == .cost, let cost = line.costUSD { return self.money(cost) }
    return self.tokens(line.tokens) + (metric == .cost ? " tokens" : "")
  }

  public static func percent(_ value: Double) -> String {
    "\(Int(min(100, max(0, value)).rounded()))%"
  }

  public static func share(_ fraction: Double) -> String {
    let value = fraction * 100
    if value > 0, value < 1 { return "<1%" }
    return value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
  }

  public static func moment(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  /// "Oct 20, 10:00 AM": a reset is always within the year.
  public static func reset(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
  }

  public static func planTitle(_ plan: UsageShareModel.Plan) -> String {
    [plan.name, plan.planName].compactMap { $0 }.joined(separator: " · ")
  }

  public static func mixParts(_ mix: UsageShareModel.Mix) -> [(label: String, tokens: Int64)] {
    [("Cache read", mix.cacheRead), ("Uncached input", mix.uncachedInput),
     ("Cache write", mix.cacheWrite), ("Output", mix.output)].filter { $0.1 > 0 }
  }

  public static func list(_ names: [String]) -> String {
    guard names.count > 1, let last = names.last else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }

  public static func disclaimer(includesCost: Bool) -> String {
    includesCost
      ? "Shared from Reserve. API-price estimates are not an actual charge. No account, organization or file details."
      : "Shared from Reserve. No account, organization or file details."
  }

  private static func compact(_ value: Double, suffix: String) -> String {
    let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
    return String(format: "%.*f", digits, value) + suffix
  }
}

public enum UsageShareCardBuilder {
  /// Catalog names Reserve itself assigns. Anything else, including an email
  /// or organization stuffed into a plan field, is omitted.
  public static let allowedPlans: Set<String> = [
    "Free", "Plus", "Pro", "Pro+", "Team", "Business", "Enterprise", "Edu",
    "Max", "Max 5x", "Max 20x",
    "SuperGrok", "SuperGrok Heavy", "X Premium", "X Premium+",
    // The X Subscription tiers ("Free", "Plus" and "Ultra" are listed above).
    "Premium", "Super",
    "Hobby", "Ultra",
    "Adagio", "Andante", "Moderato", "Allegretto", "Allegro",
    "GLM Coding Lite", "GLM Coding Pro", "GLM Coding Max",
  ]

  public static let maximumPlans = 8
  public static let maximumLimitsPerPlan = 8
  public static let maximumModels = 5

  /// Builds the card. `history` holds every day of the period for each
  /// account, quiet and missing days included; `hourly` is today's
  /// timestamped history and is used only for a one-day period.
  public static func model(
    accounts: [UsageShareAccount],
    history: [InsightReport.Entry]?,
    hourly: [HourlyUsageHistory] = [],
    usageCheckedAt: Date?,
    options: UsageShareOptions,
    now: Date = Date(),
    calendar: Calendar = .current
  ) -> UsageShareModel {
    let selected = { (provider: ProviderID) in options.provider.map { $0 == provider } ?? true }
    let plans = options.includesLimits
      ? Array(accounts.filter { selected($0.provider) }.compactMap { Self.plan($0, now: now) }
        .prefix(Self.maximumPlans))
      : []
    // A period without usage is left off rather than shown as zeros.
    let usage = history.map { entries in
      Self.usage(
        entries: entries.filter { selected($0.provider) },
        hourly: hourly.filter { selected($0.provider) },
        checkedAt: usageCheckedAt, options: options, now: now, calendar: calendar)
    }.flatMap { $0.hasUsage ? $0 : nil }
    return UsageShareModel(
      plans: plans, usage: usage, includesCost: options.includesCost, generatedAt: now)
  }

  // MARK: Limits

  static func plan(_ account: UsageShareAccount, now: Date) -> UsageShareModel.Plan? {
    let safePlan = account.planName.flatMap { allowedPlans.contains($0) ? $0 : nil }
    let limits = account.windows.compactMap { window -> UsageShareModel.Limit? in
      guard let label = Self.normalizedWindowLabel(window.label) else { return nil }
      let remaining = 100 - window.usedPercent
      guard remaining.isFinite else { return nil }
      let state = UsagePaceState.calculate(for: window, fetchedAt: account.checkedAt, now: now)
      let pace: UsageShareModel.Pace? = switch state {
      case .reserve: .underPace
      case .onPace: .onPace
      case .deficit: .overPace
      case .exhausted: .exhausted
      case .stale, .unknown: nil
      }
      // "May run out early" already says it all; "~0% at reset" would only repeat it.
      let projected = pace == nil || pace == .exhausted
        ? nil : UsagePaceProjection.calculate(for: window, now: now)?.projectedRemainingPercent
          .flatMap { pace == .overPace && $0 < 1 ? nil : $0 }
      return UsageShareModel.Limit(
        label: label,
        remainingPercent: min(100, max(0, remaining)),
        resetsAt: window.resetsAt.flatMap { $0 > now ? $0 : nil },
        pace: pace,
        projectedRemainingAtResetPercent: projected)
    }
    // A plan name alone says nothing about usage; an account appears only with a limit.
    guard !limits.isEmpty else { return nil }
    return UsageShareModel.Plan(
      kind: account.provider.kind,
      name: account.provider.neutralDisplayName,
      planName: safePlan,
      limits: Array(limits.prefix(Self.maximumLimitsPerPlan)),
      checkedAt: account.checkedAt)
  }

  /// Fixed window titles, and model-scoped ones whose scope is made of public
  /// product words. Provider text that does not match is dropped rather than
  /// copied, so a label cannot carry an email, org, or path.
  static func normalizedWindowLabel(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let base = Self.baseWindowLabel(trimmed) { return base }
    let folded = trimmed.lowercased()
    if folded.hasSuffix(" weekly") {
      let scope = String(trimmed.dropLast(" weekly".count))
      return Self.isPublicProductName(scope, requiresFamily: false) ? "\(scope) weekly" : nil
    }
    let parts = trimmed.components(separatedBy: " · ")
    if parts.count == 2, let base = Self.baseWindowLabel(parts[1]),
      Self.isPublicProductName(parts[0], requiresFamily: false)
    {
      return "\(parts[0]) · \(base)"
    }
    return nil
  }

  private static func baseWindowLabel(_ raw: String) -> String? {
    let folded = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch folded {
    case "weekly", "weekly limit": return "Weekly limit"
    case "5 hours", "5-hour window", "session": return "5-hour window"
    case "daily": return "Daily"
    case "monthly", "monthly total": return "Monthly"
    case "primary": return "Primary"
    case "coding limit": return "Coding limit"
    case "build share", "grok build share": return "Build share"
    case "grok chat share": return "Grok Chat share"
    case "grok bot share": return "Grok Bot share"
    case "grok imagine share": return "Grok Imagine share"
    case "grok voice share": return "Grok Voice share"
    case "grok api share": return "Grok API share"
    case "cursor share": return "Cursor share"
    case "cursor models": return "Cursor models"
    case "other models": return "Other models"
    default: break
    }
    if folded.range(of: #"^[0-9]{1,3} (days|hours|minutes)$"#, options: .regularExpression) != nil {
      return folded
    }
    return nil
  }

  // MARK: Model names

  /// Leading words of public model and product names.
  static let familyWords: Set<String> = [
    "claude", "opus", "sonnet", "haiku", "fable", "gpt", "chatgpt", "codex", "gemini", "gemma",
    "grok", "glm", "kimi", "moonshot", "composer", "cursor", "deepseek", "qwen", "llama",
    "mistral", "devstral", "codestral", "copilot", "auto",
  ]

  /// Every other word a public model name is made of.
  static let productWords: Set<String> = familyWords.union([
    "mini", "nano", "pro", "max", "flash", "lite", "ultra", "turbo", "preview", "latest",
    "thinking", "think", "reasoning", "reasoner", "high", "low", "medium", "xhigh", "minimal",
    "fast", "sol", "spark", "exp", "experimental", "instant", "chat", "coder", "code", "plus",
    "vision", "heavy", "beta", "alpha", "air", "image", "imagine", "voice", "build", "search",
    "deep", "research", "open", "oss", "instruct", "base", "small", "large", "micro", "default",
    "models", "model", "other", "x", "z",
  ])

  /// A model name kept only when it is a public product name: letters, digits
  /// and separators, opening with a known family word, every word a known
  /// product word or a version. A fine-tune, deployment or proxy name, which
  /// can carry an organization, falls to "Other models".
  public static func safeModelName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self.isPublicProductName(trimmed, requiresFamily: true) ? trimmed : nil
  }

  static func isPublicProductName(_ raw: String, requiresFamily: Bool) -> Bool {
    guard (1...64).contains(raw.count),
      raw.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]*$"#, options: .regularExpression) != nil
    else { return false }
    let words = raw.lowercased().split(whereSeparator: { " -_.".contains($0) }).map(String.init)
    guard let first = words.first else { return false }
    if requiresFamily, !Self.familyWords.contains(first), !Self.isVersionWord(first, leading: true) {
      return false
    }
    return words.allSatisfy { Self.productWords.contains($0) || Self.isVersionWord($0, leading: false) }
  }

  /// "5", "4o", "20250514", "v1", "o3", "k2", "a3b", "30b". A leading word may
  /// only be the short "o3" form, which is itself a model family.
  private static func isVersionWord(_ word: String, leading: Bool) -> Bool {
    if leading { return word.range(of: #"^o[0-9]{1,2}$"#, options: .regularExpression) != nil }
    return word.range(of: #"^(v?[0-9]{1,8}[a-z]?|[a-z][0-9]{1,3}[a-z]?)$"#, options: .regularExpression) != nil
  }

  // MARK: Usage

  static func usage(
    entries rawEntries: [InsightReport.Entry],
    hourly: [HourlyUsageHistory],
    checkedAt: Date?,
    options: UsageShareOptions,
    now: Date,
    calendar: Calendar
  ) -> UsageShareModel.Usage {
    // Without cost, the glance leads with tokens and shares count tokens.
    let entries = options.includesCost ? rawEntries : rawEntries.map { entry in
      InsightReport.Entry(provider: entry.provider, day: CachedUsageDay(
        day: entry.day.day, tokens: entry.day.tokens, costUSD: nil,
        fetchedAt: entry.day.fetchedAt, detail: entry.day.detail))
    }
    let report = InsightReport(entries: entries)
    let glance = UsageGlance(report: report)
    let metric: UsageShareModel.Metric = glance.lead == .cost ? .cost : .tokens
    let unpriced = Set(glance.unpricedProviders)
    let days = options.periodDays

    let providers = glance.providers.compactMap { line -> UsageShareModel.Line? in
      guard let provider = line.provider else { return nil }
      return UsageShareModel.Line(
        name: provider.neutralDisplayName, kind: provider.kind, tokens: line.tokens,
        costUSD: line.costUSD, share: line.share)
    }

    // Model names merge after cleaning; whatever cannot be named publicly is "other".
    var models: [UsageShareModel.Line] = []
    var otherTokens: Int64 = 0
    if options.includesModels {
      var merged: [String: UsageShareModel.Line] = [:]
      var order: [String] = []
      for line in glance.models {
        guard let name = Self.safeModelName(line.label) else {
          otherTokens = InsightReport.sum([otherTokens, line.tokens])
          continue
        }
        let key = (line.provider?.kind.rawValue ?? "") + ":" + name.lowercased()
        if var existing = merged[key] {
          existing.tokens = InsightReport.sum([existing.tokens, line.tokens])
          existing.costUSD = existing.costUSD.flatMap { a in line.costUSD.map { a + $0 } }
          existing.share = existing.share.flatMap { a in line.share.map { a + $0 } }
          merged[key] = existing
        } else {
          merged[key] = UsageShareModel.Line(
            name: name, kind: line.provider?.kind, tokens: line.tokens,
            costUSD: line.costUSD, share: line.share)
          order.append(key)
        }
      }
      let ranked = order.compactMap { merged[$0] }.sorted {
        let a = metric == .cost ? ($0.costUSD ?? -1) : Double($0.tokens)
        let b = metric == .cost ? ($1.costUSD ?? -1) : Double($1.tokens)
        if a != b { return a > b }
        if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
        return $0.name < $1.name
      }
      models = Array(ranked.prefix(Self.maximumModels))
      otherTokens = InsightReport.sum([otherTokens] + ranked.dropFirst(Self.maximumModels).map(\.tokens))
    }
    let unattributed = options.includesModels ? InsightReport.sum(glance.unattributed.map(\.tokens)) : 0

    // Bars draw only providers whose every active day is priced when cost leads,
    // so no bar understates a provider by skipping its unpriced days.
    func dayValue(_ entry: InsightReport.Entry) -> Double? {
      if metric == .cost {
        guard !unpriced.contains(entry.provider) else { return nil }
        return entry.day.costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
      }
      return entry.day.tokens.map { Double(max(0, $0)) }
    }
    var bars: [UsageShareModel.Bar] = []
    var hourlyBars = false
    if days == 1 {
      if !hourly.isEmpty {
        bars = Self.hourlyBars(hourly, metric: metric, unpriced: unpriced, calendar: calendar)
        hourlyBars = true
      }
    } else {
      let keys = Set(entries.map(\.day.day)).filter { !$0.isEmpty }.sorted()
      for key in keys {
        var segments: [ProviderKind: Double] = [:]
        for entry in entries where entry.day.day == key {
          guard let value = dayValue(entry), value > 0 else { continue }
          segments[entry.provider.kind, default: 0] += value
        }
        bars.append(UsageShareModel.Bar(
          label: Self.dayLabel(key, long: days > 7, calendar: calendar),
          segments: ProviderKind.allCases.compactMap { kind in
            segments[kind].map { UsageShareModel.Segment(kind: kind, value: $0) }
          }))
      }
    }

    var peakTitle: String?
    var peakLabel: String?
    var peakValue: Double?
    if let peak = bars.enumerated().max(by: { $0.element.total < $1.element.total }), peak.element.total > 0,
      bars.count > 1
    {
      peakTitle = hourlyBars ? "Busiest hour" : "Peak day"
      peakValue = peak.element.total
      peakLabel = hourlyBars
        ? peak.element.label
        : Self.dayKey(at: peak.offset, in: entries).map { Self.dayLabel($0, long: true, calendar: calendar) }
    }

    let headline = metric == .cost ? (glance.costUSD ?? 0) : Double(glance.tokens)
    let average = days > 1 && glance.activeDays > 0 ? headline / Double(glance.activeDays) : nil

    let mix = glance.tokenMix.map {
      UsageShareModel.Mix(
        cacheRead: $0.cachedInput, uncachedInput: $0.uncachedInput,
        cacheWrite: $0.cacheWrite, output: $0.output)
    }
    let savings = options.includesCost ? glance.cacheSavingsUSD.flatMap { $0 > 0 ? $0 : nil } : nil

    return UsageShareModel.Usage(
      periodDays: days,
      periodLabel: days == 1 ? "Today" : "Last \(days) days",
      rangeLabel: Self.rangeLabel(days: days, now: now, calendar: calendar),
      metric: metric,
      tokens: glance.tokens,
      costUSD: metric == .cost ? glance.costUSD : nil,
      unpricedNames: metric == .cost ? glance.unpricedProviders.map(\.neutralDisplayName) : [],
      activeDays: glance.activeDays,
      averagePerActiveDay: average,
      peakTitle: peakTitle, peakLabel: peakLabel, peakValue: peakValue,
      bars: bars,
      barsAreHourly: hourlyBars,
      providers: providers,
      models: models,
      otherModelTokens: otherTokens,
      unattributedTokens: unattributed,
      tokenMix: mix,
      tokenMixIsPartial: mix != nil && glance.tokenMixIsPartial,
      cacheSavingsUSD: savings,
      cacheSavingsIsPartial: savings != nil && glance.cacheSavingsIsPartial,
      checkedAt: checkedAt)
  }

  private static func hourlyBars(
    _ histories: [HourlyUsageHistory],
    metric: UsageShareModel.Metric,
    unpriced: Set<ProviderID>,
    calendar: Calendar
  ) -> [UsageShareModel.Bar] {
    var buckets = Array(repeating: [ProviderKind: Double](), count: 24)
    for history in histories {
      if metric == .cost && unpriced.contains(history.provider) { continue }
      for point in history.hours {
        let hour = calendar.component(.hour, from: point.start)
        guard (0..<24).contains(hour) else { continue }
        let value = metric == .cost ? point.costUSD : Double(point.tokens)
        guard let value, value.isFinite, value > 0 else { continue }
        buckets[hour][history.provider.kind, default: 0] += value
      }
    }
    return buckets.enumerated().map { hour, values in
      UsageShareModel.Bar(
        label: Self.hourLabel(hour),
        segments: ProviderKind.allCases.compactMap { kind in
          values[kind].map { UsageShareModel.Segment(kind: kind, value: $0) }
        })
    }
  }

  private static func dayKey(at index: Int, in entries: [InsightReport.Entry]) -> String? {
    let keys = Set(entries.map(\.day.day)).filter { !$0.isEmpty }.sorted()
    return keys.indices.contains(index) ? keys[index] : nil
  }

  static func hourLabel(_ hour: Int) -> String {
    let twelve = hour % 12 == 0 ? 12 : hour % 12
    return "\(twelve) \(hour < 12 ? "AM" : "PM")"
  }

  private static func date(fromKey key: String, calendar: Calendar) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var civil = Calendar(identifier: .gregorian)
    civil.timeZone = calendar.timeZone
    return civil.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }

  static func dayLabel(_ key: String, long: Bool, calendar: Calendar) -> String {
    guard let date = Self.date(fromKey: key, calendar: calendar) else { return "" }
    var style = Date.FormatStyle(date: .omitted, time: .omitted)
    style.timeZone = calendar.timeZone
    return long
      ? date.formatted(style.month(.abbreviated).day())
      : date.formatted(style.weekday(.abbreviated))
  }

  static func rangeLabel(days: Int, now: Date, calendar: Calendar) -> String {
    var style = Date.FormatStyle(date: .omitted, time: .omitted)
    style.timeZone = calendar.timeZone
    let end = now.formatted(style.month(.abbreviated).day().year())
    guard days > 1, let start = calendar.date(byAdding: .day, value: -(days - 1), to: now) else { return end }
    return start.formatted(style.month(.abbreviated).day()) + " – " + end
  }
}
