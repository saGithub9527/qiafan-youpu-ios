import AVFoundation
import PhotosUI
import SnapKit
import UIKit
import Vision

/// Product barcodes only. Photos are decoded on the device; no OCR guesses.
enum QFProductBarcodeImageDecoder {
  static func barcodes(in image: UIImage) throws -> [QFProductBarcode] {
    guard image.size.width > 0, image.size.height > 0 else { return [] }
    let ratio = min(1, 2048 / max(image.size.width * image.scale, image.size.height * image.scale))
    let size = CGSize(width: image.size.width * image.scale * ratio, height: image.size.height * image.scale * ratio)
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    guard let cg = normalized.cgImage else { return [] }
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.ean13, .ean8, .upce]
    #if targetEnvironment(simulator)
    request.usesCPUOnly = true
    request.revision = VNDetectBarcodesRequestRevision1
    #endif
    try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
    var seen = Set<String>()
    return (request.results ?? []).compactMap { result in
      let kind: String
      switch result.symbology {
      case .ean13: kind = "EAN13"
      case .ean8: kind = "EAN8"
      case .upce: kind = "UPCE"
      default: return nil
      }
      guard let value = result.payloadStringValue, seen.insert(value).inserted else { return nil }
      return QFProductBarcode(value: value, symbology: kind)
    }
  }
}

private final class QFProductBarcodeCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "com.qiafan.product-camera")
  private var configured = false
  private var device: AVCaptureDevice?
  private var output: AVCaptureMetadataOutput?
  private var scanRect = CGRect(x: 0, y: 0, width: 1, height: 1)
  var found: (([QFProductBarcode]) -> Void)?
  var failed: (() -> Void)?
  var running: (() -> Void)?
  func start() {
    queue.async { [weak self] in
      guard let self else { return }
      if !self.configured {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { self.reportFailure(); return }
        self.session.beginConfiguration()
        if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
        let output = AVCaptureMetadataOutput()
        guard self.session.canAddInput(input), self.session.canAddOutput(output) else { self.session.commitConfiguration(); self.reportFailure(); return }
        self.session.addInput(input); self.session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        let types: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce]
        output.metadataObjectTypes = types.filter { output.availableMetadataObjectTypes.contains($0) }
        guard !output.metadataObjectTypes.isEmpty else { self.session.commitConfiguration(); self.reportFailure(); return }
        output.rectOfInterest = self.scanRect
        self.session.commitConfiguration(); self.device = device; self.output = output; self.configured = true
        if (try? device.lockForConfiguration()) != nil {
          if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
          if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
          if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
          device.isSubjectAreaChangeMonitoringEnabled = true
          device.unlockForConfiguration()
        }
      }
      if !self.session.isRunning { self.session.startRunning() }
      DispatchQueue.main.async { [weak self] in self?.running?() }
    }
  }
  func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() }; setTorch(false) } }
  func setScanRect(_ rect: CGRect) {
    let safe = QFBarcodeCaptureRegion.effective(rect, previewing: true)
    queue.async { [weak self] in self?.scanRect = safe; self?.output?.rectOfInterest = safe }
  }
  func toggleTorch() { queue.async { [weak self] in guard let self else { return }; self.setTorch(self.device?.torchMode != .on) } }
  private func setTorch(_ enabled: Bool) {
    guard let device, device.hasTorch else { return }
    do { try device.lockForConfiguration(); defer { device.unlockForConfiguration() }; device.torchMode = enabled ? .on : .off } catch { reportFailure() }
  }
  private func reportFailure() { DispatchQueue.main.async { [weak self] in self?.failed?() } }
  func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
    let values: [QFProductBarcode] = objects.compactMap { object in
      guard let code = object as? AVMetadataMachineReadableCodeObject, let value = code.stringValue else { return nil }
      let kind: String
      switch code.type {
      case .ean13: kind = "EAN13"
      case .ean8: kind = "EAN8"
      case .upce: kind = "UPCE"
      default: return nil
      }
      return QFProductBarcode(value: value, symbology: kind)
    }
    if !values.isEmpty { found?(values) }
  }
}

