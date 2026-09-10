# 欢迎、登录及安全通知 UI

此目录只包含 Objective-C/UIKit 本地界面，不使用网络、身份认证 SDK、账号接口或 Token。完整正式协议尚未提供；协议入口打开可关闭的只读展示说明，不生成正式协议文本。Apple 按钮仅展示本地 UI，未调用 Apple 授权。

## 集成

- 将本目录三个 `.m` 加入 App target，引用 `QFWelcomeViewController.h`、`QFLoginViewController.h`。
- 依赖 `../../DesignSystem/QFDesign.h` 中公共函数。需提供图片资产 `chef-icon`、`chef-logo`、`dish-dimsum`、`dish-noodles`、`dish-rice`、`dish-vegetables`。
- 欢迎页 `onCompleted` 只在安全通知已勾选并点击“同意并继续”后调用一次。App 启动逻辑负责决定 Debug 每次显示、Release 仅首次安装显示，以及保存首次引导完成标记；欢迎页内部不读写该标记。
- `QFLoginViewController.onClose` 交给宿主关闭；未设置时默认 dismiss。

## 交互与状态

- 欢迎共 5 页，可左右滑动或点击圆点；每页纵向空间不足时可滚动。前 4 页没有底部进入按钮，末页显示“进入 APP”。顶部“跳过介绍”和末页按钮都打开安全通知。此行为按最新实现要求覆盖旧 H5“首次立即弹窗、跳过先跳到第五页”说明。
- 通知勾选默认 false。正文可滚动，勾选、继续和暂不同意保持可操作；点击背景不会确认或关闭。阅读协议返回保留暂选状态。“暂不同意”返回原页并保持欢迎未完成。
- 登录页仅含快速登录、Apple 登录。已勾选后点击任一按钮仅弹出“登录暂未开放”。未勾选时先弹安全通知，暂存所选方法于内存；只有勾选且点击“同意并继续”才消费一次。选择通知中的复选框本身不会触发登录。
- 登录页与通知内的勾选/取消同步更新 `NSUserDefaults` 的 `qfyp.login.consent` 字典。取消通知会保存 false 并清空待执行动作；进程重启仅恢复选择，不恢复动作。欢迎暂选状态与登录选择独立。
- 缓存包含 `schemaVersion: 1`、`loginAgreementChecked`、`updatedAt`、`uiOnly: true` 和 `uiDocumentRevision: ui-placeholder-v1`。缺失、损坏或 UI 文档修订不匹配时按未勾选处理。正式协议版本未知，两个正式版本字段省略，因为 NSUserDefaults 不接受 NSNull。当前数据仅代表 UI 选择，不是认证凭证或正式签署记录；正式文档接入时须更新修订并要求重新选择。
- 所有导航与协议阅读都在本机进行，通知不通过手势下拉关闭，减少动态效果设置会取消页面和主要模态过渡。

## 自动化标识

`welcome.skip`、`welcome.enter`、`welcome.pages`、`welcome.page.1` 到 `welcome.page.5`、`login.quick`、`login.apple`、`login.agreement`、`login.close`、`notice.agreement`、`notice.continue`、`notice.decline`、`agreement.back`、`agreement.document`。

欢迎的横向滚动视图预先建立所有页面；检查末页按钮是否可见时应使用 `isHittable`，因为未滚到末页时该按钮仍存在于视图树中。勾选按钮 accessibilityValue 为“已勾选”或“未勾选”。

## 已做验证

已使用本机 iPhone Simulator SDK 对三个实现文件运行 ARC / iOS 15 target 的 Objective-C 语法检查。宿主工程负责完整构建及模拟器视觉、交互验收。建议验收路径：首次未勾选 → 继续禁用 → 查看协议并返回 → 勾选 → 同意继续；登录取消后再次进入和 App 重启均恢复 false；登录同意后重启仅恢复勾选，绝不自动执行待登录动作。
