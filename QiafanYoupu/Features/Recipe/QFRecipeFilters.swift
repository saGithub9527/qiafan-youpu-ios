import SnapKit
import UIKit

@MainActor
final class QFRecipeFilterButton: UIButton {
  private let nameLabel = QFTabUI.label("", size: 10.5, color: QFUI.secondary)
  private let valueLabel = QFTabUI.label("", size: 12, weight: .medium)
  private let chevron = QFTabUI.symbol("chevron.down", size: 9, color: QFUI.secondary)

  init(name: String, action: @escaping () -> Void) {
    super.init(frame: .zero)
    backgroundColor = QFUI.surface
    layer.cornerRadius = 12
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    layer.borderColor = QFUI.border.cgColor
    nameLabel.text = name
    valueLabel.lineBreakMode = .byTruncatingTail
    let labels = QFTabUI.stack([nameLabel, valueLabel], spacing: 3)
    let row = QFTabUI.stack([labels, UIView(), chevron], axis: .horizontal, spacing: 4)
    row.alignment = .center
    row.isUserInteractionEnabled = false
    addSubview(row)
    row.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 9)) }
    addAction(UIAction { _ in action() }, for: .touchUpInside)
    snp.makeConstraints { $0.height.equalTo(QFRecipeHomeLayout.filterHeight) }
  }

  required init?(coder: NSCoder) { nil }

  func setName(_ value: String) {
    nameLabel.text = value
  }

  func setValue(_ value: String, active: Bool) {
    valueLabel.text = value
    valueLabel.textColor = active ? QFUI.primary : QFUI.text
    layer.borderColor = (active ? QFUI.primary : QFUI.border).cgColor
    backgroundColor = active ? QFUI.tint : QFUI.surface
    accessibilityLabel = "\(nameLabel.text ?? "")，\(value)"
    accessibilityTraits = active ? [.button, .selected] : [.button]
  }
}

@MainActor
final class QFRecipeOptionSheetViewController: UIViewController, UITableViewDelegate {
  private let app: QFAppSession
  private let heading: String
  private let unrestrictedTitle: String
  private let options: [QFRecipeOption]
  private let selection: (String?) -> Void
  private let table = UITableView(frame: .zero, style: .plain)
  private var selectedID: String?
  private var dataSource: UITableViewDiffableDataSource<Int, String>!

  init(
    app: QFAppSession, title: String, unrestrictedTitle: String, options: [QFRecipeOption],
    selectedID: String?, selection: @escaping (String?) -> Void
  ) {
    self.app = app
    heading = title
    self.unrestrictedTitle = unrestrictedTitle
    self.options = options.filter { !QFRecipeFilterState.representsAll($0.id) }
    self.selectedID = selectedID
    self.selection = selection
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    let titleLabel = QFTabUI.label(heading, size: 20, weight: .semibold)
    titleLabel.textAlignment = .center
    let close = QFTabUI.iconButton("xmark", label: app.text("关闭", "Close"), size: 17) { [weak self] in
      self?.dismiss(animated: true)
    }
    let spacer = UIView()
    spacer.snp.makeConstraints { $0.size.equalTo(44) }
    let header = QFTabUI.stack([spacer, titleLabel, close], axis: .horizontal, spacing: 4)
    header.alignment = .center
    view.addSubview(header)
    header.snp.makeConstraints {
      $0.top.equalTo(view.safeAreaLayoutGuide).offset(8)
      $0.leading.trailing.equalToSuperview().inset(16)
      $0.height.equalTo(48)
    }
    table.backgroundColor = QFUI.background
    table.separatorColor = QFUI.border
    table.rowHeight = 54
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "option")
    view.addSubview(table)
    let reset = QFTabUI.button(
      app.text("重置", "Reset"), size: 16, weight: .semibold, color: QFUI.text,
      background: QFUI.surface
    ) { [weak self] in self?.selectedID = nil; self?.applySnapshot() }
    let confirm = QFTabUI.button(
      app.text("确定", "Apply"), size: 16, weight: .semibold, color: QFUI.onPrimary,
      background: QFUI.primary
    ) { [weak self] in
      guard let self else { return }
      let value = self.selectedID
      self.dismiss(animated: true) { self.selection(value) }
    }
    for button in [reset, confirm] { button.layer.cornerRadius = 15; button.snp.makeConstraints { $0.height.equalTo(50) } }
    let footer = QFTabUI.stack([reset, confirm], axis: .horizontal, spacing: 12)
    footer.distribution = .fillEqually
    view.addSubview(footer)
    footer.snp.makeConstraints {
      $0.leading.trailing.equalToSuperview().inset(20)
      $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12)
    }
    table.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom).offset(4)
      $0.leading.trailing.equalToSuperview()
      $0.bottom.equalTo(footer.snp.top).offset(-10)
    }
    dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) {
      [weak self] table, index, id in
      guard let self else { return nil }
      let cell = table.dequeueReusableCell(withIdentifier: "option", for: index)
      var content = cell.defaultContentConfiguration()
      content.text = id == "__unrestricted" ? self.unrestrictedTitle : self.options.first { $0.id == id }?.name
      content.textProperties.color = QFUI.text
      content.textProperties.font = .preferredFont(forTextStyle: .body)
      cell.contentConfiguration = content
      cell.backgroundColor = QFUI.background
      cell.accessoryType = (id == "__unrestricted" ? self.selectedID == nil : self.selectedID == id) ? .checkmark : .none
      cell.tintColor = QFUI.primary
      return cell
    }
    applySnapshot()
    if let sheet = sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 24
    }
  }

  private func applySnapshot() {
    let existing = Set(dataSource.snapshot().itemIdentifiers)
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(["__unrestricted"] + options.map(\.id))
    snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(existing.contains))
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
    selectedID = id == "__unrestricted" ? nil : id
    applySnapshot()
  }
}

