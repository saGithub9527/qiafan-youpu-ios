import SwiftUI

struct QFDiagnosticsAccess: ViewModifier {
  #if DEBUG
    @State private var shown = false
  #endif

  func body(content: Content) -> some View {
    #if DEBUG
      content.overlay(alignment: .bottomTrailing) {
        Button {
          shown = true
        } label: {
          Label("接口", systemImage: "network")
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .foregroundColor(.white).background(Color.black.opacity(0.8), in: Capsule())
        }
        .accessibilityLabel("打开 Debug 接口日志")
        .accessibilityIdentifier("diagnostics.open")
        .padding(.trailing, 12).padding(.bottom, 76)
      }
      .fullScreenCover(isPresented: $shown) { QFRequestLogView() }
    #else
      content
    #endif
  }
}
