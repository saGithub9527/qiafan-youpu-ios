import Combine
import SnapKit
import UIKit

@MainActor
enum QFSettingsPageUI {
  static func label(
    _ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
    color: UIColor = QFUI.text, style: UIFont.TextStyle = .body, lines: Int = 0
  ) -> UILabel {
    let label = QFTabUI.label(text, size: size, weight: weight, color: color, lines: lines)
    label.font = UIFontMetrics(forTextStyle: style).scaledFont(
      for: UIFont.systemFont(ofSize: size, weight: weight))
    label.adjustsFontForContentSizeCategory = true
    return label
  }

  static func header(
    _ title: String, backLabel: String, onBack: @escaping () -> Void
  ) -> UIView {
    let back = QFTabUI.iconButton(
      "chevron.left", label: backLabel, size: 22, action: onBack)
    back.snp.remakeConstraints { $0.size.equalTo(44) }
    back.tintColor = QFUI.text
    let titleLabel = label(title, size: 23, weight: .semibold, style: .title2, lines: 2)
    titleLabel.textAlignment = .center
    titleLabel.accessibilityTraits.insert(.header)
    let trailing = UIView()
    trailing.snp.makeConstraints { $0.width.height.equalTo(44) }
    let header = QFTabUI.stack([back, titleLabel, trailing], axis: .horizontal, spacing: 4)
    header.alignment = .center
    return header
  }

  static func updateHeader(_ header: UIView?, title: String, backLabel: String) {
    guard let stack = header as? UIStackView else { return }
    (stack.arrangedSubviews.first as? UIButton)?.accessibilityLabel = backLabel
    stack.arrangedSubviews.compactMap { $0 as? UILabel }.first?.text = title
  }

  static func section(_ title: String, rows: [UIView]) -> UIView {
    let heading = label(
      title, size: 14, weight: .medium, color: QFUI.secondary, style: .subheadline)
    heading.accessibilityTraits.insert(.header)
    let rowsStack = QFTabUI.stack([], spacing: 0)
    for (index, row) in rows.enumerated() {
      if index > 0 {
        let divider = UIView()
        divider.backgroundColor = QFUI.border
        divider.snp.makeConstraints { $0.height.equalTo(0.5) }
        rowsStack.addArrangedSubview(divider)
      }
      rowsStack.addArrangedSubview(row)
    }
    let card = UIView()
    card.backgroundColor = QFUI.surface
    card.layer.cornerRadius = 18
    card.addSubview(rowsStack)
    rowsStack.snp.makeConstraints { $0.edges.equalToSuperview().inset(15) }
    return QFTabUI.stack([heading, card], spacing: 9)
  }

  static func installHeader(_ header: UIView, in view: UIView) {
    view.addSubview(header)
    header.snp.makeConstraints {
      $0.top.equalTo(view.safeAreaLayoutGuide)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(20)
      $0.trailing.lessThanOrEqualToSuperview().inset(20)
      $0.width.equalToSuperview().offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(620)
      $0.height.greaterThanOrEqualTo(52)
    }
  }
  static func installScroll(
    _ scrollView: UIScrollView, stack: UIStackView, in view: UIView, header: UIView
  ) {
    installHeader(header, in: view)
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.keyboardDismissMode = .interactive
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
    }
    let content = UIView()
    scrollView.addSubview(content)
    content.snp.makeConstraints {
      $0.edges.equalTo(scrollView.contentLayoutGuide)
      $0.width.equalTo(scrollView.frameLayoutGuide)
    }
    stack.axis = .vertical
    stack.spacing = 14
    content.addSubview(stack)
    stack.snp.makeConstraints {
      $0.top.equalToSuperview().offset(10)
      $0.bottom.equalToSuperview().inset(24)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(20)
      $0.trailing.lessThanOrEqualToSuperview().inset(20)
      $0.width.equalToSuperview().offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(620)
    }
  }
}

