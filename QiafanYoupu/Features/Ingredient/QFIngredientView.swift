import Combine
import MJRefresh
import SnapKit
import UIKit

@MainActor
final class QFIngredientViewController: QFPageViewController, UITextFieldDelegate {
  private struct Category {
    let title: String
    let code: String?
  }

  private let categories = [
    Category(title: "全部", code: nil), Category(title: "蔬菜", code: "VEGETABLE"),
    Category(title: "肉蛋", code: "MEAT_EGG"), Category(title: "奶制品", code: "DAIRY"),
    Category(title: "水果", code: "FRUIT"), Category(title: "谷物", code: "GRAIN"),
    Category(title: "水产", code: "SEAFOOD"), Category(title: "菌藻", code: "FUNGI_ALGAE"),
    Category(title: "调味", code: "SEASONING"),
  ]

  private let preparationDates: (String, String)?
  private var preparationHeader: UIView?
  private var inventoryEdit: QFInventoryInlineDraft?
  private var inventoryMutation: Task<Void, Never>?
  private var recoveryOnlyInventoryID: String?
  private var inventoryNeedsReview = false
  private var inventoryEditingError: String?
  private var inventoryUnits: [QFMeasurementUnit] = []
  private var unitTask: Task<Void, Never>?
  private var inventoryDraftKey: String { "inventory-edit." + (app.planningHouseholdID ?? "personal") }

  init(app: QFAppSession, preparationDates: (String, String)? = nil) {
    self.preparationDates = preparationDates
    super.init(app: app)
  }
  required init?(coder: NSCoder) { nil }

  private var shopping = false
  private var selectedCategoryIndex = 0
  private var inventoryItems: [QFInventoryLot] = []
  private var inventoryTotal = 0
  private var nearExpiryCount = 0
  private var expiredCount = 0
  private var expiryFilter: String?
  private var inventoryNextPage = 0
  private var inventoryHasMore = false
  private var inventoryLoaded = false
  private var shoppingList: QFShoppingList?
  private var shoppingLoaded = false
  private var shoppingContextID = UUID()
  private var loading = false
  private var loadMoreFailed = false
  private var firstAppearance = true
  private var skipNextAppearanceReload = false
  private var requestID = UUID()
  private var requestTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var shoppingMutationTasks: [String: Task<Void, Never>] = [:]
  private var shoppingListMutationTask: Task<Void, Never>?
  private let operationHUD = QFOperationHUD()
  private lazy var receiveShoppingButton = QFTabUI.button("", size: 17, weight: .semibold, color: QFUI.onPrimary, background: QFUI.primary) { [weak self] in self?.receiveShoppingSelection() }

  private let searchField = UITextField()
  private let segment = UISegmentedControl(items: [])
  private let list = QFContentListStack()
  private let listTitle = QFTabUI.label("", size: 17, weight: .semibold)
  private let headingTitle = QFTabUI.label("", size: 28, weight: .bold)
  private let headingSubtitle = QFTabUI.label("", size: 12, color: QFUI.secondary, lines: 0)
  private let scanButton = QFTabUI.iconButton("barcode.viewfinder", label: "") {}
  private let addButton = QFTabUI.button(
    "", size: 14, weight: .semibold, color: QFUI.onPrimary, background: QFUI.primary) {}
  private let noticeText = QFTabUI.label("", size: 12, color: QFUI.warning, lines: 0)
  private let noticeAction = QFTabUI.label("", size: 12, weight: .medium, color: QFUI.warning)
  private let refreshControl = UIRefreshControl()
  private lazy var loadMoreFooter: MJRefreshAutoNormalFooter = {
    let footer = MJRefreshAutoNormalFooter { [weak self] in self?.loadMoreInventory() }
    footer.autoTriggerTimes = 1
    footer.triggerAutomaticallyRefreshPercent = 0.5
    footer.stateLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
    footer.stateLabel?.textColor = QFUI.secondary
    return footer
  }()
  private var sorting: UIButton!
  private var notice: UIButton!
  private var discovery: UIStackView!
  private var categoriesView: UIView!
  private var categoryButtons: [Int: UIButton] = [:]
  private var compact = false
  private var categorySwipe: QFCategorySwipeBinding?

