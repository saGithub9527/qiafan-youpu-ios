import SnapKit
import UIKit

@MainActor
final class QFWelcomeViewController: UIViewController, UIScrollViewDelegate {
  private let app: QFAppSession
  private let onComplete: () -> Void
  private let form = UIView()
  private let pager = UIScrollView()
  private var pages: [QFWelcomePageView] = []
  private var selectedPage = 0
  private var lastPageWidth: CGFloat = 0
  private var completed = false

  init(app: QFAppSession, onComplete: @escaping () -> Void) {
    self.app = app
    self.onComplete = onComplete
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.addSubview(form)
    form.snp.makeConstraints {
      $0.top.bottom.equalTo(view.safeAreaLayoutGuide)
      $0.centerX.equalToSuperview()
      $0.width.equalTo(view.safeAreaLayoutGuide.snp.width).priority(.high)
      $0.width.lessThanOrEqualTo(520)
      $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading)
      $0.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide.snp.trailing)
    }
    let header = UIView()
    form.addSubview(header)
    header.snp.makeConstraints { $0.top.equalToSuperview().offset(8); $0.leading.trailing.equalToSuperview().inset(24); $0.height.equalTo(44) }
    let icon = UIImageView(image: UIImage(named: "chef-icon"))
    icon.contentMode = .scaleAspectFit
    icon.layer.cornerRadius = 9
    icon.clipsToBounds = true
    header.addSubview(icon)
    icon.snp.makeConstraints { $0.leading.centerY.equalToSuperview(); $0.width.height.equalTo(30) }
    let copy = QFUI.label("下厨，从这里开始", size: 12, weight: .medium, color: QFUI.secondary)
    header.addSubview(copy)
    copy.snp.makeConstraints { $0.leading.equalTo(icon.snp.trailing).offset(10); $0.centerY.equalToSuperview() }
    let skip = UIButton(type: .system)
    skip.setTitle("跳过介绍", for: .normal)
    skip.titleLabel?.font = .systemFont(ofSize: 12)
    skip.setTitleColor(QFUI.secondary, for: .normal)
    skip.accessibilityIdentifier = "welcome.skip"
    skip.addAction(UIAction { [weak self] _ in self?.requestEntry() }, for: .touchUpInside)
    header.addSubview(skip)
    skip.snp.makeConstraints { $0.trailing.centerY.equalToSuperview(); $0.width.equalTo(62); $0.height.equalTo(44); $0.leading.greaterThanOrEqualTo(copy.snp.trailing).offset(8) }
    pager.isPagingEnabled = true
    pager.isDirectionalLockEnabled = true
    pager.showsHorizontalScrollIndicator = false
    pager.showsVerticalScrollIndicator = false
    pager.alwaysBounceHorizontal = false
    pager.contentInsetAdjustmentBehavior = .never
    pager.delegate = self
    pager.accessibilityIdentifier = "welcome.pages"
    form.addSubview(pager)
    pager.snp.makeConstraints { $0.top.equalTo(header.snp.bottom).offset(9); $0.leading.trailing.bottom.equalToSuperview() }
    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 0
    pager.addSubview(row)
    row.snp.makeConstraints { $0.edges.equalTo(pager.contentLayoutGuide); $0.height.equalTo(pager.frameLayoutGuide.snp.height) }
    for index in 0..<5 {
      let page = QFWelcomePageView(page: index, onSelectPage: { [weak self] page in self?.selectPage(page) },
                                   onEnter: { [weak self] in self?.requestEntry() })
      row.addArrangedSubview(page)
      page.snp.makeConstraints { $0.width.equalTo(pager.frameLayoutGuide.snp.width) }
      pages.append(page)
    }
    updatePageAccessibility()
    QFDiagnosticsPresenter.attach(to: self, app: app, bottomInset: 76)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if pager.bounds.width > 0, abs(pager.bounds.width - lastPageWidth) > 0.5 {
      lastPageWidth = pager.bounds.width
      pager.setContentOffset(CGPoint(x: CGFloat(selectedPage) * lastPageWidth, y: 0), animated: false)
    }
    let height = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom
    pages.forEach { $0.updateAvailableHeight(height) }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updateSelection() }
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { updateSelection() }
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { updateSelection() }
  }

  private func selectPage(_ page: Int) {
    guard (0..<5).contains(page), presentedViewController == nil else { return }
    selectedPage = page
    pager.setContentOffset(CGPoint(x: CGFloat(page) * pager.bounds.width, y: 0), animated: !UIAccessibility.isReduceMotionEnabled)
    updatePageAccessibility()
  }

  private func updateSelection() {
    guard pager.bounds.width > 0 else { return }
    selectedPage = min(4, max(0, Int((pager.contentOffset.x / pager.bounds.width).rounded())))
    updatePageAccessibility()
  }

  private func updatePageAccessibility() {
    pager.accessibilityValue = "第 \(selectedPage + 1) 页，共 5 页"
    for (index, page) in pages.enumerated() { page.accessibilityElementsHidden = index != selectedPage }
  }

  private func requestEntry() {
    guard !completed, presentedViewController == nil else { return }
    let notice = QFSafetyNoticeViewController(app: app, checked: false, onCheckedChange: { _ in }, onContinue: { [weak self] in
      guard let self, !self.completed else { return }
      self.completed = true
      self.onComplete()
    }, onDecline: {})
    present(notice, animated: false)
  }
}

