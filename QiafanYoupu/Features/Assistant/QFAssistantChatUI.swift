import UIKit
import SnapKit
import Kingfisher

/// Native composited text sweep; no timer, bitmap rendering or third-party view.
@MainActor
private final class QFAssistantThinkingButton: UIButton {
  private let shine = UIView()
  private let maskLabel = UILabel()
  private let gradient = CAGradientLayer()
  private var animatedWidth: CGFloat = 0
  var thinking = false { didSet { setNeedsLayout() } }
  var expanded = false { didSet {
    setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
  } }
  override init(frame: CGRect) {
    super.init(frame: frame)
    semanticContentAttribute = .forceRightToLeft
    imageEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: -8)
    contentEdgeInsets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 10)
    shine.isUserInteractionEnabled = false; addSubview(shine)
    gradient.locations = [0, 0.35, 0.5, 0.65, 1]; gradient.startPoint = CGPoint(x: 0, y: 0.5); gradient.endPoint = CGPoint(x: 1, y: 0.5)
    shine.layer.addSublayer(gradient); shine.mask = maskLabel
  }
  required init?(coder: NSCoder) { nil }
  override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
  override func layoutSubviews() {
    super.layoutSubviews()
    setTitleColor(QFUI.secondary, for: .normal)
    setTitleColor(QFUI.primary, for: .highlighted)
    shine.frame = titleLabel?.frame ?? .zero
    // UIButton can lazily insert its title above custom subviews after setTitle.
    // Keep the transparent text sweep above the opaque normal title.
    bringSubviewToFront(shine)
    maskLabel.frame = shine.bounds; maskLabel.text = title(for: .normal); maskLabel.font = titleLabel?.font
    maskLabel.textColor = .white; maskLabel.textAlignment = .left
    shine.isHidden = !thinking || UIAccessibility.isReduceMotionEnabled
    CATransaction.begin(); CATransaction.setDisableActions(true)
    gradient.colors = [UIColor.clear.cgColor, UIColor.systemTeal.withAlphaComponent(0.4).cgColor,
      UIColor.systemTeal.cgColor, UIColor.systemTeal.withAlphaComponent(0.4).cgColor, UIColor.clear.cgColor]
    gradient.frame = CGRect(x: -shine.bounds.width, y: 0, width: shine.bounds.width, height: shine.bounds.height)
    CATransaction.commit()
    if shine.isHidden || window == nil || shine.bounds.width < 1 {
      gradient.removeAnimation(forKey: "thinking-sweep"); animatedWidth = 0; return
    }
    if abs(animatedWidth - shine.bounds.width) > 0.5 {
      gradient.removeAnimation(forKey: "thinking-sweep"); animatedWidth = shine.bounds.width
    }
    if gradient.animation(forKey: "thinking-sweep") == nil {
      let sweep = CABasicAnimation(keyPath: "transform.translation.x")
      sweep.fromValue = 0; sweep.toValue = max(1, shine.bounds.width * 2)
      sweep.duration = 1.8; sweep.repeatCount = .infinity
      gradient.add(sweep, forKey: "thinking-sweep")
    }
  }
#if DEBUG
  var debugSweepVisible: Bool { !shine.isHidden && shine.bounds.width > 1 && subviews.last === shine && gradient.animation(forKey: "thinking-sweep") != nil }
#endif
}

// MARK: - Foundation-only trusted message links

/// The model's text supplies no routes. Only this message's observed metadata can
/// provide a destination, and the cell dispatches it through existing callbacks.
enum QFAssistantMessageLinks {
  enum Target: Equatable { case source(Int), action(Int) }
  struct Candidate {
    let title: String
    let target: Target
    let url: URL
    fileprivate let identity: String
  }
  struct Span {
    let range: NSRange
    let target: Target
    let url: URL
  }