@MainActor
final class QFProductBarcodeScannerViewController: UIViewController, PHPickerViewControllerDelegate {
  private let app: QFAppSession
  private let householdID: String?
  private let binding: QFAgentScope
  private let camera = QFProductBarcodeCamera()
  private var preview: AVCaptureVideoPreviewLayer!
  private let canvas = UIView(), target = UIView()
  private let scanLine = UIView()
  private var previewObservation: NSKeyValueObservation?
  private let message = UILabel()
  private var batch = QFBarcodeScanBatch()
  private var nextButton: UIButton!
  var collectionID = "new"
  private var collectionKey: String { "barcode-collection." + (householdID ?? "personal") + "." + collectionID }
  private var active = false, handlingResult = false
  private var selectedBarcode: QFProductBarcode?
  private var operation = UUID()
  private var observers: [NSObjectProtocol] = []
  var onChanged: (() -> Void)?
  var onScannedProducts: (([QFPurchaseReceiptLine]) -> Bool)?
  #if DEBUG
  var debugWithoutCamera = false
  var debugBatchState: (count: Int, ready: Bool, hasNext: Bool) {
    (batch.items.count, active && !handlingResult && presentedViewController == nil, nextButton?.isHidden == false)
  }
  func debugCollect(_ barcode: QFProductBarcode) { decoded([barcode]) }
  func debugContinueCollecting() { resumeScanning() }
  func debugReviewCollection() { afterPrompt { [weak self] in self?.reviewBatch() } }
  #endif
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
  init(app: QFAppSession, householdID: String?) {
    self.app = app; self.householdID = householdID; binding = QFAssistantAgent.scope(app)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { nil }
  deinit { observers.forEach(NotificationCenter.default.removeObserver); camera.stop() }
  private var sameScope: Bool { QFAssistantAgent.scope(app) == binding && app.planningHouseholdID == householdID }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = UIColor(red: 0.06, green: 0.10, blue: 0.08, alpha: 1)
    if let saved = QFContentDraftStore.load(QFBarcodeScanBatch.self, app: app, kind: collectionKey), saved.items.count <= 40 { batch = saved }
    view.accessibilityIdentifier = "product.barcode-scanner"
    let back = QFTabUI.iconButton("chevron.left", label: app.text("返回", "Back"), size: 24) { [weak self] in self?.qfClose() }; back.tintColor = .white
    let title = QFTabUI.label(app.text("扫描商品条码", "Scan product barcode"), size: 22, weight: .semibold, color: .white)
    title.adjustsFontSizeToFitWidth = true; title.minimumScaleFactor = 0.65
    let header = UIView(); view.addSubview(header); header.snp.makeConstraints { $0.top.leading.trailing.equalTo(view.safeAreaLayoutGuide); $0.height.equalTo(56) }
    header.addSubview(back); back.snp.makeConstraints { $0.leading.equalToSuperview().offset(16); $0.centerY.equalToSuperview(); $0.size.equalTo(44) }
    header.addSubview(title); title.snp.makeConstraints { $0.center.equalToSuperview(); $0.leading.greaterThanOrEqualTo(back.snp.trailing).offset(8); $0.trailing.lessThanOrEqualToSuperview().inset(16) }
    nextButton = QFTabUI.button("", color: .white, background: QFUI.primary) { [weak self] in self?.reviewBatch() }
    nextButton.accessibilityIdentifier = "product.batch.next"
    view.addSubview(nextButton)
    nextButton.snp.makeConstraints { $0.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(20); $0.bottom.equalTo(view.safeAreaLayoutGuide).inset(12); $0.height.equalTo(batch.items.isEmpty ? 0 : 48) }
    view.addSubview(canvas); canvas.backgroundColor = UIColor(white: 0.10, alpha: 1)
    canvas.snp.makeConstraints { $0.top.equalTo(header.snp.bottom); $0.leading.trailing.equalToSuperview(); $0.bottom.equalTo(nextButton.snp.top).offset(-12) }
    preview = AVCaptureVideoPreviewLayer(session: camera.session); preview.videoGravity = .resizeAspectFill; canvas.layer.addSublayer(preview)
    previewObservation = preview.observe(\.isPreviewing, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.updateCaptureRegion() }
    }
    canvas.addSubview(target); target.isUserInteractionEnabled = false
    target.snp.makeConstraints { $0.centerX.equalToSuperview(); $0.centerY.equalToSuperview().multipliedBy(0.85); $0.width.equalToSuperview().multipliedBy(0.70); $0.height.equalTo(target.snp.width) }
    for index in 0..<4 {
      let corner = UIView(); target.addSubview(corner)
      corner.snp.makeConstraints { m in m.size.equalTo(26); if index < 2 { m.top.equalToSuperview() } else { m.bottom.equalToSuperview() }; if index % 2 == 0 { m.leading.equalToSuperview() } else { m.trailing.equalToSuperview() } }
      let vertical = UIView(), horizontal = UIView(); vertical.backgroundColor = .white; horizontal.backgroundColor = .white
      corner.addSubview(vertical); corner.addSubview(horizontal)
      vertical.snp.makeConstraints { m in m.top.bottom.equalToSuperview(); m.width.equalTo(2); if index % 2 == 0 { m.leading.equalToSuperview() } else { m.trailing.equalToSuperview() } }
      horizontal.snp.makeConstraints { m in m.leading.trailing.equalToSuperview(); m.height.equalTo(2); if index < 2 { m.top.equalToSuperview() } else { m.bottom.equalToSuperview() } }
    }
    scanLine.backgroundColor = .black; scanLine.accessibilityIdentifier = "product.scan-line"
    target.addSubview(scanLine)
    scanLine.snp.makeConstraints { $0.leading.trailing.equalToSuperview().inset(10); $0.centerY.equalToSuperview(); $0.height.equalTo(2) }
    resetHint(); message.textColor = .white; message.font = .preferredFont(forTextStyle: .subheadline)
    message.adjustsFontForContentSizeCategory = true; message.textAlignment = .center; message.numberOfLines = 0
    canvas.addSubview(message); message.snp.makeConstraints { $0.top.equalTo(target.snp.bottom).offset(24); $0.leading.trailing.equalToSuperview().inset(24) }
    let torch = control("flashlight.off.fill", title: app.text("手电筒", "Flashlight")) { [weak self] in self?.camera.toggleTorch() }
    let manual = control("square.and.pencil", title: app.text("手动填写", "Enter manually")) { [weak self] in self?.manualEntry() }
    let photos = control("photo", title: app.text("相册", "Photos")) { [weak self] in self?.choosePhoto() }
    let controls = QFTabUI.stack([torch, manual, photos], axis: .horizontal, spacing: 20); controls.distribution = .fillEqually
    canvas.addSubview(controls); controls.snp.makeConstraints { $0.centerX.equalToSuperview(); $0.bottom.equalToSuperview().inset(25); $0.top.greaterThanOrEqualTo(message.snp.bottom).offset(16); $0.width.equalTo(320).priority(750); $0.leading.greaterThanOrEqualToSuperview().offset(24); $0.trailing.lessThanOrEqualToSuperview().inset(24) }
    camera.found = { [weak self] in self?.decoded($0) }; camera.failed = { [weak self] in self?.showCameraUnavailable() }
    camera.running = { [weak self] in self?.updateCaptureRegion(); self?.updateScanAnimation() }
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willResignActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancelWork(); self?.camera.stop(); self?.updateScanAnimation() } })
    }
    observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.startCamera() } })
    updateBatchFooter()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews(); preview.frame = canvas.bounds
    updateCaptureRegion(); updateScanAnimation()
  }
  override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); active = true; handlingResult = false; selectedBarcode = nil; resetHint(); startCamera() }
  override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); active = false; cancelWork(); camera.stop(); updateScanAnimation() }
  private func updateCaptureRegion() {
    guard preview != nil else { return }
    if let connection = preview.connection, connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
    let converted = preview.isPreviewing && !canvas.bounds.isEmpty
      ? preview.metadataOutputRectConverted(fromLayerRect: target.convert(target.bounds, to: canvas)) : .zero
    camera.setScanRect(QFBarcodeCaptureRegion.effective(converted, previewing: preview.isPreviewing))
  }
  private func updateScanAnimation() {
    guard active, !handlingResult, UIApplication.shared.applicationState == .active, target.bounds.height > 24 else {
      scanLine.layer.removeAnimation(forKey: "barcode.scan"); return
    }
    let distance = target.bounds.height - 24
    if let old = scanLine.layer.animation(forKey: "barcode.scan") as? CABasicAnimation,
      (old.toValue as? CGFloat) == distance / 2 { return }
    let sweep = CABasicAnimation(keyPath: "transform.translation.y")
    sweep.fromValue = -distance / 2; sweep.toValue = distance / 2
    sweep.duration = 1.8; sweep.autoreverses = true; sweep.repeatCount = .infinity
    sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    scanLine.layer.add(sweep, forKey: "barcode.scan")
  }
  private func cancelWork() { operation = UUID(); handlingResult = false }
  private func resetHint() {
    message.text = batch.items.isEmpty
      ? app.text("对准食材包装上的条形码\n可连续添加，最后统一核对入库", "Point at the barcode on the food package\nAdd multiple items, then review them together")
      : app.format("已添加 %d 种食材，继续扫描下一件", "%d food items added. Scan the next package", batch.items.count)
  }
  private func updateBatchFooter() {
    nextButton?.setTitle(app.format("下一步（%d 种食材）", "Next (%d food items)", batch.items.count), for: .normal)
    nextButton?.isHidden = batch.items.isEmpty
    nextButton?.snp.updateConstraints { $0.height.equalTo(batch.items.isEmpty ? 0 : 48) }
    resetHint()
  }
  private func control(_ symbol: String, title: String, action: @escaping () -> Void) -> UIView {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26)), for: .normal)
    button.accessibilityLabel = title; button.tintColor = .white
    button.backgroundColor = UIColor(white: 0.25, alpha: 1); button.layer.cornerRadius = 28; button.clipsToBounds = true
    button.addAction(UIAction { _ in action() }, for: .touchUpInside); button.snp.makeConstraints { $0.width.height.equalTo(56) }
    let stack = QFTabUI.stack([button, QFTabUI.label(title, size: 15, color: .white, lines: 0)], spacing: 12); stack.alignment = .center; return stack
  }
  private func startCamera() {
    #if DEBUG
    if debugWithoutCamera { return }
    #endif
    guard active, sameScope, !handlingResult, presentedViewController == nil, UIApplication.shared.applicationState == .active else { return }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: updateCaptureRegion(); camera.start(); updateScanAnimation()
    case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in DispatchQueue.main.async { if granted { self?.startCamera() } else { self?.showCameraUnavailable() } } }
    default: showCameraUnavailable()
    }
  }
  private func afterPrompt(_ action: @escaping () -> Void) {
    // UIAlertAction handlers run during dismissal. Starting the camera or
    // presenting a second review sheet before it finishes can strand the page.
    if let prompt = presentedViewController as? UIAlertController { prompt.dismiss(animated: true, completion: action) }
    else { action() }
  }
  private func resumeScanning() {
    afterPrompt { [weak self] in
      self?.handlingResult = false; self?.selectedBarcode = nil; self?.startCamera()
    }
  }
  private func showCameraUnavailable() { message.text = app.text("无法使用相机，可从相册选择条码或手动填写。", "Camera unavailable. Choose a barcode photo or enter it manually.") }
  private func choosePhoto() {
    guard sameScope, presentedViewController == nil else { return }
    cancelWork(); camera.stop()
    var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config); picker.delegate = self; present(picker, animated: true)
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    let provider = results.first?.itemProvider
    picker.dismiss(animated: true) { [weak self] in
      guard let self, self.sameScope else { return }
      guard let provider, provider.canLoadObject(ofClass: UIImage.self) else { self.startCamera(); return }
      self.handlingResult = true; self.camera.stop(); let token = UUID(); self.operation = token
      provider.loadObject(ofClass: UIImage.self) { [weak self] value, _ in
        guard let image = value as? UIImage else { Task { @MainActor in self?.photoFailed(token) }; return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          let codes = (try? QFProductBarcodeImageDecoder.barcodes(in: image)) ?? []
          Task { @MainActor [weak self] in
            guard let self, self.active, self.sameScope, self.operation == token else { return }
            self.handlingResult = false
            if codes.isEmpty { self.photoFailed(token) } else { self.decoded(codes) }
          }
        }
      }
    }
  }
  private func photoFailed(_ token: UUID) {
    guard active, sameScope, operation == token else { return }
    handlingResult = true
    let alert = UIAlertController(title: app.text("未识别到商品条码", "No product barcode found"), message: app.text("请拍清包装条形码，或手动填写商品信息。不会再从小票文字猜测数量和价格。", "Use a clear photo of the package barcode, or enter the item manually. Receipt text is not used to guess quantities or prices."), preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: app.text("手动填写", "Enter manually"), style: .default) { [weak self] _ in self?.afterPrompt { [weak self] in self?.manualEntry() } })
    alert.addAction(UIAlertAction(title: app.text("继续扫描", "Continue scanning"), style: .cancel) { [weak self] _ in self?.resumeScanning() })
    present(alert, animated: true)
  }
  private func decoded(_ values: [QFProductBarcode]) {
    guard active, sameScope, !handlingResult, !values.isEmpty else { return }
    let fresh = values.filter { code in !batch.items.contains(where: { $0.scanBarcode == code.value }) }
    guard !fresh.isEmpty else { resetHint(); if !camera.session.isRunning { startCamera() }; return }
    handlingResult = true; camera.stop()
    updateScanAnimation()
    let distinct = Array(Dictionary(grouping: fresh, by: \.value).values.compactMap(\.first)).sorted { $0.value < $1.value }
    guard distinct.count > 1 else { resolve(distinct[0]); return }
    let alert = UIAlertController(title: app.text("选择要添加的商品条码", "Choose the product barcode to add"), message: nil, preferredStyle: .actionSheet)
    for barcode in distinct.prefix(10) { alert.addAction(UIAlertAction(title: barcode.value, style: .default) { [weak self] _ in self?.afterPrompt { [weak self] in self?.resolve(barcode) } }) }
    alert.addAction(UIAlertAction(title: app.text("继续扫描", "Continue scanning"), style: .cancel) { [weak self] _ in self?.resumeScanning() })
    alert.popoverPresentationController?.sourceView = target; alert.popoverPresentationController?.sourceRect = target.bounds
    present(alert, animated: true)
  }
  private func resolve(_ barcode: QFProductBarcode) {
    guard active, sameScope else { return }
    selectedBarcode = barcode; operation = UUID()
    guard barcode.lookupCode != nil else { openProduct(.scannedProduct(barcode: barcode, lookupState: .localOnly)); return }
    // Recognizing a barcode is immediate. Product lookup belongs to the editable
    // purchase draft and must not hold the user on the camera page.
    openProduct(.scannedProduct(barcode: barcode, lookupState: .loading))
  }
  private func manualEntry() {
    guard sameScope else { return }
    if !batch.items.isEmpty { reviewBatch(); return }
    let barcode = selectedBarcode; cancelWork(); camera.stop(); handlingResult = true
    if let barcode { openProduct(.scannedProduct(barcode: barcode)); return }
    let editor = QFPurchaseReceiptViewController(app: app, householdID: householdID)
    editor.onChanged = onChanged; qfPush(editor)
  }
  private func openProduct(_ line: QFPurchaseReceiptLine) {
    guard active, sameScope else { return }
    let original = batch
    switch batch.append(line) {
    case .duplicate: handlingResult = false; startCamera(); return
    case .full:
      reviewBatch(); return
    case .locked: return
    case .added: break
    }
    guard QFContentDraftStore.save(batch, app: app, kind: collectionKey) else {
      batch = original
      QFOperationHUD.toast(app.text("无法保存草稿，请重试", "Unable to save draft. Try again."), in: view)
      handlingResult = false; startCamera(); return
    }
    updateBatchFooter()
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    let alert = UIAlertController(
      title: app.format("已添加 %d 种食材", "%d food items added", batch.items.count),
      message: app.text("可以继续扫描其他商品，最后一起核对数量和实付价格。", "Keep scanning other packages, then review quantities and actual prices together."), preferredStyle: .alert)
    let more = UIAlertAction(title: app.text("继续添加", "Add more"), style: .default) { [weak self] _ in
      self?.resumeScanning()
    }
    more.isEnabled = batch.items.count < 40
    alert.addAction(more)
    alert.addAction(UIAlertAction(title: app.text("核对并入库", "Review and save to fridge"), style: .default) { [weak self] _ in self?.afterPrompt { [weak self] in self?.reviewBatch() } })
    alert.preferredAction = more.isEnabled ? more : alert.actions.last
    present(alert, animated: true)
  }
  private func reviewBatch() {
    guard active, sameScope, !batch.items.isEmpty else { return }
    camera.stop(); handlingResult = true; updateScanAnimation()
    if let onScannedProducts {
      guard onScannedProducts(batch.items) else {
        QFOperationHUD.toast(app.text("请先处理采购草稿，再添加本批食材。", "Resolve the purchase draft before adding this batch."), in: view)
        handlingResult = false; startCamera(); return
      }
      consumeCollection(); qfClose(); return
    }
    let key = "receipt." + (householdID ?? "personal") + ".new"
    if let existing = QFContentDraftStore.load(QFPurchaseReceiptDraft.self, app: app, kind: key), !existing.items.isEmpty || existing.pending != nil {
      let alert = UIAlertController(title: app.text("已有采购草稿", "Purchase draft exists"),
        message: app.text("本批扫描已保留，可以加入当前草稿或先处理原草稿。", "This scan batch is saved. Add it to the current draft, or resolve the existing draft first."), preferredStyle: .alert)
      if existing.pending == nil {
        alert.addAction(UIAlertAction(title: app.text("加入当前草稿", "Add to current draft"), style: .default) { [weak self] _ in self?.afterPrompt { [weak self] in self?.openBatchEditor() } })
      }
      alert.addAction(UIAlertAction(title: app.text("编辑原草稿", "Edit existing draft"), style: .default) { [weak self] _ in
        guard let self, self.sameScope else { return }
        self.afterPrompt { [weak self] in
          guard let self, self.sameScope else { return }
          let editor = QFPurchaseReceiptViewController(app: self.app, householdID: self.householdID)
          editor.onChanged = self.onChanged; self.qfPush(editor)
        }
      })
      alert.addAction(UIAlertAction(title: app.text("继续扫描", "Continue scanning"), style: .cancel) { [weak self] _ in self?.resumeScanning() })
      present(alert, animated: true)
    } else { openBatchEditor() }
  }
  private func openBatchEditor() {
    guard active, sameScope else { return }
    let editor = QFPurchaseReceiptViewController(app: app, householdID: householdID)
    guard editor.appendScannedProducts(batch.items) else {
      QFOperationHUD.toast(app.text("请先处理采购草稿，再添加本批食材。", "Resolve the purchase draft before adding this batch."), in: view)
      handlingResult = false; startCamera(); return
    }
    consumeCollection(); editor.onChanged = onChanged; qfPush(editor)
  }
  private func consumeCollection() {
    QFContentDraftStore.remove(app: app, kind: collectionKey)
    batch = QFBarcodeScanBatch(); updateBatchFooter()
  }
}
