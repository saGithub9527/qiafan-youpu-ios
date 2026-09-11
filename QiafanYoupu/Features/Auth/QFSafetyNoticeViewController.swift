import SnapKit
import UIKit

@MainActor
final class QFSafetyNoticeViewController: UIViewController {
  private let app: QFAppSession
  private let onCheckedChange: (Bool) -> Void
  private let onContinue: () -> Void
  private let onDecline: () -> Void
  private let dim = UIView()
  private let sheet = UIView()
  private let rootStack = UIStackView()
  private let scroll = UIScrollView()
  private let scrollStack = UIStackView()
  private let handle = UIView()
  private let bodyContent = UIView()
  private let agreementSection = UIView()
  private let actions = UIView()
  private let agreement = QFAuthAgreementControl(identifier: "notice.agreement", noticeStyle: true)
  private let continueButton = QFAuthLoadingButton("同意并继续")
  private var handleHeight: Constraint?
  private var actionsBottom: Constraint?
  private var mode: Int?
  private var bottomInset: CGFloat = -1
  private var resolved = false
  private var entered = false
  private var checked: Bool

  init(app: QFAppSession, checked: Bool, onCheckedChange: @escaping (Bool) -> Void,
       onContinue: @escaping () -> Void, onDecline: @escaping () -> Void) {
    self.app = app
    self.checked = checked
    self.onCheckedChange = onCheckedChange
    self.onContinue = onContinue
    self.onDecline = onDecline
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    isModalInPresentation = true
  }
  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.accessibilityViewIsModal = true
    dim.backgroundColor = QFAuthPalette.color(0x24372C).withAlphaComponent(0.39)
    dim.isAccessibilityElement = false
    view.addSubview(dim)
    dim.snp.makeConstraints { $0.edges.equalToSuperview() }
    sheet.backgroundColor = QFUI.background
    sheet.layer.cornerRadius = 28
    sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    sheet.clipsToBounds = true
    view.addSubview(sheet)
    sheet.snp.makeConstraints {
      $0.bottom.equalToSuperview()
      $0.centerX.equalToSuperview()
      $0.width.equalTo(view.safeAreaLayoutGuide.snp.width).priority(.high)
      $0.width.lessThanOrEqualTo(520)
      $0.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.leading)
      $0.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide.snp.trailing)
      $0.top.greaterThanOrEqualTo(view.safeAreaLayoutGuide.snp.top).offset(12)
      $0.height.lessThanOrEqualTo(650)
      $0.height.equalTo(650).priority(.high)
    }
    rootStack.axis = .vertical
    rootStack.spacing = 0
    sheet.addSubview(rootStack)
    rootStack.snp.makeConstraints { $0.edges.equalToSuperview() }
    scroll.alwaysBounceVertical = false
    scroll.showsVerticalScrollIndicator = true
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    scrollStack.axis = .vertical
    scrollStack.spacing = 0
    scrollStack.isLayoutMarginsRelativeArrangement = true
    scroll.addSubview(scrollStack)
    scrollStack.snp.makeConstraints {
      $0.edges.equalTo(scroll.contentLayoutGuide)
      $0.width.equalTo(scroll.frameLayoutGuide.snp.width)
    }
    buildHandle()
    buildBody()
    buildAgreement()
    buildActions()
    setChecked(checked)
    arrange(mode: 0)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safeHeight = view.bounds.height - view.safeAreaInsets.top - view.safeAreaInsets.bottom
    let nextMode = sheet.bounds.height < 260 ? 2 : (safeHeight < 500 ? 1 : 0)
    if mode != nextMode { arrange(mode: nextMode) }
    if bottomInset != view.safeAreaInsets.bottom {
      bottomInset = view.safeAreaInsets.bottom
      actionsBottom?.update(inset: 11 + bottomInset)
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !entered else { return }
    entered = true
    dim.alpha = 0
    if UIAccessibility.isReduceMotionEnabled { sheet.alpha = 0 }
    else { sheet.transform = CGAffineTransform(translationX: 0, y: sheet.bounds.height) }
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.26) {
      self.dim.alpha = 1
      self.sheet.alpha = 1
      self.sheet.transform = .identity
    }
    UIAccessibility.post(notification: .screenChanged, argument: bodyContent)
  }

  func setChecked(_ checked: Bool) {
    self.checked = checked
    guard isViewLoaded else { return }
    agreement.checked = checked
    continueButton.isEnabled = checked && !resolved
  }

  private func buildHandle() {
    let capsule = UIView()
    capsule.backgroundColor = QFAuthPalette.color(0xD5DACF)
    capsule.layer.cornerRadius = 2
    handle.addSubview(capsule)
    capsule.snp.makeConstraints { $0.centerX.equalToSuperview(); $0.top.equalToSuperview().offset(13); $0.width.equalTo(42); $0.height.equalTo(4) }
    handle.snp.makeConstraints { handleHeight = $0.height.equalTo(39).constraint }
    handle.accessibilityElementsHidden = true
  }

  private func buildBody() {
    let icon = UIImageView(image: UIImage(named: "chef-icon"))
    icon.contentMode = .scaleAspectFit
    icon.layer.cornerRadius = 12
    icon.clipsToBounds = true
    icon.snp.makeConstraints { $0.width.height.equalTo(40) }
    let title = QFUI.label("安全与使用须知", size: 22, weight: .bold)
    title.accessibilityTraits.insert(.header)
    let header = QFUI.stack([icon, title], axis: .horizontal, spacing: 13)
    header.alignment = .center
    let content = QFUI.stack([
      header, QFUI.label("开始之前，请先了解这些说明。", size: 14, color: QFUI.secondary)
    ], spacing: 15)
    let items = [
      ("食材与饮食安全", "请留意过敏原和个人饮食需求，\n并确认食材新鲜、适合食用。"),
      ("烹饪与设备安全", "使用刀具、热油及电器时请注意安全，\n未成年人应在成人指导下操作。"),
      ("内容仅供烹饪参考", "份量、时间与做法请结合实际调整，\n菜谱内容不能替代专业健康建议。"),
      ("使用范围与限制", "请勿恶意抓取、干扰服务或滥用内容，\n具体使用规则以用户协议为准。"),
    ]
    for (index, item) in items.enumerated() {
      let number = QFUI.label("\(index + 1)", size: 11, weight: .medium, color: QFAuthPalette.color(0xAC391C), lines: 1)
      number.textAlignment = .center
      number.backgroundColor = QFAuthPalette.color(0xFFF0E5)
      number.layer.cornerRadius = 9
      number.clipsToBounds = true
      number.snp.makeConstraints { $0.width.height.equalTo(18) }
      let text = QFUI.stack([
        QFUI.label(item.0, size: 15, weight: .semibold),
        QFUI.label(item.1, size: 13, color: QFUI.secondary),
      ], spacing: 5)
      let row = QFUI.stack([number, text], axis: .horizontal, spacing: 10)
      row.alignment = .top
      content.addArrangedSubview(row)
    }
    bodyContent.addSubview(content)
    content.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 0, left: 24, bottom: 2, right: 24)) }
  }

  private func buildAgreement() {
    let divider = UIView()
    divider.backgroundColor = QFUI.border
    agreementSection.addSubview(divider)
    divider.snp.makeConstraints { $0.top.equalToSuperview(); $0.leading.trailing.equalToSuperview().inset(24); $0.height.equalTo(1) }
    agreementSection.addSubview(agreement)
    agreement.snp.makeConstraints {
      $0.top.equalTo(divider.snp.bottom).offset(7)
      $0.leading.trailing.equalToSuperview().inset(24)
      $0.bottom.equalToSuperview().inset(15)
    }
    agreement.onCheckedChange = { [weak self] checked in
      guard let self, !self.resolved else { return }
      self.setChecked(checked)
      self.onCheckedChange(checked)
    }
    agreement.onReadDocument = { [weak self] document in
      guard let self, !self.resolved, self.presentedViewController == nil else { return }
      self.present(QFAuthAgreementViewController(app: self.app, document: document), animated: true)
    }
  }

  private func buildActions() {
    continueButton.accessibilityIdentifier = "notice.continue"
    continueButton.snp.makeConstraints { $0.height.equalTo(55) }
    continueButton.addAction(UIAction { [weak self] _ in
      guard let self, self.checked, !self.resolved else { return }
      self.finish(accepted: true)
    }, for: .touchUpInside)
    let decline = UIButton(type: .system)
    decline.setTitle("暂不同意", for: .normal)
    decline.setTitleColor(QFUI.secondary, for: .normal)
    decline.titleLabel?.font = .systemFont(ofSize: 15)
    decline.accessibilityIdentifier = "notice.decline"
    decline.snp.makeConstraints { $0.height.equalTo(44) }
    decline.addAction(UIAction { [weak self] _ in self?.finish(accepted: false) }, for: .touchUpInside)
    let stack = QFUI.stack([continueButton, decline], spacing: 12)
    actions.addSubview(stack)
    stack.snp.makeConstraints {
      $0.top.equalToSuperview()
      $0.leading.trailing.equalToSuperview().inset(24)
      actionsBottom = $0.bottom.equalToSuperview().inset(11).constraint
    }
  }

  private func arrange(mode: Int) {
    self.mode = mode
    for stack in [rootStack, scrollStack] {
      for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    handleHeight?.update(offset: mode == 0 ? 39 : 27)
    scrollStack.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: mode == 0 ? 17 : 10, right: 0)
    if mode == 2 {
      rootStack.addArrangedSubview(scroll)
      [handle, bodyContent, agreementSection, actions].forEach { scrollStack.addArrangedSubview($0) }
    } else {
      rootStack.addArrangedSubview(handle)
      rootStack.addArrangedSubview(scroll)
      scrollStack.addArrangedSubview(bodyContent)
      if mode == 1 { scrollStack.addArrangedSubview(agreementSection) }
      else { rootStack.addArrangedSubview(agreementSection) }
      rootStack.addArrangedSubview(actions)
    }
    view.setNeedsLayout()
  }

  private func finish(accepted: Bool) {
    guard !resolved, !accepted || checked, presentedViewController == nil else { return }
    resolved = true
    continueButton.isEnabled = false
    agreement.setEnabled(false)
    view.isUserInteractionEnabled = false
    if !accepted { setChecked(false); onCheckedChange(false) }
    let completion = accepted ? onContinue : onDecline
    UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.2, animations: {
      self.dim.alpha = 0
      if UIAccessibility.isReduceMotionEnabled { self.sheet.alpha = 0 }
      else { self.sheet.transform = CGAffineTransform(translationX: 0, y: self.sheet.bounds.height) }
    }, completion: { _ in self.dismiss(animated: false, completion: completion) })
  }
}