  static func sourceIsNavigable(_ source: QFAgentSource) -> Bool {
    if source.id.hasPrefix("knowledge:") {
      return source.id.range(of: "^knowledge:[a-z0-9][a-z0-9-]{0,79}$", options: .regularExpression) != nil
    }
    if source.id.hasPrefix("recipe:") { return UUID(uuidString: String(source.id.dropFirst(7))) != nil }
    if source.id.hasPrefix("inventory-lot:") { return UUID(uuidString: String(source.id.dropFirst(14))) != nil }
    if source.id.hasPrefix("plan-slot:") {
      let parts = source.id.components(separatedBy: ":")
      return parts.count == 4 && (parts[1] == "personal" || UUID(uuidString: parts[1]) != nil)
        && QFAgentPlan.validDate(parts[2]) && ["BREAKFAST", "LUNCH", "DINNER"].contains(parts[3])
    }
    guard let raw = source.url, let url = URL(string: raw) else { return false }
    return url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
  }

  static func actionIsNavigable(_ action: QFAgentAction) -> Bool {
    switch action.type {
    case "NAVIGATE_RECIPES", "NAVIGATE_PLAN", "NAVIGATE_INVENTORY", "NAVIGATE_MODEL_SETTINGS", "NAVIGATE_MEMORY": return true
    case "OPEN_RECIPE": return action.recipeID.flatMap(UUID.init(uuidString:)) != nil
    case "WEEKLY_PLAN_PROPOSAL": return action.proposalID.flatMap(UUID.init(uuidString:)) != nil
    case "PLAN_DRAFT":
      return action.recipeID.flatMap(UUID.init(uuidString:)) != nil
        && action.date.map(QFAgentPlan.validDate) == true
        && ["BREAKFAST", "LUNCH", "DINNER"].contains(action.meal ?? "")
    default: return false
    }
  }

  static func candidates(sources: [QFAgentSource], actions: [QFAgentAction], actionTitles: [String], binding: String) -> [Candidate] {
    var values: [Candidate] = []
    func append(_ title: String, target: Target, kind: String, index: Int, identity: String) {
      let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, title.utf16.count <= 512,
        !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        let url = URL(string: "qf-assistant-link://message/\(binding)/\(kind)/\(index)") else { return }
      values.append(Candidate(title: title, target: target, url: url, identity: identity))
    }
    for (index, source) in sources.enumerated() where sourceIsNavigable(source) {
      append(source.title, target: .source(index), kind: "source", index: index, identity: "source:" + source.id)
    }
    for (index, action) in actions.enumerated() where actionIsNavigable(action) && actionTitles.indices.contains(index) {
      let identity = [action.type, action.recipeID ?? "", action.date ?? "", action.meal ?? "", action.proposalID ?? ""].joined(separator: "|")
      append(actionTitles[index], target: .action(index), kind: "action", index: index, identity: "action:" + identity)
    }
    // A repeated title with different destinations is ambiguous: keep its source
    // buttons instead of silently choosing one of two same-name recipes.
    let grouped = Dictionary(grouping: values, by: \.title)
    return values.enumerated().compactMap { index, value -> (Int, Candidate)? in
      guard let group = grouped[value.title], Set(group.map(\.identity)).count == 1,
        group.first?.url == value.url else { return nil }
      return (index, value)
    }.sorted {
      $0.1.title.utf16.count == $1.1.title.utf16.count ? $0.0 < $1.0 : $0.1.title.utf16.count > $1.1.title.utf16.count
    }.map(\.1)
  }

  static func spans(in text: String, candidates: [Candidate]) -> [Span] {
    let value = text as NSString
    var spans: [Span] = []
    for candidate in candidates {
      var remaining = NSRange(location: 0, length: value.length)
      while remaining.length > 0 {
        let found = value.range(of: candidate.title, options: .literal, range: remaining)
        if found.location == NSNotFound { break }
        if let range = Range(found, in: text), hasWordBoundaries(range, in: text),
          spans.allSatisfy({ NSIntersectionRange($0.range, found).length == 0 }) {
          spans.append(Span(range: found, target: candidate.target, url: candidate.url))
        }
        let next = NSMaxRange(found)
        remaining = NSRange(location: next, length: value.length - next)
      }
    }
    return spans.sorted { $0.range.location < $1.range.location }
  }

  private static func hasWordBoundaries(_ range: Range<String.Index>, in text: String) -> Bool {
    // Avoid linking "ham" in "champion"; CJK titles do not use word spaces.
    func word(_ character: Character) -> Bool {
      character.unicodeScalars.contains { $0.value < 0x2E80 && (CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)) }
    }
    if let first = text[range].first, word(first), range.lowerBound > text.startIndex,
      word(text[text.index(before: range.lowerBound)]) { return false }
    if let last = text[range].last, word(last), range.upperBound < text.endIndex,
      word(text[range.upperBound]) { return false }
    return true
  }
}