@MainActor
final class QFEditProfileViewController: UIViewController {
  private let app: QFAppSession
  private let initialProfile: QFUserProfile
  private let onSessionExpired: () -> Void
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private lazy var nickname = QFSettingsTextFieldRow(
    title: app.text("昵称", "Nickname"), placeholder: app.text("请输入昵称", "Enter a nickname"), maxLength: 64, identifier: "profile.edit.nickname")
  private lazy var country = QFSettingsTextFieldRow(
    title: app.text("国家或地区代码", "Country or region code"), placeholder: app.text("例如 CN", "For example, US"), maxLength: 2,
    identifier: "profile.edit.country")
  private lazy var region = QFSettingsTextFieldRow(
    title: app.text("省份或地区", "State or region"), placeholder: app.text("选填", "Optional"), maxLength: 32, identifier: "profile.edit.region")
  private lazy var bio = QFSettingsTextViewRow(
    title: app.text("个人简介", "Bio"), placeholder: app.text("介绍一下你的下厨偏好", "Share what you like to cook"), maxLength: 255,
    identifier: "profile.edit.bio")
  private let validationLabel = QFSettingsPageUI.label(
    "", size: 13, color: QFUI.danger, style: .footnote)
  private lazy var saveButton = QFAuthLoadingButton(app.text("保存资料", "Save profile"), size: 18)
  private var saveTask: Task<Void, Never>?
  private var subscriptions = Set<AnyCancellable>()
  private var closingForExpiredSession = false

  init(app: QFAppSession, profile: QFUserProfile, onSessionExpired: @escaping () -> Void) {
    self.app = app
    self.initialProfile = profile
    self.onSessionExpired = onSessionExpired
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }
  deinit { saveTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "profile.edit.screen"
    buildLayout()
    populate()
    for row in [nickname, country, region] {
      row.onChange = { [weak self] in self?.renderState() }
    }
    bio.onChange = { [weak self] in self?.renderState() }
    saveButton.addAction(UIAction { [weak self] _ in self?.save() }, for: .touchUpInside)
    app.$user.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] user in
      if user == nil { self?.closeForExpiredSession() }
    }.store(in: &subscriptions)
  }

  private func buildLayout() {
    let header = QFSettingsPageUI.header(app.text("编辑资料", "Edit profile"), backLabel: app.text("返回", "Back")) { [weak self] in self?.qfClose() }
    QFSettingsPageUI.installScroll(scrollView, stack: contentStack, in: view, header: header)
    let summary = QFSettingsPageUI.label(
      app.text("完善公开资料，帮助你的收藏和作品更容易识别。", "Complete your public profile so your saved items and posts are easier to recognize."), size: 15,
      color: QFUI.secondary, style: .body)
    contentStack.addArrangedSubview(summary)
    contentStack.addArrangedSubview(
      QFSettingsPageUI.section(
        app.text("公开资料", "Public profile"), rows: [nickname, country, region, bio]))
    validationLabel.isHidden = true
    validationLabel.accessibilityIdentifier = "profile.edit.validation"
    contentStack.addArrangedSubview(validationLabel)
    saveButton.accessibilityIdentifier = "profile.edit.save"
    saveButton.snp.makeConstraints { $0.height.equalTo(54) }
    contentStack.addArrangedSubview(saveButton)
  }

  private func populate() {
    nickname.text = initialProfile.nickname
    country.text = initialProfile.countryCode ?? ""
    region.text = initialProfile.regionCode ?? ""
    bio.text = initialProfile.bio ?? ""
    country.textField.autocapitalizationType = .allCharacters
    country.textField.autocorrectionType = .no
    renderState()
  }

  private func renderState() {
    let values = normalizedValues()
    validationLabel.text = values.error
    validationLabel.isHidden = values.error == nil
    saveButton.isEnabled = values.error == nil && values.changed && saveTask == nil
    saveButton.accessibilityHint = values.error ?? (values.changed ? app.text("保存当前修改", "Save changes") : app.text("资料尚未修改", "No changes"))
  }

  private func normalizedValues() -> (
    nickname: String, country: String?, region: String?, bio: String?, changed: Bool, error: String?
  ) {
    let name = nickname.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let countryValue = optional(country.text)?.uppercased()
    let regionValue = optional(region.text)
    let bioValue = optional(bio.text)
    var error: String?
    if name.isEmpty {
      error = app.text("请输入昵称。", "Enter a nickname.")
    } else if name.count > 64 {
      error = app.text("昵称最多 64 个字。", "Nickname must be 64 characters or fewer.")
    } else if let countryValue,
      countryValue.utf8.count != 2
        || !countryValue.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) })
    {
      error = app.text("国家或地区代码需为两个英文字母。", "Country or region code must contain two letters.")
    } else if regionValue?.count ?? 0 > 32 {
      error = app.text("省份或地区最多 32 个字。", "State or region must be 32 characters or fewer.")
    } else if bioValue?.count ?? 0 > 255 {
      error = app.text("个人简介最多 255 个字。", "Bio must be 255 characters or fewer.")
    }
    let changed =
      name != initialProfile.nickname
      || countryValue != optional(initialProfile.countryCode)
      || regionValue != optional(initialProfile.regionCode)
      || bioValue != optional(initialProfile.bio)
    return (name, countryValue, regionValue, bioValue, changed, error)
  }

  private func optional(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func save() {
    let values = normalizedValues()
    guard values.error == nil, values.changed, saveTask == nil else {
      renderState()
      return
    }
    view.endEditing(true)
    saveButton.setLoading(true)
    saveTask = Task { [weak self, app] in
      guard let self else { return }
      do {
        _ = try await app.updateProfile(
          QFProfileUpdate(
            nickname: values.nickname, countryCode: values.country,
            regionCode: values.region, bio: values.bio))
        guard !Task.isCancelled else { return }
        self.saveTask = nil
        self.saveButton.setLoading(false)
        self.qfClose()
      } catch is CancellationError {
        self.saveTask = nil
        self.saveButton.setLoading(false)
      } catch {
        self.saveTask = nil
        self.saveButton.setLoading(false)
        self.renderState()
        self.showMessage(title: self.app.text("保存失败", "Could not save"), message: self.profileErrorMessage(error))
      }
    }
  }

  private func profileErrorMessage(_ error: Error) -> String {
    guard let apiError = error as? QFAPIError else { return app.text("网络连接失败，请稍后重试。", "Network connection failed. Please try again later.") }
    switch apiError.code {
    case 40000: return app.text("请检查昵称和地区信息后重试。", "Check your nickname and region, then try again.")
    case 40100, 40101: return app.text("登录状态已失效，请重新登录。", "Your session expired. Please sign in again.")
    case 40300: return app.text("当前账号暂不可用。", "This account is temporarily unavailable.")
    case 42900: return app.text("操作过于频繁，请稍后再试。", "Too many attempts. Please try again later.")
    default: return app.text("暂时无法保存资料，请稍后重试。", "Your profile could not be saved. Please try again later.")
    }
  }

  private func closeForExpiredSession() {
    guard !closingForExpiredSession else { return }
    closingForExpiredSession = true
    view.accessibilityElementsHidden = true
    qfClose(completion: onSessionExpired)
  }

  private func showMessage(title: String, message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
    present(alert, animated: true)
  }
}

