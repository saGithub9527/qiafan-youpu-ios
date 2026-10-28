import XCTest
@testable import QiafanYoupu

final class QFProactiveSpeechScheduleTests: XCTestCase {
  private func activeSchedule() -> QFProactiveSpeechSchedule {
    var value = QFProactiveSpeechSchedule()
    value.bind("account-a/en", at: 0)
    value.setForeground(true, at: 0)
    return value
  }

  func testFirstUtteranceWaitsTheFullFiveMinutes() {
    var value = activeSchedule()
    XCTAssertFalse(value.claim(at: 299.999, permitted: true))
    XCTAssertTrue(value.claim(at: 300, permitted: true))
    XCTAssertFalse(value.claim(at: 300.001, permitted: true))
    XCTAssertTrue(value.claim(at: 600, permitted: true))
  }

  func testSameBindingRefreshOrTabChangeCannotRestartOrBypassDeadline() {
    var value = activeSchedule()
    value.bind("account-a/en", at: 250)
    value.setForeground(true, at: 250)
    XCTAssertEqual(value.nextDeadline, 300)
    XCTAssertFalse(value.claim(at: 299, permitted: true))
    XCTAssertTrue(value.claim(at: 300, permitted: true))
  }

  func testSuppressedGreetingIsConsumedRatherThanQueuedForTheFormToClose() {
    var value = activeSchedule()
    XCTAssertFalse(value.claim(at: 300, permitted: false))
    XCTAssertFalse(value.claim(at: 301, permitted: true))
    XCTAssertTrue(value.claim(at: 600, permitted: true))
  }

  func testShortBackgroundRetainsRemainingInterval() {
    var value = activeSchedule()
    value.setForeground(false, at: 100)
    XCTAssertNil(value.nextDeadline)
    XCTAssertFalse(value.claim(at: 150, permitted: true))
    value.setForeground(true, at: 200)
    XCTAssertEqual(value.nextDeadline, 300)
    XCTAssertFalse(value.claim(at: 299, permitted: true))
    XCTAssertTrue(value.claim(at: 300, permitted: true))
  }

  func testReturningAfterMissedDeadlineWaitsAgainWithoutBacklog() {
    var value = activeSchedule()
    value.setForeground(false, at: 100)
    value.setForeground(true, at: 1_000)
    XCTAssertFalse(value.claim(at: 1_000, permitted: true))
    XCTAssertFalse(value.claim(at: 1_299.999, permitted: true))
    XCTAssertTrue(value.claim(at: 1_300, permitted: true))
  }

  func testAudioInterruptionDoesNotResumeAMissedGreeting() {
    var value = activeSchedule()
    value.discardMissed(at: 310)
    XCTAssertFalse(value.claim(at: 310, permitted: true))
    XCTAssertTrue(value.claim(at: 610, permitted: true))
  }

  func testAccountOrLanguageChangeCancelsTheOldDeadline() {
    var value = activeSchedule()
    value.bind("account-a/ja", at: 299)
    XCTAssertFalse(value.claim(at: 300, permitted: true))
    XCTAssertTrue(value.claim(at: 599, permitted: true))
    value.bind("account-b/ja", at: 600)
    XCTAssertFalse(value.claim(at: 899.999, permitted: true))
    XCTAssertTrue(value.claim(at: 900, permitted: true))
  }

  func testAccessLossOrDisabledPreferenceCancelsAllEligibility() {
    var value = activeSchedule()
    value.bind(nil, at: 299)
    XCTAssertNil(value.nextDeadline)
    XCTAssertFalse(value.claim(at: 1_000, permitted: true))
    value.bind("account-a/en", at: 1_000)
    XCTAssertFalse(value.claim(at: 1_000, permitted: true))
    XCTAssertTrue(value.claim(at: 1_300, permitted: true))
  }

  func testLateWakeProducesAtMostOneUtteranceAndNoCatchupLoop() {
    var value = activeSchedule()
    XCTAssertTrue(value.claim(at: 1_000, permitted: true))
    for time in [1_000.0, 1_001, 1_200, 1_299.999] {
      XCTAssertFalse(value.claim(at: time, permitted: true))
    }
    XCTAssertTrue(value.claim(at: 1_300, permitted: true))
  }

  func testVoicePreferenceIsAccountScopedAndForgettingOneScopePreservesTheOther() throws {
    let suite = "QFProactiveSpeechScheduleTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(QFProactiveSpeechPreferences.isEnabled(scope: "a", defaults: defaults))
    QFProactiveSpeechPreferences.setEnabled(false, scope: "a", defaults: defaults)
    XCTAssertFalse(QFProactiveSpeechPreferences.isEnabled(scope: "a", defaults: defaults))
    XCTAssertTrue(QFProactiveSpeechPreferences.isEnabled(scope: "b", defaults: defaults))
    QFProactiveSpeechPreferences.setEnabled(false, scope: "b", defaults: defaults)
    QFProactiveSpeechPreferences.forget(scope: "a", defaults: defaults)
    XCTAssertTrue(QFProactiveSpeechPreferences.isEnabled(scope: "a", defaults: defaults))
    XCTAssertFalse(QFProactiveSpeechPreferences.isEnabled(scope: "b", defaults: defaults))
    XCTAssertNil(defaults.data(forKey: "qfyp.user.settings.v1"))
  }

  func testMissingCurrentLanguageContentDoesNotFallBackToEnglishSpeech() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("QFProactiveSpeech-" + UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let info = try PropertyListSerialization.data(fromPropertyList: [
      "CFBundleIdentifier": "com.qiafan.unit-empty-speech", "CFBundlePackageType": "BNDL"
    ], format: .xml, options: 0)
    try info.write(to: folder.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: folder))
    XCTAssertNil(QFProactiveSpeechContext.greeting(for: .russian, bundle: bundle))
    XCTAssertNotNil(QFProactiveSpeechContext.greeting(for: .english, bundle: bundle))
  }
}