// MARK: - Native message text view

/// TextKit handles link hit-testing and accessibility; intrinsic width keeps
/// short answers compact rather than stretching every message to the full row.
@MainActor
private final class QFAssistantFadeLayoutManager: NSLayoutManager {
  private var appearance: [QFAssistantTextFade.Frame] = []
  func updateAppearance(_ frames: [QFAssistantTextFade.Frame]) {
    let dirty = appearance.map(\.range) + frames.map(\.range)
    appearance = frames.filter { $0.opacity < 1 }
    for range in dirty where NSMaxRange(range) <= (textStorage?.length ?? 0) { invalidateDisplay(forCharacterRange: range) }
  }
  func opacity(at character: Int) -> Double? { appearance.first { NSLocationInRange(character, $0.range) }?.opacity }
  override func drawGlyphs(forGlyphRange glyphs: NSRange, at origin: CGPoint) {
    guard !appearance.isEmpty, let context = UIGraphicsGetCurrentContext() else { super.drawGlyphs(forGlyphRange: glyphs, at: origin); return }
    var cursor = glyphs.location
    for frame in appearance.sorted(by: { $0.range.location < $1.range.location }) {
      guard NSMaxRange(frame.range) <= (textStorage?.length ?? 0) else { continue }
      let faded = NSIntersectionRange(glyphs, glyphRange(forCharacterRange: frame.range, actualCharacterRange: nil))
      guard faded.length > 0 else { continue }
      if faded.location > cursor { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: faded.location - cursor), at: origin) }
      let start = max(cursor, faded.location)
      if NSMaxRange(faded) > start {
        context.saveGState(); context.setAlpha(CGFloat(frame.opacity))
        super.drawGlyphs(forGlyphRange: NSRange(location: start, length: NSMaxRange(faded) - start), at: origin)
        context.restoreGState()
      }
      cursor = max(cursor, NSMaxRange(faded))
    }
    if cursor < NSMaxRange(glyphs) { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: NSMaxRange(glyphs) - cursor), at: origin) }
  }
}

