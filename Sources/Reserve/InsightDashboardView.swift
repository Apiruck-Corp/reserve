import AppKit
import ReserveCore

/// The Insights workspace. All controls operate on published data in memory.
/// It states only what the published history backs: filters offer providers
/// and sources that have data, missing values are left out rather than shown
/// as zero or a dash, and an empty selection says so once.
@MainActor
final class InsightDashboardView: NSStackView, NSSearchFieldDelegate {
  enum Metric: Int { case cost, tokens, limits }
  enum Group: Int { case model, day, provider }
  struct Filters {
    var provider: ProviderID?
    var source = 0
    var metric = Metric.tokens
    var group = Group.model
    var search = ""
  }
  private let store: UsageStore
  private let contentWidth: CGFloat
  private let changed: (Filters) -> Void
  private var filters: Filters
  private var series: [InsightHistorySeries] = []
  private var report = InsightReport(entries: [])
  private var glance = UsageGlance(report: InsightReport(entries: []))
  private var breakdown = NSStackView()
  private var providerOptions: [ProviderID] = []
  private var referenceSignature = ""
  private var hourly: [ProviderID: HourlyUsageHistory] = [:]
  private var hourlyStatus = ""
  private var deferredRefresh = false
  private var retainedHeatmaps: [String: UsageHeatmapView] = [:]
  private var retainedTotal: NSTextField?

  init(store: UsageStore, width: CGFloat, filters: Filters, changed: @escaping (Filters) -> Void) {
    self.store = store; self.contentWidth = width; self.filters = filters; self.changed = changed
    super.init(frame: .zero)
    self.orientation = .vertical; self.alignment = .leading
    self.spacing = 14 + 2 * SettingsSectionCard.outset.height
    self.identifier = NSUserInterfaceItemIdentifier("insights-dashboard")
    self.widthAnchor.constraint(equalToConstant: width).isActive = true
    self.rebuild()
  }
  required init?(coder: NSCoder) { nil }

  /// Cost is offered only when some selected provider is fully priced.
  private var metric: Metric {
    self.filters.metric == .cost && self.glance.costUSD == nil ? .tokens : self.filters.metric
  }

  private func rebuild() {
    func descendants(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }
    let previous = descendants(self)
    self.retainedHeatmaps = Dictionary(uniqueKeysWithValues: previous.compactMap {
      guard let map = $0 as? UsageHeatmapView, let id = map.identifier?.rawValue else { return nil }
      return (id, map)
    })
    self.retainedTotal = previous.first { $0.identifier?.rawValue == "insights-total" } as? NSTextField
    defer { self.retainedHeatmaps.removeAll(); self.retainedTotal = nil }
    self.series = self.currentSeries()
    self.referenceSignature = self.referencesSignature()
    self.hourly = self.store.insightHourlyHistory()
    self.hourlyStatus = self.store.hourlyHistoryStatus
    // Only providers with something to show in this range are offered.
    self.providerOptions = self.series.filter { $0.coveredDays > 0 || $0.provider == self.filters.provider }
      .map(\.provider)
    if let provider = self.filters.provider, !self.providerOptions.contains(provider) {
      self.filters.provider = nil
    }
    let selected = self.selectedSeries()
    self.report = InsightReport(entries: selected.flatMap { series in
      series.days.map { day in InsightReport.Entry(provider: series.provider,
        day: CachedUsageDay(day: day.day, tokens: day.tokens, costUSD: day.costUSD,
          fetchedAt: .distantPast, detail: day.detail)) }
    })
    self.glance = UsageGlance(report: self.report)
    for view in self.arrangedSubviews { self.removeArrangedSubview(view); view.removeFromSuperview() }
    self.addArrangedSubview(self.filterBar())
    self.addArrangedSubview(self.label(self.rangeCaption(), color: .secondaryLabelColor))
    // Each block sits on the theme's card surface, as Settings sections do.
    let card = { (view: NSView) in SettingsSectionCard(content: view, width: self.contentWidth) }
    if self.metric == .limits {
      self.addArrangedSubview(card(self.limits(selected)))
      return
    }
    guard self.glance.hasUsage else {
      self.addArrangedSubview(card(self.emptyState(selected)))
      return
    }
    self.addArrangedSubview(card(self.overview(selected)))
    if let mix = self.glance.tokenMix { self.addArrangedSubview(card(self.totals(mix))) }
    if self.store.insightHistoryDays > 1 { self.addArrangedSubview(card(self.heatmap(selected))) }
    self.addArrangedSubview(card(self.breakdownSection()))
    self.addArrangedSubview(self.references(selected))
  }

