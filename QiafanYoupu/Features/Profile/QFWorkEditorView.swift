import SnapKit
import UIKit

struct QFStoredWorkDraft: Codable {
  let id: String
  let value: QFWorkDraft
  var updatedAt: String?
}

@MainActor
final class QFWorkEditorViewController: QFProfileContentController {
  private var workID: String
  private var draft: QFWorkDraft {
    didSet {
      localMediaIDs.formUnion(draft.photoIds + [draft.videoId].compactMap({ $0 }))
      if isViewLoaded { scheduleDraftSave() }
    }
  }
  private let ownerScope: String
  private var localMediaIDs = Set<String>()
  private var finishedDraft = false
  private var draftSaveTask: Task<Void, Never>?
  private let original: QFWorkDraft
  private let published: Bool
  private let recoveryKey: String
  private var publishButton: UIButton!
  override var hasUnsavedChanges: Bool { draft != original }
  private lazy var gallery = QFWorkPhotoGallery(app: app)
  private let materialsStack = UIStackView()
  private let stepsStack = UIStackView()
  private var videoButton: UIButton!
  private lazy var videoPreview = QFVideoPreviewView(app: app)
  private var recipeButton: UIButton!
  private var removeVideoButton: UIButton!
  private var unlinkRecipeButton: UIButton!
  private var linkedRecipeTitle: String?
  private let validationNotice = QFContentUI.label("", size: 13, color: QFUI.secondary)