@MainActor
final class QFRecipeCountryFilterViewController: UIViewController, UITableViewDelegate,
  UISearchBarDelegate
{
  private let app: QFAppSession
  private let selection: (String?) -> Void
  private let allOptions: [QFRecipeOption]
  private var visibleOptions: [QFRecipeOption]
  private var selectedID: String?
  private let table = UITableView(frame: .zero, style: .plain)
  private let searchBar = UISearchBar()
  private var dataSource: UITableViewDiffableDataSource<Int, String>!

  init(
    app: QFAppSession, options: [QFRecipeOption], selectedID: String?,
    selection: @escaping (String?) -> Void
  ) {
    self.app = app
    allOptions = options.filter { !QFRecipeFilterState.representsAll($0.id) }
    visibleOptions = allOptions
    self.selectedID = selectedID
    self.selection = selection
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    let header = QFSettingsPageUI.header(
      app.text("国家或地区", "Country or region"), backLabel: app.text("返回", "Back")
    ) { [weak self] in
      self?.qfClose()
    }
    QFSettingsPageUI.installHeader(header, in: view)
    searchBar.searchBarStyle = .minimal
    searchBar.placeholder = app.text("搜索国家或地区", "Search countries or regions")
    searchBar.delegate = self
    view.addSubview(searchBar)
    searchBar.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(12)
      $0.height.equalTo(50)
    }
    let reset = QFTabUI.button(
      app.text("重置", "Reset"), size: 16, weight: .semibold, color: QFUI.text,
      background: QFUI.surface
    ) { [weak self] in self?.selectedID = nil; self?.applySnapshot() }
    let confirm = QFTabUI.button(
      app.text("确定", "Apply"), size: 16, weight: .semibold, color: QFUI.onPrimary,
      background: QFUI.primary
    ) { [weak self] in
      guard let self else { return }
      let value = self.selectedID
      self.qfClose { self.selection(value) }
    }
    for button in [reset, confirm] { button.layer.cornerRadius = 15; button.snp.makeConstraints { $0.height.equalTo(50) } }
    let footer = QFTabUI.stack([reset, confirm], axis: .horizontal, spacing: 12)
    footer.distribution = .fillEqually
    view.addSubview(footer)
    footer.snp.makeConstraints {
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20)
      $0.bottom.equalTo(view.keyboardLayoutGuide.snp.top).offset(-12)
    }
    table.backgroundColor = QFUI.background
    table.keyboardDismissMode = .interactive
    table.separatorColor = QFUI.border
    table.rowHeight = 56
    table.delegate = self
    table.register(UITableViewCell.self, forCellReuseIdentifier: "country")
    view.addSubview(table)
    table.snp.makeConstraints {
      $0.top.equalTo(searchBar.snp.bottom)
      $0.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      $0.bottom.equalTo(footer.snp.top).offset(-10)
    }
    dataSource = UITableViewDiffableDataSource<Int, String>(tableView: table) {
      [weak self] table, index, id in
      guard let self else { return nil }
      let cell = table.dequeueReusableCell(withIdentifier: "country", for: index)
      var content = cell.defaultContentConfiguration()
      content.text = id == "__global"
        ? self.app.text("全球", "Global") : self.visibleOptions.first { $0.id == id }?.name
      content.textProperties.color = QFUI.text
      content.textProperties.font = .preferredFont(forTextStyle: .body)
      cell.contentConfiguration = content
      cell.backgroundColor = QFUI.background
      cell.accessoryType = (id == "__global" ? self.selectedID == nil : self.selectedID == id) ? .checkmark : .none
      cell.tintColor = QFUI.primary
      return cell
    }
    applySnapshot()
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    visibleOptions = text.isEmpty ? allOptions : allOptions.filter {
      $0.name.localizedCaseInsensitiveContains(text) || $0.id.localizedCaseInsensitiveContains(text)
    }
    applySnapshot()
  }

  private func applySnapshot() {
    let existing = Set(dataSource.snapshot().itemIdentifiers)
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(["__global"] + visibleOptions.map(\.id))
    snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(existing.contains))
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let id = dataSource.itemIdentifier(for: indexPath) else { return }
    selectedID = id == "__global" ? nil : id
    applySnapshot()
  }
}

