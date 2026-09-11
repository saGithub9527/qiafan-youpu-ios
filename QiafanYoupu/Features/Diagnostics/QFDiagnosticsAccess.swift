import SnapKit
import UIKit

@MainActor
enum QFDiagnosticsPresenter {
  static func attach(
    to controller: UIViewController, app: QFAppSession, bottomInset: CGFloat = 76
  ) {
    #if DEBUG
      guard
        !controller.view.subviews.contains(where: {
          $0.accessibilityIdentifier == "diagnostics.open"
        })
      else { return }
      let button = UIButton(type: .system)
      var configuration = UIButton.Configuration.filled()
      configuration.title = "接口"
      configuration.image = UIImage(systemName: "network")
      configuration.imagePadding = 6
      configuration.baseForegroundColor = .white
      configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.8)
      configuration.cornerStyle = .capsule
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 10, leading: 12, bottom: 10, trailing: 12)
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
        var attributes = $0
        attributes.font = .systemFont(ofSize: 12, weight: .semibold)
        return attributes
      }
      button.configuration = configuration
      button.accessibilityLabel = "打开 Debug 接口日志"
      button.accessibilityIdentifier = "diagnostics.open"
      button.addAction(
        UIAction { [weak controller, weak app] _ in
          guard let controller, let app, controller.presentedViewController == nil else { return }
          let logs = QFRequestLogViewController(app: app)
          let navigation = UINavigationController(rootViewController: logs)
          navigation.modalPresentationStyle = .fullScreen
          controller.present(navigation, animated: true)
        }, for: .touchUpInside)
      controller.view.addSubview(button)
      button.snp.makeConstraints { make in
        make.trailing.equalTo(controller.view.safeAreaLayoutGuide).inset(12)
        make.bottom.equalTo(controller.view.safeAreaLayoutGuide).inset(bottomInset)
        make.height.greaterThanOrEqualTo(40)
      }
    #endif
  }
}
