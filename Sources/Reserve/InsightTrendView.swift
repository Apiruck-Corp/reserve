import AppKit
import ReserveCore

@MainActor
final class InsightTrendView: NSView {
  private let series: [InsightHistorySeries]
  private let metric: InsightDashboardView.Metric
  init(series: [InsightHistorySeries], metric: InsightDashboardView.Metric) {
    self.series = series; self.metric = metric
    super.init(frame: .zero)
    self.setAccessibilityElement(true)
    let title = metric == .tokens ? "Daily processed tokens by provider" : "Daily estimated API value by provider"
    self.setAccessibilityLabel(title + ". Smooth lines connect available days; missing days remain unavailable.")
    self.toolTip = "Smooth lines connect available days. Missing days remain unavailable."
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
  override func draw(_ dirtyRect: NSRect) {
    let plot = NSRect(x: 52, y: 26, width: max(1, self.bounds.width - 60), height: max(1, self.bounds.height - 40))
    let values = self.series.flatMap { $0.days.compactMap(self.value) }
    let peak = max(1, values.max() ?? 0)
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
    for step in 0...3 {
      let y = plot.minY + plot.height * CGFloat(step) / 3
      NSColor.separatorColor.setStroke()
      let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y)); line.stroke()
      let amount = peak * Double(step) / 3
      let title = self.metric == .tokens ? DashboardFormat.tokens(Int64(min(Double(Int64.max - 1024), amount))) : DashboardFormat.money(amount)
      (title as NSString).draw(at: NSPoint(x: 0, y: y - 6), withAttributes: attributes)
    }
    for item in self.series {
      let points = self.plotPoints(item, plot: plot, peak: peak)
      let path = Self.smoothPath(points)
      Self.color(item.provider).setStroke()
      path.stroke()
      // A single observation has no line to draw, so keep it visible as a dot.
      if points.count == 1, let point = points.first {
        Self.color(item.provider).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
      }
    }
    if values.isEmpty {
      let text = self.metric == .tokens ? "Daily history unavailable" : "Daily prices unavailable"
      (text as NSString).draw(at: NSPoint(x: plot.midX - 80, y: plot.midY), withAttributes: attributes)
    }
    if let days = self.series.first?.days, let first = days.first, let last = days.last {
      (first.day as NSString).draw(at: NSPoint(x: plot.minX, y: 3), withAttributes: attributes)
      let size = (last.day as NSString).size(withAttributes: attributes)
      (last.day as NSString).draw(at: NSPoint(x: plot.maxX - size.width, y: 3), withAttributes: attributes)
    }
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
    return Self.smoothPath([]).elementCount == 0
      && Self.smoothPath([.zero]).elementCount == 1
  }

  override func mouseMoved(with event: NSEvent) {
    let point = self.convert(event.locationInWindow, from: nil)
    guard let days = self.series.first?.days, !days.isEmpty else { return }
    let fraction = max(0, min(1, (point.x - 52) / max(1, self.bounds.width - 60)))
    let index = Int((fraction * CGFloat(days.count - 1)).rounded())
    self.toolTip = ([days[index].day] + self.series.compactMap { series in
      guard series.days.indices.contains(index) else { return nil }
      let day = series.days[index]
      let text = self.value(day).map { self.metric == .tokens ? DashboardFormat.tokens(day.tokens ?? 0) + " tokens" : "≈ " + DashboardFormat.money($0) } ?? "unavailable"
      return series.provider.displayName + ": " + text
    }).joined(separator: "\n")
  }
}
