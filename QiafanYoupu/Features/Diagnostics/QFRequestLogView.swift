#if DEBUG
  import Combine
  import SnapKit
  import UIKit

  @MainActor
  final class QFRequestLogViewController: UIViewController, UITableViewDataSource,
    UITableViewDelegate
  {
    private let app: QFAppSession
    private let store: QFRequestLogStore
    private var subscriptions = Set<AnyCancellable>()
    private var activeAction: DebugAction?
    private var entries: [QFRequestLogEntry] = []
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let errorContainer = UIView()
    private let errorLabel = QFUI.label("", size: 12, color: .systemRed, lines: 0)
    private let menuButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let pageLabel = QFUI.label("", size: 14)
    private let countLabel = QFUI.label("", size: 11, color: QFUI.secondary)

    private enum DebugAction {
      case reloadConfiguration
      case logout

      @MainActor
      func title(app: QFAppSession) -> String {
        switch self {
        case .reloadConfiguration:
          return app.text("正在重取配置", "Reloading configuration")
        case .logout:
          return app.text("正在退出会话", "Signing out")
        }
      }
    }

    init(app: QFAppSession, store: QFRequestLogStore? = nil) {
      self.app = app
      self.store = store ?? .shared
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
      super.viewDidLoad()
      title = app.text("接口日志", "API logs")
      navigationItem.largeTitleDisplayMode = .never
      view.backgroundColor = QFUI.background
      view.accessibilityIdentifier = "diagnostics.requests"
      navigationController?.navigationBar.tintColor = QFUI.orange
      configureNavigation()
      configureContent()
      store.loadPage(store.page)
      reloadFromStore()
      updateMenu()
      store.objectWillChange.receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.reloadFromStore() }
        .store(in: &subscriptions)
      app.objectWillChange.receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateMenu() }
        .store(in: &subscriptions)
      app.$interfaceLanguage.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.applyLanguage() }
        .store(in: &subscriptions)
    }

    private func configureNavigation() {
      menuButton.accessibilityIdentifier = "diagnostics.menu"
      menuButton.showsMenuAsPrimaryAction = true
      navigationItem.leftBarButtonItem = UIBarButtonItem(customView: menuButton)
      closeButton.setTitle(app.text("关闭", "Close"), for: .normal)
      closeButton.tintColor = QFUI.orange
      closeButton.accessibilityIdentifier = "diagnostics.requests.close"
      closeButton.addAction(
        UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
      navigationItem.rightBarButtonItem = UIBarButtonItem(customView: closeButton)
      [menuButton, closeButton].forEach { button in
        button.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(44) }
      }
    }

    private func configureContent() {
      errorContainer.addSubview(errorLabel)
      errorLabel.snp.makeConstraints { make in
        make.top.leading.trailing.equalToSuperview().inset(12)
        make.bottom.equalToSuperview().inset(12).priority(.high)
      }
      errorContainer.backgroundColor = UIColor.systemRed.withAlphaComponent(0.06)
      tableView.dataSource = self
      tableView.delegate = self
      tableView.register(QFRequestLogCell.self, forCellReuseIdentifier: QFRequestLogCell.reuseID)
      tableView.rowHeight = UITableView.automaticDimension
      tableView.estimatedRowHeight = 112
      tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
      tableView.backgroundColor = QFUI.background
      tableView.tableFooterView = UIView()
      let pagination = makePagination()
      let content = QFUI.stack(
        [errorContainer, tableView, pagination], axis: .vertical, spacing: 0)
      view.addSubview(content)
      content.snp.makeConstraints { make in make.edges.equalTo(view.safeAreaLayoutGuide) }
      pagination.setContentHuggingPriority(.required, for: .vertical)
      pagination.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func makePagination() -> UIView {
      let container = UIView()
      container.backgroundColor = QFUI.surface
      previousButton.setTitle(app.text("上一页", "Previous"), for: .normal)
      previousButton.accessibilityIdentifier = "diagnostics.requests.previousPage"
      nextButton.setTitle(app.text("下一页", "Next"), for: .normal)
      nextButton.accessibilityIdentifier = "diagnostics.requests.nextPage"
      [previousButton, nextButton].forEach { button in
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.tintColor = QFUI.orange
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.snp.makeConstraints { make in make.height.greaterThanOrEqualTo(44) }
      }
      previousButton.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          self.store.loadPage(self.store.page - 1)
          self.tableView.setContentOffset(.zero, animated: false)
        }, for: .touchUpInside)
      nextButton.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          self.store.loadPage(self.store.page + 1)
          self.tableView.setContentOffset(.zero, animated: false)
        }, for: .touchUpInside)
      pageLabel.textAlignment = .center
      countLabel.textAlignment = .center
      let labels = QFUI.stack([pageLabel, countLabel], axis: .vertical, spacing: 3)
      let row = QFUI.stack([previousButton, labels, nextButton], axis: .horizontal, spacing: 12)
      row.alignment = .center
      container.addSubview(row)
      row.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview().inset(10)
        make.leading.trailing.equalToSuperview().inset(16)
      }
      return container
    }

    private func makeEmptyState() -> UIView {
      let container = UIView()
      let image = UIImageView(image: UIImage(systemName: "network"))
      image.tintColor = QFUI.secondary
      image.contentMode = .scaleAspectFit
      image.snp.makeConstraints { make in make.size.equalTo(32) }
      let title = QFUI.label(app.text("暂无请求日志", "No request logs"), size: 17, weight: .semibold)
      let subtitle = QFUI.label(
        app.text(
          "Debug 模式下，应用发起请求后会显示在这里。",
          "Requests made by the app in Debug mode appear here."),
        size: 14, color: QFUI.secondary, lines: 0)
      title.textAlignment = .center
      subtitle.textAlignment = .center
      let stack = QFUI.stack([image, title, subtitle], axis: .vertical, spacing: 12)
      stack.alignment = .center
      container.addSubview(stack)
      stack.snp.makeConstraints { make in
        make.center.equalToSuperview()
        make.leading.greaterThanOrEqualToSuperview().inset(28)
        make.trailing.lessThanOrEqualToSuperview().inset(28)
        make.width.lessThanOrEqualTo(420)
      }
      return container
    }

    private func reloadFromStore() {
      guard isViewLoaded else { return }
      entries = store.entries
      errorLabel.text = store.storageErrorCode.map {
        app.format("请求日志文件读写失败（错误码 %d）", "Could not read or write request logs (error %d).", $0)
      }
      errorContainer.isHidden = store.storageErrorCode == nil
      tableView.backgroundView = store.totalCount == 0 ? makeEmptyState() : nil
      tableView.reloadData()
      pageLabel.text = app.format("第 %d / %d 页", "Page %d of %d", store.page + 1, store.totalPages)
      countLabel.text = app.format(
        "共 %d 条 · 每页 %d 条", "%d total · %d per page", store.totalCount, store.pageSize)
      previousButton.isEnabled = store.page > 0
      nextButton.isEnabled = store.page + 1 < store.totalPages
    }

    private var displayedAction: DebugAction? {
      activeAction ?? (app.loadingConfiguration ? .reloadConfiguration : nil)
    }

    private var actionsDisabled: Bool {
      activeAction != nil || app.loadingConfiguration || app.isLoggingIn
    }

    private func updateMenu() {
      guard isViewLoaded else { return }
      var configuration = UIButton.Configuration.plain()
      configuration.title = displayedAction?.title(app: app) ?? app.text("调试", "Debug")
      configuration.baseForegroundColor = QFUI.orange
      configuration.contentInsets = .zero
      configuration.imagePadding = 6
      configuration.showsActivityIndicator = displayedAction != nil
      configuration.activityIndicatorColorTransformer = UIConfigurationColorTransformer { _ in
        QFUI.orange
      }
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
        var attributes = $0
        attributes.font = .systemFont(ofSize: 14)
        return attributes
      }
      menuButton.configuration = configuration
      menuButton.isEnabled = !actionsDisabled
      menuButton.accessibilityLabel = displayedAction?.title(app: app) ?? app.text("调试", "Debug")
      var items = [
        UIAction(title: app.text("重新获取启动配置", "Reload startup configuration")) { [weak self] _ in
          self?.perform(.reloadConfiguration)
        },
        UIAction(title: app.text("查看沙盒日志目录", "Show sandbox log directory")) { [weak self] _ in
          self?.showMessage(
            QFCrashRecorder.shared.reportsDirectory.deletingLastPathComponent().path)
        },
      ]
      if app.user != nil {
        items.append(
          UIAction(title: app.text("退出当前测试会话", "Sign out of the test session")) {
            [weak self] _ in self?.perform(.logout)
          })
      }
      menuButton.menu = UIMenu(children: items)
    }

    private func perform(_ action: DebugAction) {
      guard !actionsDisabled else { return }
      activeAction = action
      updateMenu()
      Task { [weak self, app] in
        var message: String?
        switch action {
        case .reloadConfiguration:
          await app.loadConfiguration()
          message = app.configurationError
        case .logout:
          await QFGetuiPushService.shared.unregisterBeforeSignOut()
          do { try await app.logout() } catch {
            QFGetuiPushService.shared.signOutDidFail()
            message = QFProfileContentController.errorText(error, app: app)
          }
        }
        guard let self else { return }
        self.activeAction = nil
        self.updateMenu()
        if let message { self.showMessage(message) }
      }
    }

    private func showMessage(_ message: String) {
      guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
      let alert = UIAlertController(
        title: app.text("调试信息", "Debug information"), message: message,
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .cancel))
      present(alert, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
      guard
        let cell = tableView.dequeueReusableCell(
          withIdentifier: QFRequestLogCell.reuseID, for: indexPath) as? QFRequestLogCell
      else { return UITableViewCell() }
      let entry = entries[indexPath.row]
      cell.configure(entry, app: app)
      cell.onOpen = { [weak self] in self?.open(entry.id) }
      return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
      tableView.deselectRow(at: indexPath, animated: true)
      open(entries[indexPath.row].id)
    }

    private func open(_ id: UUID) {
      navigationController?.pushViewController(
        QFRequestLogDetailViewController(app: app, store: store, id: id), animated: true)
    }

    private func applyLanguage() {
      guard isViewLoaded else { return }
      title = app.text("接口日志", "API logs")
      closeButton.setTitle(app.text("关闭", "Close"), for: .normal)
      previousButton.setTitle(app.text("上一页", "Previous"), for: .normal)
      nextButton.setTitle(app.text("下一页", "Next"), for: .normal)
      reloadFromStore()
      updateMenu()
    }
  }

  @MainActor
  private final class QFRequestLogCell: UITableViewCell {
    static let reuseID = "QFRequestLogCell"
    var onOpen: (() -> Void)?
    private let methodLabel = QFUI.label("", size: 12, weight: .bold)
    private let statusLabel = QFUI.label("", size: 12)
    private let timeLabel = QFUI.label("", size: 12, color: QFUI.secondary)
    private let urlLabel = QFUI.label("", size: 12, lines: 2)
    private let durationLabel = QFUI.label("", size: 11, color: QFUI.secondary)
    private let openButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
      super.init(style: style, reuseIdentifier: reuseIdentifier)
      backgroundColor = QFUI.surface
      selectionStyle = .none
      isAccessibilityElement = false
      urlLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      let spacer = UIView()
      let header = QFUI.stack(
        [methodLabel, statusLabel, spacer, timeLabel], axis: .horizontal, spacing: 8)
      header.alignment = .firstBaseline
      [methodLabel, statusLabel, timeLabel].forEach {
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
      }
      let stack = QFUI.stack([header, urlLabel, durationLabel], axis: .vertical, spacing: 8)
      stack.accessibilityElementsHidden = true
      contentView.addSubview(stack)
      stack.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview().inset(12)
        make.leading.trailing.equalToSuperview().inset(16)
      }
      openButton.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
      contentView.addSubview(openButton)
      openButton.snp.makeConstraints { make in make.edges.equalToSuperview() }
      accessibilityElements = [openButton]
    }

    required init?(coder: NSCoder) { return nil }

    override func prepareForReuse() {
      super.prepareForReuse()
      onOpen = nil
    }

    func configure(_ entry: QFRequestLogEntry, app: QFAppSession) {
      methodLabel.text = entry.method
      statusLabel.text = QFRequestLogPresentation.status(entry, app: app)
      statusLabel.textColor = QFRequestLogPresentation.color(entry.status)
      timeLabel.text = QFRequestLogPresentation.time(
        entry.startedAt, dateStyle: .none, timeStyle: .medium, app: app)
      urlLabel.text = entry.url
      durationLabel.text = entry.duration.map { String(format: "%.0f ms", $0 * 1000) }
      durationLabel.isHidden = entry.duration == nil
      openButton.accessibilityIdentifier = "diagnostics.request.\(entry.id.uuidString)"
      openButton.accessibilityLabel =
        "\(entry.method), \(QFRequestLogPresentation.status(entry, app: app)), \(entry.url), \(timeLabel.text ?? "")"
    }
  }

  @MainActor
  private final class QFRequestLogDetailViewController: UIViewController {
    private let app: QFAppSession
    private let store: QFRequestLogStore
    private let id: UUID
    private let scrollView = UIScrollView()
    private let content = UIView()
    private let stack = QFUI.stack([], axis: .vertical, spacing: 16)
    private var subscriptions = Set<AnyCancellable>()
    private var entry: QFRequestLogEntry?
    private var rendered = false

    init(app: QFAppSession, store: QFRequestLogStore, id: UUID) {
      self.app = app
      self.store = store
      self.id = id
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
      super.viewDidLoad()
      title = app.text("请求详情", "Request details")
      navigationItem.largeTitleDisplayMode = .never
      view.backgroundColor = QFUI.background
      scrollView.accessibilityIdentifier = "diagnostics.request.detail"
      scrollView.alwaysBounceVertical = true
      view.addSubview(scrollView)
      scrollView.addSubview(content)
      content.addSubview(stack)
      scrollView.snp.makeConstraints { make in make.edges.equalTo(view.safeAreaLayoutGuide) }
      content.snp.makeConstraints { make in
        make.edges.equalTo(scrollView.contentLayoutGuide)
        make.width.equalTo(scrollView.frameLayoutGuide)
      }
      stack.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview().inset(16)
        make.centerX.equalToSuperview()
        make.width.equalToSuperview().offset(-32).priority(.high)
        make.width.lessThanOrEqualTo(760)
        make.leading.greaterThanOrEqualToSuperview().inset(16)
        make.trailing.lessThanOrEqualToSuperview().inset(16)
      }
      reloadEntry()
      store.$revision.dropFirst().receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.reloadEntry() }
        .store(in: &subscriptions)
      app.$interfaceLanguage.removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          guard let self else { return }
          self.title = self.app.text("请求详情", "Request details")
          self.reloadEntry(force: true)
        }
        .store(in: &subscriptions)
    }

    private func reloadEntry(force: Bool = false) {
      let updated = store.entry(id: id)
      if !force, rendered, entry?.finishedAt == updated?.finishedAt,
        (entry == nil) == (updated == nil)
      {
        return
      }
      rendered = true
      entry = updated
      stack.arrangedSubviews.forEach {
        stack.removeArrangedSubview($0)
        $0.removeFromSuperview()
      }
      guard let entry else {
        stack.addArrangedSubview(
          QFUI.label(
            app.text("这条日志已被轮转清理。", "This log was removed during rotation."),
            size: 14, color: QFUI.secondary, lines: 0))
        return
      }
      stack.addArrangedSubview(timeSection(entry))
      stack.addArrangedSubview(
        field(title: app.text("URL / 接口", "URL / API"), value: "\(entry.method)\n\(entry.url)"))
      stack.addArrangedSubview(field(title: app.text("请求参数", "Request parameters"), value: parameters(entry)))
      stack.addArrangedSubview(field(title: app.text("请求头", "Request headers"), value: headers(entry.requestHeaders)))
      stack.addArrangedSubview(field(title: app.text("返回内容", "Response"), value: response(entry)))
    }

    private func timeSection(_ entry: QFRequestLogEntry) -> UIView {
      let title = QFUI.label(app.text("请求时间", "Request time"), size: 17, weight: .semibold)
      let time = selectableText(
        QFRequestLogPresentation.time(
          entry.startedAt, dateStyle: .short, timeStyle: .long, app: app))
      let status = QFUI.label(
        QFRequestLogPresentation.status(entry, app: app), size: 14,
        color: QFRequestLogPresentation.color(entry.status))
      var labels: [UIView] = [title, time, status]
      if let duration = entry.duration {
        labels.append(
          QFUI.label(app.format("耗时 %.0f ms", "Duration: %.0f ms", duration * 1000), size: 14))
      }
      return card(QFUI.stack(labels, axis: .vertical, spacing: 8))
    }

    private func field(title: String, value: String) -> UIView {
      card(
        QFUI.stack(
          [QFUI.label(title, size: 17, weight: .semibold), selectableText(value)],
          axis: .vertical, spacing: 10))
    }

    private func selectableText(_ value: String) -> UITextView {
      let text = UITextView()
      text.text = value
      text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      text.textColor = QFUI.text
      text.backgroundColor = .clear
      text.isEditable = false
      text.isSelectable = true
      text.isScrollEnabled = false
      text.textContainerInset = .zero
      text.textContainer.lineFragmentPadding = 0
      text.textContainer.lineBreakMode = .byCharWrapping
      text.setContentCompressionResistancePriority(.required, for: .vertical)
      return text
    }

    private func card(_ content: UIView) -> UIView {
      let container = UIView()
      container.backgroundColor = QFUI.surface
      container.layer.cornerRadius = 12
      container.addSubview(content)
      content.snp.makeConstraints { make in make.edges.equalToSuperview().inset(16) }
      return container
    }

    private func parameters(_ entry: QFRequestLogEntry) -> String {
      let query =
        URLComponents(string: entry.url)?.queryItems?.map {
          "\($0.name): \($0.value ?? "")"
        }.joined(separator: "\n") ?? ""
      let body = entry.requestBody.isEmpty ? app.text("（无请求体）", "(No request body)") : entry.requestBody
      return "Query\n\(query.isEmpty ? app.text("（无查询参数）", "(No query parameters)") : query)\n\nBody\n\(body)"
    }

    private func headers(_ headers: [String: String]) -> String {
      guard !headers.isEmpty else { return app.text("（无）", "(None)") }
      return headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    private func response(_ entry: QFRequestLogEntry) -> String {
      if entry.status == .inProgress {
        return app.text("请求进行中，尚无返回内容。", "The request is still in progress.")
      }
      let status = entry.statusCode.map(String.init) ?? app.text("无响应", "No response")
      var parts = [app.format("HTTP 状态码：%@", "HTTP status: %@", status)]
      if let error = entry.errorDescription {
        parts.append(app.format("错误：%@", "Error: %@", error))
      }
      parts.append(app.text("响应头", "Response headers") + "\n" + headers(entry.responseHeaders))
      let body = entry.responseBody.isEmpty ? app.text("（无响应体）", "(No response body)") : entry.responseBody
      parts.append("Body\n\(body)")
      return parts.joined(separator: "\n\n")
    }
  }

  private enum QFRequestLogPresentation {
    @MainActor
    static func status(_ entry: QFRequestLogEntry, app: QFAppSession) -> String {
      switch entry.status {
      case .inProgress: return app.text("进行中", "In progress")
      case .succeeded: return app.format("成功 · %d", "Succeeded · %d", entry.statusCode ?? 0)
      case .failed:
        return entry.statusCode.map { app.format("失败 · %d", "Failed · %d", $0) }
          ?? app.text("请求失败", "Request failed")
      }
    }

    @MainActor
    static func time(
      _ date: Date, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style,
      app: QFAppSession
    ) -> String {
      let formatter = DateFormatter()
      formatter.locale = Locale(
        identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
      formatter.dateStyle = dateStyle
      formatter.timeStyle = timeStyle
      return formatter.string(from: date)
    }

    static func color(_ status: QFRequestLogStatus) -> UIColor {
      switch status {
      case .inProgress: return QFUI.orange
      case .succeeded: return QFUI.green
      case .failed: return .systemRed
      }
    }
  }
#endif