  private func currentSeries() -> [InsightHistorySeries] {
    self.store.accounts.map { self.store.insightSeries(for: $0, origin: self.historyOrigin) }
      .filter { $0.available && (self.store.isEnabled($0.provider) || $0.coveredDays > 0) }
  }

  private func selectedSeries() -> [InsightHistorySeries] {
    self.series.filter {
      (self.filters.provider == nil || self.filters.provider == $0.provider)
        && (self.filters.metric == .limits || self.filters.source == 0
          || (self.filters.source == 1 ? $0.origin == .localDevice : $0.origin == .providerAccount))
    }
  }

  /// Same structure is kept between updates unless the published data changes.
  func refresh() {
    guard self.currentSeries() != self.series || self.referenceSignature != self.referencesSignature()
      || self.hourly != self.store.insightHourlyHistory() || self.hourlyStatus != self.store.hourlyHistoryStatus else { return }
    if let editor = self.window?.firstResponder as? NSTextView,
      let field = editor.delegate as? NSSearchField,
      field.identifier?.rawValue == "insights-breakdown-search",
      !field.stringValue.isEmpty || editor.hasMarkedText() {
      self.deferredRefresh = true
      return
    }
    self.rebuild()
  }

  private var historyOrigin: UsageInsightOrigin? {
    guard self.filters.metric != .limits else { return nil }
    return self.filters.source == 0 ? nil : (self.filters.source == 1 ? .localDevice : .providerAccount)
  }

  private func referencesSignature() -> String {
    self.store.accounts.map {
      "\($0.displayName):\(self.store.monthlySubscriptionCost(for: $0) ?? -1):\(self.store.states[$0]?.snapshot?.accountUsage?.totalTokens ?? -1):\(self.store.states[$0]?.snapshot?.accountUsage?.apiEquivalentCostUSD ?? -1):\(self.store.states[$0]?.snapshot?.accountUsage?.periodDays ?? 0):\(String(describing: self.store.states[$0]?.snapshot?.windows))"
    }.joined(separator: "|") + "\u{1}\(self.store.localHistoryEnabled)\(self.store.localHistoryIsUpdating)"
      + "\(String(describing: self.store.localHistoryUpdatedAt))\(self.store.localHistoryFailure ?? "")"
  }

  private func rangeCaption() -> String {
    if self.metric == .limits { return "Latest readings from each provider" }
    let keys = InsightHistoryRange.dayKeys(count: self.store.insightHistoryDays, now: Date())
    let parse = DateFormatter()
    parse.locale = Locale(identifier: "en_US_POSIX"); parse.dateFormat = "yyyy-MM-dd"
    let show = DateFormatter()
    show.setLocalizedDateFormatFromTemplate("MMM d")
    let dates = [keys.first, keys.last].compactMap { $0.flatMap(parse.date(from:)).map(show.string(from:)) }
    let range = self.store.insightHistoryDays == 1 ? "Today" : dates.joined(separator: " – ")
    var parts = [range]
    if self.store.localHistoryIsUpdating {
      parts.append("updating…")
    } else if let updated = self.store.localHistoryUpdatedAt {
      parts.append(DashboardFormat.updated(updated, now: Date()).lowercased())
    }
    return parts.joined(separator: " · ")
  }

