import CryptoKit
import Foundation

struct QFAPIEnvelope<Value: Decodable>: Decodable {
  let code: Int
  let message: String
  let requestId: String?
  let data: Value?
}

struct QFServerConfig: Codable, Equatable {
  let appName: String
  let serviceRegion: String
  let loginMethods: LoginMethods
  let agreements: Agreements
  var assistantCapabilities: AssistantCapabilities? = nil

  struct AssistantCapabilities: Codable, Equatable {
    let chatWebConsent: Bool
    var chatProviders: [String]? = nil
  }

  struct LoginMethods: Codable, Equatable {
    let quick: Bool
    let apple: Bool
  }
  struct Agreements: Codable, Equatable {
    let userAgreement: String?
    let privacyPolicy: String?
    let userAgreementUrl: String?
    let privacyPolicyUrl: String?
    let imageLicenseUrl: String?
    let imageRightsUrl: String?

    var isAvailable: Bool {
      [userAgreement, privacyPolicy].allSatisfy {
        !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      }
    }
  }

  var consentRevision: String? {
    guard agreements.isAvailable else { return nil }
    // Hash ordered strings, independent of JSON dictionary ordering. Sent only as local cache metadata.
    let content =
      "\(agreements.userAgreement?.utf8.count ?? 0):\(agreements.userAgreement ?? "")\(agreements.privacyPolicy ?? "")"
    return "server-"
      + SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct QFUserSettings: Codable, Equatable {
  let theme: String
  let interfaceLanguage: String
  let planReminders: Bool
  let workAndContributionUpdates: Bool

  private enum CodingKeys: String, CodingKey {
    case theme, interfaceLanguage, planReminders, workAndContributionUpdates
  }

  init(
    theme: String, interfaceLanguage: String, planReminders: Bool,
    workAndContributionUpdates: Bool
  ) {
    self.theme = theme
    self.interfaceLanguage = interfaceLanguage
    self.planReminders = planReminders
    self.workAndContributionUpdates = workAndContributionUpdates
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    theme = try values.decode(String.self, forKey: .theme)
    // Language is device-local. This default only keeps older/newer settings payloads compatible;
    // callers always merge the current local language before presenting settings.
    interfaceLanguage = try values.decodeIfPresent(String.self, forKey: .interfaceLanguage) ?? "zh-Hans"
    planReminders = try values.decode(Bool.self, forKey: .planReminders)
    workAndContributionUpdates = try values.decode(Bool.self, forKey: .workAndContributionUpdates)
  }
}

struct QFUserSettingsUpdate: Encodable {
  let planReminders: Bool
  let workAndContributionUpdates: Bool
}

struct QFProfileUpdate: Encodable {
  let nickname: String
  let countryCode: String?
  let regionCode: String?
  let bio: String?

  private enum CodingKeys: String, CodingKey {
    case nickname
    case countryCode
    case regionCode
    case bio
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(nickname, forKey: .nickname)
    try container.encode(countryCode, forKey: .countryCode)
    try container.encode(regionCode, forKey: .regionCode)
    try container.encode(bio, forKey: .bio)
  }
}

enum QFFeedbackCategory: String, CaseIterable, Codable {
  case bug = "BUG"
  case suggestion = "SUGGESTION"
  case account = "ACCOUNT"
  case other = "OTHER"

  var title: String {
    switch self {
    case .bug: return "问题"
    case .suggestion: return "建议"
    case .account: return "账号"
    case .other: return "其他"
    }
  }

  @MainActor
  func title(app: QFAppSession) -> String {
    switch self {
    case .bug: return app.text("问题", "Issue")
    case .suggestion: return app.text("建议", "Suggestion")
    case .account: return app.text("账号", "Account")
    case .other: return app.text("其他", "Other")
    }
  }
}

struct QFFeedbackRequest: Encodable {
  let category: QFFeedbackCategory
  let content: String
}

struct QFUserProfile: Codable, Equatable {
  let userId: String
  let systemAccount: String
  let boundAccount: String?
  let accountNameBound: Bool
  let passwordConfigured: Bool
  let nickname: String
  let avatarUrl: String?
  let countryCode: String?
  let regionCode: String?
  let bio: String?
  let appleBound: Bool
}

struct QFSessionTokens: Codable, Equatable {
  let accessToken: String
  let accessTokenExpiresIn: Int
  let refreshToken: String
  let refreshTokenExpiresIn: Int

  var isValid: Bool {
    [accessToken, refreshToken].allSatisfy(QFCredentials.isValid)
      && accessTokenExpiresIn > 0 && refreshTokenExpiresIn > 0
      && accessTokenExpiresIn <= 31_536_000 && refreshTokenExpiresIn <= 31_536_000
  }
}

struct QFLoginResult: Decodable {
  let session: QFSessionTokens
  let user: QFUserProfile
}
struct QFQuickLoginBody: Encodable {
  let deviceCredential: String
  let agreementAccepted: Bool
}
struct QFAppleLoginBody: Encodable {
  let authorizationCode: String
  let deviceCredential: String
  let agreementAccepted: Bool
}
struct QFRefreshBody: Encodable { let refreshToken: String }
struct QFEmptyResponse: Decodable {}

struct QFAPIError: LocalizedError {
  let code: Int
  let message: String
  var requestId: String? = nil
  var errorDescription: String? { message }
}
