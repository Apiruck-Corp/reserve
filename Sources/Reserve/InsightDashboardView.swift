import AppKit
import ReserveCore

/// The Insights workspace. All controls operate on published data in memory.
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
  private var breakdown = NSStackView()
  private var providerOptions: [ProviderID] = []
  private var referenceSignature = ""
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

  private func rebuild() {
    func descendants(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }
    let previous = descendants(self)
    self.retainedHeatmaps = Dictionary(uniqueKeysWithValues: previous.compactMap {
      guard let map = $0 as? UsageHeatmapView, let id = map.identifier?.rawValue else { return nil }
      return (id, map)
    })
    self.retainedTotal = previous.first { $0.identifier?.rawValue == "insights-total" } as? NSTextField
    defer { self.retainedHeatmaps.removeAll(); self.retainedTotal = nil }
    self.series = self.store.accounts.map { self.store.insightSeries(for: $0, origin: self.historyOrigin) }
      .filter { self.store.isEnabled($0.provider) || $0.coveredDays > 0 }
    self.referenceSignature = self.referencesSignature()
    self.providerOptions = self.series.map(\.provider)
    if let provider = self.filters.provider, !self.providerOptions.contains(provider) {
      self.filters.provider = nil
    }
    let selected = self.series.filter {
      (self.filters.provider == nil || self.filters.provider == $0.provider)
        && (self.filters.metric == .limits || self.filters.source == 0 || (self.filters.source == 1 ? $0.origin == .localDevice : $0.origin == .providerAccount))
    }
    self.report = InsightReport(entries: selected.flatMap { series in
      series.days.map { day in InsightReport.Entry(provider: series.provider,
        day: CachedUsageDay(day: day.day, tokens: day.tokens, costUSD: day.costUSD,
          fetchedAt: .distantPast, detail: day.detail)) }
    })
    for view in self.arrangedSubviews { self.removeArrangedSubview(view); view.removeFromSuperview() }
    self.addArrangedSubview(self.filterBar())
    let keys = InsightHistoryRange.dayKeys(count: self.store.insightHistoryDays, now: Date())
    self.addArrangedSubview(self.label(self.filters.metric == .limits ? "Current provider readings" : "\(keys.first ?? "")  –  \(keys.last ?? "")", color: .secondaryLabelColor))
    // Each block sits on the theme's card surface, as Settings sections do.
    let card = { (view: NSView) in SettingsSectionCard(content: view, width: self.contentWidth) }
    if self.filters.metric == .limits {
      self.addArrangedSubview(card(self.limits(selected)))
    } else {
      self.addArrangedSubview(card(self.overview(selected)))
      self.addArrangedSubview(card(self.totals()))
    }
    self.addArrangedSubview(card(self.heatmap(selected)))
    if self.filters.metric != .limits { self.addArrangedSubview(card(self.breakdownSection())) }
    self.addArrangedSubview(self.references(selected))
  }

  /// Same structure is kept between updates unless the published data changes.
  func refresh() {
    let current = self.store.accounts.map { self.store.insightSeries(for: $0, origin: self.historyOrigin) }
      .filter { self.store.isEnabled($0.provider) || $0.coveredDays > 0 }
    guard current != self.series || self.referenceSignature != self.referencesSignature() else { return }
    if let editor = self.window?.firstResponder as? NSTextView,
      (editor.delegate as? NSSearchField)?.identifier?.rawValue == "insights-breakdown-search" {
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
    }.joined(separator: "|")
  }

  private func filterBar() -> NSView {
    let provider = self.popup(["All providers"] + self.providerOptions.map(self.historyName),
      id: "insights-provider-filter", action: #selector(self.providerChanged(_:)), width: 205)
    provider.selectItem(at: self.filters.provider.flatMap { self.providerOptions.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    let source = self.popup(["All sources", "This Mac", "Provider account"],
      id: "insights-source-filter", action: #selector(self.sourceChanged(_:)), width: 165)
    source.selectItem(at: self.filters.metric == .limits ? 0 : self.filters.source)
    source.isEnabled = self.filters.metric != .limits
    let metric = NSSegmentedControl(labels: ["Cost", "Tokens", "Limits"], trackingMode: .selectOne,
      target: self, action: #selector(self.metricChanged(_:)))
    metric.selectedSegmentBezelColor = ReserveColor.accent
    metric.selectedSegment = self.filters.metric.rawValue
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
    return self.row([provider, source, self.spacer(), metric, range, refresh], width: self.contentWidth)
  }

  private func overview(_ selected: [InsightHistorySeries]) -> NSView {
    let value = self.filters.metric == .tokens ? DashboardFormat.tokens(self.report.tokens)
      : self.report.costUSD.map { "≈ " + DashboardFormat.money($0) } ?? "Unavailable"
    let headline = self.label(value, size: 34, weight: .semibold, color: .labelColor)
    headline.identifier = NSUserInterfaceItemIdentifier("insights-headline")
    let caption = self.filters.metric == .tokens ? "Processed tokens · \(self.report.activeDays) active days"
      : "Estimated API value · \(self.report.pricedDays)/\(self.report.coveredDays) provider-days priced"
    var summary: [NSView] = [headline, self.label(caption, color: .secondaryLabelColor)]
    let rows = self.sorted(self.report.providerRows)
    for data in rows {
      guard let provider = data.provider else { continue }
      let name = self.label(self.historyName(provider), size: 13, color: .labelColor)
      name.toolTip = self.historyName(provider)
      let value = self.label(self.value(data), size: 13, weight: .medium, color: .labelColor)
      let heading = self.row([self.dot(provider), name, self.spacer(), value], width: 286)
      let source = selected.first { $0.provider == provider }?.origin == .providerAccount ? "account" : "this Mac"
      let subtitle = "\(self.share(data)) · \(self.filters.metric == .tokens ? self.money(data.costUSD) : DashboardFormat.tokens(data.tokens) + " tokens") · \(source)"
      let group = self.column([heading, self.label(subtitle, size: 11, color: .secondaryLabelColor)], spacing: 5)
      group.identifier = NSUserInterfaceItemIdentifier("insight-\(provider.rawValue)")
      summary.append(group)
    }
    if rows.isEmpty { summary.append(self.label("No daily usage in this range", color: .secondaryLabelColor)) }
    let left = self.column(summary, spacing: 14)
    left.widthAnchor.constraint(equalToConstant: 286).isActive = true
    let chartWidth = self.contentWidth - 318
    let title = self.label(self.filters.metric == .tokens ? "Daily processed tokens" : "Daily estimated API value",
      size: 13, weight: .medium, color: .labelColor)
    let chart = InsightTrendView(series: selected, metric: self.filters.metric)
    chart.widthAnchor.constraint(equalToConstant: chartWidth).isActive = true
    chart.heightAnchor.constraint(equalToConstant: 218).isActive = true
    chart.identifier = NSUserInterfaceItemIdentifier("insights-daily-trend")
    let right = self.column([title, chart], spacing: 10)
    let row = self.row([left, right], width: self.contentWidth, spacing: 32)
    row.alignment = .top
    return row
  }

  private func limits(_ selected: [InsightHistorySeries]) -> NSView {
    var rows: [NSView] = [self.label("Current limits", size: 20, weight: .semibold, color: .labelColor),
      self.label("Latest provider readings. Limits and reset times are current, independent of the daily history range.",
        color: .secondaryLabelColor, wraps: true, width: self.contentWidth)]
    for series in selected {
      let windows = self.store.states[series.provider]?.snapshot?.windows ?? []
      for window in windows {
        let label = self.label(series.provider.displayName + " · " + window.label, color: .labelColor)
        label.widthAnchor.constraint(equalToConstant: 310).isActive = true
        let progress = NSProgressIndicator()
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 100
        progress.doubleValue = min(100, max(0, window.usedPercent))
        progress.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let reset = window.resetsAt.map { "Resets " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Reset unavailable"
        rows.append(self.row([label, progress, self.spacer(), self.label(String(format: "%.0f%% used · %@", window.usedPercent, reset),
          size: 12, color: .secondaryLabelColor)], width: self.contentWidth))
      }
    }
    if rows.count == 2 { rows.append(self.label("Current limit data unavailable", color: .secondaryLabelColor)) }
    return self.column(rows, spacing: 14)
  }

  private func totals() -> NSView {
    let mix = self.report.tokenMix
    let fields: [(String, String)] = [("Processed tokens", DashboardFormat.tokens(self.report.tokens)),
      ("Cache read", self.report.detailDays == 0 ? "—" : DashboardFormat.tokens(mix.cachedInput)),
      ("Uncached input", self.report.detailDays == 0 ? "—" : DashboardFormat.tokens(mix.uncachedInput)),
      ("Cache write", self.report.detailDays == 0 ? "—" : DashboardFormat.tokens(mix.cacheWrite)),
      ("Output", self.report.detailDays == 0 ? "—" : DashboardFormat.tokens(mix.output)),
      ("Cache savings", self.money(self.report.cacheSavingsUSD))]
    let columns = fields.map { title, value in
      let col = self.column([self.label(title, color: .secondaryLabelColor),
        self.label(value, size: 16, weight: .medium, color: .labelColor)], spacing: 6)
      col.widthAnchor.constraint(equalToConstant: (self.contentWidth - 60) / 6).isActive = true
      return col
    }
    let coverage = self.label("Token-type detail: \(self.report.detailDays)/\(self.report.coveredDays) provider-days. "
      + (self.report.unpricedCacheReads > 0 ? "Cache savings are partial; some cache reads have no price." : "Older cached days may have no model or token-type detail."),
      color: .secondaryLabelColor, wraps: true, width: self.contentWidth)
    return self.column([self.row(columns, width: self.contentWidth, spacing: 12), coverage], spacing: 12)
  }

  private func heatmap(_ selected: [InsightHistorySeries]) -> NSView {
    let title = self.label("Daily heatmap", size: 13, weight: .semibold, color: .labelColor)
    var rows: [NSView] = [title]
    for series in selected where series.available {
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
      let source = series.origin == .providerAccount ? "account" : "this Mac"
      let coverage = self.label("\(series.coveredDays)/\(series.requestedDays) days · \(source)", size: 11, color: .secondaryLabelColor)
      coverage.alignment = .right
      coverage.widthAnchor.constraint(equalToConstant: 160).isActive = true
      rows.append(self.row([self.dot(series.provider), name, map, coverage], width: self.contentWidth, spacing: 4))
    }
    if !selected.contains(where: { $0.available }) { rows.append(self.label("Daily history unavailable for these providers", color: .secondaryLabelColor)) }
    rows.append(self.label("Oldest → newest · Darker cells mean more tokens. An outline is a missing day, not zero. Account history can include other devices.",
      color: .secondaryLabelColor, wraps: true, width: self.contentWidth))
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
    let rows = self.sorted(data).filter { row in
      self.filters.search.isEmpty || (row.label + " " + (row.provider.map(self.historyName) ?? "")).localizedCaseInsensitiveContains(self.filters.search)
    }
    let nameTitle = ["Model / provider", "Day", "Provider"][self.filters.group.rawValue]
    self.breakdown.addArrangedSubview(self.tableRow(name: nameTitle, cost: "API estimate", share: "Share", tokens: "Tokens", header: true))
    for item in rows {
      let name = self.filters.group == .provider ? item.provider.map(self.historyName) ?? item.label
        : self.filters.group == .model ? item.label + " · " + (item.provider.map(self.historyName) ?? "") : item.label
      self.breakdown.addArrangedSubview(self.tableRow(name: name, cost: self.money(item.costUSD)
        + (item.pricedSamples > 0 && item.pricedSamples < item.samples ? " *" : ""),
        share: self.share(item), tokens: DashboardFormat.tokens(item.tokens)))
    }
    if rows.isEmpty { self.breakdown.addArrangedSubview(self.label("No matching usage", color: .secondaryLabelColor)) }
  }

  private func tableRow(name: String, cost: String, share: String, tokens: String, header: Bool = false) -> NSView {
    let nameLabel = self.label(name, size: header ? 11 : 12, color: header ? .secondaryLabelColor : .labelColor)
    nameLabel.toolTip = name
    nameLabel.widthAnchor.constraint(equalToConstant: self.contentWidth - 352).isActive = true
    let values = [(cost, CGFloat(150)), (share, 70), (tokens, 90)].map { text, width in
      let value = self.label(text, size: header ? 11 : 12, color: header ? .secondaryLabelColor : .labelColor)
      value.alignment = .right; value.widthAnchor.constraint(equalToConstant: width).isActive = true
      return value
    }
    let row = self.row([nameLabel] + values, width: self.contentWidth, spacing: 14)
    row.heightAnchor.constraint(equalToConstant: header ? 28 : 34).isActive = true
    let line = NSBox(); line.boxType = .separator
    line.widthAnchor.constraint(equalToConstant: self.contentWidth).isActive = true
    return self.column([row, line], spacing: 0)
  }

  private func references(_ selected: [InsightHistorySeries]) -> NSView {
    let providers = selected.map(\.provider)
    let plans = providers.compactMap { self.store.monthlySubscriptionCost(for: $0) }
    let text = "\(self.money(self.report.costUSD)) estimated API value · \(self.report.coveredDays) cached provider-days · \(self.report.pricedDays) priced. "
      + "API estimates cover known prices only. * Partial pricing. "
      + (plans.isEmpty ? "Monthly plan costs unavailable." : "\(DashboardFormat.money(plans.reduce(0, +)))/month in known plan costs is a separate reference.")
    let total: NSTextField
    if let retained = self.retainedTotal {
      (retained.superview as? NSStackView)?.removeArrangedSubview(retained)
      retained.removeFromSuperview()
      retained.stringValue = text
      retained.setAccessibilityLabel(text)
      total = retained
    } else {
      total = self.label(text, color: .secondaryLabelColor, wraps: true, width: self.contentWidth)
    }
    total.identifier = NSUserInterfaceItemIdentifier("insights-total")
    var views: [NSView] = [total]
    let accountTotals = providers.compactMap { provider -> String? in
      guard let usage = self.store.states[provider]?.snapshot?.accountUsage, usage.origin == .providerAccount else { return nil }
      return "\(provider.displayName): \(DashboardFormat.tokens(usage.totalTokens)) tokens · \(self.money(usage.apiEquivalentCostUSD)) provider-reported usage value · \(usage.periodDays)-day account total"
    }
    if !accountTotals.isEmpty {
      views.append(self.label(accountTotals.joined(separator: "\n"), color: .secondaryLabelColor, wraps: true, width: self.contentWidth))
    }
    views.append(self.label("Daily filters use cached history. Account totals above retain their provider-reported period. Model detail requires an unambiguous source record; older, partial or mixed-model cumulative records remain labeled Model unavailable.",
      color: .secondaryLabelColor, wraps: true, width: self.contentWidth))
    return self.column(views, spacing: 8)
  }

  private func sorted(_ rows: [InsightReport.Row]) -> [InsightReport.Row] {
    if self.filters.group == .day && rows.allSatisfy({ $0.provider == nil }) { return rows.sorted { $0.label > $1.label } }
    return rows.sorted {
      let a = self.filters.metric == .tokens ? Double($0.tokens) : ($0.costUSD ?? -1)
      let b = self.filters.metric == .tokens ? Double($1.tokens) : ($1.costUSD ?? -1)
      return a == b ? ($0.label, $0.provider?.rawValue ?? "") < ($1.label, $1.provider?.rawValue ?? "") : a > b
    }
  }
  private func value(_ row: InsightReport.Row) -> String {
    self.filters.metric == .tokens ? DashboardFormat.tokens(row.tokens) : self.money(row.costUSD)
  }
  private func share(_ row: InsightReport.Row) -> String {
    let denominator = self.filters.metric == .tokens ? Double(self.report.tokens) : self.report.costUSD ?? 0
    let numerator = self.filters.metric == .tokens ? Double(row.tokens) : row.costUSD
    guard denominator > 0, let numerator else { return "—" }
    return String(format: "%.1f%%", 100 * numerator / denominator)
  }
  private func money(_ value: Double?) -> String { value.map { "≈ " + DashboardFormat.money($0) } ?? "—" }
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
