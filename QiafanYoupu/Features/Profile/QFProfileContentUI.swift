import AVKit
import Combine
import Kingfisher
import MJRefresh
import PhotosUI
import SnapKit
import UIKit
import UniformTypeIdentifiers

/// Keeps loaded pages stable across navigation. A pull refresh starts at page zero;
/// ordinary re-entry reuses the response cache for each previously loaded page.
@MainActor
struct QFContentPagination<Item: Decodable> {
  private(set) var items: [Item] = []
  private(set) var total = 0
  private(set) var totals: [QFCurrencyTotal]?
  private(set) var nextPage = 0
  private(set) var hasMore = false

  func fetching(
    app: QFAppSession, path: String, query: [String: String] = [:],
    append: Bool = false, reset: Bool = false, id: (Item) -> String
  ) async throws -> Self {
    let first = append ? nextPage : 0
    let last = append ? first : reset ? 0 : max(0, nextPage - 1)
    var result = append ? self : Self()
    for page in first...last {
      var parameters = query
      parameters["page"] = String(page)
      let response: QFContentPage<Item> = try await app.contentRequest(
        path: path, query: parameters)
      try Task.checkCancellation()
      let countBeforeMerge = result.items.count
      var positions = Dictionary(
        uniqueKeysWithValues: result.items.enumerated().map { (id($0.element), $0.offset) })
      for item in response.items {
        let key = id(item)
        if let index = positions[key] {
          result.items[index] = item
        } else {
          positions[key] = result.items.count
          result.items.append(item)
        }
      }
      result.total = response.total
      result.totals = response.totals
      result.nextPage = page + 1
      result.hasMore = result.items.count > countBeforeMerge && result.items.count < response.total
      if !result.hasMore { break }
    }
    return result
  }
}

@MainActor
enum QFContentImageCache {
  static let shared: ImageCache = {
    let cache = ImageCache(name: "qf.profile.content.images")
    cache.memoryStorage.config.totalCostLimit = 64 * 1024 * 1024
    cache.memoryStorage.config.countLimit = 60
    cache.memoryStorage.config.expiration = .seconds(120)
    return cache
  }()
}

@MainActor
class QFProfileContentController: QFPageViewController, QFNavigationBackHandling {
  private(set) var heading: String
  let bodyStack = QFContentListStack()
  let footer = UIStackView()
  let notice = QFSettingsPageUI.label("", size: 13, color: QFUI.secondary)
  private var operation: Task<Void, Never>?
  private var mediaPicker: QFContentMediaPicker?
  private var busy = false
  private var reading = false
  private var operationID = UUID()
  private var didAppear = false
  private var didLoadContent = false
  private let refresh = UIRefreshControl()
  private let hud = QFOperationHUD()
  private var categorySwipe: QFCategorySwipeBinding?
  private weak var categoryControl: UISegmentedControl?
  var hasUnsavedChanges: Bool { false }
  var reloadsOnAppearance: Bool { true }
  private var ownerID: String?
  private var reloadAction: (() -> Void)?
  private var emptyFooterHeight: Constraint?
  private var loadMoreAction: (() -> Void)?
  private var loadMoreFooter: MJRefreshAutoNormalFooter?
  private var loadingMore = false
  private var loadMoreFailed = false
  private weak var listScrollView: UIScrollView?
  private weak var pageHeader: UIView?
  private var dataScrollView: UIScrollView { listScrollView ?? scrollView }
  var isRefreshingContent: Bool { refresh.isRefreshing }

  var onChanged: (() -> Void)?

