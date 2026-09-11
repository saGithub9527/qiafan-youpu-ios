import SnapKit
import UIKit

@MainActor
final class QFWelcomeViewController: UIViewController, UIScrollViewDelegate {
  private enum Canvas {
    static let size = CGSize(width: 390, height: 844)
  }

  private let app: QFAppSession
  private let onComplete: () -> Void
  private let stage = UIView()
  private let pager = UIScrollView()
  private let skipButton = UIButton(type: .system)
  private var pages: [QFWelcomePageView] = []
  private var selectedPage = 0
  private var lastPageWidth: CGFloat = 0
  private var completed = false
  private var didPresentInitialNotice = false
  private var agreementAccepted = false

  init(app: QFAppSession, onComplete: @escaping () -> Void) {
    self.app = app
    self.onComplete = onComplete
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override var preferredStatusBarStyle: UIStatusBarStyle { .darkContent }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFWelcomePalette.background
    buildStage()
    buildPager()
    buildHeader()
    updatePageAccessibility()
    QFDiagnosticsPresenter.attach(to: self, app: app, bottomInset: 76)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didPresentInitialNotice else { return }
    didPresentInitialNotice = true
    presentSafetyNotice(continueToApp: false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let horizontalScale = view.bounds.width / Canvas.size.width
    let verticalScale = view.bounds.height / Canvas.size.height
    let scale = max(0.1, min(horizontalScale, verticalScale))
    stage.transform = CGAffineTransform(scaleX: scale, y: scale)

    if pager.bounds.width > 0, abs(pager.bounds.width - lastPageWidth) > 0.5 {
      lastPageWidth = pager.bounds.width
      pager.setContentOffset(
        CGPoint(x: CGFloat(selectedPage) * lastPageWidth, y: 0), animated: false)
    }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updateSelection() }
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { updateSelection() }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { preloadAdjacentPages() }
  func scrollViewDidEndDragging(
    _ scrollView: UIScrollView, willDecelerate decelerate: Bool
  ) {
    if !decelerate { updateSelection() }
  }

  private func buildStage() {
    view.addSubview(stage)
    stage.backgroundColor = QFWelcomePalette.background
    stage.snp.makeConstraints {
      $0.center.equalToSuperview()
      $0.width.equalTo(Canvas.size.width)
      $0.height.equalTo(Canvas.size.height)
    }
  }

  private func buildPager() {
    pager.isPagingEnabled = true
    pager.isDirectionalLockEnabled = true
    pager.showsHorizontalScrollIndicator = false
    pager.showsVerticalScrollIndicator = false
    pager.alwaysBounceHorizontal = false
    pager.contentInsetAdjustmentBehavior = .never
    pager.delegate = self
    pager.accessibilityIdentifier = "welcome.pages"
    stage.addSubview(pager)
    pager.snp.makeConstraints { $0.edges.equalToSuperview() }

    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 0
    pager.addSubview(row)
    row.snp.makeConstraints {
      $0.edges.equalTo(pager.contentLayoutGuide)
      $0.height.equalTo(pager.frameLayoutGuide.snp.height)
    }

    for index in 0..<5 {
      let page = QFWelcomePageView(
        page: index,
        onSelectPage: { [weak self] page in self?.selectPage(page) },
        onEnter: { [weak self] in self?.requestEntry() })
      row.addArrangedSubview(page)
      page.snp.makeConstraints {
        $0.width.equalTo(pager.frameLayoutGuide.snp.width)
        $0.height.equalTo(pager.frameLayoutGuide.snp.height)
      }
      pages.append(page)
    }
    pages.first?.loadArtworkIfNeeded()
  }

  private func buildHeader() {
    let header = UIView()
    stage.addSubview(header)
    header.snp.makeConstraints {
      $0.top.leading.trailing.equalToSuperview()
      $0.height.equalTo(108)
    }

    let icon = UIImageView(image: UIImage(named: "chef-icon"))
    icon.contentMode = .scaleAspectFit
    icon.layer.cornerRadius = 9
    icon.clipsToBounds = true
    header.addSubview(icon)
    icon.snp.makeConstraints {
      $0.leading.equalToSuperview().offset(24)
      $0.top.equalToSuperview().offset(64)
      $0.width.height.equalTo(30)
    }

    let copy = UILabel()
    copy.text = "下厨，从这里开始"
    copy.font = QFWelcomePalette.font(size: 12, weight: .medium)
    copy.textColor = QFWelcomePalette.secondary
    header.addSubview(copy)
    copy.snp.makeConstraints {
      $0.leading.equalToSuperview().offset(64)
      $0.centerY.equalTo(icon)
    }

    skipButton.setTitle("跳过介绍", for: .normal)
    skipButton.titleLabel?.font = QFWelcomePalette.font(size: 12, weight: .regular)
    skipButton.setTitleColor(QFWelcomePalette.secondary, for: .normal)
    skipButton.contentHorizontalAlignment = .right
    skipButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
    skipButton.accessibilityIdentifier = "welcome.skip"
    skipButton.addAction(
      UIAction { [weak self] _ in self?.selectPage(4) }, for: .touchUpInside)
    header.addSubview(skipButton)
    skipButton.snp.makeConstraints {
      $0.leading.equalToSuperview().offset(286)
      $0.top.equalToSuperview().offset(60)
      $0.width.equalTo(88)
      $0.height.equalTo(44)
    }
  }

  private func selectPage(_ page: Int) {
    guard (0..<5).contains(page), presentedViewController == nil else { return }
    selectedPage = page
    pages[page].loadArtworkIfNeeded()
    pager.setContentOffset(
      CGPoint(x: CGFloat(page) * pager.bounds.width, y: 0),
      animated: !UIAccessibility.isReduceMotionEnabled)
    updatePageAccessibility()
  }

  private func updateSelection() {
    guard pager.bounds.width > 0 else { return }
    selectedPage = min(4, max(0, Int((pager.contentOffset.x / pager.bounds.width).rounded())))
    pages[selectedPage].loadArtworkIfNeeded()
    updatePageAccessibility()
  }

  private func preloadAdjacentPages() {
    for index in [selectedPage - 1, selectedPage + 1] where pages.indices.contains(index) {
      pages[index].loadArtworkIfNeeded()
    }
  }

  private func updatePageAccessibility() {
    pager.accessibilityValue = "第 \(selectedPage + 1) 页，共 5 页"
    skipButton.isHidden = selectedPage == 4
    for (index, page) in pages.enumerated() {
      page.accessibilityElementsHidden = index != selectedPage
    }
  }

  private func presentSafetyNotice(continueToApp: Bool) {
    guard !completed, presentedViewController == nil else { return }
    let notice = QFSafetyNoticeViewController(
      app: app,
      checked: false,
      onCheckedChange: { _ in },
      onContinue: { [weak self] in
        guard let self, !self.completed else { return }
        self.agreementAccepted = true
        self.preloadAdjacentPages()
        if continueToApp { self.finishWelcome() }
      },
      onDecline: { [weak self] in self?.agreementAccepted = false })
    present(notice, animated: false)
  }

  private func requestEntry() {
    guard !completed else { return }
    if agreementAccepted { finishWelcome() }
    else { presentSafetyNotice(continueToApp: true) }
  }

  private func finishWelcome() {
    guard !completed, agreementAccepted else { return }
    completed = true
    onComplete()
  }
}

@MainActor
private final class QFWelcomePageView: UIView {
  private let page: Int
  private let onSelectPage: (Int) -> Void
  private let onEnter: () -> Void
  private let artwork = UIImageView()
  private var artworkLoaded = false

