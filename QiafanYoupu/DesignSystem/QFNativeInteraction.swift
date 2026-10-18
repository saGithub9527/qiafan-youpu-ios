import MBProgressHUD
import SnapKit
import UIKit

@MainActor
protocol QFNavigationBackHandling: AnyObject {
  var hasUnsavedChanges: Bool { get }
  func close()
}

@MainActor
final class QFNavigationController: UINavigationController, UIGestureRecognizerDelegate {
  override func viewDidLoad() {
    super.viewDidLoad()
    setNavigationBarHidden(true, animated: false)
    interactivePopGestureRecognizer?.delegate = self
  }
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard viewControllers.count > 1, transitionCoordinator == nil else { return false }
    if let editor = topViewController as? QFNavigationBackHandling, editor.hasUnsavedChanges {
      editor.close()
      return false
    }
    return true
  }
}

@MainActor
extension UIViewController {
  func qfPush(_ controller: UIViewController) {
    view.endEditing(true)
    if let navigationController {
      controller.hidesBottomBarWhenPushed = true
      navigationController.pushViewController(controller, animated: true)
    } else {
      let navigation = QFNavigationController(rootViewController: controller)
      navigation.modalPresentationStyle = .fullScreen
      present(navigation, animated: true)
    }
  }
  func qfClose(animated: Bool = true, completion: (() -> Void)? = nil) {
    view.endEditing(true)
    if let navigationController, navigationController.viewControllers.first !== self {
      navigationController.popViewController(animated: animated)
      if let coordinator = navigationController.transitionCoordinator {
        coordinator.animate(alongsideTransition: nil) { context in
          if !context.isCancelled { completion?() }
        }
      } else {
        completion?()
      }
    } else {
      dismiss(animated: animated, completion: completion)
    }
  }
}

/// A view-scoped HUD; quick operations finish before the grace period and never flash.
@MainActor
final class QFOperationHUD {
  private var hud: MBProgressHUD?
  func show(in view: UIView, text: String) {
    hide()
    let value = MBProgressHUD(view: view)
    value.graceTime = 0.35
    value.minShowTime = 0.3
    value.removeFromSuperViewOnHide = true
    value.label.text = text
    value.isUserInteractionEnabled = false
    view.addSubview(value)
    value.show(animated: true)
    hud = value
  }
  func hide() {
    hud?.hide(animated: true)
    hud = nil
  }
  static func toast(_ text: String, in view: UIView) {
    let value = MBProgressHUD.showAdded(to: view, animated: true)
    value.mode = .text
    value.label.text = text
    value.label.numberOfLines = 0
    value.isUserInteractionEnabled = false
    value.hide(animated: true, afterDelay: 1.8)
  }
}

struct QFContentRow {
  let id: String
  let version: String
  let makeView: () -> UIView
  init(_ id: String, version: String = "", _ makeView: @escaping () -> UIView) {
    self.id = id
    self.version = version
    self.makeView = makeView
  }
  init<Value: Encodable>(_ id: String, value: Value, _ makeView: @escaping () -> UIView) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    self.init(
      id, version: (try? encoder.encode(value).base64EncodedString()) ?? UUID().uuidString, makeView
    )
  }
}

/// Keyed rows keep unchanged controls, images and scroll geometry mounted.
@MainActor
final class QFContentListStack: UIStackView {
  private var rows: [String: (version: String, view: UIView)] = [:]
  private var pending: [QFContentRow] = []
  func beginUpdates() { pending.removeAll(keepingCapacity: true) }
  func row(_ id: String, version: String = "", _ make: @escaping () -> UIView) {
    pending.append(QFContentRow(id, version: version, make))
  }
  func row<Value: Encodable>(_ id: String, value: Value, _ make: @escaping () -> UIView) {
    pending.append(QFContentRow(id, value: value, make))
  }
  func endUpdates() {
    let next = pending
    pending.removeAll(keepingCapacity: true)
    apply(next)
  }
  func apply(_ next: [QFContentRow]) {
    let ids = Set(next.map(\.id))
    for (id, entry) in rows where !ids.contains(id) {
      removeArrangedSubview(entry.view)
      entry.view.removeFromSuperview()
      rows[id] = nil
    }
    UIView.performWithoutAnimation {
      for (index, item) in next.enumerated() {
        let row: UIView
        if let previous = rows[item.id], previous.version == item.version {
          row = previous.view
        } else {
          if let old = rows[item.id]?.view {
            removeArrangedSubview(old)
            old.removeFromSuperview()
          }
          row = item.makeView()
          rows[item.id] = (item.version, row)
        }
        if arrangedSubviews.firstIndex(of: row) != index {
          removeArrangedSubview(row)
          insertArrangedSubview(row, at: min(index, arrangedSubviews.count))
        }
      }
    }
  }
}

