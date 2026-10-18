# ACCOUNT-01 iOS 实现记录

- assignment_id：`QFYP-20260912-ACCOUNT01-IOS-A01`
- requirement_id：`ACCOUNT-01`
- 实现文件：`QiafanYoupu/Features/Profile/QFSettingsView.swift`
- 产品基线：`ACCOUNT-01-G1-BASELINE-v1`
- G1 评审：`PASS`，文件 SHA-256 `7ae94da4cb573367f28379cc0032e242c51efaa4e2cdbc4a75f59081b668ce7c`

## QFYP-20260912-ACCOUNT01-IOS-A02 技术返工

本增量依据 `ACCOUNT-01-G2技术评审.json`（SHA-256 `e88522ce12146104a3e635035c5ce4b29f2ec164c060c8beb2bc0e7ca74a7460`）限定修正三项：

- `userId` 仅在严格由 9 位 ASCII 数字组成时展示四项账号资料；否则清空并隐藏资料卡，显示统一“账号信息／暂时不可用”卡片，协议入口保持可用。
- 用户协议或隐私政策的 HTTPS URL 无效时，仅在对应内联正文去除空白后非空时打开内置正文；两者均不可用时显示“内容暂时不可用，请稍后重试。”。
- 本页标题、分组标题、字段名、字段值和协议入口均通过 `UIFontMetrics` 缩放、启用 `adjustsFontForContentSizeCategory` 并保留多行布局；没有改变设置页其他文本样式。

本增量前后 `QFSettingsView.swift` SHA-256 为 `930c9a699342ae54608664d8c120e1af181eea4c485b07942da484669b631c09` → `dc1bc23a330c6698d770b9509637f284e4d110b03dd778460d54dcc76335f083`。Swift parse 与 scoped diff check 通过；未运行构建、模拟器或运行态辅助功能检查。

## 已实现

- 设置页“账号与隐私”副标题改为“查看账号与登录安全”，已登录时打开单一全屏只读页；未登录时沿用“需要登录”门禁。
- 页面只读取当前 `QFAppSession.user` 中的 `QFUserProfile`，展示用户编号、自定义账号、登录密码和 Apple 身份；未读取或展示 `systemAccount`。
- 自定义账号仅在 `accountNameBound == true` 且 `boundAccount` 去除空白后非空时显示账号；两者均表示未绑定时显示“未绑定”，矛盾时显示“状态暂不可用”。密码和 Apple 状态分别独立映射为“已设置/未设置”和“已绑定/未绑定”。
- 页面保留用户协议、隐私政策入口并复用现有 HTTPS/内置正文路由。
- 页面监听现有会话发布值；会话变空后先隐藏内容，再关闭只读页并由设置页提示“登录状态已失效，请重新登录。”。

## 边界

页面没有新增网络请求、加载、刷新、重试、保存、绑定、修改、解绑、注销、权限、设备或其他写操作。未增加 API、模型字段、依赖或工程配置。

## 检查

- `xcrun swiftc -frontend -parse QiafanYoupu/Features/Profile/QFSettingsView.swift`：通过，仅证明 Swift 语法可解析。
- `git diff --check -- QiafanYoupu/Features/Profile/QFSettingsView.swift`：通过。
- 未运行构建、自动化测试、模拟器、视觉检查、VoiceOver、浏览器、数据库或服务；这些项目保持未验证。

后续由独立 QA 基于固定源码哈希检查字段组合、会话失效、协议入口、大字体、VoiceOver 和三种既有主题。本记录不代替 G2—G5 或用户最终验收。
