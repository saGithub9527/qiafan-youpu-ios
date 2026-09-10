import SwiftUI

struct QFWelcomeView: View {
  let onCompleted: () -> Void

  init(onCompleted: @escaping () -> Void) {
    self.onCompleted = onCompleted
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selectedPage = 0
  @State private var showsNotice = false
  @State private var noticeChecked = false
  @State private var completed = false
  @State private var document: QFAuthDocument?

  var body: some View {
    ZStack {
      GeometryReader { geometry in
        VStack(spacing: 9) {
          header
          TabView(selection: $selectedPage) {
            ForEach(0..<5) { page in
              QFAuthWelcomePage(
                page: page,
                width: geometry.size.width,
                selectedPage: $selectedPage,
                onEnter: requestEntry
              )
              .tag(page)
            }
          }
          .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
          .accessibilityIdentifier("welcome.pages")
          .accessibilityValue("第 \(selectedPage + 1) 页，共 5 页")
        }
      }
      .allowsHitTesting(!showsNotice)
      .accessibilityHidden(showsNotice)

      if showsNotice {
        QFSafetyNoticeView(
          checked: $noticeChecked,
          onReadDocument: { document = $0 },
          onContinue: completeWelcome,
          onDecline: declineNotice
        )
        .transition(.asymmetric(insertion: .identity, removal: .opacity))
        .zIndex(1)
      }
    }
    .background(QFTheme.background.ignoresSafeArea())
    .interactiveDismissDisabled(showsNotice)
    .fullScreenCover(item: $document) { document in
      QFAuthAgreementDocument(document: document)
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image("chef-icon")
        .resizable()
        .scaledToFit()
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
      Text("下厨，从这里开始")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(QFTheme.secondary)
      Spacer(minLength: 8)
      Button("跳过介绍", action: requestEntry)
        .font(.system(size: 12))
        .foregroundColor(QFTheme.secondary)
        .frame(width: 62, height: 44)
        .accessibilityIdentifier("welcome.skip")
    }
    .padding(.horizontal, 24)
    .padding(.top, 8)
  }

  private func requestEntry() {
    guard !showsNotice, !completed, document == nil else { return }
    noticeChecked = false
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
      showsNotice = true
    }
  }

  private func completeWelcome() {
    guard showsNotice, noticeChecked, !completed else { return }
    completed = true
    showsNotice = false
    onCompleted()
  }

  private func declineNotice() {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
      showsNotice = false
    }
  }
}

private struct QFAuthWelcomePage: View {
  let page: Int
  let width: CGFloat
  @Binding var selectedPage: Int
  let onEnter: () -> Void

  private static let titles = [
    "今天，\n想做点什么？", "把世界风味，\n端上餐桌", "搜一道菜，\n跟着步骤做",
    "这一周，\n吃得有计划", "准备好，开饭啦",
  ]
  private static let subtitles = [
    "和小狗厨师一起，\n把每一天，做得有滋有味。",
    "按国家、口味与菜系探索，\n找到今天想尝试的那一味。",
    "先看需要什么食材，\n再跟着清晰步骤，一步步开做。",
    "安排一周菜单，整理所需食材，\n让每天吃什么，提前有答案。",
    "从第一道想做的菜开始，\n发现属于你的好味道。",
  ]

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 0) {
        QFAuthWelcomeIllustration(page: page)
          .frame(width: max(1, min(390, width - 48)), height: max(1, min(390, width - 48)))
        Text(Self.titles[page])
          .font(.system(size: page == 4 ? 28 : 29, weight: .bold))
          .foregroundColor(QFTheme.text)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 24)
          .accessibilityAddTraits(.isHeader)
        Text(Self.subtitles[page])
          .font(.system(size: 14))
          .foregroundColor(QFTheme.secondary)
          .multilineTextAlignment(.center)
          .lineSpacing(6)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 14)
        QFAuthPageIndicators(page: page, selectedPage: $selectedPage)
          .padding(.top, 26)
        if page == 0 {
          Text("左右滑动，继续了解")
            .font(.system(size: 12))
            .foregroundColor(QFTheme.secondary)
            .padding(.top, 37)
        } else if page == 4 {
          Button("进入 APP", action: onEnter)
            .buttonStyle(QFAuthPrimaryButtonStyle())
            .accessibilityIdentifier("welcome.enter")
            .padding(.top, 29)
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.top, 17)
      .padding(.bottom, 30)
    }
    .accessibilityIdentifier("welcome.page.\(page + 1)")
  }
}

