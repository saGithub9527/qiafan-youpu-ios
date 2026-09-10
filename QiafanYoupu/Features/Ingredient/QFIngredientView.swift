import SwiftUI
import UIKit

struct QFIngredientView: View {
  let isActive: Bool
  @State private var shopping = false
  @State private var selectedCategory = "全部"
  @State private var query = ""
  @State private var nearDateFirst = true
  @State private var unavailableTitle = ""
  @State private var showsUnavailable = false
  @FocusState private var searchFocused: Bool

  private let categories = ["全部", "蔬菜", "肉蛋", "奶制品", "水果", "谷物", "水产", "菌藻", "调味"]

  private var visibleIngredients: [QFIngredientSample] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = shopping ? QFIngredientSample.shopping : QFIngredientSample.inventory
    let ordered =
      !shopping && !nearDateFirst
      ? source.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      : source
    return ordered.filter {
      (selectedCategory == "全部" || $0.category == selectedCategory)
        && (trimmedQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmedQuery))
    }
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 16) {
        header
        searchField
        discoveryEntries
        inventorySegment
        if !shopping { nearDateNotice }
        categoryStrip
        listHeader
        ingredientList
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)
      .padding(.bottom, 24)
    }
    .simultaneousGesture(DragGesture().onChanged { _ in searchFocused = false })
    .onChange(of: isActive) { active in
      if !active { searchFocused = false }
    }
    .background(QFTheme.background.ignoresSafeArea())
    .alert(unavailableTitle, isPresented: $showsUnavailable) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text("该功能暂未开放")
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 6) {
        Text("食材")
          .font(.system(size: 28, weight: .bold))
          .foregroundColor(QFTheme.text)
        Text("把家里的食材用起来")
          .font(.system(size: 12))
          .foregroundColor(QFTheme.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        showUnavailable("扫描小票二维码")
      } label: {
        Image(systemName: "qrcode.viewfinder")
          .font(.system(size: 20))
          .foregroundColor(QFTheme.text)
          .frame(width: 44, height: 40)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
          .overlay(RoundedRectangle(cornerRadius: 14).stroke(QFTheme.border, lineWidth: 1))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("扫描小票二维码")
      .accessibilityIdentifier("ingredient.scan")
      Button {
        showUnavailable("添加食材")
      } label: {
        Text("＋ 添加")
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.white)
          .frame(width: 72, height: 40)
          .background(QFTheme.orange, in: RoundedRectangle(cornerRadius: 14))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("ingredient.add")
    }
  }

  private var searchField: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 19))
        .foregroundColor(QFTheme.secondary)
        .frame(width: 19, height: 19)
        .accessibilityHidden(true)
      TextField("搜索食材名称", text: $query)
        .font(.system(size: 14))
        .foregroundColor(QFTheme.text)
        .tint(QFTheme.orange)
        .focused($searchFocused)
        .submitLabel(.search)
        .onSubmit { searchFocused = false }
        .accessibilityLabel("搜索食材名称")
        .accessibilityIdentifier("ingredient.search")
      if !query.isEmpty && searchFocused {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(QFTheme.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("清除搜索")
      }
    }
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .frame(height: 44)
    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).stroke(QFTheme.border, lineWidth: 1))
  }

  private var discoveryEntries: some View {
    HStack(spacing: 12) {
      QFIngredientDiscoveryButton(
        title: "食材大全", subtitle: "分类查找，认识食材", symbol: "book.closed",
        background: QFTheme.paleGreen, accent: QFTheme.green
      ) { showUnavailable("食材大全") }
      QFIngredientDiscoveryButton(
        title: "食材组合推荐", subtitle: "选食材，看看能做什么", symbol: "circle",
        background: Color(hex: 0xFFF0E7), accent: QFTheme.orange
      ) { showUnavailable("食材组合推荐") }
    }
  }

  private var inventorySegment: some View {
    Picker("食材状态", selection: $shopping) {
      Text("家里已有 · 12").tag(false)
      Text("待采购 · 3").tag(true)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(4)
    .frame(height: 44)
    .background(Color(hex: 0xE9EDE2), in: RoundedRectangle(cornerRadius: 18))
    .accessibilityIdentifier("ingredient.segment")
  }

  private var nearDateNotice: some View {
    Button {
      showUnavailable("临期食材")
    } label: {
      HStack(spacing: 9) {
        Image(systemName: "clock")
          .font(.system(size: 17))
          .frame(width: 17, height: 17)
        Text("2 种食材临近标注日期")
          .font(.system(size: 12))
        Spacer(minLength: 0)
        Text("查看  ›")
          .font(.system(size: 12, weight: .medium))
      }
      .foregroundColor(Color(hex: 0xA16A17))
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .background(Color(hex: 0xFFF4DC), in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("2 种食材临近标注日期，查看")
  }

  private var categoryStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(categories, id: \.self) { category in
          QFIngredientCategoryButton(
            name: category, selected: selectedCategory == category
          ) { selectedCategory = category }
        }
      }
    }
    .frame(height: 32)
    .accessibilityIdentifier("ingredient.categories")
  }

  private var listHeader: some View {
    HStack(spacing: 8) {
      Text(shopping ? "待采购食材" : "我的食材")
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(QFTheme.text)
      Spacer(minLength: 0)
      Button {
        nearDateFirst.toggle()
      } label: {
        Text(shopping ? "预计 ¥16.20" : (nearDateFirst ? "临期优先  ﹀" : "默认排序  ﹀"))
          .font(.system(size: 12))
          .foregroundColor(QFTheme.secondary)
          .frame(minHeight: 24)
      }
      .buttonStyle(.plain)
      .disabled(shopping)
      .accessibilityLabel(shopping ? "预计花费16.20元" : (nearDateFirst ? "食材排序，临期优先" : "食材排序，默认排序"))
    }
  }

  private var ingredientList: some View {
    LazyVStack(spacing: 10) {
      ForEach(visibleIngredients) { ingredient in
        QFIngredientSampleCard(ingredient: ingredient, shopping: shopping) {
          showUnavailable("\(ingredient.name)管理")
        }
      }
      if visibleIngredients.isEmpty {
        VStack(spacing: 8) {
          Text("没有找到相关食材")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(QFTheme.text)
          Text("换个名称或分类试试")
            .font(.system(size: 12))
            .foregroundColor(QFTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 30)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
      }
    }
    .accessibilityIdentifier("ingredient.list")
  }

  private func showUnavailable(_ title: String) {
    searchFocused = false
    unavailableTitle = title
    showsUnavailable = true
  }
}

