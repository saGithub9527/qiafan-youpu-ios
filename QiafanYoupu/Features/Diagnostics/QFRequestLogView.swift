#if DEBUG
  import SwiftUI

  @MainActor
  struct QFRequestLogView: View {
    @ObservedObject private var store: QFRequestLogStore
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: QFAppSession
    @State private var message: String?
    @State private var showMessage = false
    @State private var activeAction: DebugAction?

    private enum DebugAction {
      case reloadConfiguration
      case logout

      var title: String {
        switch self {
        case .reloadConfiguration: return "正在重取配置"
        case .logout: return "正在退出会话"
        }
      }
    }

    init(store: QFRequestLogStore? = nil) {
      self.store = store ?? .shared
    }

    var body: some View {
      NavigationView {
        VStack(spacing: 0) {
          if let error = store.storageError {
            Text(error)
              .font(.caption)
              .foregroundColor(.red)
              .padding(12)
          }
          if store.totalCount == 0 {
            emptyState
          } else {
            List(store.entries) { entry in
              NavigationLink {
                QFRequestLogDetailView(store: store, id: entry.id)
              } label: {
                QFRequestLogRow(entry: entry)
              }
              .listRowBackground(Color.white)
              .accessibilityIdentifier("diagnostics.request.\(entry.id.uuidString)")
            }
            .listStyle(.plain)
          }
          pagination
        }
        .background(QFTheme.background)
        .navigationTitle("接口日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarLeading) {
            Menu {
              Button("重新获取启动配置") { perform(.reloadConfiguration) }
              Button("查看沙盒日志目录") {
                message = QFCrashRecorder.shared.reportsDirectory.deletingLastPathComponent().path
                showMessage = true
              }
              if app.user != nil {
                Button("退出当前测试会话") { perform(.logout) }
              }
            } label: {
              HStack(spacing: 6) {
                if let action = displayedAction {
                  ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: QFTheme.orange))
                    .accessibilityHidden(true)
                  Text(action.title)
                } else {
                  Text("调试")
                }
              }
            }
            .disabled(actionsDisabled)
            .accessibilityIdentifier("diagnostics.menu")
          }
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("关闭") { dismiss() }
              .accessibilityIdentifier("diagnostics.requests.close")
          }
        }
      }
      .navigationViewStyle(.stack)
      .tint(QFTheme.orange)
      .onAppear { store.loadPage(store.page) }
      .alert("调试信息", isPresented: $showMessage) {
        Button("知道了", role: .cancel) {}
      } message: {
        Text(message ?? "")
      }
      .accessibilityIdentifier("diagnostics.requests")
    }

    private var displayedAction: DebugAction? {
      activeAction ?? (app.loadingConfiguration ? .reloadConfiguration : nil)
    }

    private var actionsDisabled: Bool {
      activeAction != nil || app.loadingConfiguration || app.isLoggingIn
    }

    private func perform(_ action: DebugAction) {
      guard !actionsDisabled else { return }
      activeAction = action
      Task {
        defer { activeAction = nil }
        switch action {
        case .reloadConfiguration:
          await app.loadConfiguration()
          if let error = app.configurationError {
            message = error
            showMessage = true
          }
        case .logout:
          do { try await app.logout() } catch {
            message = error.localizedDescription
            showMessage = true
          }
        }
      }
    }

    private var emptyState: some View {
      VStack(spacing: 12) {
        Image(systemName: "network")
          .font(.system(size: 30))
          .foregroundColor(QFTheme.secondary)
        Text("暂无请求日志")
          .font(.headline)
          .foregroundColor(QFTheme.text)
        Text("Debug 模式下，应用发起请求后会显示在这里。")
          .font(.subheadline)
          .foregroundColor(QFTheme.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(28)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pagination: some View {
      HStack(spacing: 12) {
        Button("上一页") { store.loadPage(store.page - 1) }
          .disabled(store.page == 0)
          .accessibilityIdentifier("diagnostics.requests.previousPage")
        Spacer(minLength: 0)
        VStack(spacing: 3) {
          Text("第 \(store.page + 1) / \(store.totalPages) 页")
            .font(.subheadline)
          Text("共 \(store.totalCount) 条 · 每页 \(store.pageSize) 条")
            .font(.caption2)
            .foregroundColor(QFTheme.secondary)
        }
        Spacer(minLength: 0)
        Button("下一页") { store.loadPage(store.page + 1) }
          .disabled(store.page + 1 >= store.totalPages)
          .accessibilityIdentifier("diagnostics.requests.nextPage")
      }
      .font(.subheadline)
      .padding(16)
      .background(Color.white)
    }
  }

  private struct QFRequestLogRow: View {
    let entry: QFRequestLogEntry

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          Text(entry.method)
            .font(.caption.bold())
            .foregroundColor(QFTheme.text)
          Text(QFRequestLogPresentation.status(entry))
            .font(.caption)
            .foregroundColor(QFRequestLogPresentation.color(entry.status))
          Spacer(minLength: 4)
          Text(entry.startedAt, style: .time)
            .font(.caption)
            .foregroundColor(QFTheme.secondary)
        }
        Text(entry.url)
          .font(.system(.caption, design: .monospaced))
          .foregroundColor(QFTheme.text)
          .lineLimit(2)
        if let duration = entry.duration {
          Text(String(format: "%.0f ms", duration * 1000))
            .font(.caption2)
            .foregroundColor(QFTheme.secondary)
        }
      }
      .padding(.vertical, 6)
    }
  }

  @MainActor
  private struct QFRequestLogDetailView: View {
    @ObservedObject var store: QFRequestLogStore
    let id: UUID
    @State private var entry: QFRequestLogEntry?

    var body: some View {
      ScrollView {
        if let entry {
          VStack(alignment: .leading, spacing: 16) {
            timeSection(entry)
            QFRequestLogField(title: "URL / 接口", value: "\(entry.method)\n\(entry.url)")
            QFRequestLogField(title: "请求参数", value: parameters(entry))
            QFRequestLogField(title: "请求头", value: headers(entry.requestHeaders))
            QFRequestLogField(title: "返回内容", value: response(entry))
          }
          .padding(16)
        } else {
          Text("这条日志已被轮转清理。")
            .foregroundColor(QFTheme.secondary)
            .padding(24)
        }
      }
      .background(QFTheme.background)
      .navigationTitle("请求详情")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear { entry = store.entry(id: id) }
      .onChange(of: store.revision) { _ in entry = store.entry(id: id) }
      .accessibilityIdentifier("diagnostics.request.detail")
    }

    private func timeSection(_ entry: QFRequestLogEntry) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("请求时间")
          .font(.headline)
        Text(entry.startedAt.formatted(date: .numeric, time: .complete))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
        Text(QFRequestLogPresentation.status(entry))
          .foregroundColor(QFRequestLogPresentation.color(entry.status))
        if let duration = entry.duration {
          Text(String(format: "耗时 %.0f ms", duration * 1000))
        }
      }
      .font(.subheadline)
      .foregroundColor(QFTheme.text)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(Color.white)
      .cornerRadius(12)
    }

    private func parameters(_ entry: QFRequestLogEntry) -> String {
      let query =
        URLComponents(string: entry.url)?.queryItems?.map {
          "\($0.name): \($0.value ?? "")"
        }.joined(separator: "\n") ?? ""
      let body = entry.requestBody.isEmpty ? "（无请求体）" : entry.requestBody
      return "Query\n\(query.isEmpty ? "（无查询参数）" : query)\n\nBody\n\(body)"
    }

    private func headers(_ headers: [String: String]) -> String {
      guard !headers.isEmpty else { return "（无）" }
      return headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    private func response(_ entry: QFRequestLogEntry) -> String {
      if entry.status == .inProgress { return "请求进行中，尚无返回内容。" }
      var parts = ["HTTP 状态码：\(entry.statusCode.map(String.init) ?? "无响应")"]
      if let error = entry.errorDescription { parts.append("错误：\(error)") }
      parts.append("响应头\n\(headers(entry.responseHeaders))")
      parts.append("Body\n\(entry.responseBody.isEmpty ? "（无响应体）" : entry.responseBody)")
      return parts.joined(separator: "\n\n")
    }
  }

  private struct QFRequestLogField: View {
    let title: String
    let value: String

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        Text(title)
          .font(.headline)
        Text(value)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .foregroundColor(QFTheme.text)
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.white)
      .cornerRadius(12)
    }
  }

  private enum QFRequestLogPresentation {
    static func status(_ entry: QFRequestLogEntry) -> String {
      switch entry.status {
      case .inProgress: return "进行中"
      case .succeeded: return "成功 · \(entry.statusCode ?? 0)"
      case .failed:
        return entry.statusCode.map { "失败 · \($0)" } ?? "请求失败"
      }
    }

    static func color(_ status: QFRequestLogStatus) -> Color {
      switch status {
      case .inProgress: return QFTheme.orange
      case .succeeded: return QFTheme.green
      case .failed: return .red
      }
    }
  }
#endif