private struct QFAuthPageIndicators: View {
  let page: Int
  @Binding var selectedPage: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 5) {
      ForEach(0..<5) { index in
        Button {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            selectedPage = index
          }
        } label: {
          Capsule()
            .fill(index == page ? QFTheme.orange : Color(hex: 0xD8DDD2))
            .frame(width: index == page ? 24 : 6, height: 6)
            .frame(width: 31, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(index + 1) 页，共 5 页")
        .accessibilityAddTraits(index == page ? .isSelected : [])
      }
    }
  }
}

private struct QFAuthWelcomeIllustration: View {
  let page: Int

  var body: some View {
    GeometryReader { geometry in
      illustration
        .frame(width: 342, height: 342)
        .scaleEffect(min(geometry.size.width, geometry.size.height) / 342)
        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isImage)
    .accessibilityLabel(accessibilityDescription)
  }

  @ViewBuilder private var illustration: some View {
    switch page {
    case 0, 4: QFAuthChefIllustration(ready: page == 4)
    case 1: QFAuthWorldIllustration()
    case 2: QFAuthRecipeIllustration()
    default: QFAuthPlanIllustration()
    }
  }

  private var accessibilityDescription: String {
    switch page {
    case 0: return "小狗厨师拿着锅铲和一锅蔬菜"
    case 1: return "按国家、口味与菜系探索：中国家常味点心，意大利地中海风味意面"
    case 2: return "搜索番茄炒蛋，准备番茄、鸡蛋和调味料，再跟着步骤做"
    case 3: return "一周菜单安排了晚餐，食材清单中的蔬菜和鸡蛋已准备好"
    default: return "小狗厨师准备开饭"
    }
  }
}

// Independent SwiftUI shapes, labels and dish assets recreate the artwork; no full-page image is used.
extension View {
  fileprivate func qfArtFrame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat)
    -> some View
  {
    frame(width: width, height: height).position(x: x + width / 2, y: y + height / 2)
  }
}

private struct QFAuthArtText: View {
  let text: String
  var size: CGFloat = 12
  var weight: Font.Weight = .regular
  var color: Color = QFTheme.text

  var body: some View {
    Text(text)
      .font(.system(size: size, weight: weight))
      .foregroundColor(color)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct QFAuthArtChip: View {
  let text: String
  var background: Color = .white
  var color: Color = QFTheme.green

  var body: some View {
    Text(text)
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(color)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Capsule().fill(background))
  }
}

private struct QFAuthArtCard<Content: View>: View {
  var shadow: Color = Color(hex: 0xD5E1C9)
  @ViewBuilder let content: () -> Content

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 22)
        .fill(Color.white)
        .shadow(color: shadow, radius: 0, x: 4, y: 6)
      content()
    }
  }
}

private struct QFAuthArtDish: View {
  let asset: String
  var radius: CGFloat = 17

  var body: some View {
    GeometryReader { geometry in
      Image(asset)
        .resizable()
        .scaledToFill()
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
  }
}

private struct QFAuthPlus: View {
  var color: Color = QFTheme.orange

  var body: some View {
    Text("+").font(.system(size: 30, weight: .light)).foregroundColor(color)
  }
}

private struct QFAuthChefIllustration: View {
  let ready: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      Circle().fill(Color(hex: 0xFFF0E5)).qfArtFrame(32, 30, 278, 278)
      if !ready {
        Ellipse().fill(Color(hex: 0xF3DBC0)).qfArtFrame(50, 298, 242, 17)
      }
      Image("chef-logo").resizable().scaledToFit().qfArtFrame(58, 8, 231, 297)
      QFAuthArtChip(text: ready ? "从喜欢的一道菜开始" : "今天也要好好吃饭", color: Color(hex: 0xBF4223))
        .qfArtFrame(84, 302, 174, 30)
      QFAuthPlus().qfArtFrame(24, 112, 24, 30)
      QFAuthPlus(color: ready ? QFTheme.green : QFTheme.orange)
        .qfArtFrame(ready ? 298 : 295, ready ? 231 : 50, 24, 30)
      Circle().fill(QFTheme.orange).qfArtFrame(57, 48, 5, 5)
      Circle().fill(Color(hex: 0xD6E5C9)).qfArtFrame(289, 225, 7, 7)
      if ready {
        Text("✓")
          .font(.system(size: 24, weight: .medium))
          .foregroundColor(QFTheme.green)
          .frame(width: 38, height: 38)
          .background(Circle().fill(Color.white))
          .qfArtFrame(275, 42, 38, 38)
      }
    }
  }
}