  deinit {
    requestTask?.cancel()
    searchTask?.cancel()
    inventoryMutation?.cancel()
    unitTask?.cancel()
    shoppingMutationTasks.values.forEach { $0.cancel() }
    shoppingListMutationTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.accessibilityIdentifier = "ingredient.screen"
    scrollView.keyboardDismissMode = .onDrag
    let regularHeader = makeHeader()
    if preparationDates == nil {
      contentStack.addArrangedSubview(regularHeader)
    } else {
      let header = QFSettingsPageUI.header(app.text("备菜", "Prep"), backLabel: app.text("返回", "Back")) { [weak self] in self?.qfClose() }
      preparationHeader = header
      QFSettingsPageUI.installHeader(header, in: view)
      if let stack = header as? UIStackView, let last = stack.arrangedSubviews.last {
        stack.removeArrangedSubview(last); last.removeFromSuperview()
        if let back = stack.arrangedSubviews.first as? UIButton {
          back.snp.remakeConstraints { $0.width.equalTo(84); $0.height.equalTo(44) }; back.contentHorizontalAlignment = .leading
        }
        addButton.removeFromSuperview()
        addButton.snp.remakeConstraints { $0.width.equalTo(84); $0.height.equalTo(44) }
        addButton.titleLabel?.numberOfLines = 2
        addButton.titleLabel?.lineBreakMode = .byWordWrapping
        addButton.titleLabel?.adjustsFontSizeToFitWidth = true
        addButton.titleLabel?.minimumScaleFactor = 0.75
        addButton.backgroundColor = .clear; addButton.setTitleColor(QFUI.primary, for: .normal)
        stack.addArrangedSubview(addButton)
      }
      scrollView.snp.remakeConstraints { $0.top.equalTo(header.snp.bottom); $0.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide) }
      let scan = QFTabUI.button("", background: QFUI.warningBackground) { [weak self] in self?.openReceiptScanner() }
      let label = QFTabUI.label(app.text("扫描商品条码", "Scan product barcode"), size: 16, weight: .semibold, lines: 0)
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
      let row = QFTabUI.stack([label, QFTabUI.symbol("barcode.viewfinder", size: 28, color: QFUI.primary)], axis: .horizontal, spacing: 12)
      row.isUserInteractionEnabled = false; scan.addSubview(row)
      row.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
      scan.snp.makeConstraints { $0.height.greaterThanOrEqualTo(76) }
      contentStack.addArrangedSubview(scan)
    }
    contentStack.addArrangedSubview(makeSearch())
    discovery = QFTabUI.stack([], axis: .horizontal, spacing: 12)
    discovery.distribution = .fillEqually
    contentStack.addArrangedSubview(discovery)
    configureSegment()
    let segmentedCard = QFTabUI.card(segment, padding: 4, background: QFUI.surfaceAlt)
    if preparationDates == nil { contentStack.addArrangedSubview(segmentedCard) }
    else { contentStack.insertArrangedSubview(segmentedCard, at: 1) }
    notice = makeExpiryNotice()
    contentStack.addArrangedSubview(notice)
    categoriesView = makeCategories()
    contentStack.addArrangedSubview(categoriesView)
    sorting = QFTabUI.button("", size: 12, color: QFUI.secondary) {}
    sorting.addAction(UIAction { [weak self] _ in guard let self else { return }; if self.shopping { self.showShoppingListActions() } else { self.chooseExpiryFilter() } }, for: .touchUpInside)
    sorting.snp.makeConstraints { $0.height.greaterThanOrEqualTo(32) }
    let heading = QFTabUI.stack([listTitle, UIView(), sorting], axis: .horizontal, spacing: 8)
    heading.alignment = .center
    heading.accessibilityIdentifier = "ingredient.list.heading"
    heading.isHidden = preparationDates != nil
    discovery.isHidden = preparationDates != nil
    contentStack.addArrangedSubview(heading)
    list.axis = .vertical
    list.spacing = 10
    list.accessibilityIdentifier = "ingredient.list"
    contentStack.addArrangedSubview(list)
    view.addSubview(receiveShoppingButton)
    receiveShoppingButton.accessibilityIdentifier = "shopping.receive"
    receiveShoppingButton.snp.makeConstraints {
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
      $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12); $0.height.equalTo(48)
    }
    refreshControl.addAction(UIAction { [weak self] _ in self?.reloadCurrent(force: true) }, for: .valueChanged)
    scrollView.refreshControl = refreshControl
    scrollView.mj_footer = loadMoreFooter
    applyLanguage()
    refreshCategories()
    renderCurrent()
    updateLoadMoreFooter()
    categorySwipe = QFCategorySwipeBinding(
      control: segment, in: list,
      backGesture: navigationController?.interactivePopGestureRecognizer)
    inventoryEdit = QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: inventoryDraftKey)
    bindSessionChanges()
    loadInventoryUnits()
    reloadCurrent()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if firstAppearance {
      firstAppearance = false
    } else if skipNextAppearanceReload {
      skipNextAppearanceReload = false
    } else {
      reloadCurrent()
    }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isMovingFromParent || isBeingDismissed {
      requestTask?.cancel()
      searchTask?.cancel()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let next = view.bounds.width < 360
    guard next != compact else { return }
    compact = next
    discovery.axis = compact ? .vertical : .horizontal
  }

  private func configureSegment() {
    segment.selectedSegmentIndex = 0
    segment.accessibilityIdentifier = "ingredient.segment"
    segment.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.requestTask?.cancel()
        self.shopping = self.segment.selectedSegmentIndex == 1
        self.applyLanguage()
        self.renderCurrent()
        self.updateLoadMoreFooter()
        if self.shopping ? !self.shoppingLoaded : !self.inventoryLoaded { self.reloadCurrent() }
      }, for: .valueChanged)
    segment.snp.makeConstraints { $0.height.equalTo(36) }
  }

  private func bindSessionChanges() {
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      guard let self else { return }
      self.resetLoadedContent()
      self.applyLanguage()
      self.refreshCategories()
      self.renderCurrent()
      self.reloadCurrent(force: true)
    }.store(in: &cancellables)
    app.$user.dropFirst().map { $0?.userId }.removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      guard let self else { return }
      self.resetLoadedContent()
      self.applyLanguage()
      self.renderCurrent()
      self.reloadCurrent(force: true)
    }.store(in: &cancellables)
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      guard let self else { return }
      self.resetLoadedContent()
      self.applyLanguage()
      self.renderCurrent()
      self.reloadCurrent(force: true)
    }.store(in: &cancellables)
  }

  private func resetLoadedContent() {
    inventoryMutation?.cancel(); inventoryMutation = nil
    if presentedViewController is QFInventoryDeleteSheet { dismiss(animated: false) }
    unitTask?.cancel()
    inventoryEdit = QFContentDraftStore.load(QFInventoryInlineDraft.self, app: app, kind: inventoryDraftKey)
    inventoryEditingError = nil
    inventoryNeedsReview = false
    nearExpiryCount = 0; expiredCount = 0; expiryFilter = nil
    loadInventoryUnits()
    requestTask?.cancel()
    searchTask?.cancel()
    requestID = UUID()
    shoppingContextID = UUID()
    skipNextAppearanceReload = false
    shoppingMutationTasks.values.forEach { $0.cancel() }
    shoppingMutationTasks.removeAll()
    shoppingListMutationTask?.cancel()
    shoppingListMutationTask = nil
    operationHUD.hide()
    inventoryItems = []
    recoveryOnlyInventoryID = nil
    inventoryTotal = 0
    inventoryNextPage = 0
    inventoryHasMore = false
    inventoryLoaded = false
    shoppingList = nil
    shoppingLoaded = false
    loading = false
    loadMoreFailed = false
    refreshControl.endRefreshing()
    loadMoreFooter.endRefreshing()
  }

  private func makeHeader() -> UIView {
    let heading = QFTabUI.stack([headingTitle, headingSubtitle], spacing: 6)
    scanButton.addAction(
      UIAction { [weak self] _ in self?.openReceiptScanner() }, for: .touchUpInside)
    scanButton.backgroundColor = QFUI.surface
    scanButton.layer.cornerRadius = 14
    scanButton.accessibilityIdentifier = "ingredient.scan"
    addButton.addAction(UIAction { [weak self] _ in self?.chooseIngredientForInventory() }, for: .touchUpInside)
    addButton.accessibilityIdentifier = "ingredient.add"
    addButton.contentEdgeInsets = .zero
    addButton.snp.makeConstraints {
      $0.width.equalTo(72)
      $0.height.equalTo(40)
    }
    let row = QFTabUI.stack([heading, scanButton, addButton], axis: .horizontal, spacing: 10)
    row.alignment = .center
    return row
  }

  private func makeSearch() -> UIView {
    searchField.font = .systemFont(ofSize: 14)
    searchField.textColor = QFUI.text
    searchField.tintColor = QFUI.primary
    searchField.clearButtonMode = .whileEditing
    searchField.returnKeyType = .search
    searchField.delegate = self
    searchField.accessibilityIdentifier = "ingredient.search"
    searchField.addAction(UIAction { [weak self] _ in self?.scheduleSearch() }, for: .editingChanged)
    let icon = QFTabUI.symbol("magnifyingglass", size: 19, color: QFUI.secondary)
    let row = QFTabUI.stack([icon, searchField], axis: .horizontal, spacing: 12)
    row.alignment = .center
    row.snp.makeConstraints { $0.height.equalTo(22) }
    return QFTabUI.card(row, padding: 11, border: true)
  }

  private func makeExpiryNotice() -> UIButton {
    let button = QFTabUI.button("", background: QFUI.warningBackground) { [weak self] in self?.chooseExpiryFilter() }
    noticeAction.setContentCompressionResistancePriority(.required, for: .horizontal)
    let row = QFTabUI.stack(
      [QFTabUI.symbol("clock", size: 17, color: QFUI.warning), noticeText, UIView(), noticeAction],
      axis: .horizontal, spacing: 9)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    row.accessibilityElementsHidden = true
    button.addSubview(row)
    row.snp.makeConstraints {
      $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
    }
    return button
  }

  private func discoveryButton(
    _ title: String, subtitle: String, symbol: String, background: UIColor, accent: UIColor
  ) -> UIButton {
    let button = QFTabUI.button("", background: background) { [weak self] in
      guard let self else { return }
      if symbol == "circle" { self.qfPush(QFIngredientCombinationsViewController(app: self.app)) }
      else { self.qfPush(QFIngredientCatalogViewController(app: self.app)) }
    }
    button.accessibilityLabel = title
    button.accessibilityHint = subtitle
    let icon = UIView()
    let first = QFTabUI.symbol(symbol, size: 21, color: accent)
    icon.addSubview(first)
    first.snp.makeConstraints { $0.top.leading.equalToSuperview() }
    icon.snp.makeConstraints {
      $0.width.equalTo(29)
      $0.height.equalTo(32)
    }
    if symbol == "circle" {
      let second = QFTabUI.symbol("circle", size: 19, color: accent)
      icon.addSubview(second)
      second.snp.makeConstraints {
        $0.leading.equalToSuperview().offset(7)
        $0.top.equalToSuperview().offset(9)
      }
    }
    let titleLabel = QFTabUI.label(title, size: 16, weight: .semibold, lines: 2)
    let heading = QFTabUI.stack([titleLabel, UIView(), icon], axis: .horizontal, spacing: 4)
    heading.alignment = .top
    let body = QFTabUI.stack(
      [heading, QFTabUI.label(subtitle, size: 11, color: accent, lines: 0)], spacing: 4)
    body.isUserInteractionEnabled = false
    body.accessibilityElementsHidden = true
    button.addSubview(body)
    body.snp.makeConstraints { $0.edges.equalToSuperview().inset(13) }
    button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(74) }
    return button
  }

  private func makeCategories() -> UIView {
    let row = QFTabUI.stack([], axis: .horizontal, spacing: 8)
    for (index, category) in categories.enumerated() {
      let button = QFTabUI.button(
        localized(category.title), size: 13, weight: .semibold, color: QFUI.secondary,
        background: QFUI.surface
      ) { [weak self] in
        guard let self, self.selectedCategoryIndex != index else { return }
        self.selectedCategoryIndex = index
        self.refreshCategories()
        self.loadInventory(reset: true)
      }
      button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 15, bottom: 0, right: 15)
      button.layer.cornerRadius = 16
      button.layer.borderWidth = 1
      button.accessibilityIdentifier = "ingredient.category.\(category.title)"
      row.addArrangedSubview(button)
      categoryButtons[index] = button
    }
    return QFTabUI.horizontalScroll(row, height: 32, identifier: "ingredient.categories")
  }

  private func refreshCategories() {
    for (index, button) in categoryButtons {
      let selected = selectedCategoryIndex == index
      button.accessibilityTraits = selected ? [.button, .selected] : [.button]
      button.backgroundColor = selected ? QFUI.successBackground : QFUI.surface
      button.layer.borderColor = (selected ? UIColor.clear : QFUI.border).cgColor
      button.setTitleColor(selected ? QFUI.green : QFUI.secondary, for: .normal)
      button.setTitle(localized(categories[index].title), for: .normal)
    }
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
      guard let self else { return }
      if self.shopping { self.renderCurrent() } else { self.loadInventory(reset: true) }
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    searchTask?.cancel()
    if shopping { renderCurrent() } else { loadInventory(reset: true) }
    return true
  }

  private func reloadCurrent(force: Bool = false) {
    if shopping { loadShopping(force: force) } else { loadInventory(reset: true, force: force) }
  }
  func showFridgeAfterPurchase() {
    loadViewIfNeeded()
    shopping = false; segment.selectedSegmentIndex = 0
    applyLanguage(); renderCurrent(); loadInventory(reset: true, force: true)
  }

  private func loadInventory(reset: Bool, force: Bool = false) {
    guard inventoryMutation == nil, inventoryEdit == nil || !inventoryLoaded || !inventoryItems.contains(where: { $0.id == inventoryEdit?.lot.id }) else { refreshControl.endRefreshing(); loadMoreFooter.endRefreshing(); return }
    if !reset && loading { updateLoadMoreFooter(); return }
    requestTask?.cancel()
    requestID = UUID()
    let id = requestID
    let page = reset ? 0 : inventoryNextPage
    let category = categories[selectedCategoryIndex].code
    let expiry = expiryFilter
    let query = searchText
    let householdID = app.planningHouseholdID
    loading = true
    if reset {
      loadMoreFailed = false
      if !inventoryLoaded { renderCurrent() }
    }
    updateLoadMoreFooter()
    guard app.user != nil else {
      inventoryItems = []
      inventoryTotal = 0
      inventoryHasMore = false
      inventoryLoaded = true
      loading = false
      refreshControl.endRefreshing()
      renderCurrent()
      updateLoadMoreFooter()
      return
    }
    requestTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.requestID == id {
          self.loading = false
          self.refreshControl.endRefreshing()
          self.updateLoadMoreFooter()
        }
      }
      do {
        let response: QFContentPage<QFInventoryLot> = try await
          QFContentLoadingContext.$forceRefresh.withValue(force || self.refreshControl.isRefreshing) {
            try await self.app.inventoryLots(
              householdID: householdID, category: category, query: query, page: page, expiry: expiry, groupByProduct: true)
          }
        try Task.checkCancellation()
        guard self.requestID == id, !self.shopping,
          self.categories[self.selectedCategoryIndex].code == category, self.searchText == query, self.expiryFilter == expiry,
          self.app.planningHouseholdID == householdID
        else { return }
        if reset {
          self.inventoryItems = response.items
        } else {
          var positions = Dictionary(
            uniqueKeysWithValues: self.inventoryItems.enumerated().map { ($0.element.id, $0.offset) })
          for item in response.items {
            if let index = positions[item.id] { self.inventoryItems[index] = item }
            else {
              positions[item.id] = self.inventoryItems.count
              self.inventoryItems.append(item)
            }
          }
        }
        if reset, let draft = self.inventoryEdit, !self.inventoryItems.contains(where: { $0.id == draft.lot.id }) {
          // A previously submitted delete may already have hidden the lot. Keep its receipt reachable.
          var recovery = draft.lot
          if draft.language != self.app.interfaceLanguage { recovery = QFInventoryLot(id: draft.lot.id, ingredientId: draft.lot.ingredientId, ingredientName: nil, mediaId: nil, contentAvailable: false, categoryCode: draft.lot.categoryCode, unitCode: draft.lot.unitCode, initialQuantity: draft.lot.initialQuantity, currentQuantity: draft.lot.currentQuantity, expiresOn: draft.lot.expiresOn, location: draft.lot.location, householdId: draft.lot.householdId, status: draft.lot.status, revision: draft.lot.revision, createdAt: draft.lot.createdAt) }
          self.inventoryItems.insert(recovery, at: 0); self.recoveryOnlyInventoryID = draft.lot.id
        }
        if category == nil && query.isEmpty && expiry == nil { self.inventoryTotal = response.total }
        self.nearExpiryCount = response.nearExpiryIngredientCount ?? 0; self.expiredCount = response.expiredIngredientCount ?? 0
        self.inventoryNextPage = page + 1
        self.inventoryHasMore = !response.items.isEmpty && self.inventoryItems.filter { $0.id != self.recoveryOnlyInventoryID }.count < response.total
        self.inventoryLoaded = true
        self.loadMoreFailed = false
        self.applyLanguage()
        self.renderCurrent()
      } catch is CancellationError {
      } catch {
        guard self.requestID == id else { return }
        if reset && self.inventoryItems.isEmpty {
          self.inventoryLoaded = true
          self.renderFailure(error)
        } else if !reset {
          self.loadMoreFailed = true
        } else {
          QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
        }
      }
    }
  }

  private func loadMoreInventory() {
    guard !shopping, inventoryHasMore, !loading else { updateLoadMoreFooter(); return }
    loadInventory(reset: false)
  }

  private func loadShopping(force: Bool = false) {
    guard shoppingListMutationTask == nil, shoppingMutationTasks.isEmpty else {
      refreshControl.endRefreshing()
      return
    }
    requestTask?.cancel()
    requestID = UUID()
    let id = requestID
    let householdID = app.planningHouseholdID
    let selectedListID = shoppingList?.id
    loading = true
    if !shoppingLoaded { renderCurrent() }
    updateLoadMoreFooter()
    guard app.user != nil else {
      shoppingList = nil
      shoppingLoaded = true
      loading = false
      refreshControl.endRefreshing()
      renderCurrent()
      updateLoadMoreFooter()
      return
    }
    requestTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.requestID == id {
          self.loading = false
          self.refreshControl.endRefreshing()
          self.updateLoadMoreFooter()
        }
      }
      do {
        let selected: QFShoppingList? = try await
          QFContentLoadingContext.$forceRefresh.withValue(force || self.refreshControl.isRefreshing) {
            if let selectedListID {
              do {
                let selected = try await self.app.shoppingList(selectedListID)
                if selected.status != "DELETED" { return selected }
              } catch let error as QFAPIError where error.code == 40400 || error.code == 404 {
                // A list removed on another device should not trap the user in a stale selection.
              }
            }
            let response = try await self.app.shoppingLists(householdID: householdID, page: 0)
            return response.items.first { $0.status == "DRAFT" || $0.status == "CONFIRMED" }
              ?? response.items.first
          }
        try Task.checkCancellation()
        guard self.requestID == id, self.shopping,
          self.app.planningHouseholdID == householdID
        else { return }
        self.shoppingList = selected
        self.shoppingLoaded = true
        self.applyLanguage()
        self.renderCurrent()
      } catch is CancellationError {
      } catch {
        guard self.requestID == id else { return }
        if self.shoppingList == nil {
          self.shoppingLoaded = true
          self.renderFailure(error)
        } else {
          QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
        }
      }
    }
  }

  private func renderFailure(_ error: Error) {
    list.beginUpdates()
    list.row("load-failure", version: app.interfaceLanguage) { [weak self] in
      guard let self else { return UIView() }
      let message = QFTabUI.label(
        QFProfileContentController.errorText(error, app: self.app), size: 12,
        color: QFUI.secondary, lines: 0)
      message.textAlignment = .center
      let retry = QFTabUI.button(
        self.localized("点击重新加载"), size: 14, weight: .semibold, color: QFUI.orange
      ) { [weak self] in self?.reloadCurrent(force: true) }
      retry.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
      return QFTabUI.card(QFTabUI.stack([message, retry], spacing: 8), padding: 14, border: true)
    }
    list.endUpdates()
  }

  private func renderCurrent() {
    categoriesView?.isHidden = shopping || preparationDates != nil
    notice?.isHidden = shopping || preparationDates != nil || (nearExpiryCount == 0 && expiredCount == 0)
    renderCurrentLabelsOnly()
    searchField.isEnabled = inventoryEdit == nil
    addButton.isEnabled = inventoryEdit == nil && inventoryMutation == nil
    segment.isEnabled = inventoryMutation == nil
    categoryButtons.values.forEach { $0.isEnabled = inventoryEdit == nil }
    contentStack.arrangedSubviews.first { $0.accessibilityIdentifier == "ingredient.list.heading" }?.isHidden = preparationDates != nil && !shopping
    guard app.user != nil else {
      renderEmpty(
        title: localized("登录后管理食材和采购单"),
        detail: localized("登录后的数据会在不同设备间同步"), identity: "signed-out")
      return
    }
    if shopping {
      guard shoppingLoaded else { renderSkeleton(); return }
      guard let shoppingList else {
        renderEmpty(
          title: localized("暂无采购单"),
          detail: localized("生成采购单后，待采购食材会显示在这里"), identity: "no-shopping-list")
        return
      }
      let items = shoppingList.items.filter {
        searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
      }
      renderShopping(items, list: shoppingList)
    } else {
      guard inventoryLoaded else { renderSkeleton(); return }
      if inventoryItems.isEmpty {
        let isUnfilteredInventory = selectedCategoryIndex == 0 && searchText.isEmpty && expiryFilter == nil
        renderEmpty(
          title: localized(isUnfilteredInventory ? "暂无库存" : "没有找到相关食材"),
          detail: localized(isUnfilteredInventory ? "添加食材" : "换个名称或分类试试"),
          identity: isUnfilteredInventory ? "empty-inventory" : "empty-inventory-search")
      } else {
        renderInventory(inventoryItems)
      }
    }
  }

  private func renderInventory(_ items: [QFInventoryLot]) {
    list.beginUpdates()
    for item in items {
      var versionParts: [String] = [
        String(item.revision), item.ingredientName ?? "", item.mediaId ?? "", item.categoryCode ?? "",
        item.currentQuantity, item.unitCode, item.expiresOn ?? "", item.location,
      ]
      let isEditing = inventoryEdit?.lot.id == item.id
      versionParts.append(contentsOf: [
        item.groupQuantity ?? "", String(item.groupLotCount ?? 1), app.interfaceLanguage,
        String(isEditing), String(isEditing && inventoryMutation != nil),
        isEditing ? inventoryEditingError ?? "" : "", item.createdAt ?? "",
      ])
      let version = versionParts.joined(separator: "|")
      list.row("inventory.\(item.id)", version: version) { [weak self] in
        guard let self else { return UIView() }
        return self.inventoryEdit?.lot.id == item.id ? self.makeInventoryEditor(item) : self.makeInventoryCard(item)
      }
    }
    list.endUpdates()
  }

  private func renderShopping(_ items: [QFShoppingItem], list shoppingList: QFShoppingList) {
    self.list.beginUpdates()
    for item in items {
      let version = [
        String(item.revision), item.name, item.quantityKind, item.quantityMin ?? "",
        item.quantityMax ?? "", item.unitCode ?? "", item.quantityText ?? "",
        String(item.requiresConfirmation), String(item.checked),
        shoppingList.status, String(shoppingList.revision), app.interfaceLanguage,
        String(shoppingMutationTasks[item.id] != nil),
      ].joined(separator: "|")
      self.list.row("shopping.\(item.id)", version: version) { [weak self] in
        self?.makeShoppingCard(item, list: shoppingList) ?? UIView()
      }
    }
    if items.isEmpty {
      self.list.row("empty-shopping-search", version: searchText) { [weak self] in
        guard let self else { return UIView() }
        return QFTabUI.empty(
          self.localized("没有找到相关食材"),
          detail: self.localized("换个名称或分类试试"))
      }
    }
    if !shoppingList.warnings.isEmpty {
      self.list.row(
        "shopping-warnings", version: "\(shoppingList.warnings.count)|\(app.interfaceLanguage)"
      ) { [weak self] in
        guard let self else { return UIView() }
        return QFTabUI.card(
          QFTabUI.label(
            self.app.format(
              "有 %d 项计划材料不完整，未加入采购单。",
              "%d planned items have incomplete ingredient data and were not added.",
              shoppingList.warnings.count),
            size: 12, color: QFUI.warning, lines: 0),
          padding: 13, background: QFUI.warningBackground)
      }
    }
    self.list.endUpdates()
  }

  private func renderSkeleton() {
    list.beginUpdates()
    for index in 0..<3 {
      list.row("skeleton.\(index)", version: app.interfaceLanguage) { [weak self] in
        self?.makeSkeletonCard() ?? UIView()
      }
    }
    list.endUpdates()
  }

  private func renderEmpty(title: String, detail: String, identity: String) {
    list.beginUpdates()
    list.row(identity, version: title + detail) { QFTabUI.empty(title, detail: detail) }
    list.endUpdates()
  }

  private func makeSkeletonCard() -> UIView {
    let icon = UIView()
    icon.backgroundColor = QFUI.surfaceAlt
    icon.layer.cornerRadius = 12
    icon.snp.makeConstraints { $0.size.equalTo(48) }
    let line1 = UIView()
    line1.backgroundColor = QFUI.surfaceAlt
    line1.layer.cornerRadius = 5
    line1.snp.makeConstraints {
      $0.width.equalTo(126)
      $0.height.equalTo(12)
    }
    let line2 = UIView()
    line2.backgroundColor = QFUI.surfaceAlt
    line2.layer.cornerRadius = 4
    line2.snp.makeConstraints {
      $0.width.equalTo(82)
      $0.height.equalTo(9)
    }
    let body = QFTabUI.stack([line1, line2], spacing: 9)
    let row = QFTabUI.stack([icon, body, UIView()], axis: .horizontal, spacing: 10)
    row.alignment = .center
    let card = QFTabUI.card(row, padding: 13, border: true)
    card.accessibilityLabel = localized("正在加载")
    return card
  }

  private func makeInventoryCard(_ ingredient: QFInventoryLot) -> UIView {
    let name = ingredient.contentAvailable
      ? nonEmpty(ingredient.ingredientName) ?? localized("未命名食材")
      : localized("当前语言下食材暂不可用")
    let artwork = QFInventoryArtwork.make(ingredientID: ingredient.ingredientId, category: ingredient.categoryCode, iconKey: ingredient.iconKey)
    let details = QFTabUI.stack(
      [
        QFTabUI.label(name, size: 17, weight: .semibold, lines: 2),
        QFTabUI.label(inventoryQuantity(ingredient.displayedQuantity, unit: ingredient.displayedUnitCode), size: 16, lines: 0),
        QFTabUI.label(preparationDates == nil ? expiryText(ingredient.expiresOn) : inventoryAddedDate(ingredient.createdAt), size: 12, color: isNearExpiry(ingredient.expiresOn) ? QFUI.warning : QFUI.secondary, lines: 0),
      ], spacing: 9)
    let more = QFTabUI.iconButton(
      "ellipsis", label: app.format("%@，更多操作", "More actions for %@", name), size: 18
    ) { [weak self] in
      guard let self else { return }
      if (ingredient.groupLotCount ?? 1) > 1 {
        let binding = QFAssistantAgent.scope(self.app), household = self.app.planningHouseholdID
        let batches = QFInventoryBatchesViewController(app: self.app, ingredient: ingredient) { [weak self] lot in
          guard let self, QFAssistantAgent.scope(self.app) == binding, self.app.planningHouseholdID == household else { return }
          // Only a real ungrouped lot can enter the editor. Never write the
          // displayed aggregate into the representative lot.
          if let index = self.inventoryItems.firstIndex(where: { $0.id == lot.id }) { self.inventoryItems[index] = lot }
          else if let index = self.inventoryItems.firstIndex(where: {
            $0.ingredientId == lot.ingredientId && $0.householdId == lot.householdId && $0.unitCode == lot.unitCode
              && $0.location == lot.location && $0.packageSize == lot.packageSize && $0.packageContentUnit == lot.packageContentUnit
          }) { self.inventoryItems[index] = lot }
          else { self.inventoryItems.insert(lot, at: 0); self.recoveryOnlyInventoryID = lot.id }
          self.beginInventoryEdit(lot)
        }
        self.qfPush(batches)
      } else { self.beginInventoryEdit(ingredient) }
    }
    let top = QFTabUI.stack([], axis: .horizontal, spacing: 5)
    top.alignment = .center
    if !ingredient.location.isEmpty {
      // Keep the location label's padding independent from its intrinsic text
      // width. The former label-only pill had no horizontal insets, so longer
      // translations pressed into the rounded background and made the circle
      // look uneven.
      let storage = UIView()
      storage.backgroundColor = QFUI.paleGreen
      storage.clipsToBounds = true
      storage.layer.cornerRadius = 12
      storage.layer.cornerCurve = .continuous
      let storageLabel = QFTabUI.label(ingredient.location == "fridge" ? app.text("冰箱", "Fridge") : ingredient.location, size: 10.5, color: QFUI.green)
      storageLabel.textAlignment = .center
      storageLabel.lineBreakMode = .byTruncatingTail
      storageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      storage.addSubview(storageLabel)
      storageLabel.snp.makeConstraints {
        $0.leading.trailing.equalToSuperview().inset(8)
        $0.top.bottom.equalToSuperview().inset(3)
      }
      storage.snp.makeConstraints { $0.height.equalTo(24); $0.width.lessThanOrEqualTo(116) }
      top.addArrangedSubview(storage)
    }
    top.addArrangedSubview(more)
    more.accessibilityIdentifier = "inventory.edit.\(ingredient.id)"
    let status = QFTabUI.stack([top], spacing: 3)
    status.alignment = .trailing
    status.snp.makeConstraints { $0.width.lessThanOrEqualTo(116) }
    let row = QFTabUI.stack([artwork, details, status], axis: .horizontal, spacing: 8)
    row.alignment = .center
    return QFTabUI.card(row, padding: 13, border: true)
  }

  private func makeShoppingCard(_ ingredient: QFShoppingItem, list shoppingList: QFShoppingList) -> UIView {
    let artwork = QFInventoryArtwork.make(ingredientID: ingredient.ingredientId ?? "", category: ingredient.categoryCode, iconKey: ingredient.iconKey)
    var detail = shoppingQuantity(ingredient)
    if ingredient.received == true { detail += " · " + app.text("已入库", "In stock") }
    if ingredient.requiresConfirmation && ingredient.received != true { detail += " · " + localized("需要确认数量") }
    let details = QFTabUI.stack(
      [
        QFTabUI.label(ingredient.name, size: 17, weight: .semibold, lines: 2),
        QFTabUI.label(
          detail, size: 12,
          color: ingredient.requiresConfirmation ? QFUI.warning : QFUI.secondary, lines: 0),
      ], spacing: 9)
    let busy = shoppingMutationTasks[ingredient.id] != nil
    let check = QFTabUI.iconButton(
      ingredient.checked ? "checkmark.circle.fill" : "circle",
      label: ingredient.checked ? localized("已购买") : localized("标记为已购买"), size: 24
    ) { [weak self] in self?.toggleShoppingItem(ingredient, list: shoppingList) }
    check.tintColor = ingredient.checked ? QFUI.green : QFUI.secondary
    check.isEnabled = shoppingList.status == "DRAFT" && ingredient.received != true && !busy
    check.alpha = busy ? 0.45 : 1
    check.snp.makeConstraints { $0.size.equalTo(44) }
    let edit = QFTabUI.iconButton(
      "ellipsis", label: app.format("调整%@的数量", "Edit quantity for %@", ingredient.name),
      size: 18
    ) { [weak self] in self?.editShoppingItem(ingredient, list: shoppingList) }
    edit.isEnabled = shoppingList.status == "DRAFT" && ingredient.received != true && !busy
    edit.alpha = busy ? 0.45 : 1
    edit.snp.makeConstraints { $0.size.equalTo(44) }
    let actions = QFTabUI.stack([edit, check], axis: .horizontal, spacing: 0)
    let row = QFTabUI.stack([artwork, details, actions], axis: .horizontal, spacing: 8)
    row.alignment = .center
    return QFTabUI.card(row, padding: 13, border: true)
  }

  private func ingredientArtwork(mediaID: String?, categoryCode: String?) -> UIView {
    let artwork = UIView()
    artwork.layer.cornerRadius = 12
    artwork.clipsToBounds = true
    artwork.backgroundColor = QFUI.paleGreen
    artwork.snp.makeConstraints { $0.size.equalTo(48) }
    if let mediaID {
      let image = QFContentImageView()
      image.load(mediaID, app: app)
      artwork.addSubview(image)
      image.snp.makeConstraints { $0.edges.equalToSuperview() }
    } else {
      let fallback: String
      switch categoryCode {
      case "MEAT_EGG": fallback = "meat"
      case "VEGETABLE": fallback = "vegetable"
      case "DAIRY": fallback = "milk"
      case "FRUIT": fallback = "fruit"
      case "GRAIN": fallback = "grain"
      case "SEAFOOD": fallback = "seafood"
      case "FUNGI_ALGAE": fallback = "mushroom"
      case "SEASONING": fallback = "seasoning"
      default: fallback = "generic"
      }
      let image = UIImageView(image: UIImage(named: "ingredient-\(fallback)"))
      image.contentMode = .scaleAspectFit
      artwork.addSubview(image)
      image.snp.makeConstraints {
        $0.center.equalToSuperview()
        $0.size.equalTo(36)
      }
    }
    return artwork
  }

  private func cancelShoppingRead() {
    requestTask?.cancel()
    requestID = UUID()
    loading = false
    refreshControl.endRefreshing()
    updateLoadMoreFooter()
  }

  private func toggleShoppingItem(_ item: QFShoppingItem, list: QFShoppingList) {
    guard list.status == "DRAFT" else {
      QFOperationHUD.toast(localized("已确认的采购单不能修改"), in: view)
      return
    }
    guard shoppingMutationTasks[item.id] == nil, shoppingListMutationTask == nil else { return }
    cancelShoppingRead()
    let contextID = shoppingContextID
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.shoppingContextID == contextID {
          self.shoppingMutationTasks[item.id] = nil
          self.applyLanguage()
          self.renderCurrent()
        }
      }
      do {
        let saved = try await self.app.updateShoppingItem(
          listID: list.id, itemID: item.id,
          patch: QFShoppingItemPatch(
            checked: !item.checked, quantityKind: nil,
            quantityMin: nil, quantityMax: nil,
            unitCode: nil, quantityText: nil,
            expectedRevision: item.revision))
        try Task.checkCancellation()
        guard self.shoppingContextID == contextID, var current = self.shoppingList, current.id == list.id,
          let index = current.items.firstIndex(where: { $0.id == saved.id })
        else { return }
        var items = current.items
        items[index] = saved
        current = QFShoppingList(
          id: current.id, householdId: current.householdId, startDate: current.startDate,
          endDate: current.endDate, status: current.status,
          subtractInventory: current.subtractInventory, language: current.language,
          revision: current.revision, items: items, warnings: current.warnings,
          createdAt: current.createdAt, updatedAt: current.updatedAt)
        self.shoppingList = current
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, self.shoppingContextID == contextID else { return }
        QFOperationHUD.toast(QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
    }
    shoppingMutationTasks[item.id] = task
    renderCurrent()
  }

  private func editShoppingItem(_ item: QFShoppingItem, list: QFShoppingList) {
    guard list.status == "DRAFT", shoppingMutationTasks[item.id] == nil else { return }
    qfPush(
      QFShoppingItemEditorViewController(app: app, listID: list.id, item: item) {
        [weak self] saved in
        guard let self, var current = self.shoppingList, current.id == list.id,
          let index = current.items.firstIndex(where: { $0.id == saved.id })
        else { return }
        var items = current.items
        items[index] = saved
        current = QFShoppingList(
          id: current.id, householdId: current.householdId, startDate: current.startDate,
          endDate: current.endDate, status: current.status,
          subtractInventory: current.subtractInventory, language: current.language,
          revision: current.revision, items: items, warnings: current.warnings,
          createdAt: current.createdAt, updatedAt: current.updatedAt)
        self.shoppingList = current
        self.applyLanguage()
        self.renderCurrent()
      })
  }

  private func showShoppingListActions() {
    guard shopping, app.user != nil, shoppingListMutationTask == nil,
      shoppingMutationTasks.isEmpty else { return }
    guard let list = shoppingList else {
      if let dates = preparationDates { qfPush(QFPreparationViewController(app: app, startDate: dates.0, endDate: dates.1)) }
      else { chooseShoppingList() }
      return
    }
    let sheet = UIAlertController(
      title: localized("采购单操作"),
      message: "\(list.startDate) – \(list.endDate)", preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: localized("选择采购单"), style: .default) { [weak self] _ in
      self?.chooseShoppingList()
    })
    if list.status == "DRAFT" {
      sheet.addAction(UIAlertAction(title: localized("确认采购单"), style: .default) { [weak self] _ in
        self?.confirmShoppingList(list)
      })
      if !list.items.contains(where: { $0.received == true }) {
        sheet.addAction(UIAlertAction(title: localized("按当前计划重新生成"), style: .default) { [weak self] _ in
          self?.regenerateShoppingList(list)
        })
      }
    }
    sheet.addAction(UIAlertAction(title: localized("删除采购单"), style: .destructive) { [weak self] _ in
      self?.deleteShoppingList(list)
    })
    sheet.addAction(UIAlertAction(title: localized("取消"), style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = sorting
      popover.sourceRect = sorting.bounds
    }
    present(sheet, animated: true)
  }

  private func receiveShoppingSelection() {
    guard let shoppingList, shoppingList.items.contains(where: { $0.checked && $0.received != true }),
      shoppingMutationTasks.isEmpty, shoppingListMutationTask == nil else { return }
    let controller = QFPurchaseReceiptViewController(app: app, householdID: shoppingList.householdId, shoppingList: shoppingList)
    controller.onChanged = { [weak self] in
      guard let self else { return }; self.inventoryLoaded = false; self.shoppingLoaded = false
      self.reloadCurrent(force: true)
    }
    qfPush(controller)
  }

  private func chooseShoppingList() {
    let contextID = shoppingContextID
    qfPush(QFShoppingListPickerViewController(
      app: app, householdID: app.planningHouseholdID, selectedID: shoppingList?.id
    ) { [weak self] selected in
      guard let self, self.shoppingContextID == contextID else { return }
      self.requestTask?.cancel()
      self.requestID = UUID()
      self.loading = false
      self.refreshControl.endRefreshing()
      self.shoppingList = selected
      self.shoppingLoaded = true
      self.skipNextAppearanceReload = true
      self.applyLanguage()
      self.renderCurrent()
      self.updateLoadMoreFooter()
    })
  }

  private func confirmShoppingList(_ list: QFShoppingList) {
    guard !list.items.contains(where: \.requiresConfirmation) else {
      QFOperationHUD.toast(localized("请先补全需要确认的数量"), in: view)
      return
    }
    mutateShoppingList(label: localized("正在确认采购单")) { [app] in
      try await app.confirmShoppingList(list.id, expectedRevision: list.revision)
    }
  }

  private func regenerateShoppingList(_ list: QFShoppingList) {
    mutateShoppingList(label: localized("正在重新生成采购单")) { [app] in
      try await app.regenerateShoppingList(list.id)
    }
  }

  private func deleteShoppingList(_ list: QFShoppingList) {
    let alert = UIAlertController(
      title: localized("删除采购单？"), message: localized("删除后可从饮食计划重新生成。"),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: localized("取消"), style: .cancel))
    alert.addAction(UIAlertAction(title: localized("删除"), style: .destructive) { [weak self] _ in
      guard let self else { return }
      guard self.shoppingListMutationTask == nil, self.shoppingList?.id == list.id else { return }
      self.cancelShoppingRead()
      let contextID = self.shoppingContextID
      self.shoppingListMutationTask = Task { [weak self] in
        guard let self else { return }
        self.operationHUD.show(in: self.view, text: self.localized("正在删除"))
        defer {
          if self.shoppingContextID == contextID {
            self.operationHUD.hide()
            self.shoppingListMutationTask = nil
            self.renderCurrentLabelsOnly()
          }
        }
        do {
          try await self.app.deleteShoppingList(list.id)
          try Task.checkCancellation()
          guard self.shoppingContextID == contextID, self.shoppingList?.id == list.id else { return }
          self.shoppingList = nil
          self.shoppingLoaded = true
          self.applyLanguage()
          self.renderCurrent()
          QFOperationHUD.toast(self.localized("采购单已删除"), in: self.view)
          self.shoppingListMutationTask = nil
          self.loadShopping(force: true)
        } catch is CancellationError {
        } catch {
          guard !Task.isCancelled, self.shoppingContextID == contextID else { return }
          QFOperationHUD.toast(
            QFProfileContentController.errorText(error, app: self.app), in: self.view)
        }
      }
      self.renderCurrentLabelsOnly()
    })
    present(alert, animated: true)
  }

  private func mutateShoppingList(
    label: String, operation: @escaping () async throws -> QFShoppingList
  ) {
    guard shoppingListMutationTask == nil, shoppingMutationTasks.isEmpty else { return }
    cancelShoppingRead()
    let contextID = shoppingContextID
    shoppingListMutationTask = Task { [weak self] in
      guard let self else { return }
      self.operationHUD.show(in: self.view, text: label)
      defer {
        if self.shoppingContextID == contextID {
          self.operationHUD.hide()
          self.shoppingListMutationTask = nil
          self.renderCurrentLabelsOnly()
        }
      }
      do {
        let saved = try await operation()
        try Task.checkCancellation()
        guard self.shoppingContextID == contextID else { return }
        self.shoppingList = saved
        self.shoppingLoaded = true
        self.applyLanguage()
        self.renderCurrent()
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, self.shoppingContextID == contextID else { return }
        QFOperationHUD.toast(
          QFProfileContentController.errorText(error, app: self.app), in: self.view)
      }
    }
    renderCurrentLabelsOnly()
  }

  private func chooseIngredientForInventory() {
    view.endEditing(true)
    guard app.user != nil else {
      QFOperationHUD.toast(localized("请先登录"), in: view)
      return
    }
    let sheet = QFInventoryAddIngredientSheet(app: app) { [weak self] choice in
      guard let self else { return }
      switch choice {
      case .catalog: self.chooseCatalogIngredientForInventory()
      case .custom: self.promptCustomIngredient()
      case .recipe: self.chooseRecipeForInventory()
      case .assistant:
        self.qfPush(QFAssistantIngredientViewController(app: self.app, householdID: self.app.planningHouseholdID))
      }
    }
    present(sheet, animated: true)
  }

  private func chooseCatalogIngredientForInventory() {
    qfPush(QFCatalogSearchViewController(app: app, type: "INGREDIENT") { [weak self] item in
      guard let self else { return }
      self.qfPush(
        QFInventoryLotEditorViewController(
          app: self.app, ingredient: item, householdID: self.app.planningHouseholdID
        ) { [weak self] saved in
          self?.mergeCreatedInventoryLot(saved)
        })
    })
  }

  private func promptCustomIngredient() {
    let alert = UIAlertController(title: app.text("自定义食材名称", "Custom ingredient name"), message: nil, preferredStyle: .alert)
    alert.addTextField { $0.placeholder = self.app.text("食材名称", "Ingredient name"); $0.clearButtonMode = .whileEditing }
    alert.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: app.text("继续", "Continue"), style: .default) { [weak self, weak alert] _ in
      guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 100 else { return }
      let item = QFCatalogItem(id: UUID().uuidString.lowercased(), type: "INGREDIENT", title: name, subtitle: "", mediaId: nil, materials: [], steps: [], minutes: nil, sourceName: nil, sourceUrl: nil, license: nil, licenseUrl: nil, attribution: nil)
      self.qfPush(QFInventoryLotEditorViewController(app: self.app, ingredient: item, householdID: self.app.planningHouseholdID, customIngredientName: name) { [weak self] saved in self?.mergeCreatedInventoryLot(saved) })
    })
    present(alert, animated: true)
  }

  private func chooseRecipeForInventory() {
    qfPush(QFCatalogSearchViewController(app: app, type: "RECIPE") { [weak self] recipe in
      guard let self else { return }
      self.qfPush(QFRecipeInventoryBatchViewController(app: self.app, recipe: recipe, householdID: self.app.planningHouseholdID) { [weak self] lots in
        guard let self else { return }
        self.inventoryLoaded = false
        self.loadInventory(reset: true, force: true)
      })
    })
  }

  private func loadInventoryUnits() {
    unitTask?.cancel()
    unitTask = Task { [weak self] in
      guard let self else { return }
      do { let units = try await self.app.inventoryMeasurementUnits(householdID: self.app.planningHouseholdID); try Task.checkCancellation(); self.inventoryUnits = units }
      catch { /* Keep canonical codes visible if localized unit metadata is unavailable. */ }
    }
  }

  private func inventoryAddedDate(_ value: String?) -> String {
    guard let value else { return app.text("入库日期未知", "Date added unknown") }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = parser.date(from: value)
    if date == nil { parser.formatOptions = [.withInternetDateTime]; date = parser.date(from: value) }
    guard let date else { return app.text("入库日期未知", "Date added unknown") }
    let format = DateFormatter(); format.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    format.timeZone = .current; format.setLocalizedDateFormatFromTemplate("yyyyMMMd")
    return app.format("入库 %@", "Added %@", format.string(from: date))
  }

  private func inventoryQuantity(_ value: String, unit: String) -> String {
    let symbol = inventoryUnits.first { $0.code == unit }?.name ?? {
      switch unit {
      case "bottle": return app.text("瓶", "Bottle")
      case "pack": return app.text("包", "Pack")
      case "bag": return app.text("袋", "Bag")
      case "box": return app.text("盒", "Box")
      default: return unit
      }
    }()
    return "\(value) \(symbol)"
  }

  private func persistInventoryEdit() -> Bool {
    guard let inventoryEdit else { QFContentDraftStore.remove(app: app, kind: inventoryDraftKey); return true }
    return QFContentDraftStore.save(inventoryEdit, app: app, kind: inventoryDraftKey)
  }

  private func beginInventoryEdit(_ lot: QFInventoryLot) {
    guard inventoryMutation == nil else { return }
    if let draft = inventoryEdit, draft.lot.id != lot.id {
      QFOperationHUD.toast(app.text("请先完成当前编辑", "Finish the current edit first"), in: view); return
    }
    cancelShoppingRead(); searchTask?.cancel()
    if inventoryEdit == nil { inventoryEdit = QFInventoryInlineDraft(lot: lot, language: app.interfaceLanguage) }
    inventoryEditingError = nil
    _ = persistInventoryEdit(); renderCurrent()
  }

  private func makeInventoryEditor(_ item: QFInventoryLot) -> UIView {
    guard let draft = inventoryEdit else { return makeInventoryCard(item) }
    let name = item.contentAvailable ? (item.ingredientName ?? localized("未命名食材")) : localized("当前语言下食材暂不可用")
    let frozen = draft.isFrozen || inventoryMutation != nil
    let heading = QFTabUI.stack([
      QFTabUI.label(name, size: 17, weight: .semibold, lines: 0), UIView(),
      QFTabUI.label(app.text("编辑中", "Editing"), size: 12, color: QFUI.primary),
    ], axis: .horizontal, spacing: 8)
    func field(_ title: String, value: String, id: String, editable: Bool, changed: @escaping (String) -> Void) -> UIView {
      let input = UITextField(); input.text = value; input.font = .systemFont(ofSize: 15); input.textColor = QFUI.text
      input.borderStyle = .roundedRect; input.isEnabled = editable && !frozen
      input.accessibilityIdentifier = id; input.accessibilityLabel = title
      input.addAction(UIAction { [weak input, weak self] _ in
        changed(input?.text ?? ""); _ = self?.persistInventoryEdit()
      }, for: .editingChanged)
      if id == "inventory.quantity" { input.keyboardType = .decimalPad }
      input.snp.makeConstraints { $0.height.equalTo(QFInventoryLayout.fieldHeight) }
      return QFTabUI.stack([QFTabUI.label(title, size: 12, color: QFUI.secondary, lines: 0), input], spacing: 6)
    }
    let ingredient = field(app.text("食材名称", "Ingredient name"), value: name, id: "inventory.name", editable: false) { _ in }
    let location = field(app.text("存放位置", "Storage location"), value: draft.location, id: "inventory.location", editable: true) { [weak self] in self?.inventoryEdit?.location = $0 }
    let quantity = field(app.text("库存数量", "Stock quantity"), value: draft.quantity, id: "inventory.quantity", editable: true) { [weak self] in self?.inventoryEdit?.quantity = $0 }
    let unitButton = QFTabUI.button(inventoryUnits.first { $0.code == draft.effectiveUnitCode }?.name ?? draft.effectiveUnitCode, color: QFUI.text, background: QFUI.surfaceAlt) { [weak self] in self?.chooseInventoryUnit() }
    unitButton.accessibilityIdentifier = "inventory.unit"; unitButton.isEnabled = !frozen && !inventoryUnits.isEmpty
    unitButton.snp.makeConstraints { $0.height.equalTo(QFInventoryLayout.fieldHeight) }
    let unit = QFTabUI.stack([QFTabUI.label(app.text("单位", "Unit"), size: 12, color: QFUI.secondary), unitButton], spacing: 6)
    let first = QFTabUI.stack([ingredient, location], axis: .horizontal, spacing: 12); first.distribution = .fillEqually
    let second = QFTabUI.stack([quantity, unit], axis: .horizontal, spacing: 12); second.distribution = .fillEqually
    let cancel = QFTabUI.button(app.text("取消", "Cancel"), background: QFUI.surfaceAlt) { [weak self] in
      guard let self, self.inventoryMutation == nil, self.inventoryEdit?.isFrozen != true else { return }
      self.view.endEditing(true); self.inventoryEdit = nil; self.inventoryEditingError = nil; _ = self.persistInventoryEdit()
      self.reloadGroupedInventoryAfterEditing()
    }
    cancel.isEnabled = !frozen; cancel.accessibilityIdentifier = "inventory.cancel"
    let delete = QFTabUI.iconButton("trash", label: app.text("删除", "Delete"), size: 20) { [weak self] in
      guard let self, !frozen else { return }; self.view.endEditing(true)
      let contextID = self.shoppingContextID, lotID = item.id
      self.present(QFInventoryDeleteSheet(app: self.app, context: "\(name) · \(self.inventoryQuantity(item.currentQuantity, unit: item.unitCode))") { [weak self] in
        guard let self, self.shoppingContextID == contextID, self.inventoryEdit?.lot.id == lotID else { return }
        self.submitInventoryEdit(archive: true)
      }, animated: true)
    }
    delete.snp.remakeConstraints { $0.height.equalTo(44) }
    delete.tintColor = QFUI.danger; delete.isEnabled = !frozen; delete.accessibilityIdentifier = "inventory.delete"
    let save = QFTabUI.button(draft.isFrozen ? app.text("重试", "Retry") : app.text("保存", "Save"), color: .white, background: QFUI.primary) { [weak self] in self?.submitInventoryEdit(archive: self?.inventoryEdit?.pendingArchive != nil) }
    save.isEnabled = inventoryMutation == nil; save.accessibilityIdentifier = "inventory.save"
    let actions = QFTabUI.stack([cancel, delete, save], axis: .horizontal, spacing: 12); actions.distribution = .fillEqually
    cancel.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }; save.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    let content = QFTabUI.stack([heading, first, second], spacing: 12)
    if let error = inventoryEditingError { content.addArrangedSubview(QFTabUI.label(error, size: 13, color: QFUI.danger, lines: 0)) }
    if inventoryNeedsReview {
      let reload = QFTabUI.button(app.text("重新加载", "Reload"), color: QFUI.primary) { [weak self] in
        guard let self, self.inventoryMutation == nil else { return }
        self.inventoryEdit = nil; self.inventoryNeedsReview = false; self.inventoryEditingError = nil
        _ = self.persistInventoryEdit(); self.loadInventory(reset: true, force: true)
      }
      reload.accessibilityIdentifier = "inventory.reload"; reload.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
      content.addArrangedSubview(reload)
    }
    let cost = QFTabUI.button(app.text("补全食材成本", "Complete ingredient costs"), size: 13, color: QFUI.primary) { [weak self] in
      guard let self else { return }
      let controller = QFInventoryCostSourcesViewController(app: self.app, lot: item)
      controller.onChanged = { [weak self] in
        guard let self else { return }; self.inventoryEdit = nil; _ = self.persistInventoryEdit(); self.inventoryLoaded = false
      }
      self.qfPush(controller)
    }
    cost.accessibilityIdentifier = "inventory.cost." + item.id
    cost.isEnabled = !frozen && draft.quantity == item.currentQuantity && draft.location == item.location
    content.addArrangedSubview(cost)
    content.addArrangedSubview(actions)
    let card = QFTabUI.card(content, padding: 14, border: true)
    card.layer.borderColor = QFUI.primary.cgColor; card.layer.cornerRadius = QFInventoryLayout.cardRadius
    card.accessibilityIdentifier = "inventory.editing.\(item.id)"
    return card
  }

  private func chooseInventoryUnit() {
    guard let draft = inventoryEdit, !draft.isFrozen, let current = inventoryUnits.first(where: { $0.code == draft.effectiveUnitCode }) else { return }
    let choices = inventoryUnits.filter { $0.code == current.code || ($0.dimension == current.dimension && ["MASS", "VOLUME"].contains($0.dimension)) }
    let picker = QFMeasurementUnitPickerViewController(app: app, title: app.text("单位", "Unit"), units: choices, selectedCode: current.code) { [weak self] unit in
      guard let self, var draft = self.inventoryEdit, !draft.isFrozen, unit.code != draft.effectiveUnitCode else { return }
      guard draft.convertUnit(to: unit, units: self.inventoryUnits) else {
        self.inventoryEditingError = self.app.text("无法精确换算，请检查数量和单位", "Cannot convert exactly. Check the quantity and unit.")
        self.renderCurrent(); return
      }
      self.inventoryEdit = draft; self.inventoryEditingError = nil; _ = self.persistInventoryEdit(); self.renderCurrent()
    }
    present(picker, animated: true)
  }

  private func submitInventoryEdit(archive: Bool) {
    guard inventoryMutation == nil, var draft = inventoryEdit else { return }
    view.endEditing(true)
    if !draft.isFrozen {
      if archive {
        draft.pendingArchive = QFInventoryArchiveRequest(expectedRevision: draft.lot.revision, idempotencyKey: UUID().uuidString)
      } else {
        guard let amount = draft.normalizedQuantity, draft.location.count <= 100 else {
          inventoryEditingError = app.text("请输入有效的库存数量和存放位置", "Enter a valid stock quantity and storage location")
          renderCurrent(); return
        }
        draft.pendingEdit = QFInventoryEditRequest(currentQuantity: amount, unitCode: draft.effectiveUnitCode, location: draft.location, expectedRevision: draft.lot.revision, idempotencyKey: UUID().uuidString)
      }
      inventoryEdit = draft
      guard persistInventoryEdit() else {
        inventoryEdit?.pendingEdit = nil; inventoryEdit?.pendingArchive = nil
        QFOperationHUD.toast(app.text("无法保存草稿，请重试", "Unable to save draft. Try again."), in: view); return
      }
    }
    let contextID = shoppingContextID, key = inventoryDraftKey
    inventoryEditingError = nil
    inventoryMutation = Task { [weak self] in
      guard let self else { return }
      self.operationHUD.show(in: self.view, text: self.app.text("正在保存", "Saving"))
      var succeeded = false
      defer { if self.shoppingContextID == contextID {
        self.inventoryMutation = nil; self.operationHUD.hide()
        if succeeded { self.reloadGroupedInventoryAfterEditing() }
        else { self.renderCurrent() }
      } }
      do {
        let saved: QFInventoryLot
        if let request = draft.pendingArchive { saved = try await self.app.archiveInventoryLot(draft.lot.id, draft: request) }
        else if let request = draft.pendingEdit { saved = try await self.app.editInventoryLot(draft.lot.id, draft: request) }
        else { return }
        try Task.checkCancellation(); guard self.shoppingContextID == contextID else { return }
        guard saved.id == draft.lot.id else { throw QFAPIError(code: 50300, message: "Inventory receipt mismatch") }
        self.inventoryEdit = nil; QFContentDraftStore.remove(app: self.app, kind: key)
        // A mutation response describes one real batch. Product groups can gain
        // a new representative or merge after a unit/location change, so only
        // a new grouped read may determine the card total and pagination.
        succeeded = true
        self.shoppingLoaded = false
      } catch is CancellationError {
      } catch {
        guard self.shoppingContextID == contextID else { return }
        if let failure = error as? QFAPIError, failure.code == 40000 || failure.code == 42207 {
          // Both responses guarantee transaction rollback, so the user can correct the draft.
          self.inventoryEdit?.pendingEdit = nil; self.inventoryEdit?.pendingArchive = nil
          _ = self.persistInventoryEdit()
        }
        self.inventoryNeedsReview = (error as? QFAPIError)?.code == 40900
        self.inventoryEditingError = QFProfileContentController.errorText(error, app: self.app)
      }
    }
    renderCurrent()
  }

  private func reloadGroupedInventoryAfterEditing() {
    recoveryOnlyInventoryID = nil
    inventoryItems = []; inventoryTotal = 0; inventoryNextPage = 0
    inventoryHasMore = false; inventoryLoaded = false
    applyLanguage(); renderCurrent(); loadInventory(reset: true, force: true)
  }

  private func showInventoryActions(_ item: QFInventoryLot, displayName: String) {
    guard app.user != nil else { return }
    let sheet = UIAlertController(
      title: displayName, message: quantity(item.currentQuantity, unit: item.unitCode),
      preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: localized("调整库存"), style: .default) { [weak self] _ in
        guard let self else { return }
        self.qfPush(
          QFInventoryAdjustmentViewController(app: self.app, lot: item) { [weak self] saved in
            self?.reloadGroupedInventoryAfterEditing()
          })
      })
    sheet.addAction(
      UIAlertAction(title: app.text("库存流水", "Inventory history"), style: .default) {
        [weak self] _ in
        guard let self else { return }
        self.qfPush(
          QFInventoryLedgerViewController(
            app: self.app, householdID: self.app.planningHouseholdID,
            ingredientID: item.ingredientId, ingredientName: displayName))
      })
    sheet.addAction(UIAlertAction(title: localized("取消"), style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    }
    present(sheet, animated: true)
  }

  private func mergeCreatedInventoryLot(_ item: QFInventoryLot) {
    // New stock may join an existing group instead of adding a visible card.
    reloadGroupedInventoryAfterEditing()
  }

  private func updateLoadMoreFooter() {
    loadMoreFooter.resetNoMoreData()
    loadMoreFooter.setTitle(localized("上拉加载更多"), for: .idle)
    loadMoreFooter.setTitle(localized("加载中…"), for: .refreshing)
    loadMoreFooter.setTitle(localized("已全部加载"), for: .noMoreData)
    guard !shopping else {
      loadMoreFooter.endRefreshing()
      loadMoreFooter.isAutomaticallyRefresh = false
      loadMoreFooter.isHidden = true
      return
    }
    if loading { return }
    loadMoreFooter.endRefreshing()
    if loadMoreFailed {
      loadMoreFooter.setTitle(localized("加载失败，上拉重试"), for: .idle)
      loadMoreFooter.isAutomaticallyRefresh = true
      loadMoreFooter.isHidden = false
    } else if inventoryHasMore {
      loadMoreFooter.isAutomaticallyRefresh = true
      loadMoreFooter.isHidden = false
    } else {
      loadMoreFooter.isAutomaticallyRefresh = false
      loadMoreFooter.isHidden = inventoryItems.isEmpty
      if !inventoryItems.isEmpty { loadMoreFooter.endRefreshingWithNoMoreData() }
    }
  }

  private func scrollToList() {
    let origin = list.convert(CGPoint.zero, to: scrollView)
    scrollView.setContentOffset(
      CGPoint(x: 0, y: max(-scrollView.adjustedContentInset.top, origin.y - 16)), animated: true)
  }

  private var searchText: String {
    (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func chooseExpiryFilter() {
    guard inventoryEdit == nil, inventoryMutation == nil else { return }
    let sheet = UIAlertController(title: app.text("有效期", "Expiry"), message: nil, preferredStyle: .actionSheet)
    let choices: [(String, String?)] = [(app.text("全部", "All"), nil), (app.text("临期食材", "Expiring soon"), "NEAR"), (app.text("已过期", "Expired"), "EXPIRED")]
    for (title, value) in choices { sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
      guard let self else { return }; self.expiryFilter = value; self.inventoryItems = []; self.inventoryLoaded = false; self.inventoryHasMore = false; self.inventoryNextPage = 0
      self.renderCurrentLabelsOnly(); self.loadInventory(reset: true, force: true); self.scrollToList()
    }) }
    sheet.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    sheet.popoverPresentationController?.sourceView = notice; sheet.popoverPresentationController?.sourceRect = notice.bounds; present(sheet, animated: true)
  }

  private func isNearExpiry(_ value: String?) -> Bool {
    guard let value, let date = Self.dayFormatter.date(from: value) else { return false }
    let today = Calendar.current.startOfDay(for: Date())
    guard let limit = Calendar.current.date(byAdding: .day, value: 3, to: today) else { return false }
    return date >= today && date <= limit
  }

  private func expiryText(_ value: String?) -> String {
    guard let value, let date = Self.dayFormatter.date(from: value) else { return localized("未标注日期") }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    formatter.timeZone = .current
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return app.format("到期：%@", "Expires: %@", formatter.string(from: date))
  }

  private func quantity(_ value: String, unit: String) -> String {
    unit.isEmpty ? value : "\(value) \(unit)"
  }

  private func shoppingQuantity(_ item: QFShoppingItem) -> String {
    if item.quantityKind == "TEXT" { return nonEmpty(item.quantityText) ?? localized("数量待确认") }
    if item.quantityKind == "RANGE", let min = item.quantityMin, let max = item.quantityMax {
      return "\(min)–\(max)\(item.unitCode.map { " \($0)" } ?? "")"
    }
    if let min = item.quantityMin { return quantity(min, unit: item.unitCode ?? "") }
    return localized("数量待确认")
  }

  private func shoppingStatusTitle(_ status: String?) -> String {
    switch status {
    case "DRAFT": return localized("采购单草稿")
    case "CONFIRMED": return localized("采购单已确认")
    case "SUPERSEDED": return localized("已被新采购单替代")
    default: return localized("选择采购单")
    }
  }

  private func nonEmpty(_ value: String?) -> String? {
    guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
    return result
  }

  private func openReceiptScanner() {
    view.endEditing(true)
    let scanner = QFProductBarcodeScannerViewController(app: app, householdID: app.planningHouseholdID)
    scanner.onChanged = { [weak self] in self?.inventoryLoaded = false; self?.shoppingLoaded = false }
    qfPush(scanner)
  }

  private func unavailable(_ title: String) {
    view.endEditing(true)
    showUnavailable(localized(title))
  }

  private func applyLanguage() {
    let receiveVisible = shopping && shoppingList != nil
    receiveShoppingButton.isHidden = !receiveVisible
    receiveShoppingButton.setTitle(app.text("入库", "Receive stock"), for: .normal)
    receiveShoppingButton.isEnabled = shoppingList?.items.contains { $0.checked && $0.received != true } == true && shoppingMutationTasks.isEmpty && shoppingListMutationTask == nil
    receiveShoppingButton.alpha = receiveShoppingButton.isEnabled ? 1 : 0.45
    scrollView.snp.updateConstraints { $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(receiveVisible ? 76 : 0) }
    headingTitle.text = localized("食材")
    headingSubtitle.text = app.planningScope.householdName ?? localized("把家里的食材用起来")
    scanButton.accessibilityLabel = app.text("扫描商品条码", "Scan product barcode")
    let addTitle = preparationDates == nil ? localized("＋ 添加") : app.text("手动添加", "Add manually")
    addButton.setTitle(addTitle, for: .normal)
    if preparationDates != nil {
      let longestWord = addTitle.split(separator: " ").map(String.init).max { $0.count < $1.count } ?? addTitle
      let width = (longestWord as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .semibold)]).width
      addButton.titleLabel?.font = .systemFont(ofSize: min(14, 14 * 82 / max(width, 1)), weight: .semibold)
    }
    if let preparationHeader { QFSettingsPageUI.updateHeader(preparationHeader, title: app.text("备菜", "Prep"), backLabel: app.text("返回", "Back")) }
    searchField.placeholder = localized("搜索食材名称")
    searchField.accessibilityLabel = localized("搜索食材名称")
    let shoppingCount = shoppingList?.items.filter { $0.received != true }.count ?? 0
    let previousSelection = shopping ? 1 : 0
    segment.removeAllSegments()
    segment.insertSegment(
      withTitle: app.format("家里已有 · %d", "At home · %d", inventoryTotal), at: 0,
      animated: false)
    segment.insertSegment(
      withTitle: app.format("待采购 · %d", "To buy · %d", shoppingCount), at: 1,
      animated: false)
    segment.selectedSegmentIndex = previousSelection
    QFTabUI.clear(discovery)
    discovery.addArrangedSubview(
      discoveryButton(
        localized("食材大全"), subtitle: localized("分类查找，认识食材"), symbol: "book.closed",
        background: QFUI.paleGreen, accent: QFUI.green))
    discovery.addArrangedSubview(
      discoveryButton(
        localized("食材组合推荐"), subtitle: localized("选食材，看看能做什么"), symbol: "circle",
        background: QFUI.tint, accent: QFUI.orange))
    noticeText.text = app.format("%d 种临期 · %d 种已过期", "%d expiring soon · %d expired", nearExpiryCount, expiredCount)
    notice.accessibilityLabel = noticeText.text
    noticeAction.text = localized("查看  ›")
    refreshCategories()
    renderCurrentLabelsOnly()
  }

  private func renderCurrentLabelsOnly() {
    guard sorting != nil else { return }
    listTitle.text = shopping ? localized("待采购食材") : localized("我的食材")
    sorting.setTitle(
      shopping ? shoppingStatusTitle(shoppingList?.status) : expiryFilter == "NEAR" ? app.text("临期食材", "Expiring soon") : expiryFilter == "EXPIRED" ? app.text("已过期", "Expired") : localized("临期优先"), for: .normal)
    sorting.accessibilityLabel = sorting.title(for: .normal)
    sorting.isUserInteractionEnabled = app.user != nil
      && shoppingListMutationTask == nil && shoppingMutationTasks.isEmpty
    sorting.accessibilityTraits = sorting.isUserInteractionEnabled ? .button : .staticText
    sorting.alpha = shoppingListMutationTask == nil ? 1 : 0.45
  }

  private func localized(_ chinese: String) -> String {
    app.text(chinese, Self.english[chinese] ?? chinese)
  }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let english: [String: String] = [
    "全部": "All", "蔬菜": "Vegetables", "肉蛋": "Meat & eggs", "奶制品": "Dairy",
    "水果": "Fruit", "谷物": "Grains", "水产": "Seafood", "菌藻": "Mushrooms & algae",
    "调味": "Seasonings", "食材": "Ingredients", "把家里的食材用起来": "Make the most of what you have",
    "＋ 添加": "+ Add", "添加食材": "Add ingredient",
    "食材大全": "Ingredient guide", "分类查找，认识食材": "Browse and learn by category",
    "食材组合推荐": "Recipe suggestions", "选食材，看看能做什么": "Choose ingredients to find recipes",
    "查看  ›": "View  ›", "搜索食材名称": "Search ingredients",
    "待采购食材": "Ingredients to buy", "我的食材": "My ingredients",
    "临期优先": "Expiring first", "没有找到相关食材": "No matching ingredients",
    "暂无库存": "No ingredients in stock",
    "换个名称或分类试试": "Try another name or category.", "点击重新加载": "Tap to reload",
    "正在加载": "Loading", "登录后管理食材和采购单": "Sign in to manage ingredients and shopping lists",
    "登录后的数据会在不同设备间同步": "Your data will sync across signed-in devices.",
    "暂无采购单": "No shopping list yet", "生成采购单后，待采购食材会显示在这里": "Generated shopping items will appear here.",
    "未命名食材": "Untitled ingredient", "当前语言下食材暂不可用": "Ingredient unavailable in this language",
    "未标注日期": "No marked date", "需要确认数量": "Quantity needs confirmation",
    "数量待确认": "Quantity to confirm", "已购买": "Purchased", "标记为已购买": "Mark as purchased",
    "已确认的采购单不能修改": "A confirmed shopping list cannot be changed.",
    "选择采购单": "Choose shopping list", "已被新采购单替代": "Replaced by a new shopping list",
    "采购单草稿": "Shopping list draft", "采购单已确认": "Shopping list confirmed",
    "上拉加载更多": "Pull up for more", "加载中…": "Loading…", "已全部加载": "All loaded",
    "加载失败，上拉重试": "Pull up to retry", "请先登录": "Sign in first",
    "调整库存": "Adjust inventory", "取消": "Cancel",
    "采购单操作": "Shopping list actions", "确认采购单": "Confirm shopping list",
    "按当前计划重新生成": "Regenerate from current plan", "删除采购单": "Delete shopping list",
    "请先补全需要确认的数量": "Complete quantities that need confirmation first.",
    "正在确认采购单": "Confirming shopping list", "正在重新生成采购单": "Regenerating shopping list",
    "删除采购单？": "Delete shopping list?", "删除后可从饮食计划重新生成。": "You can generate it again from the meal plan.",
    "删除": "Delete", "正在删除": "Deleting", "采购单已删除": "Shopping list deleted",
  ]
}