@MainActor
final class QFLanguageSettingsViewController: QFProfileContentController {
  private var selected: String
  private let onSelect: (String) -> Void
  init(app: QFAppSession, selected: String, onSelect: @escaping (String) -> Void) {
    self.selected = selected
    self.onSelect = onSelect
    super.init(app: app, title: app.text("界面语言", "Language"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "settings.language.screen"
    renderLanguages()
  }
  private func renderLanguages() {
    updateHeading(
      app.text("界面语言", "App language"), backLabel: app.text("返回", "Back"))
    bodyStack.beginUpdates()
    for language in QFInterfaceLanguage.allCases {
      let code = language.rawValue
      let name = language.autonym
      bodyStack.row(code, version: String(selected == code) + app.interfaceLanguage) { [self] in
        let row = QFSettingsSelectionRow(
          title: name, selected: selected == code,
          selectedValue: app.text("已选择", "Selected"),
          unselectedValue: app.text("未选择", "Not selected"))
        row.addAction(
          UIAction { [weak self] _ in
            guard let self, self.selected != code else { return }
            self.selected = code
            self.onSelect(code)
            self.renderLanguages()
          }, for: .touchUpInside)
        return row
      }
    }
    bodyStack.endUpdates()
  }
}

@MainActor
final class QFHelpFeedbackViewController: UIViewController {
  private struct Draft: Codable { let category: QFFeedbackCategory; let text: String }
  private let app: QFAppSession
  private let ownerScope: String
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private lazy var category = UISegmentedControl(
    items: QFFeedbackCategory.allCases.map { $0.title(app: app) })
  private lazy var feedback = QFSettingsTextViewRow(
    title: app.text("反馈内容", "Feedback"), placeholder: app.text("请描述遇到的问题或建议（10–1000 字）", "Describe the issue or suggestion (10–1,000 characters)"), maxLength: 1000,
    identifier: "feedback.content")
  private let sessionHint = QFSettingsPageUI.label(
    "", size: 13, color: QFUI.secondary, style: .footnote)
  private lazy var submitButton = QFAuthLoadingButton(app.text("提交反馈", "Submit feedback"), size: 18)
  private var submitTask: Task<Void, Never>?
  private var categorySwipe: QFCategorySwipeBinding?
  private let operationHUD = QFOperationHUD()
  private var subscriptions = Set<AnyCancellable>()

  init(app: QFAppSession) {
    self.app = app
    ownerScope = app.contentScope
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }
  deinit { submitTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "feedback.screen"
    buildLayout()
    if let draft = QFContentDraftStore.load(Draft.self, app: app, kind: "feedback") {
      feedback.text = draft.text
      category.selectedSegmentIndex = QFFeedbackCategory.allCases.firstIndex(of: draft.category) ?? 0
    }
    feedback.onChange = { [weak self] in self?.saveDraft(); self?.renderState() }
    category.addAction(UIAction { [weak self] _ in self?.saveDraft(); self?.renderState() }, for: .valueChanged)
    categorySwipe = QFCategorySwipeBinding(
      control: category, in: contentStack,
      backGesture: navigationController?.interactivePopGestureRecognizer)
    submitButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
    app.$user.receive(on: DispatchQueue.main).sink { [weak self] _ in
      guard let self else { return }
      if self.app.contentScope != self.ownerScope { self.submitTask?.cancel(); self.feedback.text = "" }
      self.renderState()
    }
      .store(in: &subscriptions)
    renderState()
  }

  private func buildLayout() {
    let header = QFSettingsPageUI.header(app.text("帮助与反馈", "Help and feedback"), backLabel: app.text("返回", "Back")) { [weak self] in self?.qfClose() }
    QFSettingsPageUI.installScroll(scrollView, stack: contentStack, in: view, header: header)
    contentStack.addArrangedSubview(
      QFSettingsPageUI.section(
        app.text("常见问题", "Frequently asked questions"),
        rows: [
          QFSettingsHelpRow(
            title: app.text("账号资料在哪里修改？", "Where can I edit my profile?"), detail: app.text("在“我的”页面打开“编辑资料”；账号绑定状态可在设置中查看。", "Open Edit profile from My. You can view account linking in Settings.")),
          QFSettingsHelpRow(
            title: app.text("清理缓存会删除什么？", "What does Clear cache remove?"), detail: app.text("清理可重新获取的图片与网络缓存，保留账号资料和本地草稿。", "It removes downloadable images and network cache while keeping account data and local drafts.")),
          QFSettingsHelpRow(
            title: app.text("协议和图片规则在哪里？", "Where are the policies and image rules?"), detail: app.text("用户协议、隐私政策及图片授权规则均可从设置页直接打开。", "Open the Terms, Privacy Policy, and image rules directly from Settings.")),
        ]))
    category.selectedSegmentIndex = 0
    category.accessibilityIdentifier = "feedback.category"
    category.selectedSegmentTintColor = QFUI.primary
    category.setTitleTextAttributes([.foregroundColor: QFUI.onPrimary], for: .selected)
    category.setTitleTextAttributes([.foregroundColor: QFUI.text], for: .normal)
    category.snp.makeConstraints { $0.height.greaterThanOrEqualTo(40) }
    contentStack.addArrangedSubview(
      QFSettingsPageUI.section(app.text("提交反馈", "Submit feedback"), rows: [QFTabUI.stack([category, feedback], spacing: 12)]))
    sessionHint.numberOfLines = 0
    contentStack.addArrangedSubview(sessionHint)
    submitButton.accessibilityIdentifier = "feedback.submit"
    submitButton.snp.makeConstraints { $0.height.equalTo(54) }
    contentStack.addArrangedSubview(submitButton)
  }

  private func renderState() {
    let count = feedback.text.trimmingCharacters(in: .whitespacesAndNewlines).count
    let signedIn = app.user != nil
    sessionHint.isHidden = signedIn
    sessionHint.text =
      signedIn
      ? ""
      : app.text("登录后可以提交反馈；常见问题仍可直接查看。", "Sign in to submit feedback. You can still read the FAQs.")
    submitButton.isEnabled = submitTask == nil
    submitButton.setLoading(submitTask != nil)
    submitButton.accessibilityHint =
      signedIn
      ? ((10...1000).contains(count) ? app.text("提交当前反馈", "Submit this feedback") : app.text("请填写 10 到 1000 字", "Enter 10 to 1,000 characters"))
      : app.text("需要先登录", "Sign in required")
  }

  private func submit() {
    guard app.user != nil, app.contentScope == ownerScope else {
      showMessage(title: app.text("需要登录", "Sign in required"), message: app.text("登录后可以提交反馈。", "Sign in to submit feedback."))
      return
    }
    let submittedDraft = feedback.text
    let content = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (10...1000).contains(content.count), submitTask == nil else {
      showMessage(title: app.text("请完善反馈", "Complete your feedback"), message: app.text("请填写 10 到 1000 字的反馈内容。", "Enter 10 to 1,000 characters of feedback."))
      return
    }
    let index = max(0, category.selectedSegmentIndex)
    let selectedCategory = QFFeedbackCategory.allCases[index]
    view.endEditing(true)
    submitButton.isEnabled = false
    submitButton.setLoading(true)
    operationHUD.show(in: view, text: app.text("提交中", "Submitting"))
    submitTask = Task { [weak self, app] in
      guard let self else { return }
      do {
        try await app.submitFeedback(category: selectedCategory, content: content)
        guard !Task.isCancelled else { return }
        self.submitTask = nil
        self.operationHUD.hide()
        if self.feedback.text == submittedDraft && self.category.selectedSegmentIndex == index {
          self.feedback.text = ""
        }
        self.saveDraft()
        self.renderState()
        self.showMessage(title: self.app.text("已提交", "Submitted"), message: self.app.text("感谢你的反馈，我们会认真处理。", "Thank you. We will review your feedback."))
      } catch is CancellationError {
        self.submitTask = nil
        self.operationHUD.hide()
        self.renderState()
      } catch {
        self.submitTask = nil
        self.operationHUD.hide()
        self.renderState()
        self.showMessage(title: self.app.text("提交失败", "Submission failed"), message: self.feedbackErrorMessage(error))
      }
    }
  }

  private func saveDraft() {
    guard app.contentScope == ownerScope else { return }
    if feedback.text.isEmpty { QFContentDraftStore.remove(app: app, kind: "feedback"); return }
    let selected = QFFeedbackCategory.allCases[max(0, min(category.selectedSegmentIndex, QFFeedbackCategory.allCases.count - 1))]
    QFContentDraftStore.save(Draft(category: selected, text: feedback.text), app: app, kind: "feedback")
  }

  private func feedbackErrorMessage(_ error: Error) -> String {
    guard let apiError = error as? QFAPIError else {
      return app.text("提交结果未确认，反馈内容已保留，请稍后重试。", "The result could not be confirmed. Your feedback is saved; please try again later.")
    }
    switch apiError.code {
    case 40000: return app.text("请填写 10 到 1000 字的反馈内容。", "Enter 10 to 1,000 characters of feedback.")
    case 40100, 40101: return app.text("登录状态已失效，请重新登录。", "Your session expired. Please sign in again.")
    case 40300: return app.text("当前账号暂不可用。", "This account is temporarily unavailable.")
    case 42900: return app.text("提交过于频繁，请稍后再试。", "You are submitting too often. Please try again later.")
    default: return app.text("暂时无法提交，反馈内容已保留，请稍后重试。", "Submission is temporarily unavailable. Your feedback is saved; please try again later.")
    }
  }

  private func showMessage(title: String, message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
    present(alert, animated: true)
  }
}

@MainActor
private final class QFSettingsTextFieldRow: UIView {
  let textField = UITextField()
  private let maxLength: Int
  var onChange: (() -> Void)?

  var text: String {
    get { textField.text ?? "" }
    set { textField.text = newValue }
  }

  init(title: String, placeholder: String, maxLength: Int, identifier: String) {
    self.maxLength = maxLength
    super.init(frame: .zero)
    let label = QFSettingsPageUI.label(
      title, size: 13, color: QFUI.secondary, style: .caption1)
    textField.placeholder = placeholder
    textField.font = UIFontMetrics(forTextStyle: .body).scaledFont(
      for: UIFont.systemFont(ofSize: 16))
    textField.adjustsFontForContentSizeCategory = true
    textField.textColor = QFUI.text
    textField.clearButtonMode = .whileEditing
    textField.returnKeyType = .done
    textField.accessibilityIdentifier = identifier
    textField.addAction(UIAction { [weak self] _ in self?.changed() }, for: .editingChanged)
    let stack = QFTabUI.stack([label, textField], spacing: 6)
    addSubview(stack)
    stack.snp.makeConstraints {
      $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0))
    }
    snp.makeConstraints { $0.height.greaterThanOrEqualTo(66) }
  }

