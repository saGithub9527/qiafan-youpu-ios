# 恰饭有谱 · iOS 客户端

Swift + SwiftUI 为主、UIKit 按需补充的原生 iPhone 工程，采用 SwiftUI App 生命周期。本轮保留五页欢迎、协议通知、登录，以及「菜谱 / 计划 / 食材 / 我的」四个一级主页面 UI。

页面使用本地展示样例，没有 API、真实登录、Apple 授权或 Token。具体边界见 [实现范围](docs/实现范围.md)。原 OC/UIKit 实现保存在 Git 标签 `oc-uikit-baseline`。

## 打开与构建

工程配置为 iOS 15.0 起、iPhone 竖屏。使用 Xcode 26.3 的 Swift 6 编译器，当前 `SWIFT_VERSION = 5.0`，即 Swift 5 语言模式。

```bash
cd '/Users/talka/Documents/恰饭有谱/客户端/qiafan-youpu-ios'
open QiafanYoupu.xcodeproj
```

选择 `QiafanYoupu` scheme 和已安装的 iPhone 模拟器，然后运行。真机运行需配置可用开发团队与签名。

命令行构建模拟器版本：

```bash
xcodebuild \
  -project QiafanYoupu.xcodeproj \
  -scheme QiafanYoupu \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

将 `Debug` 改为 `Release` 可构建 Release 配置。`project.yml` 是 XcodeGen 配置；修改 target 或构建设置后执行 `xcodegen generate --spec project.yml` 同步工程。日常打开现有 `.xcodeproj` 不需要 XcodeGen。

## 启动与 Debug 预览

Debug 默认每次显示欢迎；Release 仅在本地引导尚未完成时显示。勾选安全通知并点击“同意并继续”后才写入 `qfyp.onboarding.completed`。暂不同意不会完成引导。“我的”默认未登录，登录页由根容器展示和关闭。

以下参数仅在 Debug 生效，在 Edit Scheme → Run → Arguments 中设置：

| 参数 | 用途 |
| --- | --- |
| `-QFResetUIState` | 清除本 App 的持久化 UserDefaults |
| `-QFSkipWelcome` | 本次启动跳过欢迎，不写引导完成标记 |
| `-QFStartTab recipe` | 指定初始页；可选 `recipe`、`plan`、`ingredient`、`profile` |
| `-QFPreviewSignedIn` | 仅预览“我的”登录态样式，不创建真实身份 |

应用已安装且停止运行时，可在已启动的模拟器中预览：

```bash
xcrun simctl launch booted com.talka.qiafanyoupu \
  -QFSkipWelcome -QFStartTab profile -QFPreviewSignedIn
```

规则和参数在 `QiafanYoupu/App/QFLaunchPolicy.swift`，App 入口、Tab 容器和登录展示在 `QiafanYoupu/App/QiafanYoupuApp.swift`。

## 目录与素材

```text
QiafanYoupu.xcodeproj/          工程入口与共享 scheme
project.yml                    XcodeGen 配置
QiafanYoupu/
  App/                         SwiftUI App、根视图、Tab、启动规则
  DesignSystem/QFTheme.swift    语义颜色与 Color(hex:)
  Features/Auth/               欢迎、登录、协议通知与 UI 选择缓存
  Features/Recipe/             菜谱一级页
  Features/Plan/               计划一级页
  Features/Ingredient/         食材一级页
  Features/Profile/            我的一级页
  Resources/                   本地 Assets、素材来源、隐私清单
QiafanYoupuTests/               启动策略测试
QiafanYoupuUITests/             欢迎、协议、Tab、登录及 Release 流程测试
docs/                          实现范围、组件选型和验证记录
```

图片复制自用户已确认的设计档案，映射见 [素材来源](QiafanYoupu/Resources/ASSET-SOURCES.md)。页面使用本地 Assets、SF Symbols 和 SwiftUI 图形；食材使用已确认的 Emoji PNG，并按分类回退到通用图。图片随 App 打包。

## 依赖与后续开发

第三方依赖统一使用 Xcode 内置 Swift Package Manager（SPM）。当前页面由原生 SwiftUI 完成，尚无外部包，因此没有 `Package.resolved`。CocoaPods、Pods 与 Masonry 已移除。

将来新增包时，先核查 SPM 支持、维护状态、平台兼容与许可证，固定版本并提交 Xcode 生成的 `Package.resolved`，同步更新许可证记录。UIKit 仅在具体系统能力或组件确有需要时通过薄适配层补充。现行依据见 [UI 组件选型](docs/UI组件选型.md)。

真实协议、认证、会话、网络和业务缓存按后续确认范围接入。后台是独立 Vue 工程；当前客户端无需启动后台或 Java 服务。

测试入口为 Product → Test。`QiafanYoupu` scheme 使用 Debug；`QiafanYoupu-ReleaseUI` 用于真实 Release 启动流程，首次安装场景需先卸载所选模拟器中的 App，再仅运行 `QFReleaseWelcomeUITests`。实际执行结果单独写入 [验证记录](docs/验证记录.md)，历史 OC 记录不代表 SwiftUI 版本已通过相同检查。
