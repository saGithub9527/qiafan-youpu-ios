import SwiftUI

struct QFProfileView: View {
  let previewSignedIn: Bool
  let user: QFUserProfile?
  private var signedIn: Bool { user != nil || previewSignedIn }
  let onLogin: () -> Void
  @State private var unavailableFeature: QFProfileUnavailableFeature?

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 20) {
        header
        QFProfileIdentityView(
          previewSignedIn: previewSignedIn, user: user, onAction: identityTapped
        )
        .padding(.top, 2)
        QFProfileStatsView(previewSignedIn: previewSignedIn)
        featureCards
        Text("我的内容")
          .font(.system(size: 20, weight: .semibold))
          .foregroundColor(QFTheme.text)
          .accessibilityAddTraits(.isHeader)
        menu
        QFProfileMenuRow(
          title: "兴趣偏好",
          symbol: "slider.horizontal.3",
          detail: signedIn ? "" : "登录后设置",
          onAction: { openProtected("兴趣偏好") }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)
      .padding(.bottom, 24)
    }
    .background(QFTheme.background)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("profile.screen")
    .alert(item: $unavailableFeature) { feature in
      Alert(
        title: Text(feature.title),
        message: Text("该功能暂未开放"),
        dismissButton: .default(Text("知道了"))
      )
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Text("我的")
        .font(.system(size: 30, weight: .semibold))
        .foregroundColor(QFTheme.text)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Button {
        showUnavailable("设置")
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 22, weight: .medium))
          .foregroundColor(QFTheme.text)
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("设置")
    }
  }

  private var featureCards: some View {
    HStack(spacing: 14) {
      QFProfileFeatureCard(
        title: "发布作品",
        subtitle: "记录今天的拿手菜",
        symbol: "photo",
        color: QFTheme.orange,
        background: Color(hex: 0xFFF0E7),
        onAction: { openProtected("发布作品") }
      )
      QFProfileFeatureCard(
        title: "补充图片",
        subtitle: "为食材、菜谱补充实拍",
        symbol: "photo.badge.plus",
        color: QFTheme.green,
        background: QFTheme.paleGreen,
        onAction: { openProtected("补充图片") }
      )
    }
  }

  private var menu: some View {
    VStack(spacing: 0) {
      ForEach(Array(QFProfileMenuItem.items.enumerated()), id: \.element.id) { index, item in
        QFProfileMenuRow(
          title: item.title,
          symbol: item.symbol,
          detail: signedIn ? "" : "登录后查看",
          onAction: { openProtected(item.title) }
        )
        if index < QFProfileMenuItem.items.count - 1 {
          Rectangle().fill(QFTheme.border).frame(height: 0.5)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
  }

  private func identityTapped() {
    if signedIn {
      showUnavailable("编辑资料")
    } else {
      onLogin()
    }
  }

  private func openProtected(_ title: String) {
    if signedIn {
      showUnavailable(title)
    } else {
      onLogin()
    }
  }

  private func showUnavailable(_ title: String) {
    unavailableFeature = QFProfileUnavailableFeature(title: title)
  }
}

private struct QFProfileUnavailableFeature: Identifiable {
  let title: String
  var id: String { title }
}

private struct QFProfileIdentityView: View {
  let previewSignedIn: Bool
  let user: QFUserProfile?
  private var signedIn: Bool { user != nil || previewSignedIn }
  private var regionText: String {
    guard let user else { return previewSignedIn ? "中国 · 上海" : "收藏菜谱，记录下厨日常" }
    let parts = [user.countryCode, user.regionCode].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? "地区未设置" : parts.joined(separator: " · ")
  }
  let onAction: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      avatar
      VStack(alignment: .leading, spacing: 6) {
        Text(user?.nickname ?? (previewSignedIn ? "小满的厨房" : "登录恰饭有谱"))
          .font(.system(size: 20, weight: .semibold))
          .foregroundColor(QFTheme.text)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text(regionText)
          .font(.system(size: 12))
          .foregroundColor(QFTheme.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(signedIn ? "编辑资料" : "去登录", action: onAction)
        .font(.system(size: 14, weight: .medium))
        .foregroundColor(.white)
        .frame(width: 80, height: 38)
        .background(Capsule().fill(QFTheme.orange))
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.login")
    }
  }

  private var avatar: some View {
    ZStack {
      Circle().fill(QFTheme.paleGreen)
      if let avatar = user?.avatarUrl, let url = URL(string: avatar), url.scheme == "https" {
        AsyncImage(url: url) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          Image("default-avatar").resizable().scaledToFit()
        }
        .frame(width: 72, height: 72).clipShape(Circle())
      } else if signedIn {
        Image("default-avatar")
          .resizable()
          .scaledToFit()
          .frame(width: 48, height: 48)
      } else {
        Image(systemName: "person.fill")
          .font(.system(size: 36))
          .foregroundColor(Color(hex: 0x9AA78C))
      }
    }
    .frame(width: 72, height: 72)
    .accessibilityHidden(true)
  }
}

private struct QFProfileStatsView: View {
  let previewSignedIn: Bool
  private let titles = ["收藏", "做菜天数", "作品"]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(0..<titles.count, id: \.self) { index in
        VStack(spacing: 4) {
          Text(values[index])
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(previewSignedIn ? QFTheme.text : Color(hex: 0x99A08F))
          Text(titles[index])
            .font(.system(size: 13))
            .foregroundColor(QFTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.vertical, 14)
    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
  }

  private var values: [String] {
    previewSignedIn ? ["128", "26", "12"] : ["—", "—", "—"]
  }
}

private struct QFProfileFeatureCard: View {
  let title: String
  let subtitle: String
  let symbol: String
  let color: Color
  let background: Color
  let onAction: () -> Void

  var body: some View {
    Button(action: onAction) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Image(systemName: symbol)
            .font(.system(size: 23))
          Spacer(minLength: 0)
          Image(systemName: "chevron.right")
            .font(.system(size: 15, weight: .medium))
        }
        .foregroundColor(color)
        Spacer(minLength: 0)
        Text(title)
          .font(.system(size: 21, weight: .semibold))
          .foregroundColor(QFTheme.text)
        Text(subtitle)
          .font(.system(size: 12))
          .foregroundColor(color)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
      .padding(16)
      .background(RoundedRectangle(cornerRadius: 18).fill(background))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}

private struct QFProfileMenuItem: Identifiable, Sendable {
  let title: String
  let symbol: String
  var id: String { title }

  static let items = [
    QFProfileMenuItem(title: "我的作品", symbol: "photo"),
    QFProfileMenuItem(title: "我的图片贡献", symbol: "photo.badge.plus"),
    QFProfileMenuItem(title: "我的收藏", symbol: "bookmark"),
    QFProfileMenuItem(title: "做菜记录与统计", symbol: "calendar.badge.checkmark"),
  ]
}

private struct QFProfileMenuRow: View {
  let title: String
  let symbol: String
  let detail: String
  let onAction: () -> Void

  var body: some View {
    Button(action: onAction) {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 21))
          .foregroundColor(QFTheme.green)
          .frame(width: 22)
        Text(title)
          .font(.system(size: 16, weight: .medium))
          .foregroundColor(QFTheme.text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        if !detail.isEmpty {
          Text(detail)
            .font(.system(size: 12))
            .foregroundColor(QFTheme.secondary)
            .fixedSize()
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .medium))
          .foregroundColor(QFTheme.secondary)
      }
      .frame(minHeight: 51)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityHint(detail)
  }
}