  private static let titles = [
    ["今天，", "想做点什么？"],
    ["把世界风味，", "端上餐桌"],
    ["搜一道菜，", "跟着步骤做"],
    ["这一周，", "吃得有计划"],
    ["准备好，开饭啦"],
  ]

  private static let subtitles = [
    ["和小狗厨师一起，", "把每一天，做得有滋有味。"],
    ["按国家、口味与菜系探索，", "找到今天想尝试的那一味。"],
    ["先看需要什么食材，", "再跟着清晰步骤，一步步开做。"],
    ["安排一周菜单，整理所需食材，", "让每天吃什么，提前有答案。"],
    ["从第一道想做的菜开始，", "发现属于你的好味道。"],
  ]

  init(page: Int, onSelectPage: @escaping (Int) -> Void, onEnter: @escaping () -> Void) {
    self.page = page
    self.onSelectPage = onSelectPage
    self.onEnter = onEnter
    super.init(frame: .zero)
    backgroundColor = QFWelcomePalette.background
    accessibilityIdentifier = "welcome.page.\(page + 1)"
    buildArtwork()
    buildTitle()
    buildSubtitle()
    buildIndicators()
    buildPageAction()
  }

  required init?(coder: NSCoder) { return nil }

  func loadArtworkIfNeeded() {
    guard !artworkLoaded else { return }
    artworkLoaded = true
    artwork.image = UIImage(named: "welcome-page-\(page + 1)-art")
  }

  private func buildArtwork() {
    artwork.contentMode = .scaleAspectFit
    artwork.clipsToBounds = true
    artwork.isAccessibilityElement = true
    artwork.accessibilityTraits = .image
    artwork.accessibilityLabel = [
      "小狗厨师拿着锅铲和一锅蔬菜",
      "按国家、口味与菜系探索不同地方的菜",
      "搜索菜谱、查看食材并跟着步骤做菜",
      "安排一周菜单并整理需要的食材",
      "小狗厨师准备开饭",
    ][page]
    addSubview(artwork)
    artwork.snp.makeConstraints {
      $0.leading.equalToSuperview().offset(24)
      $0.top.equalToSuperview().offset(128)
      $0.width.height.equalTo(342)
    }
  }