@MainActor
private final class QFWelcomePageView: UIView {
  private let page: Int
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private let artwork: QFWelcomeArtworkView
  private let title: UILabel
  private let subtitle: UILabel
  private let indicators = UIStackView()
  private var illustrationSize: Constraint?
  private var contentTop: Constraint?
  private var contentBottom: Constraint?
  private var availableHeight: CGFloat = 0
  private var lastArtworkSize: CGFloat = -1
  private let onSelectPage: (Int) -> Void
  private let onEnter: () -> Void
  private var lastItem: UIView?
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

  init(page: Int, onSelectPage: @escaping (Int) -> Void, onEnter: @escaping () -> Void) {
    self.page = page
    self.onSelectPage = onSelectPage
    self.onEnter = onEnter
    artwork = QFWelcomeArtworkView(page: page)
    title = QFUI.label(Self.titles[page], size: page == 4 ? 28 : 29, weight: .bold)
    subtitle = QFUI.label(Self.subtitles[page], size: 14, color: QFUI.secondary)
    super.init(frame: .zero)
    accessibilityIdentifier = "welcome.page.\(page + 1)"
    scroll.showsVerticalScrollIndicator = false
    scroll.isDirectionalLockEnabled = true
    scroll.alwaysBounceVertical = false
    scroll.contentInsetAdjustmentBehavior = .never
    addSubview(scroll)
    scroll.snp.makeConstraints { $0.edges.equalToSuperview() }
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 0
    scroll.addSubview(stack)
    stack.snp.makeConstraints {
      contentTop = $0.top.equalTo(scroll.contentLayoutGuide.snp.top).offset(17).constraint
      $0.leading.trailing.equalTo(scroll.contentLayoutGuide).inset(24)
      contentBottom = $0.bottom.equalTo(scroll.contentLayoutGuide.snp.bottom).inset(30).constraint
      $0.width.equalTo(scroll.frameLayoutGuide.snp.width).offset(-48)
    }
    title.textAlignment = .center
    title.accessibilityTraits.insert(.header)
    subtitle.textAlignment = .center
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = 6
    subtitle.attributedText = NSAttributedString(string: Self.subtitles[page], attributes: [
      .font: UIFont.systemFont(ofSize: 14), .foregroundColor: QFUI.secondary, .paragraphStyle: paragraph
    ])
    [artwork, title, subtitle, indicators].forEach { stack.addArrangedSubview($0) }
    artwork.snp.makeConstraints { illustrationSize = $0.width.equalTo(300).constraint; $0.height.equalTo(artwork.snp.width) }
    title.snp.makeConstraints { $0.width.equalTo(stack.snp.width) }
    subtitle.snp.makeConstraints { $0.width.equalTo(stack.snp.width) }
    buildIndicators()
    if page == 0 {
      let hint = QFUI.label("左右滑动，继续了解", size: 12, color: QFUI.secondary)
      hint.textAlignment = .center
      stack.addArrangedSubview(hint)
      hint.snp.makeConstraints { $0.width.equalTo(stack.snp.width) }
      lastItem = hint
    } else if page == 4 {
      let enter = QFAuthLoadingButton("进入 APP")
      enter.accessibilityIdentifier = "welcome.enter"
      enter.addAction(UIAction { [weak self] _ in self?.onEnter() }, for: .touchUpInside)
      stack.addArrangedSubview(enter)
      enter.snp.makeConstraints { $0.width.equalTo(stack.snp.width); $0.height.equalTo(55) }
      lastItem = enter
    }
    updateLayout()
  }
  required init?(coder: NSCoder) { return nil }

  override func layoutSubviews() { super.layoutSubviews(); updateLayout() }
  func updateAvailableHeight(_ height: CGFloat) {
    if availableHeight != height { availableHeight = height; setNeedsLayout() }
  }

  private func updateLayout() {
    let compact = availableHeight > 0 && availableHeight < 500
    let widthLimit = max(1, min(390, bounds.width - 48))
    let size = compact ? min(widthLimit, max(80, availableHeight * 0.36)) : widthLimit
    if abs(size - lastArtworkSize) > 0.5 { lastArtworkSize = size; illustrationSize?.update(offset: size) }
    stack.setCustomSpacing(compact ? 14 : 24, after: artwork)
    stack.setCustomSpacing(compact ? 10 : 14, after: title)
    stack.setCustomSpacing(compact ? 16 : 26, after: subtitle)
    if lastItem != nil { stack.setCustomSpacing(compact ? 18 : (page == 0 ? 37 : 29), after: indicators) }
    contentTop?.update(offset: compact ? 10 : 17)
    contentBottom?.update(inset: compact ? 20 : 30)
  }

  private func buildIndicators() {
    indicators.axis = .horizontal
    indicators.spacing = 5
    for index in 0..<5 {
      let button = UIButton(type: .custom)
      button.accessibilityLabel = "第 \(index + 1) 页，共 5 页"
      button.isSelected = index == page
      button.accessibilityTraits = index == page ? [.button, .selected] : [.button]
      let capsule = UIView()
      capsule.backgroundColor = index == page ? QFUI.orange : QFAuthPalette.color(0xD8DDD2)
      capsule.layer.cornerRadius = 3
      capsule.isUserInteractionEnabled = false
      button.addSubview(capsule)
      capsule.snp.makeConstraints { $0.center.equalToSuperview(); $0.width.equalTo(index == page ? 24 : 6); $0.height.equalTo(6) }
      button.snp.makeConstraints { $0.width.equalTo(31); $0.height.equalTo(28) }
      button.addAction(UIAction { [weak self] _ in self?.onSelectPage(index) }, for: .touchUpInside)
      indicators.addArrangedSubview(button)
    }
  }
}