  init(app: QFAppSession, title: String) {
    heading = title
    super.init(app: app)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { nil }
  deinit { operation?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    scrollView.panGestureRecognizer.addTarget(self, action: #selector(resumeLoadMoreAfterDrag))
    ownerID = app.user?.userId
    view.accessibilityIdentifier = "profile.content.\(heading)"
    let header = QFSettingsPageUI.header(
      heading, backLabel: app.text("返回", "Back")
    ) { [weak self] in self?.close() }
    pageHeader = header
    QFSettingsPageUI.installHeader(header, in: view)
    notice.isHidden = true
    refresh.addAction(UIAction { [weak self] _ in self?.reloadAction?() }, for: .valueChanged)
    bodyStack.axis = .vertical
    bodyStack.spacing = 16
    contentStack.addArrangedSubview(bodyStack)
    footer.axis = .horizontal
    footer.spacing = 12
    footer.distribution = .fillEqually
    footer.backgroundColor = QFUI.background
    view.addSubview(footer)
    footer.snp.makeConstraints {
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(20)
      $0.trailing.lessThanOrEqualToSuperview().inset(20)
      $0.width.equalToSuperview().offset(-40).priority(999)
      $0.width.lessThanOrEqualTo(620)
      $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top).offset(-12)
      emptyFooterHeight = $0.height.equalTo(0).constraint
    }
    scrollView.snp.remakeConstraints {
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(footer.snp.top).offset(-12)
    }
    app.$user.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] user in
      guard let self, user?.userId != self.ownerID else { return }
      self.operation?.cancel()
      self.mediaPicker?.cancel()
      self.bodyStack.isHidden = true
      self.dataScrollView.isHidden = true
      self.footer.isHidden = true
      self.navigationController?.popToRootViewController(animated: false)
    }.store(in: &cancellables)
  }

  func updateHeading(_ title: String, backLabel: String? = nil) {
    heading = title
    QFSettingsPageUI.updateHeader(
      pageHeader, title: title, backLabel: backLabel ?? app.text("返回", "Back"))
  }
  func installHeaderAction(_ button: UIButton) {
    guard let header = pageHeader as? UIStackView,
      let back = header.arrangedSubviews.first as? UIButton,
      let trailing = header.arrangedSubviews.last else { return }
    header.removeArrangedSubview(trailing); trailing.removeFromSuperview()
    back.snp.remakeConstraints { $0.width.equalTo(84); $0.height.equalTo(44) }
    back.contentHorizontalAlignment = .leading
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.65
    button.snp.makeConstraints { $0.width.equalTo(84); $0.height.greaterThanOrEqualTo(44) }
    header.addArrangedSubview(button)
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if didAppear && reloadsOnAppearance { reloadAction?() }
    didAppear = true
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed {
      operation?.cancel()
      mediaPicker?.cancel()
      hud.hide()
    }
  }
  func close() {
    operation?.cancel()
    mediaPicker?.cancel()
    hud.hide()
    qfClose()
  }
  func closeWithSuccess(_ text: String) {
    let destination = navigationController?.viewControllers.dropLast().last
    qfClose { [weak destination] in
      guard let destination, destination.viewIfLoaded?.window != nil else { return }
      QFOperationHUD.toast(text, in: destination.view)
    }
  }
  func setReloadAction(allowsPullToRefresh: Bool = true, _ action: @escaping () -> Void) {
    reloadAction = action
    dataScrollView.refreshControl = allowsPullToRefresh ? refresh : nil
  }
  func installList(_ list: UIScrollView, controls: UIView? = nil) {
    scrollView.isHidden = true
    view.addSubview(list)
    if let controls {
      view.addSubview(controls)
      controls.snp.makeConstraints {
        $0.top.equalTo(scrollView)
        $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(12)
      }
    }
    list.snp.makeConstraints {
      $0.leading.trailing.bottom.equalTo(scrollView)
      if let controls {
        $0.top.equalTo(controls.snp.bottom).offset(8)
      } else {
        $0.top.equalTo(scrollView)
      }
    }
    list.alwaysBounceVertical = true
    list.keyboardDismissMode = .onDrag
    list.panGestureRecognizer.addTarget(self, action: #selector(resumeLoadMoreAfterDrag))
    listScrollView = list
    bindCategorySwipe()
  }
  func setLoadMoreAction(_ action: (() -> Void)?) {
    loadMoreAction = action
    loadMoreFailed = false
    if loadMoreFooter == nil, action != nil {
      let control = MJRefreshAutoNormalFooter { [weak self] in
        guard let self else { return }
        guard !self.busy, !self.refresh.isRefreshing,
          self.view.window != nil, self.navigationController?.topViewController === self,
          let action = self.loadMoreAction
        else {
          self.loadMoreFooter?.endRefreshing()
          return
        }
        action()
      }
      control.autoTriggerTimes = 1
      control.triggerAutomaticallyRefreshPercent = 0.5
      control.stateLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
      control.stateLabel?.textColor = QFUI.secondary
      control.stateLabel?.isUserInteractionEnabled = false
      control.isAccessibilityElement = true
      control.accessibilityCustomActions = [
        UIAccessibilityCustomAction(name: app.text("加载更多", "Load more")) { [weak self] _ in
          guard let self, !self.busy, let action = self.loadMoreAction else { return false }
          action()
          return true
        }
      ]
      dataScrollView.mj_footer = control
      loadMoreFooter = control
    }
    updateLoadMoreIndicator()
  }
  @objc private func resumeLoadMoreAfterDrag() {
    guard dataScrollView.panGestureRecognizer.state == .began else { return }
    loadMoreFooter?.isAutomaticallyRefresh = !busy && loadMoreAction != nil
  }
  private func updateLoadMoreIndicator() {
    guard let control = loadMoreFooter else { return }
    control.setTitle(
      loadMoreFailed
        ? app.text("加载失败，上拉重试", "Pull up to retry") : app.text("上拉加载更多", "Pull up for more"),
      for: .idle)
    control.setTitle(app.text("加载中…", "Loading…"), for: .refreshing)
    control.setTitle(app.text("已全部加载", "All loaded"), for: .noMoreData)
    control.accessibilityLabel =
      loadingMore
      ? app.text("加载中", "Loading")
      : loadMoreFailed
        ? app.text("加载失败，上拉重试", "Pull up to retry")
        : app.text("上拉加载更多", "Pull up for more")
    control.isAutomaticallyRefresh = !busy && !loadMoreFailed && loadMoreAction != nil
    if !loadingMore { control.endRefreshing() }
    control.isHidden = loadMoreAction == nil && !loadingMore
  }
  func categoryTabs(_ titles: [String], selected: Int = 0, action: @escaping (Int) -> Void)
    -> UISegmentedControl
  {
    let control = QFContentUI.segments(titles, selected: selected, action: action)
    categoryControl = control
    bindCategorySwipe()
    return control
  }
  private func bindCategorySwipe() {
    categorySwipe?.invalidate()
    guard let control = categoryControl else { return }
    categorySwipe = QFCategorySwipeBinding(
      control: control, in: dataScrollView,
      backGesture: navigationController?.interactivePopGestureRecognizer)
  }
  func reloadIfVisible() {
    guard isViewLoaded, view.window != nil, navigationController?.topViewController === self else {
      return
    }
    reloadAction?()
  }
  private func setBusy(_ value: Bool) {
    busy = value
    footer.isUserInteractionEnabled = !value
    bodyStack.isUserInteractionEnabled = !value || reading
    listScrollView?.isUserInteractionEnabled = !value || reading
  }
  func open(_ controller: UIViewController) {
    guard presentedViewController == nil else { return }
    if let child = controller as? QFProfileContentController, child.onChanged == nil {
      child.onChanged = { [weak self] in self?.onChanged?() }
    }
    view.endEditing(true)
    if controller is UIAlertController || controller is PHPickerViewController
      || controller is QFAvatarCropViewController || controller is AVPlayerViewController
    {
      present(controller, animated: true)
    } else {
      qfPush(controller)
    }
  }
  func addFooter(_ title: String, primary: Bool = true, action: @escaping () -> Void) -> UIButton {
    emptyFooterHeight?.deactivate()
    let button = QFTabUI.button(
      title, size: 16, weight: .semibold,
      color: primary ? QFUI.onPrimary : QFUI.text, background: primary ? QFUI.primary : QFUI.surface
    ) { [weak self] in
      self?.view.endEditing(true)
      action()
    }
    button.layer.cornerRadius = 16
    button.titleLabel?.numberOfLines = 0
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(50) }
    footer.addArrangedSubview(button)
    return button
  }
  func message(_ text: String, error: Bool = false, reload: Bool = false) {
    guard !text.isEmpty else { return }
    QFOperationHUD.toast(text, in: view)
  }
  func execute(
    reloadOnFailure: Bool = false, loadingMore: Bool = false,
    showReadProgress: Bool = false, showsInitialReadProgress: Bool = true, label: String? = nil,
    _ work: @escaping () async throws -> Void
  ) {
    if loadingMore && busy { return }
    guard !busy || reading else {
      refresh.endRefreshing()
      return
    }
    operation?.cancel()
    operationID = UUID()
    let id = operationID
    reading = reloadOnFailure
    self.loadingMore = loadingMore
    if loadingMore { loadMoreFailed = false }
    updateLoadMoreIndicator()
    if !reading { view.endEditing(true) }
    setBusy(true)
    let force = refresh.isRefreshing
    hud.hide()
    if !loadingMore && !force && (!reading || (!didLoadContent && showsInitialReadProgress) || showReadProgress) {
      let progressText = label ?? app.text("保存中", "Saving")
      hud.show(in: view, text: reading ? app.text("加载中", "Loading") : progressText)
    }
    operation = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.operationID == id {
          self.setBusy(false)
          self.loadingMore = false
          self.updateLoadMoreIndicator()
          self.hud.hide()
          self.refresh.endRefreshing()
        }
      }
      do {
        try await QFContentLoadingContext.$forceRefresh.withValue(force) { try await work() }
        try Task.checkCancellation()
        if self.operationID == id && reloadOnFailure { self.didLoadContent = true }
      } catch is CancellationError {} catch {
        if self.operationID == id {
          if loadingMore {
            self.loadMoreFailed = true
          } else if reloadOnFailure && !self.didLoadContent,
            self.dataScrollView.refreshControl == nil, let retry = self.reloadAction,
            self.view.window != nil, self.navigationController?.topViewController === self,
            self.presentedViewController == nil
          {
            let alert = UIAlertController(
              title: self.app.text("加载失败", "Could not load"),
              message: Self.errorText(error, app: self.app), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: self.app.text("稍后", "Later"), style: .cancel))
            alert.addAction(
              UIAlertAction(title: self.app.text("重试", "Retry"), style: .default) { _ in retry() })
            self.open(alert)
          } else {
            self.message(Self.errorText(error, app: self.app), error: true)
          }
        }
      }
    }
  }
  static func errorText(_ error: Error, app: QFAppSession) -> String {
    if error is QFKeychainError {
      return app.text(
        "无法访问本机安全凭证，请解锁设备后重试。",
        "The secure credential on this device could not be accessed. Unlock the device and try again.")
    }
    if let api = error as? QFAPIError {
      switch api.code {
      case 40000: return app.text("请求内容不正确，请检查后重试。", "Check the information and try again.")
      case 40100, 40101: return app.text("登录状态已失效，请重新登录。", "Your session expired. Please sign in again.")
      case 40300: return app.text("当前账号无权执行此操作。", "This account is not allowed to perform this action.")
      case 40301: return app.text("请先阅读并同意用户协议和隐私政策。", "Read and agree to the Terms of Service and Privacy Policy first.")
      case 40302: return app.text("请重新登录后修改账号安全设置。", "Sign in again before changing account security settings.")
      case 40400, 404: return app.text("内容已移除或暂时不可访问。", "This content was removed or is temporarily unavailable.")
      case 40900: return app.text("内容已变更，请刷新后重试。", "This content changed. Refresh and try again.")
      case 40901: return app.text("该账号已被占用。", "That account is already in use.")
      case 40902: return app.text("账号已绑定，不能再次绑定。", "The account is already bound and cannot be bound again.")
      case 40903: return app.text("当前 Apple 身份与该账号归属冲突。", "This Apple ID belongs to a different account.")
      case 42201: return app.text("当前语言的菜谱材料尚不可用。", "Recipe ingredients are not available in this language yet.")
      case 42202: return app.text("作品内容尚未满足审核条件。", "The work does not yet meet the review requirements.")
      case 42203: return app.text("没有满足当前条件的可用菜谱。", "No recipes match the current plan constraints.")
      case 42204: return app.text("每餐最多安排 30 道菜。", "Each meal can contain up to 30 recipes.")
      case 42205: return app.text("请核对食材、实际用量和单位。", "Confirm each ingredient, actual quantity and unit.")
      case 42206: return app.text("库存不足，请补录库存或调整实际用量。", "Not enough stock. Add inventory or adjust the actual quantity.")
      case 42900: return app.text("操作过于频繁，请稍后再试。", "Too many attempts. Please try again later.")
      case 50000: return app.text("服务处理失败，请稍后重试。", "The service could not complete the request. Try again later.")
      case 50300, 503: return app.text("服务暂时不可用，请稍后重试。", "The service is temporarily unavailable. Please try again later.")
      default:
        return app.format("请求未完成（错误码 %d）。", "The request did not complete (error %d).", api.code)
      }
    }
    return app.text("网络连接失败，请重试。未提交的内容会保留。", "Network connection failed. Please retry; unsent changes are preserved.")
  }
  func confirm(
    _ title: String, detail: String, actionTitle: String? = nil, destructive: Bool = false,
    action: @escaping () -> Void
  ) {
    let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    let resolvedActionTitle = actionTitle ?? app.text("确认", "Confirm")
    alert.addAction(
      UIAlertAction(title: resolvedActionTitle, style: destructive ? .destructive : .default) { _ in
        action()
      })
    open(alert)
  }
  func chooseMedia(
    video: Bool = false, cropAvatar: Bool = false, completion: @escaping (QFContentMedia) -> Void
  ) {
    chooseMediaBatch(video: video, cropAvatar: cropAvatar) { media in
      if let first = media.first { completion(first) }
    }
  }
  func chooseMaterial(
    from _: UIView, _ selection: @escaping (QFWorkMaterial) -> Void
  ) {
    view.endEditing(true)
    // Two choices fit the compact alert much better than a full-height action
    // sheet, especially for German and Portuguese translations.
    let sheet = UIAlertController(title: app.text("添加材料", "Add material"), message: nil, preferredStyle: .alert)
    sheet.addAction(UIAlertAction(title: app.text("从食材库选择", "Choose from ingredients"), style: .default) { [weak self] _ in
      guard let self else { return }
      self.open(QFCatalogSearchViewController(app: self.app, type: "INGREDIENT") { item in
        var material = QFWorkMaterial()
        material.name = item.title
        material.ingredientId = item.id
        material.unit = self.app.text("克", "g")
        selection(material)
      })
    })
    sheet.addAction(UIAlertAction(title: app.text("手动添加", "Add manually"), style: .default) { [app] _ in
      var material = QFWorkMaterial()
      material.unit = app.text("克", "g")
      selection(material)
    })
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    open(sheet)
  }
  func chooseMediaBatch(
    limit: Int = 1, video: Bool = false, cropAvatar: Bool = false,
    completion: @escaping ([QFContentMedia]) -> Void
  ) {
    guard limit > 0, !busy, mediaPicker == nil, presentedViewController == nil else { return }
    let crop: ((UIImage) async -> UIImage?)? =
      cropAvatar
      ? { [weak self] image in
        guard let self, self.presentedViewController == nil else { return nil }
        return await withCheckedContinuation { continuation in
          self.open(QFAvatarCropViewController(app: self.app, image: image) { continuation.resume(returning: $0) })
        }
      } : nil
    let picker = QFContentMediaPicker(
      app: app, video: video, limit: limit, crop: crop,
      loading: { [weak self] in
        guard let self else { return }
        self.reading = false
        self.setBusy(true)
        self.hud.show(in: self.view, text: self.app.text("准备媒体中", "Preparing media"))
      },
      completion: { [weak self] result in
        guard let self else { return }
        self.mediaPicker = nil
        self.setBusy(false)
        self.hud.hide()
        switch result {
        case .success(let media):
          self.message("")
          if !media.isEmpty { completion(media) }
        case .failure(let error):
          if !(error is CancellationError) { self.message(Self.errorText(error, app: self.app), error: true) }
        }
      })
    mediaPicker = picker
    open(picker.controller)
  }
  func preserveOrDiscard(_ preserve: @escaping () -> Void, discard: @escaping () -> Void = {}) {
    let alert = UIAlertController(
      title: app.text("保留未提交的内容？", "Keep unsubmitted changes?"),
      message: app.text("返回不会自动发布或提交。", "Going back will not publish or submit anything automatically."),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("继续编辑", "Keep editing"), style: .cancel))
    alert.addAction(
      UIAlertAction(title: app.text("保留草稿", "Keep draft"), style: .default) { [weak self] _ in
        self?.operation?.cancel()
        self?.mediaPicker?.cancel()
        preserve()
        self?.qfClose()
      })
    alert.addAction(
      UIAlertAction(title: app.text("放弃修改", "Discard changes"), style: .destructive) { [weak self] _ in
        self?.operation?.cancel()
        self?.mediaPicker?.cancel()
        discard()
        self?.qfClose()
      })
    open(alert)
  }
}

