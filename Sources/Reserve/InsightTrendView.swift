import AppKit
import ReserveCore

@MainActor
final class InsightTrendView: NSView {
  private let series: [InsightHistorySeries]
  private let metric: InsightDashboardView.Metric
  private let providerNames: [ProviderID: String]
  private let periodDays: Int
  private let hourly: [HourlyUsageHistory]
  private var isSingleDay: Bool { self.periodDays == 1 }
  var title: String {
    if self.isSingleDay {
      return self.metric == .tokens ? "Today's hourly processed tokens" : "Today's hourly estimated API value"
    }
    return self.metric == .tokens ? "Daily processed tokens" : "Daily estimated API value"
  }

  init(series: [InsightHistorySeries], metric: InsightDashboardView.Metric,
       providerNames: [ProviderID: String] = [:], periodDays: Int? = nil,
       hourly: [HourlyUsageHistory] = []) {
    self.series = series.filter(\.available); self.metric = metric; self.providerNames = providerNames
    self.hourly = hourly.filter { !$0.hours.isEmpty }
    self.periodDays = periodDays ?? series.map(\.requestedDays).max() ?? 30
    super.init(frame: .zero)
    self.setAccessibilityElement(true)
    let explanation = self.isSingleDay
      ? "Hourly usage from timestamped local logs. The current hour is partial. Daily account totals may differ."
      : "Smooth lines connect available days. Missing days remain unavailable."
    self.setAccessibilityLabel(self.title + ". " + explanation)
    self.toolTip = explanation
    self.addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { nil }
  // Light, clear tints retain their hue rather than fading toward gray.
  // Brighter dark-mode variants keep provider colors consistent on both surfaces.
  private static let palette: [ProviderKind: NSColor] = [
    .openAI: tone(light: 0x70B2EB, dark: 0x9FD3FF),      // Sky blue
    .anthropic: tone(light: 0xF19B87, dark: 0xFFB9A5),   // Soft coral
    .grok: tone(light: 0xB394E6, dark: 0xD2B4FF),        // Lilac
    .cursor: tone(light: 0x68CBA6, dark: 0x92E8C4),      // Fresh mint
    .copilot: tone(light: 0xE58DBB, dark: 0xF6ACD0),     // Pink
    .gemini: tone(light: 0x95A7F0, dark: 0xB8C8FF),      // Periwinkle
    .kimi: tone(light: 0xE0BD67, dark: 0xF1D38B),        // Soft gold
    .zai: tone(light: 0xA7CC75, dark: 0xCAE899),         // Light green
  ]

  static func color(_ provider: ProviderID) -> NSColor {
    Self.palette[provider.kind] ?? .secondaryLabelColor
  }

  private static func tone(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
  }

  private func value(_ day: InsightHistoryDay) -> Double? {
    let value = self.metric == .tokens ? day.tokens.map(Double.init) : day.costUSD
    return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
  private var scale: InsightChartScale {
    InsightChartScale(values: self.isSingleDay
      ? self.hourly.flatMap { $0.hours.compactMap(self.hourValue) }
      : self.series.flatMap { $0.days.compactMap(self.value) },
      minimumStep: self.metric == .tokens ? 1 : 0.000001)
  }

  private func axisValue(_ amount: Double) -> String {
    if self.metric == .tokens {
      return DashboardFormat.tokens(Int64(min(Double(Int64.max - 1024), amount)))
    }
    let step = self.scale.ticks.dropFirst().first ?? 0.01
    if step > 0, step < 0.01 {
      let decimals = min(6, max(2, Int(ceil(-log10(step)))))
      return String(format: "$%.*f", decimals, amount)
    }
    return DashboardFormat.money(amount)
  }

  private func plotRect(scale: InsightChartScale) -> NSRect {
    let font = NSFont.systemFont(ofSize: 11)
    let gutter = max(40, ceil(scale.ticks.map {
      let label = ($0 == 0 ? "0" : self.axisValue($0)) as NSString
      return label.size(withAttributes: [.font: font]).width
    }.max() ?? 0) + 10)
    return NSRect(x: gutter, y: 28, width: max(1, self.bounds.width - gutter - 12),
      height: max(1, self.bounds.height - 44))
  }

  override func draw(_ dirtyRect: NSRect) {
    let scale = self.scale
    let plot = self.plotRect(scale: scale)
    let values = self.series.flatMap { $0.days.compactMap(self.value) }
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
    if self.isSingleDay, self.hourly.isEmpty {
      self.drawHourly(plot: plot, scale: scale, attributes: attributes)
      return
    }
    for amount in scale.ticks {
      let y = plot.minY + plot.height * CGFloat(amount / scale.maximum)
      NSColor.separatorColor.setStroke()
      let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.stroke()
      let title = (amount == 0 ? "0" : self.axisValue(amount)) as NSString
      let width = title.size(withAttributes: attributes).width
      title.draw(at: NSPoint(x: plot.minX - width - 10, y: y - 6), withAttributes: attributes)
    }
    if self.isSingleDay {
      self.drawHourly(plot: plot, scale: scale, attributes: attributes)
      return
    }
    for item in self.series {
      let points = self.plotPoints(item, plot: plot, peak: scale.maximum)
      let path = Self.smoothPath(points)
      if let first = points.first, let last = points.last, points.count > 1,
        let area = path.copy() as? NSBezierPath {
        area.line(to: NSPoint(x: last.x, y: plot.minY))
        area.line(to: NSPoint(x: first.x, y: plot.minY))
        area.close()
        Self.color(item.provider).withAlphaComponent(0.10).setFill()
        area.fill()
      }
      Self.color(item.provider).setStroke()
      path.stroke()
      // A single observation has no line to draw, so keep it visible as a dot.
      if points.count == 1, let point = points.first {
        Self.color(item.provider).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
      }
    }
    if values.isEmpty {
      let text = self.metric == .tokens ? "Daily history unavailable" : "Daily prices unavailable"
      (text as NSString).draw(at: NSPoint(x: plot.midX - 80, y: plot.midY), withAttributes: attributes)
    }
    if let days = self.series.max(by: { $0.days.count < $1.days.count })?.days, !days.isEmpty {
      let tickCount = min(5, days.count)
      let indices = tickCount == 1 ? [0] : Set((0..<tickCount).map {
        Int((Double($0) * Double(days.count - 1) / Double(tickCount - 1)).rounded())
      }).sorted()
      for index in indices {
        let title = Self.dateLabel(days[index].day) as NSString
        let width = title.size(withAttributes: attributes).width
        let x = days.count == 1 ? plot.midX
          : plot.minX + plot.width * CGFloat(index) / CGFloat(days.count - 1)
        let left = min(plot.maxX - width, max(plot.minX, x - width / 2))
        title.draw(at: NSPoint(x: left, y: 3), withAttributes: attributes)
      }
    }
  }

  private func hourValue(_ hour: HourlyUsagePoint) -> Double? {
    self.metric == .tokens ? Double(hour.tokens) : hour.costUSD
  }

  private static func timeLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }

  private func drawHourly(plot: NSRect, scale: InsightChartScale,
                          attributes: [NSAttributedString.Key: Any]) {
    guard let reference = self.hourly.max(by: { $0.observedAt < $1.observedAt }),
      reference.observedAt > reference.dayStart else {
      ("Hourly detail unavailable" as NSString).draw(
        at: NSPoint(x: plot.midX - 65, y: plot.midY), withAttributes: attributes)
      return
    }
    let duration = reference.observedAt.timeIntervalSince(reference.dayStart)
    func x(_ date: Date) -> CGFloat {
      plot.minX + plot.width * CGFloat(max(0, min(1, date.timeIntervalSince(reference.dayStart) / duration)))
    }
    for history in self.hourly {
      // Draw separate runs when price information is missing; do not imply a
      // zero or a known price across an unpriced hour.
      var runs: [[NSPoint]] = [[]]
      for hour in history.hours {
        guard let value = self.hourValue(hour) else {
          if !runs[runs.count - 1].isEmpty { runs.append([]) }
          continue
        }
        runs[runs.count - 1].append(NSPoint(x: x(hour.start),
          y: plot.minY + plot.height * CGFloat(value / scale.maximum)))
      }
      if let last = history.hours.last, let value = self.hourValue(last) {
        runs[runs.count - 1].append(NSPoint(x: x(history.observedAt),
          y: plot.minY + plot.height * CGFloat(value / scale.maximum)))
      }
      for points in runs where !points.isEmpty {
        let path = Self.smoothPath(points)
        if let first = points.first, let last = points.last, points.count > 1,
          let area = path.copy() as? NSBezierPath {
          area.line(to: NSPoint(x: last.x, y: plot.minY))
          area.line(to: NSPoint(x: first.x, y: plot.minY)); area.close()
          Self.color(history.provider).withAlphaComponent(0.10).setFill(); area.fill()
        }
        Self.color(history.provider).setStroke(); path.stroke()
        for point in points {
          Self.color(history.provider).setFill()
          NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
        }
      }
    }
    let step = [1, 2, 3, 4, 6].first { Double($0 * 4) * 3600 >= duration } ?? 6
    var ticks = stride(from: 0.0, to: duration * 0.87, by: Double(step) * 3600).map {
      reference.dayStart.addingTimeInterval($0)
    }
    ticks.append(reference.observedAt)
    for date in ticks {
      let title = (date == reference.observedAt && Date().timeIntervalSince(date) < 60 ? "Now" : Self.timeLabel(date)) as NSString
      let width = title.size(withAttributes: attributes).width
      title.draw(at: NSPoint(x: min(plot.maxX - width, max(plot.minX, x(date) - width / 2)), y: 3),
        withAttributes: attributes)
    }
  }

  private static func dateLabel(_ day: String) -> String {
    let reader = DateFormatter()
    reader.locale = Locale(identifier: "en_US_POSIX")
    reader.timeZone = .gmt
    reader.dateFormat = "yyyy-MM-dd"
    guard let date = reader.date(from: day) else { return day }
    let label = DateFormatter()
    label.timeZone = .gmt
    label.dateFormat = "MMM d"
    return label.string(from: date)
  }
  private func plotPoints(_ item: InsightHistorySeries, plot: NSRect, peak: Double) -> [NSPoint] {
    item.days.enumerated().compactMap { index, day in
      guard let value = self.value(day) else { return nil }
      // Preserve the date's x coordinate when bridging missing observations.
      let x = item.days.count == 1 ? plot.midX
        : plot.minX + plot.width * CGFloat(index) / CGFloat(item.days.count - 1)
      return NSPoint(x: x, y: plot.minY + plot.height * CGFloat(value / peak))
    }
  }

  /// Shape-preserving cubic interpolation. Weighted harmonic tangents smooth
  /// irregularly spaced observations without inventing peaks or negative usage.
  private static func smoothPath(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    path.lineWidth = 2
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 1 else { return path }
    let widths = zip(points, points.dropFirst()).map { $1.x - $0.x }
    let slopes = zip(points, points.dropFirst()).enumerated().map { index, pair in
      (pair.1.y - pair.0.y) / widths[index]
    }
    var tangents = [CGFloat](repeating: 0, count: points.count)
    tangents[0] = slopes[0]
    tangents[points.count - 1] = slopes[slopes.count - 1]
    if points.count > 2 {
      for index in 1..<(points.count - 1) {
        let before = slopes[index - 1], after = slopes[index]
        guard (before > 0 && after > 0) || (before < 0 && after < 0) else { continue }
        let w1 = 2 * widths[index] + widths[index - 1]
        let w2 = widths[index] + 2 * widths[index - 1]
        tangents[index] = (w1 + w2) / (w1 / before + w2 / after)
      }
    }
    for index in 0..<(points.count - 1) {
      let start = points[index], end = points[index + 1], third = widths[index] / 3
      path.curve(to: end,
        controlPoint1: NSPoint(x: start.x + third, y: start.y + tangents[index] * third),
        controlPoint2: NSPoint(x: end.x - third, y: end.y - tangents[index + 1] * third))
    }
    return path
  }

  static func validateCurvesForSelfTest() -> Bool {
    let days = [
      InsightHistoryDay(day: "2026-10-01", tokens: 0, costUSD: 0),
      InsightHistoryDay(day: "2026-10-02", tokens: nil, costUSD: nil),
      InsightHistoryDay(day: "2026-10-03", tokens: 40, costUSD: 4),
      InsightHistoryDay(day: "2026-10-04", tokens: 100, costUSD: nil),
      InsightHistoryDay(day: "2026-10-05", tokens: 20, costUSD: 2),
      InsightHistoryDay(day: "2026-10-06", tokens: 20, costUSD: 2),
      InsightHistoryDay(day: "2026-10-07", tokens: nil, costUSD: nil),
    ]
    let series = InsightHistorySeries(provider: .grok, days: days, coveredDays: 5,
      requestedDays: days.count, available: true)
    let plot = NSRect(x: 0, y: 0, width: 600, height: 100)
    for metric in [InsightDashboardView.Metric.tokens, .cost] {
      let view = InsightTrendView(series: [series], metric: metric)
      let points = view.plotPoints(series, plot: plot, peak: metric == .tokens ? 100 : 10)
      guard points.count == (metric == .tokens ? 5 : 4), points.first == .zero,
        points[1].x == 200, points.last?.x == 500 else { return false }
      let path = Self.smoothPath(points)
      guard path.elementCount == points.count else { return false }
      // Every adjacent pair, including those separated by gaps, is joined by
      // one cubic. Sample the curves to catch overshoot, undershoot or loops.
      for index in 1..<path.elementCount {
        var controls = [NSPoint](repeating: .zero, count: 3)
        guard path.element(at: index, associatedPoints: &controls) == .cubicCurveTo else { return false }
        let a = points[index - 1], b = points[index]
        guard controls[2] == b else { return false }
        for step in 0...100 {
          let t = CGFloat(step) / 100, u = 1 - t
          let x = u*u*u*a.x + 3*u*u*t*controls[0].x + 3*u*t*t*controls[1].x + t*t*t*b.x
          let y = u*u*u*a.y + 3*u*u*t*controls[0].y + 3*u*t*t*controls[1].y + t*t*t*b.y
          guard x >= a.x - 0.001 && x <= b.x + 0.001,
            y >= min(a.y, b.y) - 0.001 && y <= max(a.y, b.y) + 0.001 else { return false }
        }
      }
    }
    // Every supported range fills its heatmap width, including a single day,
    // and hover targets follow the resized cells rather than the old 8pt cap.
    for count in [1, 7, 30, 90] {
      for width in [CGFloat(240), 600] {
        let layout = UsageHeatmapView.layout(dayCount: count, width: width)
        let used = layout.cell * CGFloat(count) + layout.gap * CGFloat(count - 1)
        guard abs(used - width) < 0.001,
          UsageHeatmapView.cellIndex(at: width - layout.cell / 2, dayCount: count, width: width) == count - 1,
          UsageHeatmapView.cellIndex(at: -1, dayCount: count, width: width) == nil else { return false }
      }
    }
    let today = InsightHistorySeries(provider: .openAI,
      days: [InsightHistoryDay(day: "2026-10-19", tokens: 20_800_000, costUSD: nil)],
      coveredDays: 1, requestedDays: 1, available: true)
    let todayView = InsightTrendView(series: [today], metric: .tokens)
    guard todayView.isSingleDay, todayView.title.contains("Today's"),
      todayView.hourly.isEmpty, todayView.scale.maximum > 0,
      !InsightTrendView(series: [series], metric: .tokens).isSingleDay else { return false }
    let start = Calendar.current.startOfDay(for: Date())
    let hourly = HourlyUsageHistory(provider: .openAI, dayStart: start,
      observedAt: start.addingTimeInterval(5400), hours: [
        HourlyUsagePoint(start: start, tokens: 100, costUSD: 0.001),
        HourlyUsagePoint(start: start.addingTimeInterval(3600), tokens: 200, costUSD: nil),
      ])
    let hourlyView = InsightTrendView(series: [today], metric: .tokens, hourly: [hourly])
    let costView = InsightTrendView(series: [today], metric: .cost, hourly: [hourly])
    guard hourlyView.title == "Today's hourly processed tokens",
      hourlyView.scale.maximum > 200, hourlyView.scale.maximum < 1000,
      costView.scale.maximum > 0.001, costView.scale.maximum < 0.01 else { return false }
    return Self.smoothPath([]).elementCount == 0
      && Self.smoothPath([.zero]).elementCount == 1
  }

  override func mouseMoved(with event: NSEvent) {
    let point = self.convert(event.locationInWindow, from: nil)
    let plot = self.plotRect(scale: self.scale)
    if self.isSingleDay {
      guard let reference = self.hourly.max(by: { $0.observedAt < $1.observedAt }) else { return }
      let fraction = max(0, min(1, (point.x - plot.minX) / plot.width))
      let date = reference.dayStart.addingTimeInterval(
        reference.observedAt.timeIntervalSince(reference.dayStart) * Double(fraction))
      self.toolTip = self.hourly.compactMap { history in
        guard let hour = history.hours.last(where: { $0.start <= date }) else { return nil }
        let end = min(hour.start.addingTimeInterval(3600), history.observedAt)
        let partial = end < hour.start.addingTimeInterval(3600) ? " (partial hour)" : ""
        let value = self.hourValue(hour).map(self.axisValue) ?? "Price unavailable"
        return "\(self.providerNames[history.provider] ?? history.provider.displayName): \(value) · \(Self.timeLabel(hour.start)) \(TimeZone.current.abbreviation(for: hour.start) ?? "")–\(Self.timeLabel(end))\(partial)"
      }.joined(separator: "\n")
      return
    }
    guard let days = self.series.max(by: { $0.days.count < $1.days.count })?.days, !days.isEmpty else { return }
    let fraction = max(0, min(1, (point.x - plot.minX) / plot.width))
    let index = Int((fraction * CGFloat(days.count - 1)).rounded())
    self.toolTip = ([days[index].day] + self.series.compactMap { series in
      guard series.days.indices.contains(index) else { return nil }
      let day = series.days[index]
      let text = self.value(day).map { self.metric == .tokens ? DashboardFormat.tokens(day.tokens ?? 0) + " tokens" : "≈ " + DashboardFormat.money($0) } ?? "unavailable"
      return series.provider.displayName + ": " + text
    }).joined(separator: "\n")
  }
}
