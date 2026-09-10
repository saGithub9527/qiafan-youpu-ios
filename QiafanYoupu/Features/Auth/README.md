# 欢迎、登录及安全通知 UI

本目录采用原生 SwiftUI，包含 `QFWelcomeView.swift`、`QFLoginView.swift` 和 `QFAuthViews.swift`。没有网络、认证 SDK、真实账号或 Token；Apple 按钮仅为本地 UI。

## 集成接口

- `QFWelcomeView(onCompleted:)`：完成协议通知门禁后回调一次。根视图保存引导完成标记，并进入四个主页面。
- `QFLoginView(onClose:)`：关闭登录时回调；登录页由 `QiafanYoupuApp.swift` 中的根容器通过 `fullScreenCover` 展示。
- `QFAuthViews.swift`：共享协议选择行、安全通知、协议说明页、按钮样式及 `QFAuthConsentStore`。
- 依赖 `DesignSystem/QFTheme.swift` 和本地 Assets：`chef-icon`、`chef-logo`、`dish-dimsum`、`dish-noodles`、`dish-rice`、`dish-vegetables`。无需外部包。

启动策略在 `App/QFLaunchPolicy.swift`：Debug 默认每次显示欢迎，Release 仅在引导尚未完成时显示。页面内不自行决定 Debug/Release 行为。

## 交互与状态边界

欢迎使用原生分页 `TabView` 展示五页，可滑动或点击圆点。顶部“跳过介绍”和末页“进入 APP”都先打开安全通知；前四页没有进入按钮。通知以 SwiftUI 叠层显示，背景点击不会确认或关闭；选择“暂不同意”返回原页，保持引导未完成。

协议默认未勾选。阅读页通过 `fullScreenCover` 展示并保留暂选状态；正式正文尚未提供，页面只展示说明，不生成正式协议。通知的继续按钮只在勾选后可用。

登录页与通知通过 `Binding` 同步选择，并写入 `qfyp.login.consent`。缓存包含 schema、更新时间、UI 文档修订及 `uiOnly` 标记；缺失、损坏或修订不匹配时按未勾选处理。欢迎通知的暂选状态与登录选择独立。

未勾选时，所选登录方式只暂存在内存；勾选并点击“同意并继续”后消费一次，显示“登录暂未开放”。暂不同意会保存 false 并清空动作，关闭或重启不会恢复待执行登录。当前选择不是正式签署记录或身份凭证；正式协议接入时需更新修订并重新要求选择。

`accessibilityReduceMotion` 用于欢迎切页与通知过渡。无障碍标识保留：`welcome.skip`、`welcome.enter`、`welcome.pages`、`welcome.page.1` 至 `welcome.page.5`、`login.quick`、`login.apple`、`login.agreement`、`login.close`、`notice.agreement`、`notice.continue`、`notice.decline`、`agreement.back`、`agreement.document`。勾选控件的值为“已勾选”或“未勾选”。

测试运行方式见 [项目 README](../../../README.md)，实际执行结果单独记录。历史 OC 语法检查不作为当前 SwiftUI 页面验收结果。
