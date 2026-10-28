import XCTest
@testable import QiafanYoupu

@MainActor
final class QFInitialLanguageTests: XCTestCase {
  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "QFInitialLanguageTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
  }

  func testFirstUseIsEnglishWithoutWritingAnExplicitPreference() {
    withDefaults { defaults in
      XCTAssertEqual(QFLocalSettingsStore.current(defaults: defaults).interfaceLanguage, "en")
      XCTAssertNil(defaults.data(forKey: "qfyp.user.settings.v1"))
    }
  }

  func testExistingLanguageSurvivesReadingAndRetainsOriginalBytes() throws {
    try withDefaults { defaults in
      for code in ["zh-Hans", "zh-Hant", "en", "ja", "ko", "ru", "es", "fr", "de", "pt-BR"] {
        let fixture: [String: Any] = ["schemaVersion": 1, "interfaceLanguage": code,
          "planReminders": false, "workAndContributionUpdates": true]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        defaults.set(data, forKey: "qfyp.user.settings.v1")
        let settings = QFLocalSettingsStore.current(defaults: defaults)
        XCTAssertEqual(settings.interfaceLanguage, code)
        XCTAssertFalse(settings.planReminders)
        XCTAssertEqual(defaults.data(forKey: "qfyp.user.settings.v1"), data)
      }
    }
  }

  func testAbsentScopeDoesNotReadOrOverwriteAnotherScopesLanguage() {
    withDefaults { defaults in
      QFLocalSettingsStore.saveInterfaceLanguage("ja", defaults: defaults, scope: "account-a")
      XCTAssertEqual(QFLocalSettingsStore.current(defaults: defaults, scope: "account-b").interfaceLanguage, "en")
      XCTAssertEqual(QFLocalSettingsStore.current(defaults: defaults, scope: "account-a").interfaceLanguage, "ja")
      XCTAssertNil(defaults.data(forKey: "qfyp.user.settings.v1.account-b"))
    }
  }

  func testUnsupportedSettingsSchemaIsNotOverwrittenByDefaultRead() {
    withDefaults { defaults in
      let data = Data(#"{"schemaVersion":99,"interfaceLanguage":"ko","planReminders":false,"workAndContributionUpdates":false}"#.utf8)
      defaults.set(data, forKey: "qfyp.user.settings.v1")
      XCTAssertEqual(QFLocalSettingsStore.current(defaults: defaults).interfaceLanguage, "en")
      XCTAssertEqual(defaults.data(forKey: "qfyp.user.settings.v1"), data)
    }
  }

  func testLegacyServerPayloadWithoutLanguageKeepsOtherSettingsAndDefaultsEnglish() throws {
    let data = Data(#"{"theme":"dark","planReminders":false,"workAndContributionUpdates":true}"#.utf8)
    let settings = try JSONDecoder().decode(QFUserSettings.self, from: data)
    XCTAssertEqual(settings.interfaceLanguage, "en")
    XCTAssertEqual(settings.theme, "dark")
    XCTAssertFalse(settings.planReminders)
    XCTAssertTrue(settings.workAndContributionUpdates)
  }
}