@MainActor
private final class QFAssistantMessageTextView: UITextView {
  private var measuredSize: CGSize?
  let fadeLayoutManager: QFAssistantFadeLayoutManager
  override init(frame: CGRect, textContainer: NSTextContainer?) {
    let container = NSTextContainer(size: .zero)
    let storage = NSTextStorage(), manager = QFAssistantFadeLayoutManager()
    fadeLayoutManager = manager
    storage.addLayoutManager(manager); manager.addTextContainer(container)
    super.init(frame: frame, textContainer: container)
  }
  required init?(coder: NSCoder) { nil }
  override func invalidateIntrinsicContentSize() { measuredSize = nil; super.invalidateIntrinsicContentSize() }
  var preferredMaxLayoutWidth: CGFloat = 280 {
    didSet { if abs(oldValue - preferredMaxLayoutWidth) > 0.5 { invalidateIntrinsicContentSize() } }
  }
  override var intrinsicContentSize: CGSize {
    if let measuredSize { return measuredSize }
    guard let attributedText, attributedText.length > 0 else { return .zero }
    let bounds = attributedText.boundingRect(with: CGSize(width: max(1, preferredMaxLayoutWidth), height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    let size = CGSize(width: min(preferredMaxLayoutWidth, ceil(bounds.width)), height: ceil(bounds.height))
    measuredSize = size; return size
  }
}

/// CADisplayLink retains its target; the callback retains the controller weakly.
@MainActor final class QFAssistantDisplayLinkTarget: NSObject {
  let callback: (CADisplayLink) -> Void
  init(_ callback: @escaping (CADisplayLink) -> Void) { self.callback = callback }
  @objc func tick(_ link: CADisplayLink) { callback(link) }
}

enum QFAssistantChatLayout {
  static let chatHorizontalInset: CGFloat = 16
  static let composerMaxHeight: CGFloat = 132
}

extension QFAssistantProcessStep {
  @MainActor func title(_ app: QFAppSession) -> String {
    switch stage {
    case "knowledge", "tool:knowledge.search", "tool:web.search": return app.text("知识检索", "Knowledge retrieval")
    case "planner": return app.text("工具选择", "Tool selection")
    case "tool:recipe.search", "tool:recipe.detail": return app.text("菜谱查询", "Recipe lookup")
    case "tool:plan.read": return app.text("饮食计划查询", "Meal plan lookup")
    case "tool:plan.weekly": return app.text("正在安排七天饮食", "Preparing seven days of meals")
    case "tool:inventory.read": return app.text("库存查询", "Stock lookup")
    case "answer", "generating": return app.text("正在生成回答", "Generating answer")
    default: return app.text("准备上下文", "Context preparation")
    }
  }
}

@MainActor
final class QFAssistantChatCell: UITableViewCell, UITextViewDelegate {
  private let stack = UIStackView()
  private var leadingConstraint: Constraint?
  private let bodyLabel = QFAssistantMessageTextView(frame: .zero)
  private let bubble = UIView()
  private let photo = UIImageView()
  private var photoURL: URL?
  private let progress = UIStackView()
  private let details = UIStackView()
  private let processButton = QFAssistantThinkingButton(frame: .zero)
  private let indicator = UIActivityIndicatorView(style: .medium)
  private let footer = UIStackView()
  private let notice = UILabel()
  private let references = UIStackView()
  private var isUserMessage = false
  private var linkedSources: [QFAgentSource] = []
  private var linkedActions: [QFAgentAction] = []
  private var linkCandidates: [QFAssistantMessageLinks.Candidate] = []
  private var activeLinks: [URL: QFAssistantMessageLinks.Target] = [:]
  private var textFade = QFAssistantTextFade()
  var hasTextFade: Bool { textFade.isActive }
  var onToggle: (() -> Void)?
  var onRetry: (() -> Void)?
  var onSource: ((QFAgentSource) -> Void)?
  var onAction: ((QFAgentAction) -> Void)?
  var onImage: ((URL) -> Void)?
  var displayedText: String { bodyLabel.text ?? "" }

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear; selectionStyle = .none
    stack.axis = .vertical; stack.spacing = 10
    stack.alignment = .leading
    contentView.addSubview(stack)
    stack.snp.makeConstraints {
      leadingConstraint = $0.leading.equalToSuperview().offset(QFAssistantChatLayout.chatHorizontalInset).constraint
      $0.trailing.equalToSuperview().inset(QFAssistantChatLayout.chatHorizontalInset)
      $0.top.equalToSuperview().offset(10)
      $0.bottom.equalToSuperview().inset(12)
    }
    progress.axis = .horizontal; progress.spacing = 8; progress.alignment = .center
    progress.addArrangedSubview(indicator); progress.addArrangedSubview(processButton)
    indicator.snp.makeConstraints { $0.width.equalTo(20).priority(999) }
    processButton.contentHorizontalAlignment = .leading
    processButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
    processButton.titleLabel?.adjustsFontForContentSizeCategory = true
    processButton.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    processButton.tintColor = QFUI.secondary
    processButton.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
    details.axis = .vertical; details.spacing = 7
    details.isLayoutMarginsRelativeArrangement = true
    details.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    details.backgroundColor = QFUI.surfaceAlt.withAlphaComponent(0.6); details.layer.cornerRadius = 12
    bodyLabel.font = .preferredFont(forTextStyle: .body)
    bodyLabel.adjustsFontForContentSizeCategory = true
    bodyLabel.backgroundColor = .clear; bodyLabel.isEditable = false; bodyLabel.isSelectable = true
    bodyLabel.isScrollEnabled = false; bodyLabel.dataDetectorTypes = []
    bodyLabel.textContainerInset = .zero; bodyLabel.textContainer.lineFragmentPadding = 0
    bodyLabel.contentInset = .zero; bodyLabel.delegate = self
    bodyLabel.setContentHuggingPriority(.required, for: .horizontal)
    bodyLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    bubble.addSubview(bodyLabel)
    bodyLabel.snp.makeConstraints { $0.edges.equalToSuperview().inset(14) }
    notice.font = .preferredFont(forTextStyle: .caption1); notice.adjustsFontForContentSizeCategory = true
    notice.numberOfLines = 0; notice.textColor = QFUI.secondary
    references.axis = .vertical; references.spacing = 8
    footer.axis = .horizontal; footer.spacing = 18; footer.alignment = .leading
    photo.isHidden = true; photo.contentMode = .scaleAspectFill; photo.clipsToBounds = true; photo.layer.cornerRadius = 14
    photo.isUserInteractionEnabled = true; photo.isAccessibilityElement = true; photo.accessibilityTraits = .button
    photo.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openImage)))
    photo.snp.makeConstraints { $0.width.equalTo(220).priority(999); $0.height.equalTo(180).priority(999) }
    for view in [progress, details, photo, bubble, notice, references, footer] { stack.addArrangedSubview(view) }
    details.snp.makeConstraints { $0.width.equalTo(stack) }
    bubble.snp.makeConstraints { $0.width.lessThanOrEqualTo(stack) }
    notice.snp.makeConstraints { $0.width.equalTo(stack) }
    references.snp.makeConstraints { $0.width.equalTo(stack) }
  }
  required init?(coder: NSCoder) { nil }

  override func prepareForReuse() {
    super.prepareForReuse()
    activeLinks = [:]; linkCandidates = []; linkedSources = []; linkedActions = []
    bodyLabel.attributedText = nil
    textFade = QFAssistantTextFade()
    processButton.thinking = false
    onToggle = nil; onRetry = nil; onSource = nil; onAction = nil
    photo.kf.cancelDownloadTask(); photo.image = nil; photoURL = nil; photo.isHidden = true; onImage = nil
  }
  func configureImage(_ url: URL?, app: QFAppSession) {
    photoURL = url; photo.isHidden = url == nil
    photo.accessibilityLabel = app.text("查看大图", "View full image")
    guard let url else { photo.kf.cancelDownloadTask(); photo.image = nil; return }
    photo.kf.setImage(with: LocalFileImageDataProvider(fileURL: url), placeholder: UIImage(systemName: "photo"),
      options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 440, height: 360))), .cacheMemoryOnly])
  }
  @objc private func openImage() { if let url = photoURL { onImage?(url) } }
  func finishProcessing(state: String, app: QFAppSession, expanded: Bool) {
    processButton.thinking = false
    let title = state == "stopped" ? app.text("已停止生成", "Generation stopped")
      : state == "failed" ? app.text("生成失败", "Generation failed") : app.text("需求分析", "Request analysis")
    processButton.setTitle(title, for: .normal); processButton.expanded = expanded
    processButton.accessibilityValue = state == "complete" ? app.text("已完成", "Completed") : title
  }

  func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
    guard interaction == .invokeDefaultAction, let target = activeLinks[URL] else { return false }
    switch target {
    case .source(let index): if linkedSources.indices.contains(index) { onSource?(linkedSources[index]) }
    case .action(let index): if linkedActions.indices.contains(index) { onAction?(linkedActions[index]) }
    }
    return false
  }

  private func setBodyText(_ text: String) {
    bodyLabel.fadeLayoutManager.updateAppearance([])
    textFade = QFAssistantTextFade()
    let body = NSMutableAttributedString(string: text, attributes: [
      .font: bodyLabel.font ?? UIFont.preferredFont(forTextStyle: .body),
      .foregroundColor: isUserMessage ? UIColor.white : QFUI.text
    ])
    activeLinks = [:]
    for span in QFAssistantMessageLinks.spans(in: text, candidates: linkCandidates) {
      body.addAttribute(.link, value: span.url, range: span.range)
      activeLinks[span.url] = span.target
    }
    bodyLabel.linkTextAttributes = [.foregroundColor: QFUI.primary, .underlineStyle: NSUnderlineStyle.single.rawValue]
    bodyLabel.attributedText = body
    bodyLabel.invalidateIntrinsicContentSize()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = max(80, contentView.bounds.width - (isUserMessage ? 64 : 16) - 16 - 28)
    if abs(bodyLabel.preferredMaxLayoutWidth - width) > 0.5 {
      bodyLabel.preferredMaxLayoutWidth = width
      contentView.setNeedsLayout(); contentView.layoutIfNeeded()
    }
  }