private struct QFAuthWorldIllustration: View {
  var body: some View {
    ZStack(alignment: .topLeading) {
      QFAuthGlobe().qfArtFrame(34, 38, 279, 279)
      QFAuthArtChip(text: "国家").qfArtFrame(27, 27, 62, 30)
      QFAuthArtChip(text: "口味").qfArtFrame(109, 10, 62, 30)
      QFAuthArtChip(text: "菜系").qfArtFrame(193, 21, 62, 30)
      chinaCard.qfArtFrame(7, 92, 144, 169)
      italyCard.qfArtFrame(188, 143, 154, 167)
      QFAuthPlus(color: QFTheme.green).qfArtFrame(305, 79, 24, 30)
      Circle().fill(QFTheme.orange).qfArtFrame(50, 305, 8, 8)
    }
  }

  private var chinaCard: some View {
    QFAuthArtCard {
      QFAuthArtDish(asset: "dish-dimsum").qfArtFrame(8, 8, 128, 112)
      QFAuthArtText(text: "中国 · 家常味", size: 13, weight: .semibold).qfArtFrame(14, 130, 124, 19)
      QFAuthArtText(text: "熟悉，也有新惊喜", size: 10, color: QFTheme.secondary).qfArtFrame(
        14, 150, 124, 15)
    }
  }

  private var italyCard: some View {
    QFAuthArtCard {
      QFAuthArtDish(asset: "dish-noodles").qfArtFrame(8, 8, 138, 108)
      QFAuthArtText(text: "意大利 · 地中海风味", size: 11.8, weight: .semibold).qfArtFrame(14, 127, 134, 19)
      QFAuthArtText(text: "换个地方，尝点不同", size: 10.8, color: QFTheme.secondary).qfArtFrame(
        14, 147, 133, 16)
    }
  }
}

private struct QFAuthGlobe: View {
  var body: some View {
    Canvas { context, size in
      context.fill(
        Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(QFTheme.paleGreen))
      let globe = CGRect(origin: .zero, size: size).insetBy(dx: 44, dy: 24)
      let outline = Path(ellipseIn: globe)
      let color = Color(hex: 0xADC399)
      context.stroke(outline, with: .color(color), lineWidth: 1.6)
      context.stroke(
        Path(ellipseIn: globe.insetBy(dx: globe.width * 0.23, dy: 0)), with: .color(color),
        lineWidth: 1.4)
      context.clip(to: outline)
      var lines = Path()
      lines.move(to: CGPoint(x: globe.midX, y: globe.minY))
      lines.addLine(to: CGPoint(x: globe.midX, y: globe.maxY))
      for index in 1..<3 {
        let y = globe.minY + globe.height * CGFloat(index) / 3
        lines.move(to: CGPoint(x: globe.minX, y: y))
        lines.addLine(to: CGPoint(x: globe.maxX, y: y))
      }
      context.stroke(lines, with: .color(color), lineWidth: 1.4)
    }
  }
}

private struct QFAuthRecipeIllustration: View {
  var body: some View {
    ZStack(alignment: .topLeading) {
      recipeCard.qfArtFrame(22, 86, 296, 249)
      searchBar.qfArtFrame(44, 48, 257, 52)
      QFAuthPlus().qfArtFrame(8, 258, 24, 30)
      Circle().fill(QFTheme.orange).qfArtFrame(311, 72, 6, 6)
    }
  }

  private var recipeCard: some View {
    QFAuthArtCard(shadow: Color(hex: 0xEDD9C0)) {
      Group {
        QFAuthArtDish(asset: "dish-rice").qfArtFrame(16, 23, 78, 78)
        QFAuthArtText(text: "番茄炒蛋", size: 17, weight: .semibold).qfArtFrame(108, 32, 130, 28)
        QFAuthArtChip(text: "家常菜", background: QFTheme.paleGreen).qfArtFrame(108, 68, 70, 30)
        Image(systemName: "heart").resizable().scaledToFit().foregroundColor(QFTheme.orange)
          .qfArtFrame(248, 33, 20, 20)
        QFAuthArtText(text: "准备食材", size: 13, weight: .semibold).qfArtFrame(19, 120, 150, 19)
      }
      Group {
        QFAuthArtChip(text: "番茄", background: Color(hex: 0xFAF5EB), color: QFTheme.secondary)
          .qfArtFrame(19, 145, 66, 30)
        QFAuthArtChip(text: "鸡蛋", background: Color(hex: 0xFAF5EB), color: QFTheme.secondary)
          .qfArtFrame(92, 145, 66, 30)
        QFAuthArtChip(text: "调味料", background: Color(hex: 0xFAF5EB), color: QFTheme.secondary)
          .qfArtFrame(165, 145, 78, 30)
        Rectangle().fill(QFTheme.border).qfArtFrame(19, 192, 259, 1)
        stepNumber.qfArtFrame(19, 208, 20, 20)
        QFAuthArtText(text: "处理食材，开始第一步", weight: .semibold).qfArtFrame(49, 206, 220, 24)
      }
    }
  }