@MainActor
final class QFRecipeRatingFilterViewController: UIViewController, UITextFieldDelegate {
  private let app: QFAppSession
  private let presets: [Double]
  private let selection: (Double?) -> Void
  private var value: Double?
  private var inputIsValid = true
  private let presetStack = UIStackView()
  private let textField = UITextField()
  private let errorLabel = QFTabUI.label("", size: 11.5, color: .systemRed, lines: 0)
  private var confirmButton: UIButton!
  private var optionButtons: [(value: Double?, button: UIButton)] = []

  init(
    app: QFAppSession, presets: [Double], selected: Double?,
    selection: @escaping (Double?) -> Void
  ) {
    self.app = app
    self.presets = presets
    value = selected
    self.selection = selection
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = QFUI.background
    let title = QFTabUI.label(app.text("评分筛选", "Rating filter"), size: 20, weight: .semibold)
    title.textAlignment = .center
    let close = QFTabUI.iconButton("xmark", label: app.text("关闭", "Close"), size: 17) {
      [weak self] in self?.dismiss(animated: true)
    }
    let spacer = UIView()
    spacer.snp.makeConstraints { $0.size.equalTo(44) }
    let header = QFTabUI.stack([spacer, title, close], axis: .horizontal, spacing: 4)
    header.alignment = .center
    view.addSubview(header)
    header.snp.makeConstraints {
      $0.top.equalTo(view.safeAreaLayoutGuide).offset(8)
      $0.leading.trailing.equalToSuperview().inset(16)
      $0.height.equalTo(48)
    }

    presetStack.axis = .vertical
    presetStack.spacing = 0
    let availablePresets = Array(presets.filter { $0 > 0 && $0 <= 5 }.prefix(4))
    addOption(title: app.text("不限", "Any rating"), value: nil)
    for number in availablePresets {
      addOption(
        title: app.format(
          "%@ 分及以上", "%@ and up",
          QFRecipeFilterState.ratingDisplayString(
            number, language: QFInterfaceLanguage.normalized(app.interfaceLanguage))),
        value: number)
    }
    view.addSubview(presetStack)
    presetStack.snp.makeConstraints {
      $0.top.equalTo(header.snp.bottom).offset(18)
      $0.leading.trailing.equalToSuperview().inset(20)
    }

    let inputTitle = QFTabUI.label(
      app.text("自定义最低评分", "Custom minimum rating"), size: 13, weight: .medium,
      color: QFUI.secondary)
    textField.backgroundColor = QFUI.surface
    textField.layer.cornerRadius = 12
    textField.layer.borderWidth = 1
    textField.layer.borderColor = QFUI.border.cgColor
    textField.font = .systemFont(ofSize: 16, weight: .medium)
    textField.textColor = QFUI.text
    textField.keyboardType = .decimalPad
    textField.returnKeyType = .done
    textField.clearButtonMode = .whileEditing
    textField.delegate = self
    textField.accessibilityLabel = app.text("自定义最低评分", "Custom minimum rating")
    textField.addAction(UIAction { [weak self] _ in self?.inputChanged() }, for: .editingChanged)
    let leftPadding = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
    textField.leftView = leftPadding
    textField.leftViewMode = .always
    let suffixLabel = QFTabUI.label(app.text("分及以上", "and up"), size: 13, color: QFUI.secondary)
    let suffix = UIView()
    suffix.addSubview(suffixLabel)
    suffixLabel.snp.makeConstraints {
      $0.leading.equalToSuperview().offset(8)
      $0.trailing.equalToSuperview().inset(14)
      $0.centerY.equalToSuperview()
    }
    textField.rightView = suffix
    textField.rightViewMode = .always
    textField.snp.makeConstraints { $0.height.equalTo(48) }
    errorLabel.isHidden = true
    let inputStack = QFTabUI.stack([inputTitle, textField, errorLabel], spacing: 8)
    view.addSubview(inputStack)
    inputStack.snp.makeConstraints {
      $0.top.equalTo(presetStack.snp.bottom).offset(22)
      $0.leading.trailing.equalToSuperview().inset(20)
    }

    let reset = QFTabUI.button(
      app.text("重置", "Reset"), size: 16, weight: .semibold, color: QFUI.text,
      background: QFUI.surface
    ) { [weak self] in self?.selectOption(nil) }
    confirmButton = QFTabUI.button(
      app.text("确定", "Apply"), size: 16, weight: .semibold, color: QFUI.onPrimary,
      background: QFUI.primary
    ) { [weak self] in
      guard let self, self.inputIsValid else { return }
      let selected = self.value
      self.dismiss(animated: true) { self.selection(selected) }
    }
    for button in [reset, confirmButton!] {
      button.layer.cornerRadius = 15
      button.snp.makeConstraints { $0.height.equalTo(50) }
    }
    reset.snp.makeConstraints { $0.width.equalTo(96) }
    let footer = QFTabUI.stack([reset, confirmButton], axis: .horizontal, spacing: 12)
    view.addSubview(footer)
    footer.snp.makeConstraints {
      $0.leading.trailing.equalToSuperview().inset(20)
      $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12)
    }

