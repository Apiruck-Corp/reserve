import Foundation

/// A zero-based axis scoped to the visible measurements, with readable ticks
/// and headroom so a peak is not drawn against the top edge of the chart.
public struct InsightChartScale: Equatable, Sendable {
  public let maximum: Double
  public let ticks: [Double]

  public init(values: [Double], minimumStep: Double = 1) {
    let minimum = minimumStep.isFinite && minimumStep > 0 ? minimumStep : 1
    let peak = values.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
    let target = max(minimum, peak)
    let magnitude = pow(10, floor(log10(target / 4)))
    let candidates = [1.0, 2, 2.5, 5, 10].map { magnitude * $0 }
    let step = max(minimum, candidates.min { abs($0 - target / 4) < abs($1 - target / 4) } ?? minimum)
    let padded = target * 1.1
    let upper = ceil(padded / step) * step
    if upper.isFinite, upper > peak, step.isFinite, step > 0 {
      self.maximum = upper
      let count = Int((upper / step).rounded())
      self.ticks = (0...count).map { Double($0) * step }
    } else {
      // An extreme finite input must not turn geometry or tick labels into NaN.
      self.maximum = target
      self.ticks = (0...4).map { target * (Double($0) / 4) }
    }
  }
}
