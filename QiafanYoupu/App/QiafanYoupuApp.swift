import SwiftUI

@main
struct QiafanYoupuApp: App {
  private let options = QFLaunchOptions()

  var body: some Scene {
    WindowGroup {
      QFRootView(options: options)
        .preferredColorScheme(.light)
        .tint(QFTheme.orange)
    }
  }
}

enum QFTab: String, CaseIterable, Identifiable {
  case recipe, plan, ingredient, profile
  var id: String { rawValue }

  var title: String {
    switch self {
    case .recipe: return "菜谱"
    case .plan: return "计划"
    case .ingredient: return "食材"
    case .profile: return "我的"
    }
  }

  var symbol: String {
    switch self {
    case .recipe: return "book.closed"
    case .plan: return "calendar.badge.checkmark"
    case .ingredient: return "basket"
    case .profile: return "person"
    }
  }
}

private struct QFRootView: View {
  let options: QFLaunchOptions
  @State private var showWelcome: Bool

  init(options: QFLaunchOptions) {
    self.options = options
    _showWelcome = State(initialValue: options.showWelcome)
  }

  var body: some View {
    Group {
      if showWelcome {
        QFWelcomeView {
          UserDefaults.standard.set(true, forKey: QFLaunchPolicy.completedKey)
          showWelcome = false
        }
      } else {
        QFMainTabsView(options: options)
      }
    }
    .foregroundColor(QFTheme.text)
    .background(QFTheme.background.ignoresSafeArea())
  }
}

private struct QFMainTabsView: View {
  let options: QFLaunchOptions
  @State private var selected: QFTab
  @State private var showLogin = false

  init(options: QFLaunchOptions) {
    self.options = options
    _selected = State(initialValue: options.initialTab)
  }

  var body: some View {
    // Keep each page mounted so switching tabs preserves local search and date selections.
    ZStack {
      page(.recipe) { QFRecipeView() }
      page(.plan) { QFPlanView() }
      page(.ingredient) { QFIngredientView(isActive: selected == .ingredient) }
      page(.profile) {
        QFProfileView(previewSignedIn: options.previewSignedIn) { showLogin = true }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
    .fullScreenCover(isPresented: $showLogin) {
      QFLoginView { showLogin = false }
        .preferredColorScheme(.light)
    }
  }

  private func page<Content: View>(_ tab: QFTab, @ViewBuilder content: () -> Content) -> some View {
    content()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .opacity(selected == tab ? 1 : 0)
      .allowsHitTesting(selected == tab)
      .accessibilityHidden(selected != tab)
  }

  private var tabBar: some View {
    HStack(spacing: 0) {
      ForEach(QFTab.allCases) { tab in
        Button {
          selected = tab
        } label: {
          VStack(spacing: 4) {
            Image(systemName: tab.symbol).font(.system(size: 22))
            Text(tab.title).font(.system(size: 11, weight: .medium))
          }
          .foregroundColor(selected == tab ? QFTheme.orange : QFTheme.secondary)
          .frame(maxWidth: .infinity, minHeight: 56)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected == tab ? [.isSelected] : [])
      }
    }
    .background(Color.white.ignoresSafeArea(edges: .bottom))
    .overlay(alignment: .top) { QFTheme.border.frame(height: 0.5) }
  }
}
