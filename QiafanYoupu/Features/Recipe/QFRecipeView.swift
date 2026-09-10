import SwiftUI

struct QFRecipeView: View {
  @State private var selectedCategory = "推荐"
  @State private var categoryScrollReset = 0
  @State private var unavailableTitle = ""
  @State private var showsUnavailable = false

  private let categories = [
    "推荐", "早餐", "家常菜", "快手菜", "肉类", "素菜", "海鲜", "小吃", "烘焙", "甜品", "饮品",
  ]

  private var visibleRecipes: [QFRecipeSample] {
    QFRecipeSample.all.filter {
      selectedCategory == "推荐" || $0.categories.contains(selectedCategory)
    }
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 0) {
        categoryHeader
          .padding(.bottom, 7)
        filters
          .padding(.bottom, 8)
        sectionHeader
          .padding(.bottom, 6)
        recipeList
      }
      .padding(.horizontal, 20)
      .padding(.top, 14)
      .padding(.bottom, 24)
    }
    .background(Color(hex: 0xF5F6F8).ignoresSafeArea())
    .alert(unavailableTitle, isPresented: $showsUnavailable) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text("该功能暂未开放")
    }
  }

  private var categoryHeader: some View {
    HStack(spacing: 8) {
      QFRecipeCategoryStrip(
        categories: categories,
        selected: $selectedCategory,
        reset: categoryScrollReset
      )
      Image(systemName: "chevron.right")
        .font(.system(size: 12))
        .foregroundColor(QFTheme.secondary)
        .frame(width: 10, height: 15)
        .accessibilityHidden(true)
      Button {
        showUnavailable("搜索菜谱")
      } label: {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 20))
          .foregroundColor(QFTheme.text)
          .frame(width: 40, height: 40)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("搜索菜谱")
      .accessibilityIdentifier("recipe.search")
    }
  }

  private var filters: some View {
    HStack(spacing: 6) {
      QFRecipeFilterButton(name: "国家", value: "全球") { showUnavailable("国家筛选") }
      QFRecipeFilterButton(name: "口味", value: "不限") { showUnavailable("口味筛选") }
      QFRecipeFilterButton(name: "菜系", value: "全部") { showUnavailable("菜系筛选") }
      QFRecipeFilterButton(name: "评分", value: "不限") { showUnavailable("评分筛选") }
    }
  }

  private var sectionHeader: some View {
    HStack(spacing: 10) {
      Text(selectedCategory == "推荐" ? "为你推荐" : selectedCategory)
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(QFTheme.text)
      Text("\(visibleRecipes.count) 道菜")
        .font(.system(size: 12))
        .foregroundColor(QFTheme.secondary)
      Spacer(minLength: 0)
      Button {
        selectedCategory = "推荐"
        categoryScrollReset += 1
      } label: {
        Text("清空筛选")
          .font(.system(size: 12))
          .foregroundColor(QFTheme.secondary)
          .frame(minHeight: 28)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("recipe.clearFilters")
    }
  }

  private var recipeList: some View {
    LazyVStack(spacing: 12) {
      ForEach(visibleRecipes) { recipe in
        QFRecipeSampleCard(
          recipe: recipe,
          onOpen: { showUnavailable(recipe.name) },
          onBookmark: { showUnavailable("收藏菜谱") }
        )
      }
      if visibleRecipes.isEmpty {
        VStack(spacing: 8) {
          Text("还没有找到相关菜谱")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(QFTheme.text)
          Text("换个分类，发现更多好味道")
            .font(.system(size: 12))
            .foregroundColor(QFTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
      }
    }
    .accessibilityIdentifier("recipe.list")
  }

  private func showUnavailable(_ title: String) {
    unavailableTitle = title
    showsUnavailable = true
  }
}

private struct QFRecipeCategoryStrip: View {
  let categories: [String]
  @Binding var selected: String
  let reset: Int

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 24) {
          ForEach(categories, id: \.self) { name in
            Button {
              selected = name
            } label: {
              Text(name)
                .font(
                  .system(
                    size: selected == name ? 20 : 17,
                    weight: selected == name ? .bold : .semibold
                  )
                )
                .foregroundColor(selected == name ? QFTheme.text : QFTheme.secondary)
                .padding(.bottom, 9)
                .frame(minWidth: 42)
                .frame(height: 40)
                .overlay(alignment: .bottom) {
                  Capsule()
                    .fill(selected == name ? QFTheme.orange : Color.clear)
                    .frame(width: 32, height: 3)
                    .padding(.bottom, 8)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityIdentifier("recipe.category.\(name)")
            .accessibilityAddTraits(selected == name ? .isSelected : [])
            .id(name)
          }
        }
        .padding(.trailing, 8)
      }
      .frame(height: 40)
      .accessibilityIdentifier("recipe.categories")
      .onChange(of: reset) { _ in
        withAnimation { proxy.scrollTo("推荐", anchor: .leading) }
      }
    }
  }
}

