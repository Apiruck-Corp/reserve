import AppKit
import ReserveCore

/// Everything the popover's usage column states, read from published history
/// only. Building it never opens a log file.
struct DashboardUsageModel {
  var days: Int
  /// Providers with a sample in the period, in the store's account order.
  var series: [InsightHistorySeries]
  var hourly: [HourlyUsageHistory]
  var glance: UsageGlance
  var names: [ProviderID: String]
  var updatedAt: Date?
  var isUpdating: Bool
  var failure: String?

  var hasSamples: Bool { self.series.contains { $0.coveredDays > 0 } }
  var accountOnly: Bool { !self.series.isEmpty && self.series.allSatisfy { $0.origin == .providerAccount } }

  /// What changes the rendered panel. Clock-only changes are left out; the
  /// freshness label follows the minute clock itself.
  var signature: String {
    var parts = [String(self.days), self.isUpdating ? "updating" : "-", self.failure ?? "-",
      self.updatedAt.map { String(Int($0.timeIntervalSinceReferenceDate)) } ?? "-",
      String(reflecting: self.glance.costUSD), String(self.glance.tokens)]
    for series in self.series {
      parts.append(series.provider.rawValue + (self.names[series.provider] ?? "") + series.origin.rawValue)
      parts.append(series.days.map { "\($0.tokens ?? -1):\($0.costUSD ?? -1):\($0.detail == nil ? 0 : 1)" }
        .joined(separator: ","))
    }
    for history in self.hourly {
      parts.append("\(history.provider.rawValue):\(history.observedAt.timeIntervalSinceReferenceDate):\(history.hours.count)")
      parts.append(history.hours.map { String($0.tokens) }.joined(separator: ","))
    }
    return parts.joined(separator: "\u{1}")
  }
}

extension UsageStore {
  /// Nil when nothing can ever be shown: history off and no provider reports
  /// account activity. The popover then keeps its single column.
  func dashboardUsage(now: Date = Date()) -> DashboardUsageModel? {
    let days = self.dashboardUsageDays
    let all = self.accounts.filter { self.isEnabled($0) }
      .map { self.insightSeries(for: $0, now: now, days: days) }
      .filter(\.available)
    let sampled = all.filter { $0.coveredDays > 0 }
    guard self.localHistoryEnabled || !sampled.isEmpty else { return nil }
    let entries = sampled.flatMap { series in
      series.days.map { day in
        InsightReport.Entry(provider: series.provider, day: CachedUsageDay(
          day: day.day, tokens: day.tokens, costUSD: day.costUSD,
          fetchedAt: .distantPast, detail: day.detail))
      }
    }
    let hourly = days == 1
      ? sampled.filter { $0.origin == .localDevice }.compactMap { self.insightHourlyHistory(now: now)[$0.provider] }
      : []
    return DashboardUsageModel(
      days: days, series: sampled, hourly: hourly,
      glance: UsageGlance(report: InsightReport(entries: entries), modelLimit: 5),
      names: Dictionary(uniqueKeysWithValues: sampled.map { ($0.provider, self.insightHistoryName(for: $0.provider)) }),
      updatedAt: self.localHistoryUpdatedAt,
      isUpdating: self.localHistoryIsUpdating,
      failure: self.localHistoryFailure)
  }
}

/// The popover's second column: what was used, what it would cost at API
/// prices, how it splits by provider, token type and model. Figures Reserve
/// cannot back are left out instead of shown as zero.
@MainActor
final class DashboardUsagePanel: NSView, ReserveClockUpdating {
  private(set) var signature = ""
  private let selectPeriod: (Int) -> Void
  private var stack = NSStackView()
  private var freshness: ReserveLabel?
  private var model: DashboardUsageModel

