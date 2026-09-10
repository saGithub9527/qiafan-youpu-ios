import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class QFAppleAuthorization: NSObject, ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding
{
  private var continuation: CheckedContinuation<String, Error>?
  private var controller: ASAuthorizationController?
  private var state: String?
  private var anchor: UIWindow?

  func authorize() async throws -> String {
    guard continuation == nil else { throw QFAPIError(code: 40900, message: "Apple 授权正在进行。") }
    guard
      let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
        .filter({ $0.activationState == .foregroundActive }).flatMap({ $0.windows }).first(
          where: \.isKeyWindow)
    else { throw QFAPIError(code: 50300, message: "当前无法展示 Apple 授权，请稍后重试。") }
    anchor = window
    let state = try QFCredentials.generate()
    self.state = state
    let request = ASAuthorizationAppleIDProvider().createRequest()
    request.state = state
    // No email/name scope is requested: the API contract only needs the verified Apple identity.
    return try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let controller = ASAuthorizationController(authorizationRequests: [request])
      self.controller = controller
      controller.delegate = self
      controller.presentationContextProvider = self
      controller.performRequests()
    }
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    anchor ?? ASPresentationAnchor()
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      credential.state == state,
      let data = credential.authorizationCode,
      let code = String(data: data, encoding: .utf8), !code.isEmpty
    else {
      complete(.failure(QFAPIError(code: 40100, message: "Apple 授权结果无效，请重新尝试。")))
      return
    }
    complete(.success(code))
  }

  func authorizationController(
    controller: ASAuthorizationController, didCompleteWithError error: Error
  ) {
    complete(.failure(error))
  }

  private func complete(_ result: Result<String, Error>) {
    let pending = continuation
    continuation = nil
    controller = nil
    state = nil
    anchor = nil
    pending?.resume(with: result)
  }
}