private struct QFRecipeFilterButton: View {
  let name: String
  let value: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .bottom, spacing: 3) {
        VStack(alignment: .leading, spacing: 4) {
          Text(name)
            .font(.system(size: 10.5))
            .foregroundColor(QFTheme.secondary)
          Text(value)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(QFTheme.text)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.down")
          .font(.system(size: 9))
          .foregroundColor(QFTheme.secondary)
          .frame(width: 9, height: 9)
      }
      .padding(.leading, 11)
      .padding(.trailing, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(QFTheme.border, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(name)，\(value)")
    .accessibilityIdentifier("recipe.filter.\(name)")
  }
}

private struct QFRecipeSampleCard: View {
  let recipe: QFRecipeSample
  let onOpen: () -> Void
  let onBookmark: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 14) {
        Image(recipe.asset)
          .resizable()
          .scaledToFill()
          .frame(width: 108, height: 108)
          .background(Color(hex: 0xFCF6EB))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .accessibilityHidden(true)
        details
      }
      .padding(.leading, 10)
      .padding(.trailing, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(recipe.name)，\(recipe.origin)，\(recipe.time)，评分\(recipe.rating)，\(recipe.saves)"
    )
    .accessibilityHint("查看菜谱详情")
    .overlay(alignment: .topTrailing) {
      Button(action: onBookmark) {
        Image(systemName: "bookmark")
          .font(.system(size: 17))
          .foregroundColor(QFTheme.secondary)
          .frame(width: 40, height: 40)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("收藏\(recipe.name)")
      .padding(6)
    }
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(recipe.name)
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(QFTheme.text)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.trailing, 22)
      Text(recipe.origin)
        .font(.system(size: 12))
        .foregroundColor(QFTheme.secondary)
      Text(recipe.time)
        .font(.system(size: 12))
        .foregroundColor(QFTheme.secondary)
      Color.clear.frame(height: 1)
      HStack(spacing: 5) {
        Text("★")
          .font(.system(size: 15))
          .foregroundColor(Color(hex: 0xE99A22))
        Text(recipe.rating)
          .font(.system(size: 13, weight: .medium))
          .foregroundColor(QFTheme.text)
        Spacer(minLength: 0)
        Text(recipe.saves)
          .font(.system(size: 11))
          .foregroundColor(QFTheme.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct QFRecipeSample: Identifiable {
  var id: String { name }
  let name: String
  let origin: String
  let time: String
  let rating: String
  let saves: String
  let asset: String
  let categories: [String]

  static let all = [
    QFRecipeSample(
      name: "番茄炖牛腩", origin: "中国 · 家常菜", time: "90 分钟 · 2 人份",
      rating: "4.9", saves: "2,386 收藏", asset: "dish-stew", categories: ["家常菜", "肉类"]),
    QFRecipeSample(
      name: "番茄罗勒意面", origin: "意大利 · 意式料理", time: "25 分钟 · 2 人份",
      rating: "4.8", saves: "1,624 收藏", asset: "dish-noodles", categories: ["快手菜", "素菜"]),
    QFRecipeSample(
      name: "泰式打抛鸡", origin: "泰国 · 泰式料理", time: "20 分钟 · 2 人份",
      rating: "4.9", saves: "3,108 收藏", asset: "dish-rice", categories: ["家常菜", "快手菜", "肉类"]),
    QFRecipeSample(
      name: "照烧三文鱼饭", origin: "日本 · 日式料理", time: "25 分钟 · 2 人份",
      rating: "4.8", saves: "2,041 收藏", asset: "dish-seafood", categories: ["快手菜", "海鲜"]),
  ]
}