  private var stepNumber: some View {
    Text("1")
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(Color(hex: 0xAB3A1C))
      .frame(width: 20, height: 20)
      .background(Circle().fill(Color(hex: 0xFFF0E5)))
  }

  private var searchBar: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 17).fill(Color.white)
      RoundedRectangle(cornerRadius: 17).stroke(QFTheme.border, lineWidth: 1)
      Image(systemName: "magnifyingglass").resizable().scaledToFit().foregroundColor(QFTheme.orange)
        .qfArtFrame(17, 16, 19, 19)
      QFAuthArtText(text: "番茄炒蛋", size: 14, weight: .semibold).qfArtFrame(48, 13, 160, 26)
      Text("→")
        .font(.system(size: 22, weight: .medium))
        .foregroundColor(QFTheme.orange)
        .frame(width: 26, height: 23)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xFFF0E5)))
        .qfArtFrame(213, 15, 26, 23)
    }
  }
}

private struct QFAuthPlanIllustration: View {
  var body: some View {
    ZStack(alignment: .topLeading) {
      Ellipse().fill(QFTheme.paleGreen).qfArtFrame(53, 66, 265, 253)
      calendar.qfArtFrame(22, 59, 282, 228)
      shoppingList.qfArtFrame(83, 250, 244, 87)
      QFAuthPlus(color: QFTheme.green).qfArtFrame(312, 110, 24, 30)
      Circle().fill(QFTheme.orange).qfArtFrame(17, 279, 6, 6)
    }
  }

  private var calendar: some View {
    QFAuthArtCard {
      QFAuthArtText(text: "我的一周菜单", size: 18, weight: .semibold).qfArtFrame(20, 15, 233, 27)
      Rectangle().fill(QFTheme.border).qfArtFrame(20, 48, 239, 1)
      calendarDays
      QFAuthArtDish(asset: "dish-vegetables", radius: 16).qfArtFrame(19, 135, 64, 64)
      QFAuthArtText(text: "今天吃点清爽的", size: 13, weight: .semibold).qfArtFrame(95, 141, 147, 23)
      QFAuthArtText(text: "已加入晚餐计划", color: QFTheme.secondary).qfArtFrame(95, 165, 147, 23)
      QFAuthArtChip(text: "✓", background: QFTheme.paleGreen).qfArtFrame(241, 144, 22, 30)
    }
  }

  private var calendarDays: some View {
    let days = ["一", "二", "三", "四", "五", "六", "日"]
    return ForEach(0..<7) { day in
      Group {
        Text(days[day])
          .font(.system(size: 11))
          .foregroundColor(QFTheme.secondary)
          .qfArtFrame(17 + CGFloat(day) * 36, 60, 30, 18)
        Text("\(14 + day)")
          .font(.system(size: 12))
          .foregroundColor(day == 2 ? .white : QFTheme.text)
          .frame(width: 27, height: 30)
          .background(RoundedRectangle(cornerRadius: 9).fill(day == 2 ? QFTheme.orange : .clear))
          .qfArtFrame(17 + CGFloat(day) * 36, 84, 27, 30)
      }
    }
  }

  private var shoppingList: some View {
    QFAuthArtCard {
      QFAuthArtText(text: "食材清单", size: 13, weight: .semibold).qfArtFrame(20, 12, 170, 20)
      QFAuthArtText(text: "✓  蔬菜", color: QFTheme.secondary).qfArtFrame(23, 42, 89, 20)
      QFAuthArtText(text: "✓  鸡蛋", color: QFTheme.secondary).qfArtFrame(110, 42, 89, 20)
      QFAuthArtText(text: "都安排好了", size: 10, weight: .semibold, color: QFTheme.green).qfArtFrame(
        167, 66, 70, 17)
    }
  }
}