/// UITableView owns cell reuse; this adapter only maps the existing business rows to stable IDs.
@MainActor
final class QFContentListTable: UITableView {
  var spacing: CGFloat = 14
  var horizontalInset: CGFloat = 20
  private var rowsByID: [String: QFContentRow] = [:]
  private var pending: [QFContentRow] = []
  private var rowDataSource: UITableViewDiffableDataSource<Int, String>!

  override init(frame: CGRect, style: UITableView.Style) {
    super.init(frame: frame, style: style)
    backgroundColor = QFUI.background
    separatorStyle = .none
    rowHeight = UITableView.automaticDimension
    estimatedRowHeight = 180
    sectionHeaderTopPadding = 0
    allowsSelection = false
    register(QFContentRowCell.self, forCellReuseIdentifier: "content-row")
    rowDataSource = UITableViewDiffableDataSource<Int, String>(tableView: self) {
      [weak self] table, index, id in
      guard let self, let row = self.rowsByID[id],
        let cell = table.dequeueReusableCell(withIdentifier: "content-row", for: index)
          as? QFContentRowCell
      else { return nil }
      cell.configure(row, spacing: self.spacing, horizontalInset: self.horizontalInset)
      return cell
    }
  }
  required init?(coder: NSCoder) { nil }
  func beginUpdatesForRows() { pending.removeAll(keepingCapacity: true) }
  func row(_ id: String, version: String = "", _ make: @escaping () -> UIView) {
    pending.append(QFContentRow(id, version: version, make))
  }
  func row<Value: Encodable>(_ id: String, value: Value, _ make: @escaping () -> UIView) {
    pending.append(QFContentRow(id, value: value, make))
  }
  func endUpdatesForRows() {
    let next = pending
    pending.removeAll(keepingCapacity: true)
    apply(next)
  }
  func apply(_ next: [QFContentRow]) {
    let previous = rowDataSource.snapshot()
    let ids = next.map(\.id)
    let oldIDs = Set(previous.itemIdentifiers)
    let changed = next.filter { rowsByID[$0.id]?.version != $0.version && oldIDs.contains($0.id) }
      .map(\.id)
    rowsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
    guard previous.itemIdentifiers != ids || !changed.isEmpty else { return }
    var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
    snapshot.appendSections([0])
    snapshot.appendItems(ids)
    snapshot.reconfigureItems(changed)
    rowDataSource.apply(snapshot, animatingDifferences: false)
  }
}

@MainActor
private final class QFContentRowCell: UITableViewCell {
  private var hostedView: UIView?
  private var rowIdentity: String?
  private var rowVersion: String?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    selectionStyle = .none
  }
  required init?(coder: NSCoder) { nil }
  override func prepareForReuse() {
    super.prepareForReuse()
    hostedView?.removeFromSuperview()
    hostedView = nil
    rowIdentity = nil
    rowVersion = nil
  }
  func configure(_ row: QFContentRow, spacing: CGFloat, horizontalInset: CGFloat) {
    guard rowIdentity != row.id || rowVersion != row.version else { return }
    hostedView?.removeFromSuperview()
    let content = row.makeView()
    contentView.addSubview(content)
    content.snp.makeConstraints {
      $0.top.bottom.equalToSuperview().inset(spacing / 2)
      $0.centerX.equalToSuperview()
      $0.leading.greaterThanOrEqualToSuperview().offset(horizontalInset)
      $0.trailing.lessThanOrEqualToSuperview().inset(horizontalInset)
      $0.width.equalToSuperview().offset(-2 * horizontalInset).priority(999)
      $0.width.lessThanOrEqualTo(620)
    }
    hostedView = content
    rowIdentity = row.id
    rowVersion = row.version
  }
}