    let dismissKeyboard = UITapGestureRecognizer(target: self, action: #selector(endEditing))
    dismissKeyboard.cancelsTouchesInView = false
    view.addGestureRecognizer(dismissKeyboard)
    if let sheet = sheetPresentationController {
      if #available(iOS 16.0, *) {
        let identifier = UISheetPresentationController.Detent.Identifier("recipe-rating")
        sheet.detents = [
          .custom(identifier: identifier) { context in min(544, context.maximumDetentValue) }
        ]
      } else {
        sheet.detents = [.large()]
      }
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 24
    }
    render(syncText: true)
  }

  private func addOption(title: String, value: Double?) {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.setTitleColor(QFUI.text, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    button.contentHorizontalAlignment = .leading
    button.tintColor = QFUI.primary
    button.accessibilityLabel = title
    button.addAction(UIAction { [weak self] _ in self?.selectOption(value) }, for: .touchUpInside)
    button.snp.makeConstraints { $0.height.equalTo(44) }
    if !optionButtons.isEmpty {
      let divider = UIView()
      divider.backgroundColor = QFUI.border
      button.addSubview(divider)
      divider.snp.makeConstraints {
        $0.leading.trailing.equalToSuperview()
        $0.top.equalToSuperview()
        $0.height.equalTo(0.5)
      }
    }
    presetStack.addArrangedSubview(button)
    optionButtons.append((value, button))
  }

  private func selectOption(_ selected: Double?) {
    value = selected
    inputIsValid = true
    errorLabel.isHidden = true
    textField.layer.borderColor = QFUI.border.cgColor
    render(syncText: true)
  }

  private func inputChanged() {
    let raw = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty {
      value = nil
      inputIsValid = true
    } else {
      let normalized = raw.replacingOccurrences(of: ",", with: ".")
      let validFormat = normalized.range(
        of: #"^(?:[0-4](?:\.[0-9])?|5(?:\.0)?)$"#, options: .regularExpression) != nil
      if validFormat, let parsed = Double(normalized) {
        value = parsed
        inputIsValid = true
      } else {
        inputIsValid = false
      }
    }
    errorLabel.text = app.text(
      "请输入 0 至 5，最多一位小数", "Enter 0–5 with at most one decimal place")
    errorLabel.isHidden = inputIsValid
    textField.layer.borderColor = (inputIsValid ? QFUI.border : UIColor.systemRed).cgColor
    render(syncText: false)
  }

  private func render(syncText: Bool) {
    if syncText {
      textField.text = value.map {
        QFRecipeFilterState.ratingDisplayString(
          $0, language: QFInterfaceLanguage.normalized(app.interfaceLanguage))
      } ?? ""
    }
    for option in optionButtons {
      let selected = inputIsValid && sameRating(option.value, value)
      option.button.setImage(
        UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"), for: .normal)
      option.button.configuration?.imagePadding = 10
      option.button.accessibilityTraits = selected ? [.button, .selected] : [.button]
    }
    confirmButton?.isEnabled = inputIsValid
    confirmButton?.alpha = inputIsValid ? 1 : 0.45
  }

  private func sameRating(_ lhs: Double?, _ rhs: Double?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (left?, right?): return abs(left - right) < 0.0001
    default: return false
    }
  }

  @objc private func endEditing() { view.endEditing(true) }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }
}
