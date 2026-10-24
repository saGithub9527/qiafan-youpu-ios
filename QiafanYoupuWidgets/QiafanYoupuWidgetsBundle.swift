import SwiftUI
import WidgetKit

@main
struct QiafanYoupuWidgetsBundle: WidgetBundle {
  @WidgetBundleBuilder
  var body: some Widget {
    QFNextMealWidget()
    if #available(iOS 16.1, *) {
      QFMealLiveActivity()
    }
  }
}
