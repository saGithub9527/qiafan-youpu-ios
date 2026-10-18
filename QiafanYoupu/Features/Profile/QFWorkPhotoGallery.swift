import SnapKit
import UIKit

@MainActor
final class QFWorkPhotoGallery: UIView, UICollectionViewDataSource,
  UICollectionViewDelegateFlowLayout
{
  private let app: QFAppSession
  private let layout = UICollectionViewFlowLayout()
  private lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
  private let countLabel = QFContentUI.label("", size: 13, color: QFUI.secondary)
  private let pageControl = UIPageControl()
  private let empty = UIButton(type: .system)
  private lazy var cover = QFContentUI.action("") { [weak self] in
    guard let self, !self.scrolling, let id = self.currentID else { return }
    self.onCover?(self.coverID == id ? nil : id)
  }
  private lazy var remove = QFContentUI.action(app.text("删除", "Delete"), destructive: true) { [weak self] in
    guard let self, !self.scrolling, let id = self.currentID else { return }
    self.onRemove?(id)
  }
  private lazy var add = QFContentUI.action(app.text("添加图片", "Add photo")) { [weak self] in self?.onAdd?() }
  private let more = UIButton(type: .system)
  private var ids: [String] = []
  private var coverID: String?
  private var index = 0
  private var scrolling = false
  var onAdd: (() -> Void)?
  var onCover: ((String?) -> Void)?
  var onRemove: ((String) -> Void)?
  var onMove: ((String, Int) -> Void)?
  private var currentID: String? { ids.indices.contains(index) ? ids[index] : nil }

  init(app: QFAppSession) {
    self.app = app
    super.init(frame: .zero)
    layout.scrollDirection = .horizontal
    layout.minimumLineSpacing = 0
    collection.isPagingEnabled = true
    collection.showsHorizontalScrollIndicator = false
    collection.backgroundColor = QFUI.surface
    collection.layer.cornerRadius = 16
    collection.clipsToBounds = true
    collection.dataSource = self
    collection.delegate = self
    collection.register(QFWorkPhotoCell.self, forCellWithReuseIdentifier: "photo")
    addSubview(collection)
    collection.snp.makeConstraints {
      $0.top.leading.trailing.equalToSuperview()
      $0.height.equalTo(240)
    }
    empty.setTitle(app.text("添加菜品图片", "Add dish photos"), for: .normal)
    empty.setTitleColor(QFUI.secondary, for: .normal)
    empty.titleLabel?.font = .systemFont(ofSize: 18)
    empty.accessibilityLabel = app.text("添加菜品图片", "Add dish photos")
    empty.accessibilityHint = app.text("打开相册选择图片，最多9张", "Open the photo library and choose up to 9 photos")
    empty.addAction(
      UIAction { [weak self] _ in
        guard let self, self.ids.isEmpty else { return }
        self.onAdd?()
      }, for: .touchUpInside)
    addSubview(empty)
    empty.snp.makeConstraints { $0.edges.equalTo(collection) }
    pageControl.currentPageIndicatorTintColor = QFUI.primary
    pageControl.pageIndicatorTintColor = QFUI.border
    pageControl.hidesForSinglePage = true
    pageControl.addAction(
      UIAction { [weak self] _ in
        guard let self, self.ids.indices.contains(self.pageControl.currentPage),
          self.pageControl.currentPage != self.index
        else { return }
        self.scrolling = true
        self.index = self.pageControl.currentPage
        self.collection.scrollToItem(
          at: IndexPath(item: self.index, section: 0), at: .centeredHorizontally, animated: true)
        self.updateControls()
      }, for: .valueChanged)
    more.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
    more.showsMenuAsPrimaryAction = true
    more.accessibilityLabel = app.text("调整图片顺序", "Reorder photos")
    more.snp.makeConstraints { $0.size.equalTo(44) }
    let status = QFTabUI.stack([countLabel, UIView(), pageControl], axis: .horizontal, spacing: 8)
    let actions = QFTabUI.stack(
      [cover, UIView(), remove, more, add], axis: .horizontal, spacing: 8)
    let footer = QFTabUI.stack([status, actions], spacing: 4)
    addSubview(footer)
    footer.snp.makeConstraints {
      $0.top.equalTo(collection.snp.bottom).offset(8)
      $0.leading.trailing.bottom.equalToSuperview()
    }
    updateControls()
  }
  required init?(coder: NSCoder) { nil }
  override func layoutSubviews() {
    super.layoutSubviews()
    let size = collection.bounds.size
    if size.width > 0, layout.itemSize != size {
      if scrolling && layout.itemSize.width > 0 {
        index = max(
          0, min(ids.count - 1, Int(round(collection.contentOffset.x / layout.itemSize.width))))
        scrolling = false
        updateControls()
      }
      layout.itemSize = size
      layout.invalidateLayout()
      collection.setContentOffset(CGPoint(x: CGFloat(index) * size.width, y: 0), animated: false)
    }
  }
  func update(ids: [String], coverID: String?) {
    let changed = self.ids != ids
    let previous = currentID
    self.ids = ids
    self.coverID = coverID
    if let previous, let position = ids.firstIndex(of: previous) {
      index = position
    } else {
      index = min(index, max(0, ids.count - 1))
    }
    if changed {
      scrolling = false
      collection.reloadData()
      collection.layoutIfNeeded()
      collection.setContentOffset(
        CGPoint(x: CGFloat(index) * collection.bounds.width, y: 0), animated: false)
    }
    updateControls()
  }
  private func updateControls() {
    countLabel.text = ids.isEmpty
      ? app.text("已选择 0/9 张", "Selected 0/9")
      : app.format(
        "已选择 %d/9 张 · %d/%d", "Selected %d/9 · %d/%d",
        ids.count, index + 1, ids.count)
    pageControl.numberOfPages = ids.count
    pageControl.currentPage = index
    empty.isHidden = !ids.isEmpty
    cover.isHidden = ids.isEmpty
    remove.isHidden = ids.isEmpty
    more.isHidden = ids.count < 2
    add.isEnabled = ids.count < 9 && !scrolling
    cover.isEnabled = !scrolling
    remove.isEnabled = !scrolling
    more.isEnabled = !scrolling
    pageControl.isEnabled = !scrolling
    cover.setTitle(coverID == currentID ? app.text("取消封面", "Remove cover") : app.text("设为封面", "Set as cover"), for: .normal)
    cover.accessibilityValue = coverID == nil ? app.text("自动使用首图", "First photo used automatically") : coverID == currentID ? app.text("当前封面", "Current cover") : ""
    if let id = currentID {
      more.menu = UIMenu(children: [
        UIAction(
          title: app.text("向前移动", "Move earlier"), image: UIImage(systemName: "arrow.left"),
          attributes: index == 0 ? .disabled : []
        ) { [weak self] _ in self?.onMove?(id, -1) },
        UIAction(
          title: app.text("向后移动", "Move later"), image: UIImage(systemName: "arrow.right"),
          attributes: index + 1 == ids.count ? .disabled : []
        ) { [weak self] _ in self?.onMove?(id, 1) },
      ])
    }
  }
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  { ids.count }
  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    let cell =
      collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath)
      as! QFWorkPhotoCell
    cell.picture.load(ids[indexPath.item], app: app)
    return cell
  }
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    scrolling = true
    updateControls()
  }
  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { settlePage() }
  }
  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settlePage() }
  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { settlePage() }
  private func settlePage() {
    scrolling = false
    guard collection.bounds.width > 0 else { return }
    index = max(
      0, min(ids.count - 1, Int(round(collection.contentOffset.x / collection.bounds.width))))
    updateControls()
  }
}

@MainActor
private final class QFWorkPhotoCell: UICollectionViewCell {
  let picture = QFContentImageView()
  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.addSubview(picture)
    picture.clipsToBounds = true
    picture.snp.makeConstraints { $0.edges.equalToSuperview() }
  }
  required init?(coder: NSCoder) { nil }
}
