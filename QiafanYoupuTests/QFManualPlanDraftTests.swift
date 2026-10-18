import Foundation
import XCTest
@testable import QiafanYoupu

final class QFManualPlanDraftTests: XCTestCase {
  private func recipe(_ id: String = "recipe-a") -> QFManualPlanDraft.Recipe {
    .init(id: id, title: "测试菜", subtitle: "", mediaId: nil, minutes: 10, language: "zh-Hans")
  }
  func testSingleDayIgnoresOldRangeAndWeekdays() throws {
    var draft = QFManualPlanDraft(date: "2026-09-30")
    draft.endDate = "2026-11-20"; draft.repeats = true; draft.weekdays = [1]
    draft.recipes["LUNCH"] = [recipe()]
    let request = try draft.request(householdID: nil)
    XCTAssertEqual(request.startDate, request.endDate)
    XCTAssertEqual(request.weekdays, [])
    XCTAssertEqual(try draft.selectedDates(), ["2026-09-30"])
  }
  func testInclusiveRangeAndISOWeekdayAcrossMonthBoundary() throws {
    var draft = QFManualPlanDraft(date: "2026-09-28")
    draft.usesRange = true; draft.endDate = "2026-10-11"
    draft.repeats = true; draft.weekdays = [1, 7]
    XCTAssertEqual(try draft.selectedDates(), ["2026-09-28", "2026-10-04", "2026-10-05", "2026-10-11"])
  }
  func testCivilDatesRemainStableAcrossDST() throws {
    var draft = QFManualPlanDraft(date: "2026-10-31")
    draft.usesRange = true; draft.endDate = "2026-11-02"
    XCTAssertEqual(try draft.selectedDates(), ["2026-10-31", "2026-11-01", "2026-11-02"])
  }
  func testRangeLimitsAndInvalidDates() throws {
    var draft = QFManualPlanDraft(date: "2026-09-01")
    draft.usesRange = true; draft.endDate = "2026-10-12"
    XCTAssertEqual(try draft.selectedDates().count, 42)
    draft.endDate = "2026-10-13"; XCTAssertThrowsError(try draft.selectedDates())
    draft.endDate = "2026-08-31"; XCTAssertThrowsError(try draft.selectedDates())
    XCTAssertNil(QFManualPlanDraft.date("2026-02-30"))
    XCTAssertNil(QFManualPlanDraft.date("2026-9-1"))
  }
  func testRepeatCannotSilentlyProduceNoDates() {
    var draft = QFManualPlanDraft(date: "2026-09-30")
    draft.usesRange = true; draft.repeats = true
    XCTAssertThrowsError(try draft.selectedDates())
    draft.weekdays = [1]; XCTAssertThrowsError(try draft.selectedDates())
    draft.weekdays = [3, 3]; XCTAssertThrowsError(try draft.selectedDates())
    draft.weekdays = [0]; XCTAssertThrowsError(try draft.selectedDates())
  }
  func testMealValidationAndStablePendingReceiptRoundTrip() throws {
    var draft = QFManualPlanDraft(date: "2026-09-30")
    XCTAssertThrowsError(try draft.request(householdID: nil))
    draft.recipes["LUNCH"] = [recipe(), recipe()]
    XCTAssertThrowsError(try draft.request(householdID: nil))
    draft.recipes["LUNCH"] = [recipe()]
    draft.recipes["DINNER"] = [recipe("recipe-b")]
    draft.pending = .init(body: try draft.request(householdID: "family"), language: "ja")
    let restored = try JSONDecoder().decode(QFManualPlanDraft.self, from: JSONEncoder().encode(draft))
    XCTAssertEqual(restored, draft)
    XCTAssertEqual(restored.pending?.body.meals.count, 2)
    XCTAssertEqual(restored.pending?.body.householdId, "family")
    XCTAssertEqual(restored.pending?.language, "ja")
  }
}