@MainActor
private final class QFShoppingListPickerViewController: QFProfileContentController {
  private let householdID: String?
  private let selectedID: String?
  private let onSelect: (QFShoppingList) -> Void
  private var pagination = QFContentPagination<QFShoppingList>()
  private var loaded = false

  init(
    app: QFAppSession, householdID: String?, selectedID: String?,
    onSelect: @escaping (QFShoppingList) -> Void
  ) {
    self.householdID = householdID
    self.selectedID = selectedID
    self.onSelect = onSelect
    super.init(app: app, title: app.text("选择采购单", "Choose shopping list"))
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load() }
    app.$interfaceLanguage.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in
      guard let self else { return }
      self.updateHeading(self.app.text("选择采购单", "Choose shopping list"))
      self.pagination = QFContentPagination<QFShoppingList>()
      self.bodyStack.beginUpdates()
      self.bodyStack.endUpdates()
      self.loaded = false
      self.load()
    }.store(in: &cancellables)
    app.$planningScope.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink {
      [weak self] _ in self?.close()
    }.store(in: &cancellables)
    load()
  }

  private func load(append: Bool = false) {
    let language = app.interfaceLanguage
    let query = householdID.map { ["householdId": $0] } ?? [:]
    execute(reloadOnFailure: true, loadingMore: append, showReadProgress: !loaded) { [self] in
      let result = try await pagination.fetching(
        app: app, path: "me/shopping-lists", query: query, append: append,
        reset: isRefreshingContent, id: { $0.id })
      try Task.checkCancellation()
      guard app.interfaceLanguage == language, app.planningHouseholdID == householdID else { return }
      pagination = result
      loaded = true
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("total", version: "\(pagination.total)|\(app.interfaceLanguage)") { [app, pagination] in
      QFTabUI.label(app.format("共 %d 条记录", "%d records", pagination.total), size: 13, color: QFUI.secondary)
    }
    if pagination.items.isEmpty {
      bodyStack.row("empty", version: app.interfaceLanguage) { [app] in
        QFTabUI.empty(
          app.text("暂无采购单", "No shopping list yet"),
          detail: app.text("生成采购单后，待采购食材会显示在这里", "Generated shopping items will appear here."))
      }
    }
    for item in pagination.items {
      bodyStack.row("list.\(item.id)", version: "\(item)|\(app.interfaceLanguage)") { [weak self] in
        guard let self else { return UIView() }
        let status: String
        switch item.status {
        case "DRAFT": status = self.app.text("采购单草稿", "Shopping list draft")
        case "CONFIRMED": status = self.app.text("采购单已确认", "Shopping list confirmed")
        default: status = self.app.text("已被新采购单替代", "Replaced by a new shopping list")
        }
        let dates = item.startDate == item.endDate ? item.startDate : "\(item.startDate) – \(item.endDate)"
        let count = self.app.format("%d 项食材", "%d ingredients", item.items.count)
        let language = QFInterfaceLanguage.normalized(item.language).autonym
        let button = QFTabUI.button("\(dates)\n\(status) · \(count) · \(language)", size: 15, weight: .medium) { [weak self] in
          guard let self else { return }
          self.onSelect(item)
          self.close()
        }
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .left
        button.contentHorizontalAlignment = .leading
        button.snp.makeConstraints { $0.height.greaterThanOrEqualTo(60) }
        if item.id == self.selectedID { button.accessibilityTraits.insert(.selected) }
        return QFTabUI.card(
          button, padding: 14,
          background: item.id == self.selectedID ? QFUI.paleGreen : QFUI.surface, border: true)
      }
    }
    bodyStack.endUpdates()
    setLoadMoreAction(pagination.hasMore ? { [weak self] in self?.load(append: true) } : nil)
  }
}