  init(app: QFAppSession, work: QFUserWork? = nil, localDraft: QFStoredWorkDraft? = nil) {
    ownerScope = app.contentScope
    let key = work.map { "work-\($0.id)" } ?? localDraft.map { "work-\($0.id)" } ?? "work-new"
    let recovery = localDraft ?? QFContentDraftStore.load(QFStoredWorkDraft.self, app: app, kind: key)
    workID = work?.id ?? recovery?.id ?? UUID().uuidString.lowercased()
    draft = recovery?.value ?? work?.draft ?? QFWorkDraft()
    original = work?.draft ?? QFWorkDraft()
    published = work?.status == "PUBLISHED"
    recoveryKey = "work-" + workID
    super.init(app: app, title: published ? app.text("编辑作品", "Edit post") : app.text("发布作品", "Publish post"))
    localMediaIDs.formUnion(draft.photoIds + [draft.videoId].compactMap({ $0 }))
  }
  convenience init(app: QFAppSession, assistant: QFAssistantPreview) {
    var value = QFWorkDraft()
    value.title = assistant.title
    value.body = assistant.body
    value.materials = assistant.ingredients.map { QFWorkMaterial(name: $0.name, amount: $0.quantity, unit: $0.unit, ingredientId: nil) }
    value.steps = assistant.steps.map { QFWorkStep(title: "", body: $0) }
    let stored = QFStoredWorkDraft(id: UUID().uuidString.lowercased(), value: value, updatedAt: nil)
    self.init(app: app, localDraft: stored)
  }
  required init?(coder: NSCoder) { nil }
  deinit { draftSaveTask?.cancel() }
  override func viewDidLoad() {
    super.viewDidLoad()
    NotificationCenter.default.addObserver(self, selector: #selector(saveBeforeBackground), name: UIApplication.willResignActiveNotification, object: nil)
    _ = addFooter(app.text("存草稿", "Save draft"), primary: false) { [weak self] in self?.save(publish: false) }
    publishButton = addFooter(published ? app.text("提交修改审核", "Submit changes for review") : app.text("提交审核", "Submit for review")) { [weak self] in
      self?.save(publish: true)
    }
    render()
  }
  private func render() {
    gallery.onAdd = { [weak self] in
      guard let self else { return }
      self.chooseMediaBatch(limit: 9 - self.draft.photoIds.count) { [weak self] media in
        guard let self else { return }
        self.draft.photoIds.append(contentsOf: media.map(\.id))
        self.updatePhotos()
      }
    }
    gallery.onCover = { [weak self] in
      self?.draft.coverMediaId = $0
      self?.updatePhotos()
    }
    gallery.onRemove = { [weak self] id in
      guard let self else { return }
      self.draft.photoIds.removeAll { $0 == id }
      if self.draft.coverMediaId == id { self.draft.coverMediaId = nil }
      self.updatePhotos()
    }
    gallery.onMove = { [weak self] id, offset in
      guard let self, let index = self.draft.photoIds.firstIndex(of: id),
        self.draft.photoIds.indices.contains(index + offset)
      else { return }
      self.draft.photoIds.swapAt(index, index + offset)
      self.updatePhotos()
    }
    bodyStack.addArrangedSubview(gallery)
    updatePhotos()
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("菜品名称", "Dish name"), size: 19, bold: true))
    bodyStack.addArrangedSubview(
      QFContentUI.field(app.text("给这道菜起个名字", "Name this dish"), text: draft.title, limit: 80) { [weak self] in
        self?.draft.title = $0
        self?.validate()
      })
    bodyStack.addArrangedSubview(
      QFContentTextArea(app.text("下厨心得（选填）", "Cooking notes (optional)"), text: draft.body, limit: 2000) { [weak self] in
        self?.draft.body = $0
      })
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("所需材料", "Materials"), size: 19, bold: true))
    materialsStack.axis = .vertical
    materialsStack.spacing = 12
    bodyStack.addArrangedSubview(materialsStack)
    renderMaterials()
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("做法步骤", "Steps"), size: 19, bold: true))
    stepsStack.axis = .vertical
    stepsStack.spacing = 12
    bodyStack.addArrangedSubview(stepsStack)
    renderSteps()
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("做菜视频", "Cooking video"), size: 19, bold: true))
    videoButton = QFContentUI.action("") { [weak self] in
      self?.chooseMedia(video: true) { [weak self] in
        self?.draft.videoId = $0.id
        self?.updateLinks()
      }
    }
    bodyStack.addArrangedSubview(videoPreview)
    bodyStack.addArrangedSubview(videoButton)
    removeVideoButton = QFContentUI.action(app.text("移除视频", "Remove video"), destructive: true) { [weak self] in
      self?.draft.videoId = nil
      self?.updateLinks()
    }
    bodyStack.addArrangedSubview(removeVideoButton)
    bodyStack.addArrangedSubview(QFContentUI.label(app.text("关联菜谱", "Related recipe"), size: 19, bold: true))
    recipeButton = QFContentUI.action("") { [weak self] in
      guard let self else { return }
      self.open(
        QFCatalogSearchViewController(app: self.app, type: "RECIPE") { [weak self] item in
          self?.draft.linkedRecipeId = item.id
          self?.linkedRecipeTitle = item.title
          self?.updateLinks()
        })
    }
    bodyStack.addArrangedSubview(recipeButton)
    unlinkRecipeButton = QFContentUI.action(app.text("取消关联", "Unlink")) { [weak self] in
      self?.draft.linkedRecipeId = nil
      self?.linkedRecipeTitle = nil
      self?.updateLinks()
    }
    bodyStack.addArrangedSubview(unlinkRecipeButton)
    bodyStack.addArrangedSubview(validationNotice)
    updateLinks()
    validate()
  }
  private func updatePhotos() {
    gallery.update(ids: draft.photoIds, coverID: draft.coverMediaId)
    validate()
  }
  private func updateLinks() {
    videoPreview.load(draft.videoId)
    removeVideoButton?.isHidden = draft.videoId == nil
    unlinkRecipeButton?.isHidden = draft.linkedRecipeId == nil
    videoButton?.setTitle(draft.videoId == nil ? app.text("添加视频（选填，最多20MB）", "Add video (optional, up to 20 MB)") : app.text("更换视频", "Replace video"), for: .normal)
    recipeButton?.setTitle(
      draft.linkedRecipeId == nil ? app.text("选择菜谱（选填）", "Choose recipe (optional)") : linkedRecipeTitle ?? app.text("更换关联菜谱", "Change related recipe"), for: .normal)
  }
  private func renderMaterials() {
    QFTabUI.clear(materialsStack)
    for index in draft.materials.indices {
      let item = draft.materials[index]
      let name = QFContentUI.field(app.text("材料名称", "Material name"), text: item.name) { [weak self] in
        self?.draft.materials[index].name = $0
        self?.draft.materials[index].ingredientId = nil
        self?.validate()
      }
      let amount = QFContentUI.field(app.text("用量", "Amount"), text: item.amount, keyboard: .decimalPad) {
        [weak self] in
        self?.draft.materials[index].amount = $0
        self?.validate()
      }
      let unit = QFContentUI.field(app.text("单位", "Unit"), text: item.unit, limit: 20) { [weak self] in
        self?.draft.materials[index].unit = $0
        self?.validate()
      }
      let quantities = QFTabUI.stack([amount, unit], axis: .horizontal, spacing: 8)
      quantities.distribution = .fillEqually
      let remove = QFContentUI.action(app.text("移除材料", "Remove material"), destructive: true) { [weak self] in
        self?.draft.materials.remove(at: index)
        self?.renderMaterials()
      }
      materialsStack.addArrangedSubview(
        QFTabUI.card(QFTabUI.stack([name, quantities, remove], spacing: 8)))
    }
    materialsStack.addArrangedSubview(
      QFContentUI.anchoredAction(app.text("＋ 添加材料", "+ Add material")) { [weak self] sourceView in
        guard let self, self.draft.materials.count < 40 else { return }
        self.chooseMaterial(from: sourceView) { [weak self] item in
          self?.draft.materials.append(item)
          self?.renderMaterials()
        }
      })
    validate()
  }
  private func renderSteps() {
    QFTabUI.clear(stepsStack)
    for index in draft.steps.indices {
      let step = draft.steps[index]
      let title = QFContentUI.field(
        app.format("步骤 %d 标题", "Step %d title", index + 1), text: step.title
      ) { [weak self] in
        self?.draft.steps[index].title = $0
      }
      let text = QFContentTextArea(
        app.format("步骤 %d 做法", "Step %d instructions", index + 1), text: step.body,
        limit: 2000
      ) {
        [weak self] in
        self?.draft.steps[index].body = $0
        self?.validate()
      }
      let actions = QFTabUI.stack(
        [
          QFContentUI.action(app.text("上移", "Move up")) { [weak self] in
            guard let self, index > 0 else { return }
            self.draft.steps.swapAt(index, index - 1)
            self.renderSteps()
          },
          QFContentUI.action(app.text("下移", "Move down")) { [weak self] in
            guard let self, index + 1 < self.draft.steps.count else { return }
            self.draft.steps.swapAt(index, index + 1)
            self.renderSteps()
          },
          QFContentUI.action(app.text("移除", "Remove"), destructive: true) { [weak self] in
            self?.draft.steps.remove(at: index)
            self?.renderSteps()
          },
        ], axis: .horizontal, spacing: 12)
      stepsStack.addArrangedSubview(
        QFTabUI.card(QFTabUI.stack([title, text, actions], spacing: 8)))
    }
    stepsStack.addArrangedSubview(
      QFContentUI.action(app.text("＋ 添加步骤", "+ Add step")) { [weak self] in
        guard let self, self.draft.steps.count < 30 else { return }
        self.draft.steps.append(QFWorkStep())
        self.renderSteps()
      })
    validate()
  }
  private func validate() {
    let validation = draft.validation(app: app)
    publishButton?.isEnabled = validation == nil
    publishButton?.alpha = validation == nil ? 1 : 0.45
    publishButton?.accessibilityHint = validation
    validationNotice.text = validation
    validationNotice.isHidden = validation == nil
  }
  private func save(publish: Bool) {
    if publish, let error = draft.validation(app: app) {
      message(error, error: true)
      return
    }
    preserveLocally()
    guard publish else { onChanged?(); qfClose(); return }
    execute(label: app.text("提交审核中", "Submitting for review")) { [self] in
      var body = draft
      var uploads: [String: String] = [:]
      for id in draft.photoIds { uploads[id] = try await app.uploadedMediaID(id) }
      body.photoIds = draft.photoIds.compactMap { uploads[$0] }
      if let cover = draft.coverMediaId { body.coverMediaId = uploads[cover] }
      if let video = draft.videoId { body.videoId = try await app.uploadedMediaID(video) }
      let _: QFUserWork = try await app.contentRequest(
        path: "me/works/\(workID)/publish", method: "POST", body: JSONEncoder().encode(body))
      finishedDraft = true
      draftSaveTask?.cancel()
      for id in draft.photoIds + [draft.videoId].compactMap({ $0 }) {
        QFLocalMediaStore.remove(id, scope: app.contentScope)
      }
      QFContentDraftStore.remove(app: app, kind: recoveryKey)
      QFContentDraftStore.remove(app: app, kind: "work-new")
      onChanged?()
      closeWithSuccess(app.text("作品已提交审核", "Post submitted for review"))
    }
  }
  private func scheduleDraftSave() {
    draftSaveTask?.cancel()
    draftSaveTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
      self?.preserveLocally()
    }
  }
  @objc private func saveBeforeBackground() {
    if draft != original { preserveLocally() }
  }
  private func preserveLocally() {
    draftSaveTask?.cancel()
    guard !finishedDraft, app.contentScope == ownerScope else { return }
    QFContentDraftStore.save(
      QFStoredWorkDraft(id: workID, value: draft, updatedAt: ISO8601DateFormatter().string(from: Date())),
      app: app, kind: recoveryKey)
    QFContentDraftStore.remove(app: app, kind: "work-new")
    let retained = Set(draft.photoIds + [draft.videoId].compactMap({ $0 }))
    for id in localMediaIDs.subtracting(retained) { QFLocalMediaStore.remove(id, scope: ownerScope) }
    localMediaIDs = retained
  }
  override func close() {
    guard draft != original else {
      super.close()
      return
    }
    preserveOrDiscard(
      { [self] in preserveLocally() },
      discard: { [self] in
        finishedDraft = true
        draftSaveTask?.cancel()
        for id in localMediaIDs {
          QFLocalMediaStore.remove(id, scope: ownerScope)
        }
        QFContentDraftStore.remove(app: app, kind: recoveryKey)
      })
  }
}
