import Foundation
import XCTest

@testable import QiafanYoupu

final class QFConsentStoreTests: XCTestCase {
  private let key = "qfyp.login.consent"
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "QFConsentStoreTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    suiteName = nil
    try super.tearDownWithError()
  }

  func testReadsExistingObjectiveCDictionary() {
    // NSNumber/NSDictionary values model the record written by the original Objective-C store.
    let record: NSDictionary = [
      "schemaVersion": NSNumber(value: 1),
      "loginAgreementChecked": NSNumber(value: true),
      "updatedAt": "2026-09-10T08:00:00Z",
      "uiDocumentRevision": "ui-placeholder-v1",
      "uiOnly": NSNumber(value: true),
    ]
    defaults.set(record, forKey: key)

    XCTAssertTrue(QFAuthConsentStore.isAgreementChecked(defaults: defaults))
  }

  func testPersistsBothCheckAndUncheckWithSameSchema() throws {
    QFAuthConsentStore.setAgreementChecked(true, defaults: defaults)
    XCTAssertTrue(QFAuthConsentStore.isAgreementChecked(defaults: defaults))

    QFAuthConsentStore.setAgreementChecked(false, defaults: defaults)
    XCTAssertFalse(QFAuthConsentStore.isAgreementChecked(defaults: defaults))
    let record = try XCTUnwrap(defaults.dictionary(forKey: key))
    XCTAssertEqual(record["schemaVersion"] as? Int, 1)
    XCTAssertEqual(record["loginAgreementChecked"] as? Bool, false)
    XCTAssertEqual(record["uiDocumentRevision"] as? String, "ui-placeholder-v1")
    XCTAssertEqual(record["uiOnly"] as? Bool, true)
    XCTAssertNotNil(
      ISO8601DateFormatter().date(from: try XCTUnwrap(record["updatedAt"] as? String)))
    XCTAssertNil(record["privacyPolicyVersion"])
    XCTAssertNil(record["userAgreementVersion"])
  }

  func testMissingRecordIsUnchecked() {
    XCTAssertNil(defaults.object(forKey: key))
    XCTAssertFalse(QFAuthConsentStore.isAgreementChecked(defaults: defaults))
  }

  func testWrongRecordTypeIsUnchecked() {
    defaults.set("true", forKey: key)
    XCTAssertFalse(QFAuthConsentStore.isAgreementChecked(defaults: defaults))
  }

  func testWrongCheckboxTypesAreRejectedAndRepairedInProvidedSuite() throws {
    let invalidValues: [Any] = ["true", NSNumber(value: 1)]
    for invalidValue in invalidValues {
      var record = validRecord
      record["loginAgreementChecked"] = invalidValue
      defaults.set(record, forKey: key)

      XCTAssertFalse(QFAuthConsentStore.isAgreementChecked(defaults: defaults))
      let repaired = try XCTUnwrap(defaults.dictionary(forKey: key))
      XCTAssertEqual(repaired["loginAgreementChecked"] as? Bool, false)
    }
  }

  func testOldRevisionIsUncheckedAndRepairedInProvidedSuite() throws {
    var record = validRecord
    record["uiDocumentRevision"] = "ui-placeholder-v0"
    defaults.set(record, forKey: key)

    XCTAssertFalse(QFAuthConsentStore.isAgreementChecked(defaults: defaults))
    let repaired = try XCTUnwrap(defaults.dictionary(forKey: key))
    XCTAssertEqual(repaired["loginAgreementChecked"] as? Bool, false)
    XCTAssertEqual(repaired["uiDocumentRevision"] as? String, "ui-placeholder-v1")
  }

  func testCorruptSchemaAndTimestampAreUnchecked() {
    var record = validRecord
    record["schemaVersion"] = "1"
    defaults.set(record, forKey: key)
    XCTAssertFalse(QFAuthConsentStore.isAgreementChecked(defaults: defaults))

    record = validRecord
    record["updatedAt"] = "not-an-ISO8601-date"
    defaults.set(record, forKey: key)
    XCTAssertFalse(QFAuthConsentStore.isAgreementChecked(defaults: defaults))
  }

  private var validRecord: [String: Any] {
    [
      "schemaVersion": 1,
      "loginAgreementChecked": true,
      "updatedAt": "2026-09-10T08:00:00Z",
      "uiDocumentRevision": "ui-placeholder-v1",
      "uiOnly": true,
    ]
  }
}