@MainActor
private final class QFInventoryLedgerViewController: QFProfileContentController {
  private let householdID: String?
  private let ingredientID: String
  private let ingredientName: String
  private var entries: [QFInventoryLedgerEntry] = []
  private var total = 0
  private var nextPage = 0
  private var hasMore = false
  private var loaded = false

  init(
    app: QFAppSession, householdID: String?, ingredientID: String, ingredientName: String
  ) {
    self.householdID = householdID
    self.ingredientID = ingredientID
    self.ingredientName = ingredientName
    let scopeName = app.planningScope.householdName ?? app.text("个人", "Personal")
    super.init(
      app: app, title: "\(app.text("库存流水", "Inventory history")) · \(scopeName)")
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.load(reset: true) }
    load(reset: true)
  }

  private func load(reset: Bool) {
    let page = reset ? 0 : nextPage
    execute(reloadOnFailure: true, loadingMore: !reset, showReadProgress: !loaded) { [self] in
      let response = try await app.inventoryLedger(
        householdID: householdID, ingredientID: ingredientID, page: page)
      try Task.checkCancellation()
      if reset {
        entries = response.items
      } else {
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: response.items.filter { !known.contains($0.id) })
      }
      total = response.total
      nextPage = page + 1
      hasMore = !response.items.isEmpty && entries.count < response.total
      loaded = true
      render()
    }
  }

  private func render() {
    bodyStack.beginUpdates()
    bodyStack.row("heading", version: ingredientName + "|\(total)|\(app.interfaceLanguage)") {
      [ingredientName, app, total] in
      QFTabUI.card(
        QFTabUI.stack(
          [
            QFTabUI.label(ingredientName, size: 18, weight: .semibold, lines: 2),
            QFTabUI.label(
              app.format("共 %d 条记录", "%d records", total), size: 12,
              color: QFUI.secondary),
          ], spacing: 5), padding: 14, background: QFUI.paleGreen)
    }
    if entries.isEmpty {
      bodyStack.row("empty", version: app.interfaceLanguage) { [app] in
        QFTabUI.empty(
          app.text("还没有库存变动", "No inventory changes yet"),
          detail: app.text("入库、使用和调整会显示在这里。", "Receipts, usage, and adjustments appear here."))
      }
    }
    for entry in entries {
      bodyStack.row(entry.id, value: entry) { [weak self] in
        self?.entryCard(entry) ?? UIView()
      }
    }
    bodyStack.endUpdates()
    setLoadMoreAction(hasMore ? { [weak self] in self?.load(reset: false) } : nil)
  }

  private func entryCard(_ entry: QFInventoryLedgerEntry) -> UIView {
    let title: String
    switch entry.action {
    case "RECEIVE": title = app.text("入库", "Received")
    case "WASTE": title = app.text("损耗", "Wasted")
    case "ADJUST": title = app.text("库存校正", "Adjusted")
    case "CONSUME": title = app.text("做菜使用", "Used for cooking")
    case "REVERSE": title = app.text("撤销扣减", "Deduction reversed")
    default: title = entry.action
    }
    var rows: [UIView] = [
      QFTabUI.stack(
        [
          QFTabUI.label(title, size: 16, weight: .semibold), UIView(),
          QFTabUI.label(
            "\(entry.quantityDelta) \(entry.unitCode)", size: 14,
            color: entry.quantityDelta.hasPrefix("-") ? QFUI.danger : QFUI.green),
        ], axis: .horizontal, spacing: 10),
      QFTabUI.label(formatDate(entry.createdAt), size: 12, color: QFUI.secondary),
    ]
    if !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      rows.append(QFTabUI.label(entry.note, size: 12, color: QFUI.secondary, lines: 0))
    }
    return QFTabUI.card(QFTabUI.stack(rows, spacing: 6), padding: 14, border: true)
  }

  private func formatDate(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else { return value }
    let formatter = DateFormatter()
    formatter.locale = Locale(
      identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
  }
}