@MainActor
enum QFContentUI {
  static func label(
    _ text: String, size: CGFloat = 16, bold: Bool = false, color: UIColor = QFUI.text
  ) -> UILabel {
    QFSettingsPageUI.label(text, size: size, weight: bold ? .semibold : .regular, color: color)
  }
  static func field(
    _ placeholder: String, text: String = "", keyboard: UIKeyboardType = .default, limit: Int = 100,
    changed: @escaping (String) -> Void
  ) -> UITextField {
    let field = UITextField()
    field.text = text
    field.placeholder = placeholder
    field.textColor = QFUI.text
    field.backgroundColor = QFUI.surface
    field.layer.cornerRadius = 12
    field.font = UIFont.preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.keyboardType = keyboard
    field.clearButtonMode = .whileEditing
    field.returnKeyType = .done
    field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 44))
    field.leftViewMode = .always
    field.snp.makeConstraints { $0.height.greaterThanOrEqualTo(48) }
    field.accessibilityLabel = placeholder
    field.addAction(
      UIAction { [weak field] _ in
        guard let field, field.markedTextRange == nil else { return }
        if (field.text?.count ?? 0) > limit {
          field.text = String((field.text ?? "").prefix(limit))
        }
        changed(field.text ?? "")
      }, for: .editingChanged)
    field.addAction(
      UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
    return field
  }
  static func action(_ title: String, destructive: Bool = false, _ action: @escaping () -> Void)
    -> UIButton
  {
    let button = QFTabUI.button(title, size: 14, color: destructive ? QFUI.danger : QFUI.primary) {}
    button.addAction(
      UIAction { [weak button] _ in
        button?.window?.endEditing(true)
        action()
      }, for: .touchUpInside)
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    return button
  }
  static func anchoredAction(
    _ title: String, destructive: Bool = false, _ action: @escaping (UIButton) -> Void
  ) -> UIButton {
    let button = QFTabUI.button(
      title, size: 14, color: destructive ? QFUI.danger : QFUI.primary
    ) {}
    button.addAction(
      UIAction { [weak button] _ in
        guard let button else { return }
        button.window?.endEditing(true)
        action(button)
      }, for: .touchUpInside)
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    return button
  }
  static func segments(_ titles: [String], selected: Int = 0, action: @escaping (Int) -> Void)
    -> UISegmentedControl
  {
    let control = UISegmentedControl(items: titles)
    control.selectedSegmentIndex = selected
    control.selectedSegmentTintColor = QFUI.surface
    control.backgroundColor = QFUI.paleGreen
    control.setTitleTextAttributes([.foregroundColor: QFUI.text], for: .normal)
    control.addAction(
      UIAction { [weak control] _ in action(control?.selectedSegmentIndex ?? 0) },
      for: .valueChanged)
    control.snp.makeConstraints { $0.height.greaterThanOrEqualTo(42) }
    return control
  }
  static func chips(
    _ options: [QFInterestOption], selected: [String], action: @escaping (String) -> Void
  ) -> UIView {
    let stack = QFTabUI.stack([], spacing: 10)
    for start in stride(from: 0, to: options.count, by: 3) {
      let row = QFTabUI.stack([], axis: .horizontal, spacing: 8)
      row.distribution = .fillEqually
      for option in options[start..<min(start + 3, options.count)] {
        let isSelected = selected.contains(option.id)
        let button = QFTabUI.button(
          option.name, size: 15, weight: isSelected ? .semibold : .regular,
          color: isSelected ? QFUI.success : QFUI.text,
          background: isSelected ? QFUI.paleGreen : QFUI.surface
        ) { action(option.id) }
        button.titleLabel?.numberOfLines = 0
        button.layer.cornerRadius = 16
        button.layer.borderWidth = isSelected ? 1 : 0
        button.layer.borderColor = QFUI.success.cgColor
        if isSelected { button.accessibilityTraits.insert(.selected) }
        button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
        row.addArrangedSubview(button)
      }
      stack.addArrangedSubview(row)
    }
    return stack
  }
  static func thumbnail(_ id: String?, app: QFAppSession, height: CGFloat = 96)
    -> QFContentImageView
  {
    let image = QFContentImageView()
    image.backgroundColor = QFUI.surface
    image.layer.cornerRadius = 16
    image.clipsToBounds = true
    image.contentMode = .scaleAspectFill
    image.snp.makeConstraints { $0.height.equalTo(height) }
    image.load(id, app: app)
    return image
  }
}

