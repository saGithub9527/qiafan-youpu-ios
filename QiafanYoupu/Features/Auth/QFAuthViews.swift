import CoreFoundation
import Foundation
import SwiftUI

/// The same local UI choice used by the previous Objective-C screens, never an authentication record.
enum QFAuthConsentStore {
  private static let key = "qfyp.login.consent"

  static func isAgreementChecked(
    revision: String = "ui-placeholder-v1", defaults: UserDefaults = .standard
  ) -> Bool {
    guard let record = defaults.object(forKey: key) as? [String: Any] else {
      return false
    }
    guard let schema = record["schemaVersion"] as? NSNumber, schema.intValue == 1,
      let value = record["loginAgreementChecked"] as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID(),
      let timestamp = record["updatedAt"] as? String,
      ISO8601DateFormatter().date(from: timestamp) != nil,
      record["uiDocumentRevision"] as? String == revision
    else {
      setAgreementChecked(false, revision: revision, defaults: defaults)
      return false
    }
    return value.boolValue
  }

  static func setAgreementChecked(
    _ checked: Bool, revision: String = "ui-placeholder-v1", defaults: UserDefaults = .standard
  ) {
    let record: [String: Any] = [
      "schemaVersion": 1,
      "loginAgreementChecked": checked,
      "updatedAt": ISO8601DateFormatter().string(from: Date()),
      "uiDocumentRevision": revision,
      "uiOnly": true,
    ]
    // Formal document versions remain absent: no real agreement text has been supplied.
    defaults.set(record, forKey: key)
  }
}

enum QFAuthDocument: String, Identifiable {
  case privacy
  case terms

  var id: String { rawValue }
  var title: String { self == .privacy ? "隐私政策" : "用户协议" }
}

struct QFAuthAgreementDocument: View {
  let document: QFAuthDocument
  @EnvironmentObject private var app: QFAppSession
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          dismiss()
        } label: {
          Label("返回", systemImage: "chevron.left")
            .font(.system(size: 16))
            .frame(minHeight: 44)
        }
        .foregroundColor(QFTheme.green)
        .accessibilityIdentifier("agreement.back")
        Spacer()
        Text(document.title)
          .font(.system(size: 17, weight: .semibold))
        Spacer()
        Color.clear.frame(width: 60, height: 1)
      }
      .padding(.horizontal, 20)
      Divider().background(QFTheme.border)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text(document.title)
            .font(.system(size: 26, weight: .bold))
            .accessibilityAddTraits(.isHeader)
          if let text = document == .privacy
            ? app.configuration?.agreements.privacyPolicy
            : app.configuration?.agreements.userAgreement,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            Text(text)
          } else {
            Text("协议暂未配置，请稍后重试。")
          }

        }
        .font(.system(size: 17))
        .lineSpacing(7)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
      }
      .accessibilityIdentifier("agreement.document")
    }
    .foregroundColor(QFTheme.text)
    .background(QFTheme.background.ignoresSafeArea())
    .interactiveDismissDisabled()
  }
}

struct QFAuthAgreementRow: View {
  @Binding var checked: Bool
  let noticeStyle: Bool
  let identifier: String
  let onReadDocument: (QFAuthDocument) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      Button {
        checked.toggle()
      } label: {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
          .font(.system(size: 21))
          .foregroundColor(checked ? QFTheme.green : Color(hex: 0x93A18B))
          .frame(width: 34, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("我已阅读并同意隐私政策和用户协议")
      .accessibilityValue(checked ? "已勾选" : "未勾选")
      .accessibilityAddTraits(checked ? .isSelected : [])
      .accessibilityIdentifier(identifier)

      Text(agreementText)
        .font(.system(size: 13))
        .foregroundColor(QFTheme.secondary)
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("\(identifier).text")
        .environment(
          \.openURL,
          OpenURLAction { url in
            if url.scheme == "qfyp-document",
              let document = QFAuthDocument(rawValue: url.host ?? "")
            {
              onReadDocument(document)
            }
            return .handled
          })
    }
    .frame(minHeight: 55, alignment: .leading)
  }

  private var agreementText: AttributedString {
    let copy =
      noticeStyle
      ? "我已阅读并同意 《用户协议》\n和《隐私政策》"
      : "我已阅读并同意《隐私政策》和《用户协议》"
    var text = AttributedString(copy)
    for document in [QFAuthDocument.privacy, .terms] {
      if let range = text.range(of: "《\(document.title)》") {
        text[range].link = URL(string: "qfyp-document://\(document.rawValue)")
        text[range].foregroundColor = noticeStyle ? Color(hex: 0xA83212) : QFTheme.green
      }
    }
    return text
  }
}

struct QFAuthLoadingButtonLabel: View {
  let title: String
  var isLoading = false
  var systemImage: String?
  var tint: Color = .white

  var body: some View {
    HStack(spacing: 9) {
      if isLoading {
        ProgressView()
          .progressViewStyle(CircularProgressViewStyle(tint: tint))
          .accessibilityHidden(true)
      }
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 24, weight: .medium))
      }
      Text(title)
    }
  }
}

struct QFAuthPrimaryButtonStyle: ButtonStyle {
  var isLoading = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 17, weight: .semibold))
      .foregroundColor(isEnabled || isLoading ? .white : Color(hex: 0x6F795F))
      .frame(maxWidth: .infinity)
      .frame(height: 55)
      .background(isEnabled || isLoading ? QFTheme.orange : Color(hex: 0xE7EBDD))
      .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
      .opacity(configuration.isPressed ? 0.82 : 1)
  }
}