@MainActor
private final class QFInventoryAdjustmentViewController: QFProfileContentController {
  private let lot: QFInventoryLot
  private let onSaved: (QFInventoryLot) -> Void
  private var action = "RECEIVE"
  private var quantity = ""
  private var note = ""
  private let idempotencyKey = UUID().uuidString.lowercased()

  init(app: QFAppSession, lot: QFInventoryLot, onSaved: @escaping (QFInventoryLot) -> Void) {
    self.lot = lot
    self.onSaved = onSaved
    super.init(app: app, title: app.text("调整库存", "Adjust inventory"))
  }

  required init?(coder: NSCoder) { nil }
  override var reloadsOnAppearance: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    buildForm()
    _ = addFooter(app.text("保存调整", "Save adjustment")) { [weak self] in self?.save() }
  }

  private func buildForm() {
    let name = lot.ingredientName?.isEmpty == false
      ? lot.ingredientName! : app.text("食材", "Ingredient")
    bodyStack.addArrangedSubview(
      QFTabUI.card(
        QFTabUI.stack(
          [
            QFTabUI.label(name, size: 18, weight: .semibold, lines: 0),
            QFTabUI.label(
              app.format("当前库存：%@ %@", "Current stock: %@ %@", lot.currentQuantity, lot.unitCode),
              size: 13, color: QFUI.secondary, lines: 0),
          ], spacing: 6), padding: 14, border: true))
    let mode = QFContentUI.segments(
      [app.text("增加", "Add"), app.text("消耗", "Use"), app.text("校正", "Correct")]
    ) { [weak self] index in
      self?.action = ["RECEIVE", "WASTE", "ADJUST"][min(max(index, 0), 2)]
    }
    bodyStack.addArrangedSubview(mode)
    bodyStack.addArrangedSubview(
      QFTabUI.stack(
        [
          QFTabUI.label(app.text("调整数量", "Adjustment quantity"), size: 13, color: QFUI.secondary),
          QFContentUI.field(
            app.text("校正时可输入负数", "A correction may be negative"), keyboard: .numbersAndPunctuation,
            limit: 24
          ) { [weak self] in self?.quantity = $0 },
          QFTabUI.label(
            app.format("单位：%@", "Unit: %@", lot.unitCode), size: 12,
            color: QFUI.secondary),
        ], spacing: 7))
    bodyStack.addArrangedSubview(
      QFTabUI.stack(
        [
          QFTabUI.label(app.text("备注", "Note"), size: 13, color: QFUI.secondary),
          QFContentUI.field(app.text("可选", "Optional"), limit: 500) { [weak self] in
            self?.note = $0
          },
        ], spacing: 7))
  }

  private func save() {
    let amount = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let decimal = Decimal(string: amount), decimal != 0,
      action == "ADJUST" || decimal > 0
    else {
      message(
        app.text(
          "请输入有效数量；增加和消耗必须大于 0。",
          "Enter a valid quantity; additions and usage must be greater than 0."), error: true)
      return
    }
    execute(label: app.text("正在保存", "Saving")) { [self] in
      let saved = try await app.adjustInventoryLot(
        lot.id,
        draft: QFInventoryAdjustmentDraft(
          action: action, quantity: amount, unitCode: lot.unitCode,
          note: note.trimmingCharacters(in: .whitespacesAndNewlines),
          expectedRevision: lot.revision, idempotencyKey: idempotencyKey))
      try Task.checkCancellation()
      onSaved(saved)
      onChanged?()
      closeWithSuccess(app.text("库存已更新", "Inventory updated"))
    }
  }
}

