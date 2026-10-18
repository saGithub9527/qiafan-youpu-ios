# 账号与隐私：系统权限入口（2026-10-09）

`06-我的/页面行为说明.json` 的 `settings.accountPrivacy` 列出“相册和通知等权限管理”，但该设计文件标注为 UI 演示状态，没有定义新的隐私选择、账号注销的身份核验或数据清除合同。设计 RAG 当前没有账号与隐私页的 baseline；本次只在已有账号与隐私页增加系统权限入口，不调整设置页的固定布局。

入口使用 UIKit 的 `UIApplication.openSettingsURLString` 打开本应用的系统设置。iOS 系统负责实际授权及更改；此处不伪造通知或相机权限的应用内开关，也不在打开页面时触发权限弹窗。图片选取当前使用 `PHPickerViewController`，不要求整库照片读取权限，因此不增加“相册已授权”的假状态。通知偏好仍由应用原有设置管理，与 iOS 系统通知权限分别生效。

官方依据：

- [UIApplication.openSettingsURLString](https://developer.apple.com/documentation/uikit/uiapplication/opensettingsurlstring)
- [UNNotificationSettings](https://developer.apple.com/documentation/usernotifications/unnotificationsettings)
- [Apple PhotoKit 照片选择器示例：使用选择器无需申请相册权限](https://developer.apple.com/documentation/PhotoKit/selecting-photos-and-videos-in-ios)

验证：`validate_localizations.py --write-source` 覆盖 1172 条源字符串、8 份外置语言资源；Debug iOS Simulator 通用目标构建退出 0。本次没有实际打开系统设置做模拟器或真机交互验收。账号注销及隐私选择仍需明确具体选择项、身份再验证、共享家庭/投稿/账单数据的处理和保留边界，再进行跨端实现及协议更新。