  private func buildTitle() {
    let baselines: [CGFloat] = page == 4 ? [515] : [515, 554]
    for (line, baseline) in zip(Self.titles[page], baselines) {
      let label = makeLabel(
        line, size: 30, weight: .semibold, color: QFWelcomePalette.text)
      label.accessibilityTraits.insert(.header)
      addSubview(label)
      label.snp.makeConstraints {
        $0.centerX.equalToSuperview()
        $0.leading.greaterThanOrEqualToSuperview().offset(24)
        $0.trailing.lessThanOrEqualToSuperview().offset(-24)
        $0.lastBaseline.equalTo(self.snp.top).offset(baseline)
      }
    }
  }

  private func buildSubtitle() {
    let baselines: [CGFloat] = page == 4 ? [558, 581] : [589, 612]
    for (line, baseline) in zip(Self.subtitles[page], baselines) {
      let label = makeLabel(
        line, size: 14, weight: .regular, color: QFWelcomePalette.secondary)
      addSubview(label)
      label.snp.makeConstraints {
        $0.centerX.equalToSuperview()
        $0.leading.greaterThanOrEqualToSuperview().offset(18)
        $0.trailing.lessThanOrEqualToSuperview().offset(-18)
        $0.lastBaseline.equalTo(self.snp.top).offset(baseline)
      }
    }
  }

  private func buildIndicators() {
    let indicators = UIStackView()
    indicators.axis = .horizontal
    indicators.distribution = .fillEqually
    indicators.alignment = .fill
    addSubview(indicators)
    indicators.snp.makeConstraints {
      $0.leading.equalToSuperview().offset(105)
      $0.top.equalToSuperview().offset(640)
      $0.width.equalTo(180)
      $0.height.equalTo(34)
    }

    for index in 0..<5 {
      let button = UIButton(type: .custom)
      button.accessibilityLabel = "第 \(index + 1) 页，共 5 页"
      button.accessibilityTraits = index == page ? [.button, .selected] : [.button]
      button.addAction(
        UIAction { [weak self] _ in self?.onSelectPage(index) }, for: .touchUpInside)
      let capsule = UIView()
      capsule.isUserInteractionEnabled = false
      capsule.backgroundColor =
        index == page ? QFWelcomePalette.orange : QFWelcomePalette.pageDot
      capsule.layer.cornerRadius = 3
      button.addSubview(capsule)
      capsule.snp.makeConstraints {
        $0.center.equalToSuperview()
        $0.width.equalTo(index == page ? 24 : 6)
        $0.height.equalTo(6)
      }
      indicators.addArrangedSubview(button)
    }
  }

  private func buildPageAction() {
    if page == 0 {
      let hint = makeLabel(
        "左右滑动，继续了解", size: 12, weight: .regular,
        color: QFWelcomePalette.secondary)
      addSubview(hint)
      hint.snp.makeConstraints {
        $0.centerX.equalToSuperview()
        $0.lastBaseline.equalTo(self.snp.top).offset(738)
      }
    } else if page == 4 {
      let enter = QFAuthLoadingButton(
        "进入 APP", background: QFWelcomePalette.orange, size: 16, cornerRadius: 18)
      enter.accessibilityIdentifier = "welcome.enter"
      enter.addAction(UIAction { [weak self] _ in self?.onEnter() }, for: .touchUpInside)
      addSubview(enter)
      enter.snp.makeConstraints {
        $0.leading.equalToSuperview().offset(24)
        $0.top.equalToSuperview().offset(700)
        $0.width.equalTo(342)
        $0.height.equalTo(56)
      }
    }
  }

  private func makeLabel(
    _ copy: String, size: CGFloat, weight: UIFont.Weight, color: UIColor
  ) -> UILabel {
    let label = UILabel()
    label.text = copy
    label.textAlignment = .center
    label.font = QFWelcomePalette.font(size: size, weight: weight)
    label.textColor = color
    label.numberOfLines = 1
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.8
    return label
  }
}

private enum QFWelcomePalette {
  static let background = QFAuthPalette.color(0xFFFDF8)
  static let orange = QFAuthPalette.color(0xEA643E)
  static let text = QFAuthPalette.color(0x29342D)
  static let secondary = QFAuthPalette.color(0x747C71)
  static let pageDot = QFAuthPalette.color(0xDADDD3)

  static func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
    let name: String
    switch weight {
    case .semibold: name = "PingFangSC-Semibold"
    case .medium: name = "PingFangSC-Medium"
    default: name = "PingFangSC-Regular"
    }
    return UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
  }
}