@MainActor
private final class QFInventoryAddIngredientSheet: UIViewController {
  enum Choice { case catalog, custom, recipe, assistant }

  private let app: QFAppSession
  private let selection: (Choice) -> Void

  init(app: QFAppSession, selection: @escaping (Choice) -> Void) {
    self.app = app
    self.selection = selection
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      if #available(iOS 16.0, *) {
        sheet.detents = [.custom(identifier: .init("inventory-add")) { context in
          min(340, context.maximumDetentValue)
        }, .large()]
      } else {
        sheet.detents = [.medium(), .large()]
      }
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = QFInventoryLayout.sheetRadius
    }
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    view.accessibilityIdentifier = "inventory.add.sheet"

    let title = QFTabUI.label(app.text("添加食材", "Add ingredient"), size: 20, weight: .semibold)
    let close = QFTabUI.iconButton("xmark", label: app.text("关闭", "Close"), size: 17) { [weak self] in
      self?.dismiss(animated: true)
    }
    let header = QFTabUI.stack([title, UIView(), close], axis: .horizontal, spacing: 8)
    header.alignment = .center

    let rows = QFTabUI.stack([
      row(title: app.text("从食材库选择", "Choose from catalog"), id: "catalog") { [weak self] in self?.choose(.catalog) },
      row(title: app.text("自定义食材名称", "Use a custom ingredient name"), id: "custom") { [weak self] in self?.choose(.custom) },
      row(title: app.text("按菜谱添加食材", "Add ingredients from a recipe"), id: "recipe") { [weak self] in self?.choose(.recipe) },
      row(title: app.text("让 AI 生成添加草稿", "Ask AI to make an add draft"), id: "assistant") { [weak self] in self?.choose(.assistant) },
    ], spacing: 8)

    let cancel = QFTabUI.button(app.text("取消", "Cancel"), size: 15, color: QFUI.secondary) { [weak self] in
      self?.dismiss(animated: true)
    }
    cancel.snp.makeConstraints { $0.height.equalTo(36) }
    let stack = QFTabUI.stack([header, rows, cancel], spacing: 14)
    view.addSubview(stack)
    stack.snp.makeConstraints {
      $0.top.equalTo(view.safeAreaLayoutGuide).offset(12)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
      $0.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).inset(12)
    }
  }

  private func row(title: String, id: String, action: @escaping () -> Void) -> UIButton {
    let button = QFTabUI.button(title, size: 15, color: QFUI.text, background: QFUI.surface, action: action)
    button.contentHorizontalAlignment = .leading
    button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.lineBreakMode = .byTruncatingTail
    button.titleLabel?.adjustsFontSizeToFitWidth = true
    button.titleLabel?.minimumScaleFactor = 0.82
    button.layer.cornerRadius = 12
    button.layer.cornerCurve = .continuous
    button.accessibilityIdentifier = "inventory.add.\(id)"
    button.snp.makeConstraints { $0.height.equalTo(44) }
    return button
  }

  private func choose(_ choice: Choice) {
    dismiss(animated: true) { [selection] in selection(choice) }
  }
}