  private func filterBar() -> NSView {
    let provider = self.popup(["All providers"] + self.providerOptions.map(self.historyName),
      id: "insights-provider-filter", action: #selector(self.providerChanged(_:)), width: 205)
    provider.selectItem(at: self.filters.provider.flatMap { self.providerOptions.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    var views: [NSView] = [provider]
    // A source filter is a choice only when both sources have data.
    let unfiltered = self.store.accounts.map { self.store.insightSeries(for: $0) }.filter { $0.coveredDays > 0 }
    let origins = Set(unfiltered.map(\.origin))
    if self.filters.metric != .limits && (origins.count > 1 || self.filters.source != 0) {
      let source = self.popup(["All sources", "This Mac", "Provider account"],
        id: "insights-source-filter", action: #selector(self.sourceChanged(_:)), width: 165)
      source.selectItem(at: self.filters.source)
      views.append(source)
    }
    let metric = NSSegmentedControl(labels: ["Cost", "Tokens", "Limits"], trackingMode: .selectOne,
      target: self, action: #selector(self.metricChanged(_:)))
    metric.selectedSegmentBezelColor = ReserveColor.accent
    metric.selectedSegment = self.metric.rawValue
    metric.setEnabled(self.glance.costUSD != nil || self.filters.metric == .cost, forSegment: 0)
    metric.setToolTip(self.glance.costUSD == nil
      ? "No selected provider has a known API price for every active day" : nil, forSegment: 0)
    metric.identifier = NSUserInterfaceItemIdentifier("insights-metric")
    metric.setAccessibilityLabel("Usage metric")
    let range = self.popup(["Today", "7 days", "30 days", "90 days"],
      id: "insights-history-range", action: #selector(self.rangeChanged(_:)), width: 110)
    range.selectItem(at: [1, 7, 30, 90].firstIndex(of: self.store.insightHistoryDays) ?? 2)
    range.isEnabled = self.filters.metric != .limits
    let refresh = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh insights")!,
      target: self, action: #selector(self.refreshClicked))
    refresh.bezelStyle = .inline
    refresh.identifier = NSUserInterfaceItemIdentifier("insights-refresh")
    return self.row(views + [self.spacer(), metric, range, refresh], width: self.contentWidth)
  }

  private func emptyState(_ selected: [InsightHistorySeries]) -> NSView {
    let title: String
    let detail: String
    var action: NSView?
    if !self.store.localHistoryEnabled && !selected.contains(where: { $0.coveredDays > 0 }) {
      title = "Activity from this Mac is off"
      detail = "Reserve can read token counts from Claude Code, Codex and Grok logs on this Mac. It reads numbers only, never your prompts."
      let button = NSButton(title: "Include activity from this Mac", target: self, action: #selector(self.enableHistory))
      button.bezelStyle = .rounded
      button.identifier = NSUserInterfaceItemIdentifier("insights-enable-history")
      action = button
    } else if let failure = self.store.localHistoryFailure {
      title = "Usage history could not be read"
      detail = failure
    } else if !selected.contains(where: { $0.coveredDays > 0 })
      && (self.store.localHistoryIsUpdating || self.store.localHistoryUpdatedAt == nil) {
      title = "Reading usage on this Mac…"
      detail = "Totals appear as soon as the first pass finishes."
    } else {
      let who = self.filters.provider.map(self.historyName) ?? "Your providers"
      title = self.store.insightHistoryDays == 1 ? "No usage yet today" : "No usage in this period"
      detail = "\(who) recorded no tokens in this range."
    }
    var rows: [NSView] = [
      self.label(title, size: 15, weight: .semibold, color: .labelColor),
      self.label(detail, color: .secondaryLabelColor, wraps: true, width: self.contentWidth),
    ]
    if let action { rows.append(action) }
    let column = self.column(rows, spacing: 8)
    column.identifier = NSUserInterfaceItemIdentifier("insights-empty")
    return column
  }

  private func overview(_ selected: [InsightHistorySeries]) -> NSView {
    let glance = self.glance
    let costMetric = self.metric == .cost
    let value = costMetric ? DashboardFormat.money(glance.costUSD ?? 0) : DashboardFormat.tokens(glance.tokens)
    let headline = self.label(value, size: 34, weight: .semibold, color: .labelColor)
    headline.font = ReserveFont.digits(34, .semibold)
    headline.identifier = NSUserInterfaceItemIdentifier("insights-headline")
    let active = glance.activeDays
    let days = self.store.insightHistoryDays == 1 ? "" : " · \(active) active \(active == 1 ? "day" : "days")"
    let caption = costMetric
      ? "API-price estimate · \(DashboardFormat.tokens(glance.tokens)) tokens" + days
      : "Processed tokens" + days
    var summary: [NSView] = [self.column([headline, self.label(caption, color: .secondaryLabelColor)], spacing: 2)]
    if costMetric, !glance.unpricedProviders.isEmpty {
      let names = DashboardUsagePanel.list(glance.unpricedProviders.map(self.historyName))
      let note = self.label("No API price for \(names), not included above", size: 11, color: .tertiaryLabelColor,
        wraps: true, width: 286)
      note.identifier = NSUserInterfaceItemIdentifier("insights-unpriced")
      summary.append(note)
    }
    let unpriced = Set(glance.unpricedProviders)
    for line in glance.providers {
      guard let provider = line.provider else { continue }
      let name = self.label(self.historyName(provider), size: 13, color: .labelColor)
      name.toolTip = self.historyName(provider)
      let shownCost = costMetric ? line.costUSD : nil
      let valueText = costMetric
        ? (shownCost.map(DashboardFormat.money) ?? DashboardFormat.tokens(line.tokens) + " tokens")
        : DashboardFormat.tokens(line.tokens)
      let value = self.label(valueText, size: 13, weight: .medium,
        color: costMetric && shownCost == nil ? .secondaryLabelColor : .labelColor)
      let heading = self.row([self.dot(provider), name, self.spacer(), value], width: 286)
      var facts: [String] = []
      if let share = line.share, glance.providers.count > 1 {
        facts.append(DashboardUsagePanel.percent(share) + (costMetric ? " of cost" : " of tokens"))
      }
      if costMetric {
        facts.append(unpriced.contains(provider) ? "no API price" : DashboardFormat.tokens(line.tokens) + " tokens")
      } else if let cost = line.costUSD {
        facts.append("≈ " + DashboardFormat.money(cost) + " at API prices")
      }
      facts.append(selected.first { $0.provider == provider }?.origin == .providerAccount ? "provider account" : "this Mac")
      let group = self.column([heading, self.label(facts.joined(separator: " · "), size: 11, color: .secondaryLabelColor)], spacing: 5)
      group.identifier = NSUserInterfaceItemIdentifier("insight-\(provider.rawValue)")
      summary.append(group)
    }
    // The chart is usually taller; the spare height goes below the rows.
    let rest = NSView()
    rest.setContentHuggingPriority(.init(1), for: .vertical)
    rest.setContentCompressionResistancePriority(.init(1), for: .vertical)
    summary.append(rest)
    let left = self.column(summary, spacing: 14)
    left.widthAnchor.constraint(equalToConstant: 286).isActive = true
    let chartWidth = self.contentWidth - 318
    let source = self.filters.source == 2 ? [] : selected.compactMap { self.hourly[$0.provider] }
    let chart = InsightTrendView(
      series: costMetric ? selected.filter { !unpriced.contains($0.provider) } : selected,
      metric: self.metric,
      providerNames: Dictionary(uniqueKeysWithValues: selected.map { ($0.provider, self.historyName($0.provider)) }),
      periodDays: self.store.insightHistoryDays,
      hourly: costMetric ? source.filter { !unpriced.contains($0.provider) } : source)
    let title = self.label(chart.title, size: 13, weight: .medium, color: .labelColor)
    chart.widthAnchor.constraint(equalToConstant: chartWidth).isActive = true
    chart.heightAnchor.constraint(equalToConstant: 218).isActive = true
    chart.identifier = NSUserInterfaceItemIdentifier("insights-daily-trend")
    var chartViews: [NSView] = [title, chart]
    if self.store.insightHistoryDays == 1, let note = self.hourlyNote(selected) {
      let caption = self.label(note, size: 11, color: .secondaryLabelColor, wraps: true, width: chartWidth)
      caption.identifier = NSUserInterfaceItemIdentifier("insights-hourly-coverage")
      chartViews.append(caption)
    }
    let right = self.column(chartViews, spacing: 10)
    let row = self.row([left, right], width: self.contentWidth, spacing: 32)
    row.alignment = .top
    return row
  }

  /// What the hourly chart leaves out, only when it leaves something out.
  private func hourlyNote(_ selected: [InsightHistorySeries]) -> String? {
    if self.filters.source == 2 {
      return "Provider accounts report daily totals only. Choose This Mac for hourly usage."
    }
    let available = selected.compactMap { self.hourly[$0.provider] }
    guard let latest = available.map(\.observedAt).max() else {
      return self.hourlyStatus + " Daily totals cannot be split into hours."
    }
    let formatter = DateFormatter(); formatter.timeStyle = .short
    let missing = selected.filter { $0.coveredDays > 0 && self.hourly[$0.provider] == nil }.map { self.historyName($0.provider) }
    return "Through \(formatter.string(from: latest)); the current hour is partial."
      + (missing.isEmpty ? "" : " " + DashboardUsagePanel.list(missing)
        + (missing.count == 1 ? " reports" : " report") + " daily totals only, so "
        + (missing.count == 1 ? "it is" : "they are") + " not charted by hour.")
  }

  private func limits(_ selected: [InsightHistorySeries]) -> NSView {
    var rows: [NSView] = [self.label("Current limits", size: 20, weight: .semibold, color: .labelColor)]
    for series in selected {
      let windows = self.store.states[series.provider]?.snapshot?.windows ?? []
      for window in windows {
        let label = self.label(series.provider.displayName + " · " + window.label, color: .labelColor)
        label.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let left = 100 - min(100, max(0, window.usedPercent))
        let meter = ShareBar(fraction: CGFloat(left / 100), color: ReserveColor.accent)
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.widthAnchor.constraint(equalToConstant: 230).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 6).isActive = true
        var text = DashboardFormat.remainingPercent(left) + "% left"
        if let reset = window.resetsAt {
          text += " · resets " + reset.formatted(date: .abbreviated, time: .shortened)
        }
        rows.append(self.row([label, meter, self.spacer(), self.label(text, size: 12, color: .secondaryLabelColor)],
          width: self.contentWidth))
      }
    }
    if rows.count == 1 { rows.append(self.label("No provider reports a limit right now.", color: .secondaryLabelColor)) }
    return self.column(rows, spacing: 14)
  }

  private func totals(_ mix: TokenMix) -> NSView {
    let title = self.label("Token mix", size: 13, weight: .semibold, color: .labelColor)
    var heading: [NSView] = [title, self.spacer()]
    if let savings = self.glance.cacheSavingsUSD, savings > 0 {
      let saved = self.label("Caching saved ≈ \(DashboardFormat.money(savings))"
        + (self.glance.cacheSavingsIsPartial ? " or more" : ""), size: 12, weight: .medium, color: ReserveColor.success)
      saved.identifier = NSUserInterfaceItemIdentifier("insights-cache-savings")
      saved.toolTip = "Difference between full input and cache-read API prices for the cache reads Reserve can price."
      heading.append(saved)
    }
    let parts = TokenMixBar.parts(mix)
    let bar = TokenMixBar(parts: parts)
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.widthAnchor.constraint(equalToConstant: self.contentWidth).isActive = true
    bar.heightAnchor.constraint(equalToConstant: 10).isActive = true
    let columns = parts.map { part -> NSView in
      let swatch = ReserveSurface(fill: part.color, radius: 2)
      swatch.translatesAutoresizingMaskIntoConstraints = false
      swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
      swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
      let name = self.row([swatch, self.label(part.label, color: .secondaryLabelColor)], width: 150, spacing: 6)
      let col = self.column([name, self.label(DashboardFormat.tokens(part.tokens), size: 16, weight: .medium, color: .labelColor)], spacing: 6)
      col.widthAnchor.constraint(equalToConstant: 150).isActive = true
      return col
    }
    var rows: [NSView] = [self.row(heading, width: self.contentWidth), bar,
      self.row(columns + [self.spacer()], width: self.contentWidth, spacing: 12)]
    if self.glance.tokenMixIsPartial,
      let text = DashboardUsagePanel.tokenCoverageNote(self.selectedSeries(), name: self.historyName)
    {
      let note = self.label(text, size: 11, color: .secondaryLabelColor, wraps: true, width: self.contentWidth)
      note.identifier = NSUserInterfaceItemIdentifier("insights-token-coverage")
      rows.append(note)
    }
    return self.column(rows, spacing: 12)
  }

  private func heatmap(_ selected: [InsightHistorySeries]) -> NSView {
    let title = self.label("Daily heatmap", size: 13, weight: .semibold, color: .labelColor)
    var rows: [NSView] = [title]
    for series in selected where series.available && series.coveredDays > 0 {
      let name = self.label(self.historyName(series.provider), color: .labelColor)
      name.widthAnchor.constraint(equalToConstant: 175).isActive = true
      name.toolTip = self.historyName(series.provider)
      let map: UsageHeatmapView
      if let retained = self.retainedHeatmaps["insights-heatmap-\(series.provider.rawValue)"] {
        (retained.superview as? NSStackView)?.removeArrangedSubview(retained)
        retained.removeFromSuperview()
        retained.apply(series)
        map = retained
      } else {
        map = UsageHeatmapView(series: series)
        map.widthAnchor.constraint(equalToConstant: self.contentWidth - 355).isActive = true
      }
      let source = series.origin == .providerAccount ? "provider account" : "this Mac"
      let coverage = self.label(series.coveredDays == series.requestedDays ? source
        : "\(series.coveredDays) of \(series.requestedDays) days · \(source)", size: 11, color: .secondaryLabelColor)
      coverage.alignment = .right
      coverage.widthAnchor.constraint(equalToConstant: 160).isActive = true
      rows.append(self.row([self.dot(series.provider), name, map, coverage], width: self.contentWidth, spacing: 4))
    }
    rows.append(self.label("Darker means more tokens. An outlined cell is a day with no data, not a day with zero.",
      size: 11, color: .tertiaryLabelColor, wraps: true, width: self.contentWidth))
    return self.column(rows, spacing: 8)
  }

  private func breakdownSection() -> NSView {
    let title = self.label("Breakdown", size: 13, weight: .semibold, color: .labelColor)
    let search = NSSearchField()
    search.placeholderString = "Filter breakdown"; search.stringValue = self.filters.search
    search.delegate = self
    search.identifier = NSUserInterfaceItemIdentifier("insights-breakdown-search")
    search.widthAnchor.constraint(equalToConstant: 200).isActive = true
    search.setAccessibilityLabel("Filter breakdown")
    let group = NSSegmentedControl(labels: ["Model", "Day", "Provider"], trackingMode: .selectOne,
      target: self, action: #selector(self.groupChanged(_:)))
    group.selectedSegmentBezelColor = ReserveColor.accent
    group.selectedSegment = self.filters.group.rawValue
    group.identifier = NSUserInterfaceItemIdentifier("insights-breakdown-group")
    let heading = self.row([title, self.spacer(), search, group], width: self.contentWidth)
    self.breakdown = self.column([], spacing: 0)
    self.breakdown.identifier = NSUserInterfaceItemIdentifier("insights-breakdown")
    self.buildBreakdown()
    return self.column([heading, self.breakdown], spacing: 14)
  }

  private func buildBreakdown() {
    for v in self.breakdown.arrangedSubviews { self.breakdown.removeArrangedSubview(v); v.removeFromSuperview() }
    let data: [InsightReport.Row]
    switch self.filters.group { case .model: data = self.report.modelRows; case .day: data = self.report.dailyRows; case .provider: data = self.report.providerRows }
    let rows = self.sorted(data.filter { $0.tokens > 0 }).filter { row in
      self.filters.search.isEmpty || (self.rowName(row) + " " + (row.provider.map(self.historyName) ?? "")).localizedCaseInsensitiveContains(self.filters.search)
    }
    let showsCost = self.glance.costUSD != nil
    let nameTitle = ["Model", "Day", "Provider"][self.filters.group.rawValue]
    self.breakdown.addArrangedSubview(self.tableRow(rank: "#", name: nameTitle, provider: nil, fraction: nil,
      cost: showsCost ? "API estimate" : "", share: "Share", tokens: "Tokens", header: true))
    let peak = rows.map { self.shareValue($0) ?? 0 }.max() ?? 0
    for (index, item) in rows.enumerated() {
      let share = self.shareValue(item)
      self.breakdown.addArrangedSubview(self.tableRow(
        rank: "\(index + 1)", name: self.rowName(item), provider: item.provider,
        fraction: share.map { peak > 0 ? $0 / peak : 0 },
        cost: self.pricedCost(item).map(DashboardFormat.money) ?? "",
        share: share.map(DashboardUsagePanel.percent) ?? "", tokens: DashboardFormat.tokens(item.tokens)))
    }
    if rows.isEmpty { self.breakdown.addArrangedSubview(self.label("No matching usage", color: .secondaryLabelColor)) }
  }

  private func rowName(_ row: InsightReport.Row) -> String {
    switch self.filters.group {
    case .provider: return row.provider.map(self.historyName) ?? row.label
    case .day: return row.label
    case .model:
      let model = row.label == InsightReport.unknownModelLabel ? "No model name" : row.label
      return model + " · " + (row.provider.map(self.historyName) ?? "")
    }
  }

  /// A row's cost only when all of it is priced, and its provider is too.
  private func pricedCost(_ row: InsightReport.Row) -> Double? {
    guard row.pricedSamples == row.samples, let cost = row.costUSD else { return nil }
    if let provider = row.provider, self.glance.unpricedProviders.contains(provider) { return nil }
    if row.provider == nil, self.filters.group == .day, !self.glance.unpricedProviders.isEmpty {
      // A day total would mix priced and unpriced providers.
      return nil
    }
    return cost
  }

  private func shareValue(_ row: InsightReport.Row) -> Double? {
    if self.metric == .cost {
      guard let total = self.glance.costUSD, total > 0, let cost = self.pricedCost(row) else { return nil }
      return cost / total
    }
    return self.report.tokens > 0 ? Double(row.tokens) / Double(self.report.tokens) : nil
  }

  private func tableRow(rank: String, name: String, provider: ProviderID?, fraction: Double?,
                        cost: String, share: String, tokens: String, header: Bool = false) -> NSView {
    let size: CGFloat = header ? 11 : 12
    let color: NSColor = header ? .secondaryLabelColor : .labelColor
    let rankLabel = self.label(rank, size: size, color: .tertiaryLabelColor)
    rankLabel.widthAnchor.constraint(equalToConstant: 26).isActive = true
    let nameWidth = self.contentWidth - 352 - 40
    let nameLabel = self.label(name, size: size, color: color)
    nameLabel.toolTip = name
    nameLabel.widthAnchor.constraint(equalToConstant: nameWidth).isActive = true
    var nameViews: [NSView] = [nameLabel]
    if let fraction, !header {
      let bar = ShareBar(fraction: CGFloat(max(0, min(1, fraction))),
        color: provider.map(InsightTrendView.color) ?? ReserveColor.accent)
      bar.translatesAutoresizingMaskIntoConstraints = false
      bar.widthAnchor.constraint(equalToConstant: min(320, nameWidth)).isActive = true
      bar.heightAnchor.constraint(equalToConstant: 3).isActive = true
      nameViews.append(bar)
    }
    let nameColumn = self.column(nameViews, spacing: 4)
    let values = [(cost, CGFloat(150)), (share, 70), (tokens, 90)].map { text, width in
      let value = self.label(text, size: size, color: color)
      value.alignment = .right; value.widthAnchor.constraint(equalToConstant: width).isActive = true
      return value
    }
    let row = self.row([rankLabel, nameColumn] + values, width: self.contentWidth, spacing: 14)
    row.heightAnchor.constraint(equalToConstant: header ? 28 : 40).isActive = true
    let line = NSBox(); line.boxType = .separator
    line.widthAnchor.constraint(equalToConstant: self.contentWidth).isActive = true
    return self.column([row, line], spacing: 0)
  }

  private func references(_ selected: [InsightHistorySeries]) -> NSView {
    let providers = selected.map(\.provider)
    let plans = providers.compactMap { self.store.monthlySubscriptionCost(for: $0) }
    var sentences: [String] = []
    if self.glance.costUSD != nil {
      sentences.append("API estimates use each provider's published prices. They are not a bill: your subscriptions cover this usage.")
    }
    if !plans.isEmpty {
      sentences.append("Your plans cost \(DashboardFormat.money(plans.reduce(0, +)))/month.")
    }
    if sentences.isEmpty { sentences.append("Token counts come from this Mac's logs and from provider accounts.") }
    let text = sentences.joined(separator: " ")
    let total: NSTextField
    if let retained = self.retainedTotal {
      (retained.superview as? NSStackView)?.removeArrangedSubview(retained)
      retained.removeFromSuperview()
      retained.stringValue = text
      retained.setAccessibilityLabel(text)
      total = retained
    } else {
      total = self.label(text, size: 11, color: .tertiaryLabelColor, wraps: true, width: self.contentWidth)
    }
    total.identifier = NSUserInterfaceItemIdentifier("insights-total")
    var views: [NSView] = [total]
    let accountTotals = providers.compactMap { provider -> String? in
      guard let usage = self.store.states[provider]?.snapshot?.accountUsage, usage.origin == .providerAccount,
        usage.totalTokens > 0 else { return nil }
      return "\(provider.displayName) reports \(DashboardFormat.tokens(usage.totalTokens)) tokens"
        + (usage.apiEquivalentCostUSD > 0 ? " (≈ \(DashboardFormat.money(usage.apiEquivalentCostUSD)))" : "")
        + " over its last \(usage.periodDays) days, across every device on the account."
    }
    if !accountTotals.isEmpty {
      views.append(self.label(accountTotals.joined(separator: "\n"), size: 11, color: .tertiaryLabelColor,
        wraps: true, width: self.contentWidth))
    }
    return self.column(views, spacing: 6)
  }

  private func sorted(_ rows: [InsightReport.Row]) -> [InsightReport.Row] {
    if self.filters.group == .day && rows.allSatisfy({ $0.provider == nil }) { return rows.sorted { $0.label > $1.label } }
    return rows.sorted {
      let a = self.metric == .cost ? (self.pricedCost($0) ?? -1) : Double($0.tokens)
      let b = self.metric == .cost ? (self.pricedCost($1) ?? -1) : Double($1.tokens)
      if a != b { return a > b }
      if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
      return ($0.label, $0.provider?.rawValue ?? "") < ($1.label, $1.provider?.rawValue ?? "")
    }
  }
  /// Claude transcripts cannot tell personal from Team usage, so history rows
  /// use the store's attribution-aware name, never a subscription's label.
  private func historyName(_ provider: ProviderID) -> String {
    self.store.insightHistoryName(for: provider)
  }

  private func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                     color: NSColor, wraps: Bool = false, width: CGFloat? = nil) -> NSTextField {
    let label = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
    label.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
    label.setAccessibilityLabel(text)
    if let width { label.widthAnchor.constraint(equalToConstant: width).isActive = true }
    return label
  }
  private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .vertical; s.alignment = .leading; s.spacing = spacing
    s.setContentHuggingPriority(.required, for: .vertical)
    return s
  }
  private func row(_ views: [NSView], width: CGFloat, spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.alignment = .centerY; s.spacing = spacing
    s.widthAnchor.constraint(equalToConstant: width).isActive = true
    return s
  }
  private func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }
  private func dot(_ provider: ProviderID) -> NSView {
    InsightProviderDot(provider: provider)
  }
  private func popup(_ titles: [String], id: String, action: Selector, width: CGFloat) -> NSPopUpButton {
    let p = NSPopUpButton(); p.addItems(withTitles: titles); p.target = self; p.action = action
    p.identifier = NSUserInterfaceItemIdentifier(id); p.setAccessibilityLabel(titles[0])
    p.widthAnchor.constraint(equalToConstant: width).isActive = true
    return p
  }
  @objc private func providerChanged(_ sender: NSPopUpButton) {
    self.filters.provider = sender.indexOfSelectedItem > 0 ? self.providerOptions[sender.indexOfSelectedItem - 1] : nil
    self.changed(self.filters)
  }
  @objc private func sourceChanged(_ sender: NSPopUpButton) { self.filters.source = sender.indexOfSelectedItem; self.changed(self.filters) }
  @objc private func metricChanged(_ sender: NSSegmentedControl) { self.filters.metric = Metric(rawValue: sender.selectedSegment) ?? .tokens; self.changed(self.filters) }
  @objc private func groupChanged(_ sender: NSSegmentedControl) {
    self.filters.group = Group(rawValue: sender.selectedSegment) ?? .model
    self.changed(self.filters)
  }
  @objc private func rangeChanged(_ sender: NSPopUpButton) { self.store.insightHistoryDays = [1, 7, 30, 90][max(0, sender.indexOfSelectedItem)] }
  @objc private func refreshClicked() { self.store.refreshAll() }
  @objc private func enableHistory() { self.store.localHistoryEnabled = true }
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSSearchField else { return }
    self.filters.search = field.stringValue
    self.buildBreakdown()
    // Persist without replacing the active field editor.
    self.searchChanged?(self.filters)
  }
  func controlTextDidEndEditing(_ notification: Notification) {
    guard self.deferredRefresh else { return }
    self.deferredRefresh = false
    self.rebuild()
    self.searchChanged?(self.filters)
  }
  var searchChanged: ((Filters) -> Void)?
}

/// Resolve legend markers in their own appearance, just like the chart strokes.
@MainActor
private final class InsightProviderDot: NSView {
  private let provider: ProviderID

  init(provider: ProviderID) {
    self.provider = provider
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.cornerRadius = 4
    self.layer?.backgroundColor = self.resolvedCGColor(InsightTrendView.color(provider))
    self.widthAnchor.constraint(equalToConstant: 8).isActive = true
    self.heightAnchor.constraint(equalToConstant: 8).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(InsightTrendView.color(self.provider))
  }
}
