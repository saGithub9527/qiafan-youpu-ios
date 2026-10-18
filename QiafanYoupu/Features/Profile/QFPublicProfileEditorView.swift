import SnapKit
import UIKit

struct QFPublicProfile: Codable, Equatable {
  var nickname: String
  var countryCode: String?
  var regionCode: String?
  var bio: String?
  var avatarMediaId: String?
}

@MainActor
final class QFPublicProfileEditorViewController: QFProfileContentController {
  private var draft: QFPublicProfile {
    didSet {
      guard isViewLoaded, loaded else { return }
      QFContentDraftStore.save(draft, app: app, kind: "public-profile")
      if draft.avatarMediaId != oldValue.avatarMediaId {
        QFLocalMediaStore.remove(oldValue.avatarMediaId, scope: app.contentScope)
      }
    }
  }
  private var initial: QFPublicProfile
  private var loaded = false
  private var saveButton: UIButton!
  private let avatarImage = QFContentImageView()
  private var nicknameField: UITextField!
  private var regionField: UITextField!
  private var bioField: QFContentTextArea!
  private var countryButton: UIButton!
  override var reloadsOnAppearance: Bool { false }
  override var hasUnsavedChanges: Bool { draft != initial }
  init(app: QFAppSession) {
    let value =
      app.cachedContent(QFPublicProfile.self, path: "me/public-profile")
      ?? QFPublicProfile(
        nickname: app.user?.nickname ?? "", countryCode: app.user?.countryCode,
        regionCode: app.user?.regionCode, bio: app.user?.bio,
        avatarMediaId: app.cachedContent(QFContentSummary.self, path: "me/content-summary")?
          .avatarMediaId)
    initial = value
    draft =
      QFContentDraftStore.load(QFPublicProfile.self, app: app, kind: "public-profile") ?? value
    super.init(app: app, title: app.text("编辑资料", "Edit profile"))
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    saveButton = addFooter(app.text("保存", "Save")) { [weak self] in self?.save() }
    let avatar = UIView()
    avatar.addSubview(avatarImage)
    avatarImage.snp.makeConstraints {
      $0.size.equalTo(104)
      $0.centerX.top.bottom.equalToSuperview()
    }
    avatarImage.layer.cornerRadius = 52
    avatarImage.clipsToBounds = true
    bodyStack.addArrangedSubview(avatar)
    bodyStack.addArrangedSubview(
      QFContentUI.action(app.text("更换头像", "Change profile photo")) { [weak self] in
        self?.chooseMedia(cropAvatar: true) { [weak self] media in
          guard let self else { return }
          self.draft.avatarMediaId = media.id
          self.updateAvatar()
          self.validate()
        }
      })
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("昵称", "Nickname"), size: 14, color: QFUI.secondary))
    nicknameField = QFContentUI.field(app.text("请输入昵称", "Enter a nickname"), text: draft.nickname, limit: 64) { [weak self] in
      self?.draft.nickname = $0
      self?.validate()
    }
    bodyStack.addArrangedSubview(nicknameField)
    countryButton = QFContentUI.action("") { [weak self] in
      guard let self else { return }
      self.open(
        QFCountrySelectionViewController(app: self.app, selected: self.draft.countryCode) { [weak self] code in
          guard let self, self.draft.countryCode != code else { return }
          self.draft.countryCode = code
          self.draft.regionCode = nil
          self.regionField.text = ""
          self.updateCountry()
          self.validate()
        })
    }
    bodyStack.addArrangedSubview(countryButton)
    regionField = QFContentUI.field(app.text("州、省或地区（选填）", "State, province, or region (optional)"), text: draft.regionCode ?? "", limit: 32) {
      [weak self] in
      self?.draft.regionCode = $0.isEmpty ? nil : $0
      self?.validate()
    }
    bodyStack.addArrangedSubview(regionField)
    bioField = QFContentTextArea(app.text("个人简介", "Bio"), text: draft.bio ?? "", limit: 255) { [weak self] in
      self?.draft.bio = $0.isEmpty ? nil : $0
      self?.validate()
    }
    bodyStack.addArrangedSubview(bioField)
    updateAvatar()
    updateCountry()
    validate()
    load()
  }
  private func load() {
    guard !loaded else { return }
    setReloadAction(allowsPullToRefresh: false) { [weak self] in self?.load() }
    execute(reloadOnFailure: true) { [self] in
      let value: QFPublicProfile = try await app.contentRequest(path: "me/public-profile")
      // Merge only fields the user has not edited while this initial read was in flight.
      if draft.nickname == initial.nickname {
        draft.nickname = value.nickname
        nicknameField.text = draft.nickname
      }
      if draft.countryCode == initial.countryCode {
        draft.countryCode = value.countryCode
        updateCountry()
        if draft.regionCode == initial.regionCode {
          draft.regionCode = value.regionCode
          regionField.text = draft.regionCode
        }
      }
      if draft.bio == initial.bio {
        draft.bio = value.bio
        bioField.textView.text = draft.bio
      }
      if draft.avatarMediaId == initial.avatarMediaId {
        draft.avatarMediaId = value.avatarMediaId
        updateAvatar()
      }
      initial = value
      loaded = true
      validate()
    }
  }
  private func updateAvatar() {
    avatarImage.load(draft.avatarMediaId, app: app)
    if draft.avatarMediaId == nil {
      avatarImage.image = UIImage(named: "default-avatar")
      avatarImage.contentMode = .scaleAspectFit
    }
  }
  private func updateCountry() {
    let country =
      draft.countryCode.flatMap { Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier).localizedString(forRegionCode: $0) }
      ?? app.text("未设置", "Not set")
    countryButton.setTitle(
      app.format("国家或地区  ·  %@ ›", "Country or region · %@ ›", country), for: .normal)
  }
  private func validate() {
    let name = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    saveButton?.isEnabled = loaded && draft != initial && !name.isEmpty && name.count <= 64
    saveButton?.alpha = saveButton?.isEnabled == true ? 1 : 0.45
  }
  private func save() {
    draft.nickname = draft.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    QFContentDraftStore.save(draft, app: app, kind: "public-profile")
    execute { [self] in
      var body = draft
      if let media = body.avatarMediaId { body.avatarMediaId = try await app.uploadedMediaID(media) }
      try await app.savePublicProfile(body)
      QFLocalMediaStore.remove(draft.avatarMediaId, scope: app.contentScope)
      QFContentDraftStore.remove(app: app, kind: "public-profile")
      onChanged?()
      qfClose()
    }
  }
  override func close() {
    guard hasUnsavedChanges else {
      super.close()
      return
    }
    preserveOrDiscard(
      { [self] in QFContentDraftStore.save(draft, app: app, kind: "public-profile") },
      discard: { [self] in
        QFLocalMediaStore.remove(draft.avatarMediaId, scope: app.contentScope)
        QFContentDraftStore.remove(app: app, kind: "public-profile")
      })
  }
}