  required init?(coder: NSCoder) { nil }

  private func changed() {
    if let value = textField.text, value.count > maxLength {
      textField.text = String(value.prefix(maxLength))
    }
    onChange?()
  }
}

@MainActor
private final class QFSettingsTextViewRow: UIView, UITextViewDelegate {
  private let textView = UITextView()
  private let placeholderLabel: UILabel
  private let counter = QFSettingsPageUI.label(
    "0", size: 12, color: QFUI.secondary, style: .caption2, lines: 1)
  private let maxLength: Int
  var onChange: (() -> Void)?

  var text: String {
    get { textView.text ?? "" }
    set {
      textView.text = String(newValue.prefix(maxLength))
      render()
    }
  }

  init(title: String, placeholder: String, maxLength: Int, identifier: String) {
    self.maxLength = maxLength
    self.placeholderLabel = QFSettingsPageUI.label(
      placeholder, size: 16, color: QFUI.disabledText, style: .body)
    super.init(frame: .zero)
    let titleLabel = QFSettingsPageUI.label(
      title, size: 13, color: QFUI.secondary, style: .caption1)
    textView.delegate = self
    textView.backgroundColor = .clear
    textView.textColor = QFUI.text
    textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
      for: UIFont.systemFont(ofSize: 16))
    textView.adjustsFontForContentSizeCategory = true
    textView.isScrollEnabled = true
    textView.accessibilityIdentifier = identifier
    textView.addSubview(placeholderLabel)
    placeholderLabel.snp.makeConstraints {
      $0.top.equalTo(textView.textContainerInset.top)
      $0.leading.equalTo(
        textView.textContainerInset.left + textView.textContainer.lineFragmentPadding)
      $0.trailing.lessThanOrEqualToSuperview().inset(8)
    }
    counter.textAlignment = .right
    let stack = QFTabUI.stack([titleLabel, textView, counter], spacing: 6)
    addSubview(stack)
    stack.snp.makeConstraints {
      $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0))
    }
    textView.snp.makeConstraints { $0.height.greaterThanOrEqualTo(118) }
    render()
  }

  required init?(coder: NSCoder) { nil }

  func textViewDidChange(_ textView: UITextView) {
    if textView.text.count > maxLength { textView.text = String(textView.text.prefix(maxLength)) }
    render()
    onChange?()
  }

  private func render() {
    placeholderLabel.isHidden = !text.isEmpty
    counter.text = "\(text.count)/\(maxLength)"
  }
}

