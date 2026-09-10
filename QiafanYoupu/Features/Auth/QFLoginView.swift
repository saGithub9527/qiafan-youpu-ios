import SwiftUI

@MainActor
struct QFLoginView: View {
  let onClose: () -> Void

  init(onClose: @escaping () -> Void) {
    self.onClose = onClose
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var agreementChecked = false
  @State private var showsNotice = false
  @State private var pendingMethod: LoginMethod?
  @EnvironmentObject private var app: QFAppSession
  @State private var showsError = false
  @State private var errorMessage = ""
  @State private var authorizingApple = false
  @State private var performingLogin = false
  @State private var appleAuthorization = QFAppleAuthorization()
  @State private var loginTask: Task<Void, Never>?
  @State private var document: QFAuthDocument?

  private enum LoginMethod {
    case quick
    case apple
  }

  var body: some View {
    ZStack {
      GeometryReader { geometry in
        content(width: geometry.size.width)
      }
      .allowsHitTesting(!showsNotice)
      .accessibilityHidden(showsNotice)

      if showsNotice {
        QFSafetyNoticeView(
          checked: persistedAgreement,
          onReadDocument: { document = $0 },
          onContinue: continueAfterNotice,
          onDecline: declineNotice
        )
        .transition(.asymmetric(insertion: .identity, removal: .opacity))
        .zIndex(1)
      }
    }
    .background(Color(hex: 0xF8F8F2).ignoresSafeArea())
    .interactiveDismissDisabled(showsNotice || performingLogin)
    .fullScreenCover(item: $document) { document in
      QFAuthAgreementDocument(document: document)
    }
    .alert("登录提示", isPresented: $showsError) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
    .onAppear { reloadAgreement() }
    .onChange(of: app.configuration?.consentRevision) { _ in reloadAgreement() }

  }

  private func content(width: CGFloat) -> some View {
    VStack(spacing: 12) {
      HStack {
        Button {
          pendingMethod = nil
          loginTask?.cancel()
          onClose()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 21, weight: .light))
            .foregroundColor(Color(hex: 0x5E6C69))
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.white))
        }
        .buttonStyle(.plain)
        .disabled(performingLogin)
        .accessibilityLabel("关闭登录")
        .accessibilityIdentifier("login.close")
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.top, 10)

      ScrollView(showsIndicators: false) {
        VStack(spacing: 0) {
          QFAuthChefHero()
            .frame(width: max(1, min(320, (width - 60) * 0.69)))
          Text("恰饭有谱")
            .font(.system(size: 32, weight: .bold))
            .foregroundColor(QFTheme.text)
            .padding(.top, 19)
          Text("收藏世界风味，记录每一餐")
            .font(.system(size: 15))
            .foregroundColor(QFTheme.secondary)
            .padding(.top, 12)
          loginButtons.padding(.top, 70)
          if app.isLoggingIn || authorizingApple {
            ProgressView(authorizingApple ? "正在等待 Apple 授权…" : "正在登录…")
              .font(.footnote).padding(.top, 12)
          } else if app.configurationError != nil {
            Button("重试加载启动配置") { Task { await app.loadConfiguration() } }
              .font(.footnote).foregroundColor(QFTheme.green).padding(.top, 12)
          }
          QFAuthAgreementRow(
            checked: persistedAgreement,
            noticeStyle: false,
            identifier: "login.agreement",
            onReadDocument: { document = $0 }
          )
          .padding(.top, 88)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.top, 23)
        .padding(.bottom, 12)
      }
      .padding(.bottom, 12)
    }
  }

  private var loginButtons: some View {
    VStack(spacing: 16) {
      Button {
        requestLogin(.quick)
      } label: {
        Text("快速登录")
          .font(.system(size: 20, weight: .semibold))
      }
      .buttonStyle(QFAuthPrimaryButtonStyle())
      .accessibilityIdentifier("login.quick")
      .accessibilityValue(
        app.loadingConfiguration
          ? "配置加载中" : (app.loginAvailability(apple: false) == nil ? "可用" : "暂不可用"))

      Button {
        requestLogin(.apple)
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "apple.logo")
            .font(.system(size: 24, weight: .medium))
          Text("通过 Apple 登录")
            .font(.system(size: 22, weight: .medium))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 55)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("login.apple")
    }
    .disabled(performingLogin)
  }

  private var persistedAgreement: Binding<Bool> {
    Binding(
      get: { agreementChecked },
      set: { checked in
        agreementChecked = checked
        QFAuthConsentStore.setAgreementChecked(
          checked, revision: app.configuration?.consentRevision ?? "ui-placeholder-v1")
      }
    )
  }

  private func requestLogin(_ method: LoginMethod) {
    guard !showsNotice, !showsError, !app.isLoggingIn, !authorizingApple, document == nil else {
      return
    }
    if agreementChecked {
      beginLogin(method)
    } else {
      pendingMethod = method
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
        showsNotice = true
      }
    }
  }

  private func continueAfterNotice() {
    guard showsNotice, agreementChecked else { return }
    let method = pendingMethod
    pendingMethod = nil
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
      showsNotice = false
    }
    if let method { beginLogin(method) }
  }

  private func declineNotice() {
    // QFSafetyNoticeView has already set the shared binding to false and persisted it.
    pendingMethod = nil
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
      showsNotice = false
    }
  }
  private func reloadAgreement() {
    guard let revision = app.configuration?.consentRevision else {
      agreementChecked = false
      return
    }
    agreementChecked = QFAuthConsentStore.isAgreementChecked(revision: revision)
  }

  private func beginLogin(_ method: LoginMethod) {
    guard agreementChecked, !performingLogin else { return }
    if let reason = app.loginAvailability(apple: method == .apple) {
      errorMessage = reason
      showsError = true
      return
    }
    performingLogin = true
    loginTask = Task {
      defer { performingLogin = false }
      do {
        var code: String?
        if method == .apple {
          authorizingApple = true
          defer { authorizingApple = false }
          code = try await appleAuthorization.authorize()
        }
        guard !Task.isCancelled else { return }
        try await app.login(authorizationCode: code, agreementAccepted: agreementChecked)
        onClose()
      } catch is CancellationError {
      } catch {
        if (error as NSError).domain == "com.apple.AuthenticationServices.AuthorizationError",
          (error as NSError).code == 1001
        {
          return
        }
        errorMessage = error.localizedDescription
        showsError = true
      }
    }
  }

}
