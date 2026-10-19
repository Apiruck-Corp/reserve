import Foundation
import Testing
@testable import ReserveCore

struct InsightChartScaleTests {
  @Test func selectedPeriodAndProviderDetermineTheVisibleScale() {
    let today = InsightChartScale(values: [20_800_000])
    let month = InsightChartScale(values: [20_800_000, 2_000_000_000])
    #expect(today.maximum > 20_800_000)
    #expect(today.maximum <= 30_000_000)
    #expect(month.maximum > 2_000_000_000)
    #expect(today.maximum < month.maximum)
    #expect(today.ticks.first == 0 && today.ticks.last == today.maximum)
    #expect(today.ticks.count >= 4 && today.ticks.count <= 7)
  }

  @Test func zeroUnknownAndSmallPriceReadingsHaveUsableAxes() {
    let empty = InsightChartScale(values: [.nan, .infinity, -1])
    let zero = InsightChartScale(values: [0])
    #expect(empty == zero)
    #expect(zero.maximum > 0)
    let cents = InsightChartScale(values: [0.03], minimumStep: 0.01)
    #expect(cents.maximum > 0.03 && cents.maximum < 0.1)
    #expect(cents.ticks.allSatisfy { $0.isFinite && $0 >= 0 })
    let fraction = InsightChartScale(values: [0.00003], minimumStep: 0.000001)
    #expect(fraction.maximum > 0.00003 && fraction.maximum < 0.0001)
    let extreme = InsightChartScale(values: [.greatestFiniteMagnitude])
    #expect(extreme.maximum.isFinite)
    #expect(extreme.ticks.allSatisfy { $0.isFinite })
  }
}
