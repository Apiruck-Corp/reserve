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
    self.setAccessibilityLabel(metric == .tokens ? "Daily processed tokens by provider" : "Daily estimated API value by provider")
    self.addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
  }
  required init?(coder: NSCoder) { nil }
  static func color(_ provider: ProviderID) -> NSColor {
    switch provider.kind {
    case .openAI: .systemBlue
    case .anthropic: .systemOrange
    case .grok: .systemPurple
    case .cursor: .systemTeal
    case .copilot: .systemPink
    case .gemini: .systemIndigo
    case .kimi: .systemYellow
    case .zai: .systemGreen
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
      let path = NSBezierPath(); path.lineWidth = 2
      var connected = false
      for (index, day) in item.days.enumerated() {
        guard let value = self.value(day) else { connected = false; continue }
        let x = item.days.count == 1 ? plot.midX : plot.minX + plot.width * CGFloat(index) / CGFloat(item.days.count - 1)
        let point = NSPoint(x: x, y: plot.minY + plot.height * CGFloat(value / peak))
        if connected { path.line(to: point) } else { path.move(to: point) }
        Self.color(item.provider).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
        connected = true
      }
      Self.color(item.provider).setStroke(); path.stroke()
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