/// Compact, scrollable unit picker. A UIAlertController action sheet grows to
/// the height of every supported measurement unit, which obscures the editor
/// on smaller phones and makes custom units hard to reach.
@MainActor
private final class QFMeasurementUnitPickerViewController: UIViewController {
  private let app: QFAppSession
  private let titleText: String
  private let units: [QFMeasurementUnit]
  private let selectedCode: String
  private let selection: (QFMeasurementUnit) -> Void

  init(app: QFAppSession, title: String, units: [QFMeasurementUnit], selectedCode: String,
       selection: @escaping (QFMeasurementUnit) -> Void) {
    self.app = app; self.titleText = title; self.units = units
    self.selectedCode = selectedCode; self.selection = selection
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      if #available(iOS 16.0, *) {
        sheet.detents = [.custom(identifier: .init("unit-picker")) { context in min(380, context.maximumDetentValue) }, .large()]
      } else { sheet.detents = [.medium(), .large()] }
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = QFInventoryLayout.sheetRadius
    }
  }
  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = QFUI.background
    let title = QFTabUI.label(titleText, size: 20, weight: .semibold)
    let close = QFTabUI.iconButton("xmark", label: app.text("关闭", "Close"), size: 17) { [weak self] in self?.dismiss(animated: true) }
    let header = QFTabUI.stack([title, UIView(), close], axis: .horizontal, spacing: 8); header.alignment = .center
    let rows = QFTabUI.stack([], spacing: 8)
    for unit in units {
      let row = QFTabUI.button("\(unit.name)（\(unit.symbol)）", size: 15, color: QFUI.text, background: unit.code == selectedCode ? QFUI.tint : QFUI.surface) { [weak self] in
        guard let self else { return }; dismiss(animated: true) { self.selection(unit) }
      }
      row.contentHorizontalAlignment = .leading; row.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
      row.layer.cornerRadius = 12; row.layer.cornerCurve = .continuous; row.snp.makeConstraints { $0.height.equalTo(44) }
      rows.addArrangedSubview(row)
    }
    let scroll = UIScrollView(); scroll.alwaysBounceVertical = true; scroll.addSubview(rows)
    view.addSubview(header); view.addSubview(scroll)
    header.snp.makeConstraints { $0.top.equalTo(view.safeAreaLayoutGuide).offset(12); $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20); $0.height.equalTo(32) }
    scroll.snp.makeConstraints { $0.top.equalTo(header.snp.bottom).offset(12); $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20); $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12) }
    rows.snp.makeConstraints { $0.edges.equalToSuperview(); $0.width.equalTo(scroll.snp.width) }
  }
}