@MainActor
final class QFContentImageView: UIImageView {
  private var task: Task<Void, Never>?
  private var requestID = UUID()
  private var mediaID: String?
  private weak var app: QFAppSession?
  private var loaded = false
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let retryButton = UIButton(type: .system)
  required init?(coder: NSCoder) { nil }
  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = true
    spinner.hidesWhenStopped = true
    addSubview(spinner)
    spinner.snp.makeConstraints { $0.center.equalToSuperview() }
    retryButton.setTitle("", for: .normal)
    retryButton.titleLabel?.numberOfLines = 0
    retryButton.titleLabel?.textAlignment = .center
    retryButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
    retryButton.backgroundColor = QFUI.surface.withAlphaComponent(0.95)
    retryButton.layer.cornerRadius = 8
    retryButton.addAction(
      UIAction { [weak self] _ in
        guard let self, let app = self.app else { return }
        self.load(self.mediaID, app: app)
      }, for: .touchUpInside)
    addSubview(retryButton)
    retryButton.snp.makeConstraints {
      $0.center.equalToSuperview()
      $0.width.lessThanOrEqualToSuperview().inset(8)
      $0.height.greaterThanOrEqualTo(44)
    }
    retryButton.isHidden = true
    let tap = UITapGestureRecognizer(target: self, action: #selector(preview))
    tap.cancelsTouchesInView = false
    addGestureRecognizer(tap)
  }
  deinit { task?.cancel() }
  func load(_ id: String?, app: QFAppSession) {
    if mediaID == id, self.app === app, loaded { return }
    task?.cancel()
    requestID = UUID()
    let identifier = requestID
    self.app = app
    mediaID = id
    loaded = false
    retryButton.isHidden = true
    spinner.stopAnimating()
    image = UIImage(systemName: "photo")
    tintColor = QFUI.secondary
    contentMode = .center
    retryButton.setTitle(app.text("图片加载失败\n点击重试", "Image failed to load\nTap to retry"), for: .normal)
    accessibilityLabel = id == nil ? app.text("暂无图片", "No image") : app.text("图片加载中", "Loading image")
    guard let id else { return }
    let cacheKey = "qf.content." + app.contentScope + "." + id
    if let cached = QFContentImageCache.shared.retrieveImageInMemoryCache(forKey: cacheKey) {
      image = cached
      contentMode = .scaleAspectFill
      loaded = true
      accessibilityLabel = app.text("查看大图", "View full image")
      return
    }
    spinner.startAnimating()
    let owner = app.user?.userId
    task = Task { [weak self] in
      do {
        let bytes = try await app.loadContentMedia(id)
        try Task.checkCancellation()
        guard let self, self.requestID == identifier, app.user?.userId == owner else { return }
        guard let decoded = UIImage(data: bytes) else { throw URLError(.cannotDecodeContentData) }
        QFContentImageCache.shared.store(
          decoded, forKey: cacheKey, toDisk: false, completionHandler: nil)
        self.image = decoded
        self.contentMode = .scaleAspectFill
        self.loaded = true
        self.spinner.stopAnimating()
        self.accessibilityLabel = app.text("查看大图", "View full image")
      } catch is CancellationError {} catch {
        guard let self, self.requestID == identifier, app.user?.userId == owner else { return }
        self.spinner.stopAnimating()
        self.retryButton.isHidden = false
        self.retryButton.accessibilityHint = QFProfileContentController.errorText(error, app: app)
        self.accessibilityLabel = app.text("图片加载失败", "Image failed to load")
      }
    }
  }
  @objc private func preview() {
    guard loaded, let image, let app else { return }
    var responder: UIResponder? = self
    while let current = responder {
      if let controller = current as? UIViewController {
        guard controller.presentedViewController == nil else { return }
        controller.view.endEditing(true)
        controller.present(QFContentImagePreviewController(image: image, app: app), animated: true)
        return
      }
      responder = current.next
    }
  }
}

