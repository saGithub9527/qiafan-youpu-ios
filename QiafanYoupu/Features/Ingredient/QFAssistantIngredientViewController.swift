import SnapKit
import PhotosUI
import UIKit

/// Converts natural language into a local, reviewable ingredient draft. It never saves directly.
@MainActor
final class QFAssistantIngredientViewController: QFProfileContentController, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private let householdID: String?
  private let input = UITextView()
  private let resultStack = UIStackView()
  private var preview: QFAssistantPreview?
  private var requestTask: Task<Void, Never>?

  init(app: QFAppSession, householdID: String?) {
    self.householdID = householdID
    super.init(app: app, title: app.text("AI 添加食材", "AI add ingredients"))
  }
  required init?(coder: NSCoder) { nil }
  deinit { requestTask?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    input.font = .preferredFont(forTextStyle: .body)
    input.textColor = QFUI.text
    input.backgroundColor = QFUI.surface
    input.layer.cornerRadius = 14
    input.text = app.text("例如：把两把菠菜和一盒豆腐加入库存", "For example: add two handfuls of spinach and one box of tofu")
    input.textColor = QFUI.secondary
    input.accessibilityIdentifier = "assistant.ingredient.input"
    input.snp.makeConstraints { $0.height.greaterThanOrEqualTo(120) }
    bodyStack.addArrangedSubview(QFTabUI.label(app.text("告诉 AI 你想添加什么，发送前会显示云端处理提示。", "Tell AI what to add. A cloud-processing notice is shown before sending."), size: 14, color: QFUI.secondary, lines: 0))
    let camera = QFTabUI.button(app.text("拍照识别食材", "Take a photo"), background: QFUI.surfaceAlt) { [weak self] in self?.openCamera() }
    let library = QFTabUI.button(app.text("从相册识别", "Choose a photo"), background: QFUI.surfaceAlt) { [weak self] in self?.openLibrary() }
    camera.accessibilityIdentifier = "assistant.ingredient.camera"
    library.accessibilityIdentifier = "assistant.ingredient.library"
    let photoActions = QFTabUI.stack([camera, library], axis: .horizontal, spacing: 10)
    photoActions.distribution = .fillEqually
    bodyStack.addArrangedSubview(photoActions)
    bodyStack.addArrangedSubview(input)
    resultStack.axis = .vertical; resultStack.spacing = 12
    bodyStack.addArrangedSubview(resultStack)
    addFooter(app.text("发送并生成草稿", "Send and make a draft")) { [weak self] in self?.submit() }
  }

  private func submit() {
    let value = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    let confirm = UIAlertController(title: app.text("允许本次云端处理？", "Allow this cloud request?"), message: app.text("仅发送你输入的文字和当前语言，不会直接修改库存或发布内容。", "Only your text and language are sent. Inventory and publishing are never changed directly."), preferredStyle: .alert)
    confirm.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    confirm.addAction(UIAlertAction(title: app.text("继续", "Continue"), style: .default) { [weak self] _ in self?.send(value) })
    present(confirm, animated: true)
  }

  private func openCamera() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
      message(app.text("当前设备没有可用相机", "Camera is unavailable on this device"), error: true)
      return
    }
    view.endEditing(true)
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.cameraCaptureMode = .photo
    picker.delegate = self
    present(picker, animated: true)
  }

  private func openLibrary() {
    view.endEditing(true)
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = 1
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    present(picker, animated: true)
  }

  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
    picker.dismiss(animated: true)
    guard let image = info[.originalImage] as? UIImage else { return }
    analyze(image)
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      Task { @MainActor in
        guard let self, let image = object as? UIImage else { return }
        self.analyze(image)
      }
    }
  }

  private func analyze(_ image: UIImage) {
    guard let data = image.jpegData(compressionQuality: 0.82), !data.isEmpty else {
      message(app.text("图片读取失败，请重试。", "Could not read the image. Please try again."), error: true)
      return
    }
    let confirm = UIAlertController(
      title: app.text("允许本次云端识别？", "Allow this cloud image analysis?"),
      message: app.text("识别结果只会生成待核对的食材草稿，不会直接写入库存。你可以逐项修改、勾选后再保存。", "The result is only a reviewable ingredient draft. Nothing is written to inventory until you edit, select and save it."),
      preferredStyle: .alert)
    confirm.addAction(UIAlertAction(title: app.text("取消", "Cancel"), style: .cancel))
    confirm.addAction(UIAlertAction(title: app.text("继续", "Continue"), style: .default) { [weak self] _ in
      self?.sendImage(data)
    })
    present(confirm, animated: true)
  }

  private func sendImage(_ data: Data) {
    requestTask?.cancel()
    execute(label: app.text("正在识别食材", "Recognizing ingredients")) { [weak self] in
      guard let self else { return }
      let prompt = self.app.text(
        "请识别图片中可作为库存的食材，返回食材名称、数量和单位；看不清的内容不要猜测，保留为需要我核对的草稿。",
        "Identify ingredients that can be added to inventory. Return names, quantities and units. Do not guess unreadable content; keep uncertain items in the reviewable draft.")
      let response = try await self.app.assistantVisionPreview(imageData: data, mimeType: "image/jpeg", text: prompt)
      guard response.kind == "ADD_INGREDIENTS" || !response.ingredients.isEmpty else {
        throw NSError(domain: "QFAssistantIngredient", code: 1, userInfo: [NSLocalizedDescriptionKey: self.app.text("没有识别到可入库食材，请换一张清晰照片。", "No inventory ingredients were recognized. Try a clearer photo.")])
      }
      self.preview = response
      self.input.text = ""
      self.renderPreview()
    }
  }

  private func send(_ value: String) {
    requestTask?.cancel()
    execute(label: app.text("正在生成草稿", "Making draft")) { [weak self] in
      guard let self else { return }
      let response = try await self.app.assistantPreview(text: value)
      self.preview = response
      self.renderPreview()
    }
  }

  private func renderPreview() {
    QFTabUI.clear(resultStack)
    guard let preview else { return }
    if !preview.answer.isEmpty { resultStack.addArrangedSubview(QFTabUI.card(QFTabUI.label(preview.answer, size: 16, lines: 0), padding: 14, border: true)) }
    if !preview.ingredients.isEmpty {
      let rows = preview.ingredients.map { QFTabUI.label("\($0.name)  \($0.quantity) \($0.unit)", size: 16, lines: 0) }
      resultStack.addArrangedSubview(QFTabUI.card(QFTabUI.stack(rows, spacing: 10), padding: 14, border: true))
    }
    for action in effectiveActions(for: preview) {
      guard action.enabled, let button = makeActionButton(action, preview: preview) else { continue }
      resultStack.addArrangedSubview(button)
    }
  }

  /// Keep local/mock preview fixtures usable while the server rolls out the
  /// derived action metadata.  The fallback is limited to known safe routes.
  private func effectiveActions(for preview: QFAssistantPreview) -> [QFAssistantAction] {
    guard preview.actions.isEmpty else { return preview.actions }
    switch preview.kind {
    case "ADD_INGREDIENTS": return [QFAssistantAction(type: "INVENTORY_BATCH")]
    case "DRAFT_WORK": return [QFAssistantAction(type: "WORK_EDITOR")]
    // Public catalogue recipes are admin-reviewed data and the recipe editor
    // page has no approved design contract, so a user's AI recipe is only kept
    // as a structured local draft on this device.
    case "DRAFT_RECIPE": return [QFAssistantAction(type: "RECIPE_EDITOR")]
    default: return []
    }
  }

  private func makeActionButton(
    _ action: QFAssistantAction, preview: QFAssistantPreview
  ) -> UIButton? {
    switch action.type {
    case "INVENTORY_BATCH":
      let button = QFTabUI.button(app.text("核对后添加到库存", "Review and add to inventory"), background: QFUI.primary) { [weak self] in
        guard let self else { return }
        self.qfPush(QFRecipeInventoryBatchViewController(app: self.app, assistant: preview, requestID: UUID().uuidString.lowercased(), householdID: self.householdID) { [weak self] _ in self?.onChanged?() })
      }
      button.accessibilityIdentifier = "assistant.action.inventory"
      return button
    case "WORK_EDITOR":
      let button = QFTabUI.button(app.text("核对后打开作品编辑器", "Review and open post editor"), background: QFUI.primary) { [weak self] in
        guard let self else { return }
        self.qfPush(QFWorkEditorViewController(app: self.app, assistant: preview))
      }
      button.accessibilityIdentifier = "assistant.action.work-editor"
      return button
    case "RECIPE_EDITOR":
      // The recipe editor page has no approved design contract yet.  The
      // assistant recipe handoff is therefore only stored on this device as a
      // structured draft; it is never published or sent to the server.
      let button = QFTabUI.button(app.text("保存为菜谱草稿（编辑页待设计）", "Save as recipe draft (editor design pending)"), background: QFUI.primary) { [weak self] in
        self?.saveRecipeDraft(preview)
      }
      button.accessibilityIdentifier = "assistant.action.recipe-editor"
      return button
    default:
      return nil
    }
  }

  /// Saves the assistant recipe proposal as a user-scoped local draft.  No
  /// server recipe write happens until a recipe editor page is approved.
  private func saveRecipeDraft(_ preview: QFAssistantPreview) {
    var draft = QFAssistantRecipeDraft(assistant: preview)
    draft.updatedAt = QFContentDate.format(Date(), "yyyy-MM-dd'T'HH:mm:ssZZZZZ")
    let saved = QFContentDraftStore.save(draft, app: app, kind: "recipe-" + draft.id)
    let alert: UIAlertController
    if saved {
      alert = UIAlertController(
        title: app.text("菜谱草稿已保存", "Recipe draft saved"),
        message: app.text("菜谱编辑页面交互待设计确认。草稿已保存在本机，尚未创建或发布菜谱。", "The recipe editor interaction is pending design approval. The draft is stored on this device only; no recipe has been created or published."),
        preferredStyle: .alert)
    } else {
      alert = UIAlertController(
        title: app.text("菜谱草稿暂时无法保存在本机，请精简内容后重试。", "Could not save the recipe draft on this device. Shorten the content and try again."),
        message: nil,
        preferredStyle: .alert)
    }
    alert.addAction(UIAlertAction(title: app.text("知道了", "OK"), style: .default))
    present(alert, animated: true)
  }

}
