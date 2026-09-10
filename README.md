# 恰饭有谱 · iOS 客户端

Objective-C + UIKit 原生 iPhone 工程，使用 Auto Layout 和本地素材。本轮只实现五页欢迎、协议通知、登录页面，以及底部「菜谱 / 计划 / 食材 / 我的」四个一级主页面 UI。

所有列表和数值均为本地展示样例；没有 API、真实登录、Apple 授权、Token 或服务端连接。快速登录和 Apple 登录按钮完成协议 UI 流程后只显示“登录暂未开放”。具体范围见 [实现范围](docs/实现范围.md)。

## 打开与构建

工程配置为 iOS 15.0 起、iPhone 竖屏、ARC，`project.yml` 的 Xcode 版本为 26.3。当前没有第三方客户端依赖，无需安装 CocoaPods 或下载 Swift Package。

```bash
cd '/Users/talka/Documents/恰饭有谱/客户端/qiafan-youpu-ios'
open QiafanYoupu.xcodeproj
```

在 Xcode 中选择 `QiafanYoupu` scheme 和一个已安装的 iPhone 模拟器，然后运行。真机运行需要在 Signing & Capabilities 中配置可用的开发团队和签名。

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

将 `Debug` 改为 `Release` 可构建 Release 配置。`project.yml` 是 XcodeGen 工程配置；修改 target 或构建设置后，使用 `xcodegen generate --spec project.yml` 同步 `.xcodeproj`。只打开现有工程不需要 XcodeGen。

## 欢迎与 Debug 预览

- Debug 默认每次启动都显示欢迎，不受本地完成标记影响。
- Release 只在 `qfyp.onboarding.completed` 尚未完成时显示欢迎；勾选安全通知并点击“同意并继续”后写入完成标记，后续启动进入主页面。暂不同意不会完成引导。
- “我的”默认显示未登录界面，点击“去登录”打开登录页。关闭后回到“我的”。

以下参数只在 Debug 生效，可在 Xcode 的 Edit Scheme → Run → Arguments 中设置：

| 启动参数 | 用途 |
| --- | --- |
| `-QFResetUIState` | 清除本 App 的持久化 UserDefaults，重新检查引导和协议默认状态 |
| `-QFSkipWelcome` | 本次启动直接进入四个 Tab，不写入引导完成标记 |
| `-QFStartTab recipe` | 初始页设为菜谱；可改为 `plan`、`ingredient`、`profile`，通常配合跳过欢迎使用 |
| `-QFPreviewSignedIn` | 仅展示“我的”登录态样式；不会登录、生成凭证或开放业务功能 |

应用已安装到并正在使用某个模拟器时，可先停止 App，再用以下命令查看“我的”登录态样式：

```bash
xcrun simctl launch booted com.talka.qiafanyoupu \
  -QFSkipWelcome -QFStartTab profile -QFPreviewSignedIn
```

参数实现位于 `App/QFRootViewController.m` 和 `Features/Profile/QFProfileViewController.m`，欢迎策略集中在 `App/QFLaunchPolicy.m`。

## 目录与素材

```text
QiafanYoupu.xcodeproj/          可直接打开的 Xcode 工程与共享 scheme
project.yml                    XcodeGen 配置
QiafanYoupu/
  App/                         启动、欢迎策略、自定义底部 Tab 容器
  DesignSystem/                颜色、字体、布局、卡片和公共提示
  Features/Auth/               五页欢迎、登录、协议通知与本地选择缓存
  Features/Recipe/             菜谱一级页
  Features/Plan/               计划一级页
  Features/Ingredient/         食材一级页
  Features/Profile/            我的一级页
  Resources/                   Assets、素材来源、隐私清单
QiafanYoupuTests/               欢迎启动策略测试
QiafanYoupuUITests/             欢迎、协议、Tab 与登录 UI 流程测试
docs/实现范围.md                 本轮范围与后续接入边界
```

Logo、App 图标、默认菜谱插画、头像与食材图片复制自用户已确认的本地设计档案，映射见 [素材来源](QiafanYoupu/Resources/ASSET-SOURCES.md)。界面还使用系统 SF Symbols 和 UIKit 绘制的装饰元素；食材使用已确认的 Emoji PNG，缺少精确图时按食材分类使用通用图。图片随 App 打包，不在线下载。

测试入口为 Xcode 的 Product → Test。默认 `QiafanYoupu` scheme 运行 Debug 单元与 UI 测试；`QiafanYoupu-ReleaseUI` 专供真实 Release 启动验收，不启用 Debug 绕过或符号导出。Release 用例需先卸载所选模拟器中的本 App，再只执行 `QFReleaseWelcomeUITests`，否则不是全新安装。运行结果见 [验证记录](docs/验证记录.md)。

## 后续开发边界

后续按已确认页面逐项加入详情、编辑、真实数据与账号功能。网络层、Repository、Session、Keychain、Apple 授权和业务缓存均尚未接入；正式协议内容及版本也需另行提供。欢迎完成标记和协议 UI 勾选不能用作认证状态或正式签署记录。

后台是独立工程，位于 `../../后台/qiafan-youpu-admin/`，当前只有品牌空白壳，其运行方式见后台 README。客户端无需启动后台或 Java 服务。

`.gitignore` 已排除构建产物、用户 Xcode 状态、日志、环境文件和常见签名密钥；不要将凭证或私钥加入仓库。