  init(model: DashboardUsageModel, now: Date, selectPeriod: @escaping (Int) -> Void) {
    self.model = model
    self.selectPeriod = selectPeriod
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("usage-panel")
    self.translatesAutoresizingMaskIntoConstraints = false
    self.stack = NSStackView.column([], spacing: DashboardMetrics.rowGap)
    self.stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(self.stack)
    NSLayoutConstraint.activate([
      self.stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      self.stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      self.stack.topAnchor.constraint(equalTo: self.topAnchor),
      self.stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
    self.build(now: now)
  }

  required init?(coder: NSCoder) { nil }

  /// Rebuilds the column when what it states has changed. Returns true when it did.
  @discardableResult
  func apply(model: DashboardUsageModel, now: Date) -> Bool {
    guard model.signature != self.signature else {
      self.updateClock(now)
      return false
    }
    self.model = model
    for view in self.stack.arrangedSubviews {
      self.stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    self.build(now: now)
    return true
  }

  func updateClock(_ now: Date) {
    self.freshness?.setDisplayedText(Self.freshnessText(self.model, now: now))
  }

  private func build(now: Date) {
    self.signature = self.model.signature
    let model = self.model
    self.stack.addArrangedSubview(self.summaryCard(model))
    if model.glance.hasUsage {
      if let mix = model.glance.tokenMix { self.stack.addArrangedSubview(self.tokenCard(model, mix: mix)) }
      if !model.glance.models.isEmpty { self.stack.addArrangedSubview(self.modelsCard(model)) }
    }
    let freshness = ReserveLabel(
      Self.freshnessText(model, now: now), font: ReserveFont.sans(ReserveType.support),
      color: model.failure == nil ? ReserveColor.subtle : ReserveColor.warning)
    freshness.identifier = NSUserInterfaceItemIdentifier("usage-freshness")
    freshness.width(DashboardMetrics.contentWidth - 4)
    self.freshness = freshness
    let indent = NSStackView.row([Self.gap(4), freshness], spacing: 0)
    self.stack.addArrangedSubview(indent)
  }

  // MARK: Cards

  private func summaryCard(_ model: DashboardUsageModel) -> NSView {
    let width = DashboardMetrics.cardContentWidth
    let title = ReserveLabel(
      "Usage", font: ReserveFont.sans(ReserveType.body, .semibold), color: ReserveColor.text
    ).flexible()
    let period = NSSegmentedControl(
      labels: ["Today", "7 days", "30 days"], trackingMode: .selectOne,
      target: self, action: #selector(self.periodChanged(_:)))
    period.controlSize = .small
    period.font = ReserveFont.sans(ReserveType.support, .medium)
    period.selectedSegmentBezelColor = ReserveColor.accent
    period.selectedSegment = [1, 7, 30].firstIndex(of: model.days) ?? 1
    period.identifier = NSUserInterfaceItemIdentifier("usage-period")
    period.setAccessibilityLabel("Usage period")
    let heading = NSStackView.row([title, NSStackView.spacer(), period], spacing: 8)
    heading.widthAnchor.constraint(equalToConstant: width).isActive = true
    var rows: [NSView] = [heading]

    let glance = model.glance
    guard glance.hasUsage else {
      let text: String
      if !model.hasSamples {
        text = model.failure != nil ? "Usage history could not be read."
          : model.isUpdating || model.updatedAt == nil ? "Reading usage on this Mac…"
          : "No usage history in this period."
      } else {
        text = model.days == 1 ? "No usage yet today." : "No usage in the last \(model.days) days."
      }
      let empty = ReserveLabel(text, font: ReserveFont.sans(ReserveType.body), color: ReserveColor.muted)
      empty.identifier = NSUserInterfaceItemIdentifier("usage-empty")
      rows.append(empty)
      return self.card(rows, spacing: 12, id: "usage-summary")
    }

    let costLeads = glance.lead == .cost
    let headline = ReserveLabel(
      costLeads ? DashboardFormat.money(glance.costUSD ?? 0) : DashboardFormat.tokens(glance.tokens),
      font: ReserveFont.digits(30, .semibold), color: ReserveColor.text)
    headline.identifier = NSUserInterfaceItemIdentifier("usage-headline")
    let active = model.days == 1 ? "" : " · \(glance.activeDays) active \(glance.activeDays == 1 ? "day" : "days")"
    let captionText = costLeads
      ? "API-price estimate · \(DashboardFormat.tokens(glance.tokens)) tokens" + active
      : "Tokens" + active
    let caption = ReserveLabel(
      captionText, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted)
    caption.identifier = NSUserInterfaceItemIdentifier("usage-caption")
    caption.toolTip = costLeads
      ? "What this usage would cost at each provider's published API prices. It is not your bill; your subscription covers it."
      : "A cost appears only for providers whose every active day has a known API price."
    var headlineViews: [NSView] = [headline, caption]
    if !glance.unpricedProviders.isEmpty {
      let names = glance.unpricedProviders.map { model.names[$0] ?? $0.displayName }
      let note = ReserveLabel(
        "No API price for " + Self.list(names) + (costLeads ? ", not included above" : ""),
        font: ReserveFont.sans(ReserveType.support), color: ReserveColor.subtle)
      note.identifier = NSUserInterfaceItemIdentifier("usage-unpriced")
      headlineViews.append(note)
    }
    rows.append(NSStackView.column(headlineViews, spacing: 2))

    // A cost chart draws only providers whose every active day is priced, so
    // no line understates a provider by skipping its unpriced days.
    let unpriced = Set(glance.unpricedProviders)
    let chart = InsightTrendView(
      series: costLeads ? model.series.filter { !unpriced.contains($0.provider) } : model.series,
      metric: costLeads ? .cost : .tokens, providerNames: model.names,
      periodDays: model.days,
      hourly: costLeads ? model.hourly.filter { !unpriced.contains($0.provider) } : model.hourly)
    chart.identifier = NSUserInterfaceItemIdentifier("usage-trend")
    chart.translatesAutoresizingMaskIntoConstraints = false
    chart.widthAnchor.constraint(equalToConstant: width).isActive = true
    chart.heightAnchor.constraint(equalToConstant: 132).isActive = true
    rows.append(chart)

    for line in glance.providers {
      guard let provider = line.provider else { continue }
      rows.append(self.providerRow(line, provider: provider, model: model, width: width))
    }
    let card = self.card(rows, spacing: 12, id: "usage-summary")
    return card
  }

  private func providerRow(
    _ line: UsageGlance.Line, provider: ProviderID, model: DashboardUsageModel, width: CGFloat
  ) -> NSView {
    let costLeads = model.glance.lead == .cost
    let shownCost = costLeads ? line.costUSD : nil
    let name = ReserveLabel(
      model.names[provider] ?? provider.displayName,
      font: ReserveFont.sans(ReserveType.body, .medium), color: ReserveColor.text
    ).flexible()
    let value = ReserveLabel(
      shownCost.map(DashboardFormat.money) ?? DashboardFormat.tokens(line.tokens) + (costLeads ? " tokens" : ""),
      font: ReserveFont.digits(ReserveType.body, .semibold),
      color: costLeads && shownCost == nil ? ReserveColor.muted : ReserveColor.text
    ).fitted()
    let top = NSStackView.row([Self.dot(provider), name, NSStackView.spacer(), value], spacing: 8)
    top.widthAnchor.constraint(equalToConstant: width).isActive = true
    var facts: [String] = []
    if let share = line.share, model.glance.providers.count > 1 {
      facts.append(Self.percent(share) + (costLeads ? " of cost" : " of tokens"))
    }
    if costLeads {
      facts.append(shownCost == nil ? "no API price" : DashboardFormat.tokens(line.tokens) + " tokens")
    } else if let cost = line.costUSD {
      facts.append("≈ " + DashboardFormat.money(cost) + " at API prices")
    }
    let origin = model.series.first { $0.provider == provider }?.origin
    facts.append(origin == .providerAccount ? "provider account" : "this Mac")
    let detail = ReserveLabel(
      facts.joined(separator: " · "), font: ReserveFont.sans(ReserveType.metadata),
      color: ReserveColor.muted)
    let indented = NSStackView.row([Self.gap(16), detail], spacing: 0)
    let row = NSStackView.column([top, indented], spacing: 2)
    row.identifier = NSUserInterfaceItemIdentifier("usage-provider-\(provider.rawValue)")
    row.setAccessibilityElement(true)
    row.setAccessibilityLabel("\(name.stringValue): \(value.stringValue), \(detail.stringValue)")
    return row
  }

  private func tokenCard(_ model: DashboardUsageModel, mix: TokenMix) -> NSView {
    let width = DashboardMetrics.cardContentWidth
    let title = ReserveLabel(
      "Token mix", font: ReserveFont.sans(ReserveType.body, .semibold), color: ReserveColor.text
    ).flexible()
    var headingViews: [NSView] = [title, NSStackView.spacer()]
    if let savings = model.glance.cacheSavingsUSD, savings > 0 {
      let saved = ReserveLabel(
        "Caching saved ≈ \(DashboardFormat.money(savings))"
          + (model.glance.cacheSavingsIsPartial ? " or more" : ""),
        font: ReserveFont.sans(ReserveType.metadata, .medium), color: ReserveColor.success
      ).fitted()
      saved.identifier = NSUserInterfaceItemIdentifier("usage-cache-savings")
      saved.toolTip = model.glance.cacheSavingsIsPartial
        ? "Difference between full input and cache-read API prices, for the cache reads Reserve can price. Some cache reads have no known price."
        : "Difference between full input and cache-read API prices for these cache reads."
      headingViews.append(saved)
    }
    let heading = NSStackView.row(headingViews, spacing: 8)
    heading.widthAnchor.constraint(equalToConstant: width).isActive = true
    let parts = TokenMixBar.parts(mix)
    let bar = TokenMixBar(parts: parts)
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.widthAnchor.constraint(equalToConstant: width).isActive = true
    bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
    let legendWidth = (width - 12) / 2
    let cells = parts.map { part -> NSView in
      let swatch = ReserveSurface(fill: part.color, radius: 2)
      swatch.translatesAutoresizingMaskIntoConstraints = false
      swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
      swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
      let label = ReserveLabel(part.label, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted)
        .flexible()
      let value = ReserveLabel(
        DashboardFormat.tokens(part.tokens), font: ReserveFont.digits(ReserveType.metadata, .semibold),
        color: ReserveColor.text
      ).fitted()
      let cell = NSStackView.row([swatch, label, NSStackView.spacer(), value], spacing: 6)
      cell.widthAnchor.constraint(equalToConstant: legendWidth).isActive = true
      return cell
    }
    var legendRows: [NSView] = []
    var index = 0
    while index < cells.count {
      let pair = Array(cells[index..<min(index + 2, cells.count)])
      legendRows.append(NSStackView.row(pair, spacing: 12))
      index += 2
    }
    var rows: [NSView] = [heading, bar, NSStackView.column(legendRows, spacing: 6)]
    if model.glance.tokenMixIsPartial {
      // Name who is missing rather than counting provider-days.
      let missing = model.series.filter { series in
        series.days.contains { ($0.tokens ?? 0) > 0 && $0.detail == nil }
      }
      let complete = missing.filter { series in
        !series.days.contains { ($0.tokens ?? 0) > 0 && $0.detail != nil }
      }.map { model.names[$0.provider] ?? $0.provider.displayName }
      let someDays = missing.map { model.names[$0.provider] ?? $0.provider.displayName }
        .filter { !complete.contains($0) }
      var parts: [String] = []
      if !complete.isEmpty { parts.append(Self.list(complete) + " reports no token types") }
      if !someDays.isEmpty { parts.append("older days of " + Self.list(someDays) + " have none") }
      let note = ReserveLabel(
        parts.joined(separator: "; ") + " · not included",
        font: ReserveFont.sans(ReserveType.support), color: ReserveColor.subtle)
      note.identifier = NSUserInterfaceItemIdentifier("usage-token-mix-coverage")
      rows.append(note)
    }
    return self.card(rows, spacing: 10, id: "usage-token-mix")
  }

  private func modelsCard(_ model: DashboardUsageModel) -> NSView {
    let width = DashboardMetrics.cardContentWidth
    let costLeads = model.glance.lead == .cost
    let title = ReserveLabel(
      "Top models", font: ReserveFont.sans(ReserveType.body, .semibold), color: ReserveColor.text
    ).flexible()
    let unit = ReserveLabel(
      costLeads ? "API estimate" : "Tokens", font: ReserveFont.sans(ReserveType.metadata),
      color: ReserveColor.muted
    ).fitted()
    let heading = NSStackView.row([title, NSStackView.spacer(), unit], spacing: 8)
    heading.widthAnchor.constraint(equalToConstant: width).isActive = true
    var rows: [NSView] = [heading]
    let peak = model.glance.models.compactMap(\.share).max() ?? 1
    for (index, line) in model.glance.models.enumerated() {
      let rank = ReserveLabel(
        "\(index + 1)", font: ReserveFont.digits(ReserveType.metadata), color: ReserveColor.subtle
      ).width(14)
      let name = ReserveLabel(
        line.label, font: ReserveFont.sans(ReserveType.body), color: ReserveColor.text
      ).flexible()
      name.toolTip = line.label + (line.provider.map { " · " + (model.names[$0] ?? $0.displayName) } ?? "")
      // An unpriced model shows what is known about it, its tokens.
      let valueText = costLeads
        ? (line.costUSD.map(DashboardFormat.money) ?? DashboardFormat.tokens(line.tokens) + " tokens")
        : DashboardFormat.tokens(line.tokens)
      let value = ReserveLabel(
        valueText, font: ReserveFont.digits(ReserveType.body, .semibold), color: ReserveColor.text
      ).fitted()
      let share = ReserveLabel(
        line.share.map(Self.percent) ?? "", font: ReserveFont.digits(ReserveType.metadata),
        color: ReserveColor.muted, alignment: .right
      ).width(44)
      let top = NSStackView.row([rank, name, NSStackView.spacer(), value, share], spacing: 8)
      top.widthAnchor.constraint(equalToConstant: width).isActive = true
      let barWidth = width - 22 - 52
      let fraction = CGFloat(max(0, min(1, (line.share ?? 0) / max(peak, 0.0001))))
      let bar = ShareBar(fraction: fraction, color: line.provider.map(InsightTrendView.color) ?? ReserveColor.accent)
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.widthAnchor.constraint(equalToConstant: barWidth).isActive = true
      bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
      let barRow = NSStackView.row([Self.gap(22), bar], spacing: 0)
      let row = NSStackView.column([top, barRow], spacing: 4)
      row.identifier = NSUserInterfaceItemIdentifier("usage-model-\(index)")
      row.setAccessibilityElement(true)
      row.setAccessibilityLabel("\(index + 1). \(line.label): \(valueText)")
      rows.append(row)
    }
    if !model.glance.unattributed.isEmpty {
      let tokens = InsightReport.sum(model.glance.unattributed.map(\.tokens))
      let owners = model.glance.unattributed.compactMap(\.provider).map { model.names[$0] ?? $0.displayName }
      let note = ReserveLabel(
        "Plus \(DashboardFormat.tokens(tokens)) tokens with no model name (\(Self.list(owners)))",
        font: ReserveFont.sans(ReserveType.support), color: ReserveColor.subtle)
      note.identifier = NSUserInterfaceItemIdentifier("usage-unattributed")
      note.toolTip = "These sources record usage without naming the model, so it is not assigned to one."
      rows.append(note)
    }
    return self.card(rows, spacing: 10, id: "usage-models")
  }

  private func card(_ rows: [NSView], spacing: CGFloat, id: String) -> NSView {
    let surface = ReserveSurface(fill: ReserveColor.section, radius: ReserveRadius.section)
    surface.identifier = NSUserInterfaceItemIdentifier(id)
    let stack = NSStackView.column(rows, spacing: spacing)
    stack.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: DashboardMetrics.cardPadding),
      stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -DashboardMetrics.cardPadding),
      stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -14),
      surface.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
    return surface
  }

  // MARK: Helpers

  static func freshnessText(_ model: DashboardUsageModel, now: Date) -> String {
    if let failure = model.failure { return failure }
    let source = model.accountOnly ? "Provider accounts" : "This Mac's logs"
    if model.isUpdating { return "\(source) · updating…" }
    guard let updated = model.updatedAt else {
      return model.accountOnly ? "\(source) · daily totals" : "\(source) · not read yet"
    }
    return "\(source) · " + DashboardFormat.updated(updated, now: now).lowercased()
  }

  static func list(_ names: [String]) -> String {
    guard names.count > 1, let last = names.last else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + last
  }

  static func percent(_ fraction: Double) -> String {
    let value = fraction * 100
    if value > 0, value < 1 { return "<1%" }
    return value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
  }

  private static func gap(_ width: CGFloat) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalToConstant: width).isActive = true
    return view
  }

  private static func dot(_ provider: ProviderID) -> NSView {
    let dot = ReserveSurface(fill: InsightTrendView.color(provider), radius: 4)
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
    dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
    dot.setAccessibilityElement(false)
    return dot
  }

  @objc private func periodChanged(_ sender: NSSegmentedControl) {
    self.selectPeriod([1, 7, 30][max(0, min(2, sender.selectedSegment))])
  }
}