#if DEBUG
  var debugBubbleWidth: CGFloat { bubble.bounds.width }
  var debugSweepVisible: Bool { processButton.debugSweepVisible }
  var debugDisclosureWidth: CGFloat { processButton.imageView?.bounds.width ?? 0 }
  var debugPhotoLoaded: Bool { !photo.isHidden && photo.image?.cgImage != nil }
  func debugToggleAnalysis() { processButton.sendActions(for: .touchUpInside) }
  static func debugCheckRichContent(app: QFAppSession) throws -> [String: Any] {
    let cell = QFAssistantChatCell(style: .default, reuseIdentifier: "rich-content-check")
    cell.frame = CGRect(x: 0, y: 0, width: 414, height: 500)
    let source = QFAgentSource(id: "recipe:00000000-0000-4000-8000-000000000001", title: "Example recipe", url: nil, revision: nil)
    let item = QFAssistantLocalMessage(id: UUID(), role: "assistant", text: "Example recipe", createdAt: Date(), sources: [source], state: "streaming", process: [.init(stage: "answer", state: "running")])
    cell.configure(item, app: app, expanded: false, actionTitle: { $0.type })
    cell.setNeedsLayout(); cell.layoutIfNeeded(); cell.processButton.layoutIfNeeded()
    var tapped: QFAgentSource?
    cell.onSource = { tapped = $0 }
    guard let link = cell.activeLinks.first?.key else { throw NSError(domain: "RichContentLinkMissing", code: 1) }
    _ = cell.textView(cell.bodyLabel, shouldInteractWith: link, in: NSRange(location: 0, length: 14), interaction: .invokeDefaultAction)
    guard tapped == source else { throw NSError(domain: "RichContentCallbackMissing", code: 2) }
    let smallWidth = cell.debugBubbleWidth
    let long = QFAssistantLocalMessage(id: UUID(), role: "assistant", text: String(repeating: "Example recipe ", count: 80), createdAt: Date())
    cell.configure(long, app: app, expanded: false, actionTitle: { $0.type })
    cell.setNeedsLayout(); cell.layoutIfNeeded()
    let largeWidth = cell.debugBubbleWidth
    guard smallWidth > 28, largeWidth > smallWidth, largeWidth <= 383 else { throw NSError(domain: "RichContentBubbleWidth", code: 3) }
    cell.prepareForReuse(); tapped = nil
    _ = cell.textView(cell.bodyLabel, shouldInteractWith: link, in: NSRange(location: 0, length: 14), interaction: .invokeDefaultAction)
    guard tapped == nil else { throw NSError(domain: "RichContentStaleRoute", code: 4) }
    let color = cell.processButton.titleColor(for: .normal)?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    guard color != nil, color != UIColor.white else { throw NSError(domain: "ThinkingWhiteTitle", code: 5) }
    cell.setBodyText("旧字")
    _ = cell.revealText("旧字新字", at: 10)
    guard cell.hasTextFade,
      cell.bodyLabel.fadeLayoutManager.opacity(at: 2) == 0,
      cell.bodyLabel.fadeLayoutManager.opacity(at: 0) == nil else { throw NSError(domain: "TextFadeAffectsExistingWords", code: 6) }
    cell.advanceTextFade(at: 10.3)
    guard !cell.hasTextFade, cell.displayedText == "旧字新字" else { throw NSError(domain: "TextFadeDidNotComplete", code: 7) }
    return ["sourceCallback": true, "reuseRejectedStaleLink": true, "smallBubbleWidth": smallWidth,
      "largeBubbleWidth": largeWidth, "thinkingColorNotWhite": true, "appendedTextOnlyFade": true, "businessCalls": false]
  }
