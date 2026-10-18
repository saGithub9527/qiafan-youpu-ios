# AUTH-01 iOS 交付记录

任务 QFYP-20260912-P2-07；2026-09-12。
启动 HEAD：`06e22c58debf5e38bfd0e44820c345013fff957a`，实际 Git 二进制 status --short 为空。
依据：本任务上游产品总监 G1/G2、技术总监 G3 正式批准决定。本记录是开发落实与自检，不是开发者批准自身代码；后续独立测试与总监实现验收不得以本记录代签。

## QFYP-20260912-AUTH01-IOS-A02 增量

本增量绑定已通过 G1 的 `AUTH-01-PRD-v1`（SHA-256 `1aaeddf0a56c528fcbdfd2c629d59d5f3be346927355244812c117c1525787dc`）及独立 G1 评审（SHA-256 `fabfcb592bc025df6a4632895ff7083fad339b378aee8bcd23257dc10c399af7`），不据此声称 G2—G5 已通过。

- `QFLoginView.swift` 的授权失败、通用失败和限流提示已与 G1 冻结文案逐字对齐；`40301` 显示“请先阅读并同意用户协议和隐私政策”，同时清除当前协议同意状态，使下一次登录操作重新进入协议门禁。
- 共享协议控件沿用 G6 已复核版本：`QFAuthViews.swift` SHA-256 为 `35508871ee8ddcb8fc3327842808dd37ae1dcb4fbbc0b35c46ceb9efc5e00e69`，44 × 44pt 区域使用无系统样式按钮、无 configuration 且背景透明；本 assignment 未修改该文件。
- 本增量实际执行 `xcrun swiftc -frontend -parse QFLoginView.swift`、该文件 `git diff --check` 和冻结文案/门禁的定向源码核对，均通过。未运行 App 构建、模拟器、UI 测试、真实 Apple 授权、VoiceOver 或联调。

## 修改记录

路径相对客户端工程。

| 文件 | 变更 |
| --- | --- |
| QiafanYoupu/Features/Auth/QFLoginView.swift | 官方signIn按钮，浅底黑色/深底白色，保留55pt、位置、login.apple；外置预留等待行；状态变化时VoiceOver通知；未就绪/渠道关闭禁用；按阶段及业务码映射错误 |
| QiafanYoupu/Features/Auth/README.md | 更新控件、等待、门禁、失败说明 |
| docs/实现范围.md | 增补本轮实现与验收边界 |
| docs/验证记录.md | 追加本轮结果，保留历史记录 |
| docs/auth-01-ios.md | 本交付与验收、回退记录 |

主题依据现有QFThemeManager，主题切换重建根页面；不修改官方按钮内部视图/标题。快速登录、配置重试仍用原Loading。取消使用官方错误域和枚举判断，静默结束；既有defer恢复控件。无新页面、接口、绑定指引或自动快速登录。

## 链路核对

以下路径相对QiafanYoupu：

- App/QiafanYoupuApp.swift：showLogin打开入口。
- Features/Auth/QFAppleAuthorization.swift：随机state、原生授权、controller身份与state校验；拒绝旧controller回调，取消清理continuation。未加入nonce/challenge。
- Core/Session/QFAppSession.swift：每次新登录UUID、一次POST、无自动重试；返回成功后先写Keychain，再更新用户；成功后页面才关闭。失败不先覆盖本地用户。
- Core/Networking/QFAPIModels.swift：Apple请求仅authorizationCode、deviceCredential、agreementAccepted；响应session/user。
- Core/Networking/QFAPIClient.swift：公共头、Idempotency-Key及API baseURL规则保留；未改地址或连接环境。
- Features/Auth/QFAuthViews.swift、QFSafetyNoticeViewController.swift：协议双向缓存、正文变化重选、通知与动效保留。

后端依据：项目根目录下后端/qiafan-youpu-server/docs/auth-01-g3.md及现行API/OpenAPI。服务端不重复建号、不覆盖映射不能仅由客户端代码证明。