@MainActor
final class QFCategorySwipeBinding: NSObject, UIGestureRecognizerDelegate {
  private let count: Int
  private let current: () -> Int
  private let select: (Int) -> Void
  private weak var surface: UIView?
  private var gestures: [UISwipeGestureRecognizer] = []
  convenience init(
    control: UISegmentedControl, in surface: UIView, backGesture: UIGestureRecognizer?
  ) {
    self.init(
      count: control.numberOfSegments,
      current: { [weak control] in control?.selectedSegmentIndex ?? 0 },
      select: { [weak control] index in
        control?.selectedSegmentIndex = index
        control?.sendActions(for: .valueChanged)
      }, in: surface, backGesture: backGesture)
  }
  init(
    count: Int, current: @escaping () -> Int, select: @escaping (Int) -> Void, in surface: UIView,
    backGesture: UIGestureRecognizer?
  ) {
    self.count = count
    self.current = current
    self.select = select
    self.surface = surface
    super.init()
    let directions: [UISwipeGestureRecognizer.Direction] = [.left, .right]
    for direction in directions {
      let gesture = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
      gesture.direction = direction
      gesture.delegate = self
      if let backGesture { gesture.require(toFail: backGesture) }
      surface.addGestureRecognizer(gesture)
      gestures.append(gesture)
    }
  }
  func invalidate() {
    for gesture in gestures { gesture.view?.removeGestureRecognizer(gesture) }
    gestures.removeAll()
  }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard let surface, touch.location(in: surface).x > 30 else { return false }
    var ancestor = touch.view
    while let view = ancestor, view !== surface {
      if view is UITextInput || (view as? UIScrollView)?.isPagingEnabled == true { return false }
      ancestor = view.superview
    }
    return true
  }
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Vertical scrolling must not prevent a deliberate horizontal category swipe.
    // Edge navigation still has explicit failure precedence above.
    otherGestureRecognizer.view is UIScrollView
      && !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
  }
  @objc private func swipe(_ gesture: UISwipeGestureRecognizer) {
    let next = current() + (gesture.direction == .left ? 1 : -1)
    guard (0..<count).contains(next) else { return }
    select(next)
  }
}

@MainActor
final class QFInterestChipGroup: UIStackView {
  private var ids: [String] = []
  private var buttons: [String: UIButton] = [:]
  private var action: ((String) -> Void)?
  func update(_ options: [QFInterestOption], selected: [String], action: @escaping (String) -> Void)
  {
    self.action = action
    if ids != options.map(\.id) {
      ids = options.map(\.id)
      buttons.removeAll()
      QFTabUI.clear(self)
      axis = .vertical
      spacing = 8
      for start in stride(from: 0, to: options.count, by: 3) {
        let row = QFTabUI.stack([], axis: .horizontal, spacing: 8)
        row.distribution = .fillEqually
        for option in options[start..<min(start + 3, options.count)] {
          let button = QFTabUI.button(option.name, size: 14) { [weak self] in
            self?.action?(option.id)
          }
          button.titleLabel?.numberOfLines = 1
          button.titleLabel?.adjustsFontSizeToFitWidth = true
          button.titleLabel?.minimumScaleFactor = 0.75
          button.layer.cornerRadius = 12
          button.layer.borderWidth = 1
          button.snp.makeConstraints { $0.height.equalTo(44) }
          buttons[option.id] = button
          row.addArrangedSubview(button)
        }
        while row.arrangedSubviews.count < 3 { row.addArrangedSubview(UIView()) }
        addArrangedSubview(row)
      }
    }
    for (id, button) in buttons {
      let active = selected.contains(id)
      button.backgroundColor = active ? QFUI.paleGreen : QFUI.surface
      button.layer.borderColor = (active ? QFUI.success : QFUI.border).cgColor
      button.setTitleColor(active ? QFUI.success : QFUI.text, for: .normal)
      button.accessibilityTraits = active ? [.button, .selected] : [.button]
    }
  }
}