#endif

  func revealText(_ text: String, at time: TimeInterval = CACurrentMediaTime()) -> Bool {
    guard bodyLabel.text != text else { return false }
    let oldHeight = bodyLabel.intrinsicContentSize.height
    let wasHidden = bubble.isHidden
    let previous = bodyLabel.text ?? ""
    if text.hasPrefix(previous) {
      let suffix = String(text.dropFirst(previous.count))
      let range = NSRange(location: bodyLabel.textStorage.length, length: (suffix as NSString).length)
      bodyLabel.textStorage.append(NSAttributedString(string: suffix, attributes: [
        .font: bodyLabel.font ?? UIFont.preferredFont(forTextStyle: .body),
        .foregroundColor: isUserMessage ? UIColor.white : QFUI.text
      ]))
      // A title can span several network chunks; resolve only the bounded,
      // trusted source candidates, without replacing the existing text storage.
      for span in QFAssistantMessageLinks.spans(in: text, candidates: linkCandidates) {
        bodyLabel.textStorage.addAttribute(.link, value: span.url, range: span.range)
        activeLinks[span.url] = span.target
      }
      if !UIAccessibility.isReduceMotionEnabled {
        textFade.append(range, at: time)
        bodyLabel.fadeLayoutManager.updateAppearance(textFade.advance(at: time))
      }
      bodyLabel.invalidateIntrinsicContentSize()
    } else { setBodyText(text) }
    bubble.isHidden = text.isEmpty
    contentView.setNeedsLayout(); contentView.layoutIfNeeded()
    return wasHidden != bubble.isHidden || abs(oldHeight - bodyLabel.intrinsicContentSize.height) > 0.5
  }

  func advanceTextFade(at time: TimeInterval) {
    if UIAccessibility.isReduceMotionEnabled {
      bodyLabel.fadeLayoutManager.updateAppearance([])
      textFade = QFAssistantTextFade(); return
    }
    bodyLabel.fadeLayoutManager.updateAppearance(textFade.advance(at: time))
  }

  func configure(_ item: QFAssistantLocalMessage, app: QFAppSession, expanded: Bool, displayText: String? = nil, actionTitle: (QFAgentAction) -> String) {
    let user = item.role == "user", running = item.state == "streaming"
    isUserMessage = user
    linkedSources = user ? [] : item.sources ?? []
    linkedActions = user ? [] : item.actions ?? []
    linkCandidates = QFAssistantMessageLinks.candidates(sources: linkedSources, actions: linkedActions,
      actionTitles: linkedActions.map(actionTitle), binding: UUID().uuidString.lowercased())
    progress.isHidden = user || (item.process ?? []).isEmpty
    indicator.stopAnimating(); indicator.isHidden = true
    let answering = running && !item.text.isEmpty
    processButton.thinking = running && !answering
    let processTitle = running ? (answering ? app.text("正在回答", "Answering") : app.text("正在思考", "Thinking"))
      : item.state == "stopped" ? app.text("已停止生成", "Generation stopped")
      : item.state == "failed" ? app.text("生成失败", "Generation failed") : app.text("需求分析", "Request analysis")
    processButton.setTitle(processTitle, for: .normal)
    processButton.expanded = expanded
    processButton.accessibilityHint = expanded ? app.text("收起问题分析", "Collapse question analysis") : app.text("展开问题分析", "Expand question analysis")
    processButton.accessibilityIdentifier = "assistant.process.toggle"
    switch item.state {
    case "streaming": processButton.accessibilityValue = app.text("正在生成回答", "Generating answer")
    case "stopped": processButton.accessibilityValue = app.text("已停止生成", "Generation stopped")
    case "failed": processButton.accessibilityValue = app.text("生成失败", "Generation failed")
    default: processButton.accessibilityValue = app.text("已完成", "Completed")
    }
    QFTabUI.clear(details)
    details.isHidden = !expanded || progress.isHidden
    if expanded {
      if let analysis = item.analysis, !analysis.isEmpty {
        details.addArrangedSubview(QFTabUI.label(app.text("需求分析", "Request analysis"), size: 13, weight: .medium))
        for line in analysis {
          let label = QFTabUI.label(line, size: 13, color: QFUI.text.withAlphaComponent(0.85), lines: 0)
          label.font = .preferredFont(forTextStyle: .caption1); label.adjustsFontForContentSizeCategory = true
          details.addArrangedSubview(label)
        }
      }
      // Keep actual lookups visible; internal prompt/planner/generation stages
      // do not describe the user's needs and need no second progress display.
      for step in item.process ?? [] where ["knowledge", "tool:knowledge.search", "tool:web.search", "tool:recipe.search", "tool:recipe.detail", "tool:plan.read", "tool:inventory.read"].contains(step.stage) {
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 8; row.alignment = .top
        let icon = UIImageView(image: UIImage(systemName: step.state == "complete" ? "checkmark.circle.fill" : step.state == "running" ? "circle.dotted" : "exclamationmark.circle"))
        icon.tintColor = step.state == "complete" ? QFUI.primary : QFUI.secondary
        icon.snp.makeConstraints { $0.size.equalTo(16) }
        let title = QFTabUI.label(step.title(app), size: 13, color: QFUI.secondary, lines: 0)
        title.font = .preferredFont(forTextStyle: .caption1); title.adjustsFontForContentSizeCategory = true
        row.addArrangedSubview(icon); row.addArrangedSubview(title); details.addArrangedSubview(row)
      }
      if let reasoning = item.reasoning, !reasoning.isEmpty {
        let label = QFTabUI.label(app.text("深度分析", "Deep analysis") + "\n" + reasoning, size: 13, color: QFUI.secondary, lines: 0)
        label.font = .preferredFont(forTextStyle: .caption1); label.adjustsFontForContentSizeCategory = true
        details.addArrangedSubview(label)
      }
    }
    bubble.backgroundColor = user ? UIColor(red: 0.08, green: 0.32, blue: 0.34, alpha: 1) : QFUI.surface
    leadingConstraint?.update(offset: user ? 64 : QFAssistantChatLayout.chatHorizontalInset)
    stack.alignment = user ? .trailing : .leading
    bodyLabel.preferredMaxLayoutWidth = max(80, contentView.bounds.width - (user ? 64 : 16) - 16 - 28)
    bubble.layer.cornerRadius = 16
    bodyLabel.textColor = user ? .white : QFUI.text
    setBodyText(displayText ?? item.text)
    bubble.isHidden = (displayText ?? item.text).isEmpty
    let legacyModeNotice = app.text("本机知识模式：未查询远端菜谱、计划或库存。", "Local knowledge mode: remote recipes, plans and stock were not queried.")
    notice.text = item.notice; notice.isHidden = item.notice?.isEmpty != false || item.notice == legacyModeNotice
    QFTabUI.clear(references)
    for source in item.sources ?? [] {
      let button = QFTabUI.button(app.format("来源：%@", "Source: %@", source.title), color: QFUI.primary, background: QFUI.surfaceAlt) { [weak self] in self?.onSource?(source) }
      button.titleLabel?.numberOfLines = 0
      button.isEnabled = QFAssistantMessageLinks.sourceIsNavigable(source)
      button.accessibilityIdentifier = "assistant.source.\(source.id)"; references.addArrangedSubview(button)
    }
    for action in item.actions ?? [] where QFAssistantMessageLinks.actionIsNavigable(action) {
      let button = QFTabUI.button(actionTitle(action), color: QFUI.primary, background: QFUI.surfaceAlt) { [weak self] in self?.onAction?(action) }
      button.titleLabel?.numberOfLines = 0; button.accessibilityIdentifier = "assistant.action.\(action.type)"
      references.addArrangedSubview(button)
    }
    references.isHidden = references.arrangedSubviews.isEmpty
    QFTabUI.clear(footer)
    if !user, !running, !item.text.isEmpty {
      let copy = QFTabUI.iconButton("doc.on.doc", label: app.text("复制", "Copy"), size: 17) { [weak self] in
        guard let self else { return }
        UIPasteboard.general.string = item.text
        let copied = app.text("已复制", "Copied")
        QFOperationHUD.toast(copied, in: self.window ?? self.contentView)
        UIAccessibility.post(notification: .announcement, argument: copied)
      }
      copy.snp.makeConstraints { $0.size.equalTo(44) }; footer.addArrangedSubview(copy)
    }
    if ["failed", "stopped"].contains(item.state ?? ""), item.retryText != nil {
      let retry = QFTabUI.iconButton("arrow.clockwise", label: app.text("重新生成", "Regenerate"), size: 17) { [weak self] in self?.onRetry?() }
      retry.snp.makeConstraints { $0.size.equalTo(44) }; footer.addArrangedSubview(retry)
    }
    footer.isHidden = footer.arrangedSubviews.isEmpty
  }
}