@MainActor
final class QFContentImagePreviewController: UIViewController, UIScrollViewDelegate {
  private let image: UIImage
  private let app: QFAppSession
  private let zoomView = UIScrollView()
  private let imageView = UIImageView()
  private var subscription: AnyCancellable?
  init(image: UIImage, app: QFAppSession) {
    self.image = image
    self.app = app
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    let close = QFTabUI.button(app.text("关闭", "Close"), size: 16, color: .white) { [weak self] in self?.qfClose() }
    view.addSubview(close)
    close.snp.makeConstraints {
      $0.leading.top.equalTo(view.safeAreaLayoutGuide).offset(12)
      $0.width.equalTo(64)
      $0.height.equalTo(44)
    }
    zoomView.delegate = self
    zoomView.minimumZoomScale = 1
    zoomView.maximumZoomScale = 4
    view.addSubview(zoomView)
    zoomView.snp.makeConstraints {
      $0.top.equalTo(close.snp.bottom).offset(8)
      $0.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
    }
    imageView.image = image
    imageView.contentMode = .scaleAspectFit
    imageView.accessibilityLabel = app.text("图片预览，可双指缩放或双击放大", "Image preview. Pinch or double-tap to zoom.")
    zoomView.addSubview(imageView)
    imageView.snp.makeConstraints {
      $0.edges.equalTo(zoomView.contentLayoutGuide)
      $0.width.height.equalTo(zoomView.frameLayoutGuide)
    }
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
    doubleTap.numberOfTapsRequired = 2
    zoomView.addGestureRecognizer(doubleTap)
    let owner = app.user?.userId
    subscription = app.$user.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] user in
      if user?.userId != owner {
        self?.imageView.image = nil
        self?.qfClose()
      }
    }
  }
  func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
  @objc private func toggleZoom() {
    zoomView.setZoomScale(zoomView.zoomScale > 1 ? 1 : 2.5, animated: true)
  }
}