@MainActor
private final class QFSettingsSelectionRow: UIControl {
  init(
    title: String, selected: Bool, selectedValue: String,
    unselectedValue: String
  ) {
    super.init(frame: .zero)
    let label = QFSettingsPageUI.label(title, size: 16, weight: .medium, style: .body)
    let check = UIImageView(
      image: UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"))
    check.tintColor = selected ? QFUI.success : QFUI.secondary
    check.contentMode = .scaleAspectFit
    check.snp.makeConstraints { $0.width.height.equalTo(24) }
    let row = QFTabUI.stack([label, UIView(), check], axis: .horizontal, spacing: 12)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview() }
    snp.makeConstraints { $0.height.greaterThanOrEqualTo(52) }
    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityValue = selected ? selectedValue : unselectedValue
    accessibilityTraits = selected ? [.button, .selected] : .button
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class QFSettingsHelpRow: UIView {
  init(title: String, detail: String) {
    super.init(frame: .zero)
    let titleLabel = QFSettingsPageUI.label(title, size: 16, weight: .medium, style: .headline)
    let detailLabel = QFSettingsPageUI.label(
      detail, size: 14, color: QFUI.secondary, style: .subheadline)
    let stack = QFTabUI.stack([titleLabel, detailLabel], spacing: 6)
    addSubview(stack)
    stack.snp.makeConstraints {
      $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0))
    }
    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityValue = detail
    accessibilityTraits = .staticText
  }

  required init?(coder: NSCoder) { nil }
}
