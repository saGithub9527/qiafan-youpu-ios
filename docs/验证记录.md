# SwiftUI 迁移验证记录

日期：2026-09-10。工具 Xcode 26.3，Swift 编译器使用 Swift 5 语言模式，最低部署 iOS 15.0。当前验证运行于 iOS 26.3 模拟器；未在 iOS 15 运行时/真机验收，未做签名归档或上传。

## 已完成

- Debug / Release 模拟器编译通过。
- `SwiftMigrationDebug.xcresult`：9 个单元测试及 3 个 UI 流程通过；Release 专用用例在 Debug 按配置跳过。
- `SwiftKeyboardRegression.xcresult`：补充的键盘与 Tab 切换回归通过。
- `SwiftMigrationRelease.xcresult`：全新安装后首次引导及再次启动测试通过；Release 忽略 Debug 跳过、重置与登录态预览参数。共 9 个单元测试、5 个 UI 流程测试通过。
- 人工核对 8 张模拟器截图：欢迎第一页、末页、安全通知、登录、四个一级页。截图位于 `预览/SwiftUI/`（本地，不提交 Git）。

## 验证范围

1. Debug 每次启动显示欢迎；五页可滑动，只有末页显示进入按钮。
2. 安全通知默认未勾选，继续按钮不可用；勾选才可进入主页面。
3. 登录未勾选时弹通知，暂不同意保持未勾选；勾选/取消选择均可跨进程重启保存。
4. 旧 OC 字典格式的协议记录可读取；缺失、错误类型、损坏及旧修订回退未勾选。单元测试使用独立 UserDefaults suite，不修改真实 UI 选择。
5. 四个 Tab 显示与选中状态；“我的”打开、关闭登录；登录操作仅显示“登录暂未开放”。
6. Release 全新安装显示欢迎；完成后重启直接进入主页面，不接受 Debug 绕过参数。
7. 食材搜索后切到计划，键盘消失；切回食材仍保留搜索内容且不自动弹键盘。

## 产物与限制

测试结果位于工程 `build/` 下；日志位于 `/tmp/qiafan-swift-debug-tests.log`、`/tmp/qiafan-swift-keyboard-tests.log`、`/tmp/qiafan-swift-release-tests.log`。构建产物与日志均不提交 Git。

最后清理了测试代码中 Release 条件编译的不可达代码警告，重新执行 Release build-for-testing，日志为 `/tmp/qiafan-swift-release-final-build.log`；未改动业务行为。最终构建没有 Swift 代码警告。Xcode 的 App Intents 元数据处理器提示未引入 AppIntents 而跳过提取；应用当前没有该能力。部分模拟器测试日志含系统私有框架重复类/运行测量消息，本轮已完成测试未因此失败。

界面数据仍为本地样例；没有网络、真实认证、Apple 授权或 Token。正式协议内容、真实业务及签名发布需在后续对应阶段验收。未测试过的系统版本或真机不写作已通过。

旧 OC / CocoaPods 验证已移到 [历史记录](历史-OC验证记录.md)，不作为 SwiftUI 实现证据。
