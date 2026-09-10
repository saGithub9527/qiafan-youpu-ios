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

  struct LoginMethods: Codable, Equatable {
    let quick: Bool
    let apple: Bool
  }
  struct Agreements: Codable, Equatable {
    let userAgreement: String?
    let privacyPolicy: String?
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