/// One capsule split by token type, widest first.
@MainActor
final class TokenMixBar: NSView {
  struct Part {
    let label: String
    let tokens: Int64
    let color: NSColor
  }

  private let parts: [Part]

  static func parts(_ mix: TokenMix) -> [Part] {
    let accent = ReserveColor.accent
    return [
      Part(label: "Cache read", tokens: mix.cachedInput, color: accent.withAlphaComponent(0.28)),
      Part(label: "Uncached input", tokens: mix.uncachedInput, color: accent.withAlphaComponent(0.55)),
      Part(label: "Cache write", tokens: mix.cacheWrite, color: accent.withAlphaComponent(0.78)),
      Part(label: "Output", tokens: mix.output, color: accent),
    ].filter { $0.tokens > 0 }
  }

  init(parts: [Part]) {
    self.parts = parts
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("usage-token-bar")
    self.setAccessibilityElement(true)
    self.setAccessibilityRole(.image)
    self.setAccessibilityLabel(parts.map { "\($0.label) \(DashboardFormat.tokens($0.tokens))" }
      .joined(separator: ", "))
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    let total = Double(InsightReport.sum(self.parts.map(\.tokens)))
    guard total > 0 else { return }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: self.bounds, xRadius: self.bounds.height / 2, yRadius: self.bounds.height / 2).addClip()
    var x = self.bounds.minX
    for (index, part) in self.parts.enumerated() {
      // Every recorded type stays visible, however small its share.
      let width = index == self.parts.count - 1
        ? self.bounds.maxX - x
        : max(3, self.bounds.width * CGFloat(Double(part.tokens) / total))
      part.color.setFill()
      NSRect(x: x, y: self.bounds.minY, width: max(0, width - 1), height: self.bounds.height).fill()
      x += width
    }
    NSGraphicsContext.restoreGraphicsState()
  }
}

/// A thin proportional rule under a ranked row.
@MainActor
final class ShareBar: NSView {
  private let fraction: CGFloat
  private let color: NSColor

  init(fraction: CGFloat, color: NSColor) {
    self.fraction = fraction
    self.color = color
    super.init(frame: .zero)
    self.setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    ReserveColor.track.setFill()
    NSBezierPath(roundedRect: self.bounds, xRadius: 1.5, yRadius: 1.5).fill()
    let filled = NSRect(x: 0, y: 0, width: max(3, self.bounds.width * self.fraction), height: self.bounds.height)
    self.color.setFill()
    NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
  }
}