@MainActor
private final class QFShoppingItemEditorViewController: QFProfileContentController {
  private let listID: String
  private let item: QFShoppingItem
  private let onSaved: (QFShoppingItem) -> Void
  private var quantityKind: String
  private var quantityMin: String
  private var quantityMax: String
  private var unitCode: String
  private var units: [QFMeasurementUnit] = []
  private weak var maximumGroup: UIView?
  private weak var unitButton: UIButton?

  init(
    app: QFAppSession, listID: String, item: QFShoppingItem,
    onSaved: @escaping (QFShoppingItem) -> Void
  ) {
    self.listID = listID
    self.item = item
    self.onSaved = onSaved
    quantityKind = item.quantityKind == "RANGE" ? "RANGE" : "EXACT"
    quantityMin = item.quantityMin ?? ""
    quantityMax = item.quantityMax ?? ""
    unitCode = item.unitCode ?? "g"
    super.init(app: app, title: app.text("调整采购数量", "Edit shopping quantity"))
  }

  required init?(coder: NSCoder) { nil }
  override var reloadsOnAppearance: Bool { false }

  override func viewDidLoad() {
    super.viewDidLoad()
    setReloadAction { [weak self] in self?.loadUnits() }
    buildForm()
    _ = addFooter(app.text("保存数量", "Save quantity")) { [weak self] in self?.save() }
    loadUnits()
  }

  private func buildForm() {
    bodyStack.addArrangedSubview(
      QFTabUI.card(
        QFTabUI.stack(
          [
            QFTabUI.label(item.name, size: 18, weight: .semibold, lines: 0),
            QFTabUI.label(
              item.quantityKind == "TEXT"
                ? app.format("原始用量：%@", "Original amount: %@", item.quantityText ?? "—")
                : app.text("填写可计算的采购数量", "Enter a measurable shopping quantity"),
              size: 12, color: QFUI.secondary, lines: 0),
          ], spacing: 6), padding: 14, border: true))
    bodyStack.addArrangedSubview(
      QFContentUI.segments(
        [app.text("单一数量", "Exact quantity"), app.text("数量范围", "Quantity range")],
        selected: quantityKind == "RANGE" ? 1 : 0
      ) { [weak self] index in
        self?.quantityKind = index == 1 ? "RANGE" : "EXACT"
        self?.maximumGroup?.isHidden = index != 1
      })
    bodyStack.addArrangedSubview(
      labeled(
        app.text("数量", "Quantity"),
        view: QFContentUI.field(
          app.text("请输入数量", "Enter quantity"), text: quantityMin, keyboard: .decimalPad,
          limit: 24
        ) { [weak self] in self?.quantityMin = $0 }))
    let maximum = labeled(
      app.text("最大数量", "Maximum quantity"),
      view: QFContentUI.field(
        app.text("请输入最大数量", "Enter maximum quantity"), text: quantityMax,
        keyboard: .decimalPad, limit: 24
      ) { [weak self] in self?.quantityMax = $0 })
    maximum.isHidden = quantityKind != "RANGE"
    maximumGroup = maximum
    bodyStack.addArrangedSubview(maximum)
    let unit = QFContentUI.action(unitTitle()) { [weak self] in self?.chooseUnit() }
    unit.contentHorizontalAlignment = .leading
    unit.backgroundColor = QFUI.surface
    unit.layer.cornerRadius = 12
    unit.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    unitButton = unit
    bodyStack.addArrangedSubview(labeled(app.text("单位", "Unit"), view: unit))
  }

  private func labeled(_ title: String, view: UIView) -> UIView {
    QFTabUI.stack(
      [QFTabUI.label(title, size: 13, color: QFUI.secondary), view], spacing: 7)
  }

  private func loadUnits() {
    execute(reloadOnFailure: true, showReadProgress: units.isEmpty) { [self] in
      let loaded = try await app.measurementUnits()
      try Task.checkCancellation()
      units = loaded
      if !loaded.contains(where: { $0.code == unitCode }), let first = loaded.first {
        unitCode = first.code
      }
      unitButton?.setTitle(unitTitle(), for: .normal)
    }
  }

  private func unitTitle() -> String {
    guard let unit = units.first(where: { $0.code == unitCode }) else { return unitCode }
    return "\(unit.name)（\(unit.symbol)）"
  }

  private func chooseUnit() {
    guard !units.isEmpty else {
      message(app.text("单位仍在加载，请稍后重试。", "Units are still loading. Try again shortly."))
      return
    }
    let picker = QFMeasurementUnitPickerViewController(app: app, title: app.text("选择单位", "Choose unit"), units: units, selectedCode: unitCode) { [weak self] unit in
      self?.unitCode = unit.code
      self?.unitButton?.setTitle(self?.unitTitle(), for: .normal)
    }
    open(picker)
  }

  private func save() {
    let minimum = quantityMin.trimmingCharacters(in: .whitespacesAndNewlines)
    let maximum = quantityMax.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let minValue = Decimal(string: minimum), minValue > 0 else {
      message(app.text("请输入大于 0 的数量。", "Enter a quantity greater than 0."), error: true)
      return
    }
    if quantityKind == "RANGE" {
      guard let maxValue = Decimal(string: maximum), maxValue >= minValue else {
        message(app.text("最大数量不能小于起始数量。", "Maximum quantity cannot be less than the starting quantity."), error: true)
        return
      }
    }
    guard !unitCode.isEmpty else {
      message(app.text("请选择单位。", "Choose a unit."), error: true)
      return
    }
    execute(label: app.text("正在保存", "Saving")) { [self] in
      let saved = try await app.updateShoppingItem(
        listID: listID, itemID: item.id,
        patch: QFShoppingItemPatch(
          checked: item.checked, quantityKind: quantityKind, quantityMin: minimum,
          quantityMax: quantityKind == "RANGE" ? maximum : nil, unitCode: unitCode,
          quantityText: nil, expectedRevision: item.revision))
      try Task.checkCancellation()
      onSaved(saved)
      onChanged?()
      closeWithSuccess(app.text("采购数量已更新", "Shopping quantity updated"))
    }
  }
}