struct QFAuthChefHero: View {
  var body: some View {
    ZStack {
      Circle().fill(Color(hex: 0xFFF0E7))
      Image("chef-logo")
        .resizable()
        .scaledToFit()
        .padding(EdgeInsets(top: 10, leading: 17, bottom: 18, trailing: 17))
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("小狗厨师拿着锅铲和一锅蔬菜")
    .accessibilityAddTraits(.isImage)
  }
}

struct QFSafetyNoticeView: View {
  @Binding var checked: Bool
  let onReadDocument: (QFAuthDocument) -> Void
  let onContinue: () -> Void
  let onDecline: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var resolved = false
  @State private var appeared = false

  var body: some View {
    GeometryReader { geometry in
      let sheetHeight = min(650, max(0, geometry.size.height + geometry.safeAreaInsets.bottom - 12))
      ZStack(alignment: .bottom) {
        Color(hex: 0x24372C).opacity(appeared ? 0.39 : 0)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture {}
          .accessibilityHidden(true)
        sheet(bottomInset: geometry.safeAreaInsets.bottom)
          .frame(height: sheetHeight)
          .background(QFTheme.background)
          .clipShape(QFAuthSheetShape())
          .padding(.bottom, -geometry.safeAreaInsets.bottom)
          .offset(y: reduceMotion || appeared ? 0 : sheetHeight)
          .opacity(reduceMotion && !appeared ? 0 : 1)
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
    }
    .accessibilityAddTraits(.isModal)
    .onAppear {
      withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.26)) {
        appeared = true
      }
    }
  }

  private func sheet(bottomInset: CGFloat) -> some View {
    VStack(spacing: 0) {
      Capsule()
        .fill(Color(hex: 0xD5DACF))
        .frame(width: 42, height: 4)
        .padding(.top, 13)
        .padding(.bottom, 22)
        .accessibilityHidden(true)
      ScrollView {
        QFAuthSafetyBody()
          .padding(.horizontal, 24)
          .padding(.bottom, 2)
      }
      .padding(.bottom, 17)
      Rectangle()
        .fill(QFTheme.border)
        .frame(height: 1)
        .padding(.horizontal, 24)
        .accessibilityHidden(true)
      QFAuthAgreementRow(
        checked: $checked, noticeStyle: true, identifier: "notice.agreement",
        onReadDocument: onReadDocument
      )
      .padding(.horizontal, 24)
      .padding(.top, 7)
      .padding(.bottom, 15)
      Button("同意并继续") {
        guard checked, !resolved else { return }
        resolved = true
        onContinue()
      }
      .buttonStyle(QFAuthPrimaryButtonStyle())
      .disabled(!checked || resolved)
      .accessibilityIdentifier("notice.continue")
      .padding(.horizontal, 24)
      .padding(.bottom, 12)
      Button("暂不同意") {
        guard !resolved else { return }
        resolved = true
        checked = false
        onDecline()
      }
      .font(.system(size: 15))
      .foregroundColor(QFTheme.secondary)
      .frame(width: 150, height: 44)
      .disabled(resolved)
      .accessibilityIdentifier("notice.decline")
      .padding(.bottom, 11 + bottomInset)
    }
  }
}

private struct QFAuthSafetyBody: View {
  private let items: [(String, String)] = [
    ("食材与饮食安全", "请留意过敏原和个人饮食需求，\n并确认食材新鲜、适合食用。"),
    ("烹饪与设备安全", "使用刀具、热油及电器时请注意安全，\n未成年人应在成人指导下操作。"),
    ("内容仅供烹饪参考", "份量、时间与做法请结合实际调整，\n菜谱内容不能替代专业健康建议。"),
    ("使用范围与限制", "请勿恶意抓取、干扰服务或滥用内容，\n具体使用规则以用户协议为准。"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(spacing: 13) {
        Image("chef-icon")
          .resizable()
          .scaledToFit()
          .frame(width: 40, height: 40)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .accessibilityHidden(true)
        Text("安全与使用须知")
          .font(.system(size: 22, weight: .bold))
          .foregroundColor(QFTheme.text)
          .accessibilityAddTraits(.isHeader)
      }
      Text("开始之前，请先了解这些说明。")
        .font(.system(size: 14))
        .foregroundColor(QFTheme.secondary)
      ForEach(items.indices, id: \.self) { index in
        QFAuthSafetyRow(number: index + 1, title: items[index].0, detail: items[index].1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct QFAuthSafetyRow: View {
  let number: Int
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(Color(hex: 0xAC391C))
        .frame(width: 18, height: 18)
        .background(Circle().fill(Color(hex: 0xFFF0E5)))
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundColor(QFTheme.text)
        Text(detail)
          .font(.system(size: 13))
          .foregroundColor(QFTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct QFAuthSheetShape: Shape {
  func path(in rect: CGRect) -> Path {
    let radius = min(28, rect.width / 2, rect.height)
    var path = Path()
    path.move(to: CGPoint(x: 0, y: rect.height))
    path.addLine(to: CGPoint(x: 0, y: radius))
    path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
    path.addLine(to: CGPoint(x: rect.width - radius, y: 0))
    path.addQuadCurve(to: CGPoint(x: rect.width, y: radius), control: CGPoint(x: rect.width, y: 0))
    path.addLine(to: CGPoint(x: rect.width, y: rect.height))
    path.closeSubpath()
    return path
  }
}