@MainActor
private final class QFCountrySelectionViewController: UITableViewController, UISearchResultsUpdating
{
  private let app: QFAppSession
  private let selected: String?
  private let selection: (String?) -> Void
  private let search = UISearchController(searchResultsController: nil)
  private let locale: Locale
  private var countries: [String] = []
  init(app: QFAppSession, selected: String?, selection: @escaping (String?) -> Void) {
    self.app = app
    locale = Locale(identifier: QFInterfaceLanguage.normalized(app.interfaceLanguage).localeIdentifier)
    self.selected = selected
    self.selection = selection
    super.init(style: .insetGrouped)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidLoad() {
    super.viewDidLoad()
    tableView.backgroundColor = QFUI.background
    tableView.keyboardDismissMode = .onDrag
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = app.text("搜索国家或地区", "Search countries or regions")
    let header = UIStackView()
    header.axis = .vertical
    header.addArrangedSubview(QFSettingsPageUI.header(app.text("国家或地区", "Country or region"), backLabel: app.text("返回", "Back")) { [weak self] in self?.qfClose() })
    header.addArrangedSubview(search.searchBar)
    header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 112)
    tableView.tableHeaderView = header
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "country")
    countries = Locale.isoRegionCodes.sorted { name($0) < name($1) }
  }
  private func name(_ code: String) -> String {
    locale.localizedString(forRegionCode: code) ?? code
  }
  func updateSearchResults(for searchController: UISearchController) {
    let query = searchController.searchBar.text ?? ""
    countries = Locale.isoRegionCodes.filter {
      query.isEmpty || name($0).localizedCaseInsensitiveContains(query)
        || $0.localizedCaseInsensitiveContains(query)
    }.sorted { name($0) < name($1) }
    tableView.reloadData()
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    countries.count + 1
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
    -> UITableViewCell
  {
    let cell = tableView.dequeueReusableCell(withIdentifier: "country", for: indexPath)
    let code = indexPath.row == 0 ? nil : countries[indexPath.row - 1]
    cell.textLabel?.text = code.map { name($0) } ?? app.text("不设置地区", "Do not set a region")
    cell.textLabel?.textColor = QFUI.text
    cell.backgroundColor = QFUI.surface
    cell.accessoryType = code == selected ? .checkmark : .none
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let code = indexPath.row == 0 ? nil : countries[indexPath.row - 1]
    qfClose { [selection] in selection(code) }
  }
}