private struct QFIngredientDiscoveryButton: View {
  let title: String
  let subtitle: String
  let symbol: String
  let background: Color
  let accent: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 4) {
          Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(QFTheme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.76)
          Spacer(minLength: 0)
          Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 21, height: 23)
            .foregroundColor(accent)
            .overlay(alignment: .topLeading) {
              if symbol == "circle" {
                Image(systemName: "circle")
                  .resizable()
                  .scaledToFit()
                  .frame(width: 19, height: 19)
                  .foregroundColor(accent)
                  .offset(x: 7, y: 9)
              }
            }
            .padding(.top, 4)
        }
        Spacer(minLength: 0)
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundColor(accent)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
      .padding(.leading, 14)
      .padding(.trailing, 13)
      .padding(.vertical, 13)
      .frame(maxWidth: .infinity)
      .frame(height: 74)
      .background(background, in: RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityHint(subtitle)
  }
}

private struct QFIngredientCategoryButton: View {
  let name: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(name)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(selected ? QFTheme.green : QFTheme.secondary)
        .padding(.horizontal, 15)
        .frame(height: 32)
        .background(selected ? QFTheme.paleGreen : Color.white, in: Capsule())
        .overlay(Capsule().stroke(selected ? Color.clear : QFTheme.border, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(name)
    .accessibilityIdentifier("ingredient.category.\(name)")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct QFIngredientSampleCard: View {
  let ingredient: QFIngredientSample
  let shopping: Bool
  let onMore: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      QFIngredientArtwork(ingredient: ingredient)
      VStack(alignment: .leading, spacing: 9) {
        Text(ingredient.name)
          .font(.system(size: 17, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Text(ingredient.amount)
          .font(.system(size: 12))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
      .foregroundColor(QFTheme.text)
      .frame(maxWidth: .infinity, alignment: .leading)
      status
    }
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .padding(.vertical, 13)
    .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(QFTheme.border, lineWidth: 1))
  }

  private var status: some View {
    VStack(alignment: .trailing, spacing: 0) {
      HStack(spacing: 5) {
        if !shopping {
          Text(ingredient.storage)
            .font(.system(size: 10.5))
            .foregroundColor(QFTheme.green)
            .frame(width: 42, height: 22)
            .background(QFTheme.paleGreen, in: Capsule())
        }
        Button(action: onMore) {
          Image(systemName: "ellipsis")
            .font(.system(size: 18))
            .foregroundColor(QFTheme.secondary)
            .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ingredient.name)，更多操作")
      }
      Text(shopping ? ingredient.price : ingredient.date)
        .font(.system(size: 10.5))
        .foregroundColor(
          shopping ? QFTheme.orange : (ingredient.near ? Color(hex: 0xA66C1E) : QFTheme.secondary)
        )
        .lineLimit(1)
    }
    .frame(width: 92, alignment: .trailing)
  }
}

private struct QFIngredientArtwork: View {
  let ingredient: QFIngredientSample

  private var image: UIImage {
    let fallbackByCategory = [
      "肉蛋": "meat", "蔬菜": "vegetable", "奶制品": "milk", "水果": "fruit",
      "谷物": "grain", "水产": "seafood", "菌藻": "mushroom", "调味": "seasoning",
    ]
    let fallback = fallbackByCategory[ingredient.category] ?? "generic"
    return UIImage(named: "ingredient-\(ingredient.id)")
      ?? UIImage(named: "ingredient-\(fallback)")
      ?? UIImage(named: "ingredient-generic")
      ?? UIImage()
  }

  private var background: Color {
    if ingredient.id == "milk" { return Color(hex: 0xE7F1F5) }
    if ingredient.id == "egg" { return Color(hex: 0xFFF0D9) }
    return QFTheme.paleGreen
  }

  var body: some View {
    Image(uiImage: image)
      .resizable()
      .scaledToFit()
      .frame(width: 36, height: 36)
      .frame(width: 48, height: 48)
      .background(background, in: RoundedRectangle(cornerRadius: 12))
      .accessibilityHidden(true)
  }
}

private struct QFIngredientSample: Identifiable {
  let id: String
  let name: String
  let category: String
  let amount: String
  var storage = ""
  var date = ""
  var near = false
  var price = ""

  static let inventory = [
    QFIngredientSample(
      id: "broccoli", name: "西兰花", category: "蔬菜", amount: "1 棵 · 约 300 克",
      storage: "冷藏", date: "9月10日到期", near: true),
    QFIngredientSample(
      id: "milk", name: "鲜牛奶", category: "奶制品", amount: "1 盒 · 1 升",
      storage: "冷藏", date: "9月11日到期", near: true),
    QFIngredientSample(
      id: "egg", name: "鸡蛋", category: "肉蛋", amount: "6 个",
      storage: "冷藏", date: "9月18日到期"),
    QFIngredientSample(
      id: "tomato", name: "番茄", category: "蔬菜", amount: "500 克",
      storage: "冷藏", date: "9月15日到期"),
    QFIngredientSample(
      id: "chicken", name: "鸡胸肉", category: "肉蛋", amount: "400 克",
      storage: "冷冻", date: "10月9日到期"),
    QFIngredientSample(
      id: "beef", name: "牛腩", category: "肉蛋", amount: "500 克",
      storage: "冷冻", date: "10月9日到期"),
    QFIngredientSample(id: "rice", name: "大米", category: "谷物", amount: "2,000 克", storage: "常温"),
    QFIngredientSample(id: "flour", name: "面粉", category: "谷物", amount: "500 克", storage: "常温"),
    QFIngredientSample(id: "oil", name: "食用油", category: "调味", amount: "500 毫升", storage: "常温"),
    QFIngredientSample(id: "seaweed", name: "紫菜", category: "菌藻", amount: "20 克", storage: "常温"),
    QFIngredientSample(
      id: "carrot", name: "胡萝卜", category: "蔬菜", amount: "300 克",
      storage: "冷藏", date: "9月20日到期"),
    QFIngredientSample(
      id: "apple", name: "苹果", category: "水果", amount: "2 个",
      storage: "冷藏", date: "9月20日到期"),
  ]

  static let shopping = [
    QFIngredientSample(
      id: "tomato", name: "番茄", category: "蔬菜", amount: "500 克", price: "预计 ¥6.00"),
    QFIngredientSample(id: "egg", name: "鸡蛋", category: "肉蛋", amount: "6 个", price: "预计 ¥7.20"),
    QFIngredientSample(
      id: "salt", name: "盐", category: "调味", amount: "1 袋 · 500 克", price: "预计 ¥3.00"),
  ]
}