@MainActor
private final class QFContentMediaPicker: NSObject, PHPickerViewControllerDelegate {
  let controller: PHPickerViewController
  private let app: QFAppSession
  private let video: Bool
  private let crop: ((UIImage) async -> UIImage?)?
  private let completion: (Result<[QFContentMedia], Error>) -> Void
  private let loading: () -> Void
  private var task: Task<Void, Never>?
  private var providerProgress: Progress?
  private var completed = false
  init(app: QFAppSession, video: Bool, limit: Int, crop: ((UIImage) async -> UIImage?)?,
    loading: @escaping () -> Void, completion: @escaping (Result<[QFContentMedia], Error>) -> Void) {
    self.app = app; self.video = video; self.crop = crop
    self.loading = loading; self.completion = completion
    var configuration = PHPickerConfiguration()
    configuration.selectionLimit = video || crop != nil ? 1 : min(9, max(1, limit))
    configuration.selection = .ordered
    configuration.filter = video ? .videos : .images
    controller = PHPickerViewController(configuration: configuration)
    super.init(); controller.delegate = self
  }
  deinit { task?.cancel(); providerProgress?.cancel() }
  func cancel() { task?.cancel(); providerProgress?.cancel(); finish(.success([])) }
  private func finish(_ result: Result<[QFContentMedia], Error>) {
    guard !completed else { return }; completed = true; completion(result)
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    guard !completed, task == nil else { return }
    guard !results.isEmpty else { picker.dismiss(animated: true); finish(.success([])); return }
    let scope = app.contentScope
    let oversizedVideoMessage = app.text("视频不能超过20MB。", "Videos must be 20 MB or smaller.")
    task = Task { [self] in
      var prepared: [QFContentMedia] = []
      defer { task = nil; providerProgress = nil }
      await withCheckedContinuation { continuation in
        picker.dismiss(animated: true) { continuation.resume() }
      }
      do {
        loading()
        for result in results {
          try Task.checkCancellation()
          guard app.contentScope == scope else { throw CancellationError() }
          let provider = result.itemProvider
          let bytes: Data
          if video {
            bytes = try await withCheckedThrowingContinuation { continuation in
              providerProgress = provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                do {
                  guard let url else { throw error ?? URLError(.cannotDecodeContentData) }
                  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                  guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 20 * 1024 * 1024 else {
                    throw QFAPIError(code: 40000, message: oversizedVideoMessage)
                  }
                  continuation.resume(returning: try Data(contentsOf: url))
                } catch { continuation.resume(throwing: error) }
              }
            }
          } else {
            var source: UIImage = try await withCheckedThrowingContinuation { continuation in
              providerProgress = provider.loadObject(ofClass: UIImage.self) { value, error in
                if let value = value as? UIImage { continuation.resume(returning: value) }
                else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
              }
            }
            try Task.checkCancellation()
            guard app.contentScope == scope else { throw CancellationError() }
            if let crop {
              guard let selected = await crop(source) else { throw CancellationError() }
              source = selected
            }
            let ratio = min(1, 2048 / max(source.size.width, source.size.height))
            let size = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let sanitized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
              source.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = sanitized.jpegData(compressionQuality: 0.86), data.count <= 8 * 1024 * 1024 else {
              throw QFAPIError(code: 40000, message: app.text("图片过大，请选择其他图片。", "This image is too large. Choose another image."))
            }
            bytes = data
          }
          try Task.checkCancellation()
          let isVideo = video
          let media = try await Task.detached(priority: .userInitiated) {
            try QFLocalMediaStore.save(bytes, video: isVideo, scope: scope)
          }.value
          prepared.append(media)
        }
        try Task.checkCancellation()
        guard app.contentScope == scope else { throw CancellationError() }
        finish(.success(prepared))
      } catch {
        for item in prepared { QFLocalMediaStore.remove(item.id, scope: scope) }
        finish(.failure(error))
      }
    }
  }
}

@MainActor
final class QFContentTextArea: UIView, UITextViewDelegate {
  let textView = UITextView()
  private let changed: (String) -> Void
  private let limit: Int
  init(_ label: String, text: String, limit: Int = 5000, changed: @escaping (String) -> Void) {
    self.changed = changed
    self.limit = limit
    super.init(frame: .zero)
    let caption = QFContentUI.label(label, size: 13, color: QFUI.secondary)
    textView.text = text
    textView.delegate = self
    textView.backgroundColor = QFUI.surface
    textView.textColor = QFUI.text
    textView.layer.cornerRadius = 12
    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.accessibilityLabel = label
    textView.isScrollEnabled = false
    textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
    let stack = QFTabUI.stack([caption, textView], spacing: 6)
    addSubview(stack)
    stack.snp.makeConstraints { $0.edges.equalToSuperview() }
    textView.snp.makeConstraints { $0.height.greaterThanOrEqualTo(100) }
  }
  required init?(coder: NSCoder) { nil }
  func textViewDidChange(_ textView: UITextView) {
    guard textView.markedTextRange == nil else { return }
    if textView.text.count > limit { textView.text = String(textView.text.prefix(limit)) }
    changed(textView.text)
  }
}