## 错误映射

授权阶段失败：Apple 授权未完成，请重试。提交阶段40100：Apple 授权已失效，请重新授权；40101：通用无法完成提示，不解释为Apple失效；40300：当前账号暂不可用；40301：先阅读并同意协议；40903：当前 Apple 身份无法用于此设备的账号登录。；42900：操作过于频繁，请稍后再试。40000/40900/50000/50300、未知码、网络和Keychain错误：暂时无法完成登录，请稍后重试。全部使用既有“知道了”弹窗，不透传技术描述，不声称结果不明时未建号。

## 实际定向结果

1. Xcode工具链swift-frontend -parse QiafanYoupu/Features/Auth/QFLoginView.swift退出0；只是语法解析，不是UIKit/SnapKit类型检查或App构建。
2. 提取实际QFLoginFailureMessage及QFAPIError声明，以Swift运行16例：14例业务码/阶段/登录方式组合，另含超时、Keychain类NSError。全部通过，覆盖40100/40101区分、40903无指引、未知码兜底、服务端敏感描述不透传。
3. 实际Git二进制diff --check通过。
4. 授权、会话、Keychain、APIClient、APIModels、安全通知、协议组件7文件与干净启动HEAD逐字一致。

工具链目录：/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/。
映射脚本为下述副本目录中的error-mapping.swift；可用工具链swift -module-cache-path <任务临时缓存> <脚本>复查。源文件后续变化须重新提取声明。不是整页状态机或服务端集成测试。

未运行App构建、模拟器、UI测试、真实授权或联调；视觉、实际辅助功能、会话恢复及冲突归属未验证。进程清单查询被沙箱拒绝，未启动重型构建；轻量检查串行结束。

## 用户最终真机步骤

前置：运维提供匹配后端版本、迁移记录及可用测试配置；用户具备Apple签名、真机和测试账号；实际外部配置未验证。

1. 三主题打开登录页，核对官方标题、黑白样式、55pt；小屏/大字体文字完整；VoiceOver识别禁用、等待和恢复。
2. 配置失败出现“登录信息加载失败，请重试”及原重试入口；协议未就绪或渠道关闭不能授权，渠道关闭显示“Apple 登录暂不可用”。
3. 未同意进入原通知；阅读不等于同意，拒绝不请求；同意只继续一次，正文变化重新确认。
4. 连续点击仅一次授权；等待不挤压按钮；取消无弹窗、无POST、无自动再授权，保留勾选并恢复操作；再次点击可重新授权。
5. 提交中不提前显示成功；成功后关闭登录页并显示真实资料；记录公开userId，重启有效会话后相同。
6. 测试岗位准备授权失效、设备凭证无效、账号不可用、限流、断网/服务失败条件，核对冻结文案及恢复操作；响应丢失后重新授权，后端确认没有第二账号。
7. 已有快速账号或Apple归属不匹配触发40903，仅通用提示和“知道了”；后端/数据库核对原账号与设备映射未覆盖，无合并绑定。

不要求用户篡改凭证或生产数据；迟到回调与竞争顺序由独立测试岗位定向验证。

## 交接与回退

交测试岗位：差异、16例结果、上述运行检查点；交产品/技术总监：复核G1/G2/G3落实并登记实现验收；交项目经理：归入AUTH-01差异、检查、用户验收单及回退目录。未发送外部消息，未提交Git，未触碰后端改动。

短期副本：/var/folders/zn/mplkcdjs6l3b_1n7yzb2b6t00000gn/T/QFYP-P2-07-p62hbx0a，保留四文件原文、SHA-256清单及映射脚本供审核与回退；验收结束且确认不再需要时只删除该目录。Swift临时模块缓存已清理；检查进程已退出，无后台作业、浏览器或模拟器保留。

回退仅反向应用本任务五文件差异；若已有后续编辑，逐块回退，不整仓reset/clean。新增记录仅在确认无后续内容时移除。无数据库、依赖或运行配置回退。
