# 个推 iOS 客户端接入记录

更新：2026-09-29。本文只记录客户端薄适配和上线所需配置，不包含任何真实密钥。

## 当前状态（以本节为准）

个推已保存 `QiafanYoupuAPNs-Universal.p12`，选择“通用环境”，覆盖该 App 的 APNs Sandbox 与 Production。提交后观察到“修改配置”按钮恢复，P12 和通用环境均为不可编辑的已选项；这是保存完成的界面证据。后续刷新读取又受 CUA 悬浮菜单问题干扰，未完成第二次独立回读，未做真机投递。证书于北京时间 **2027-10-29 18:42:08** 到期。下面保留各阶段历史，先前“尚未关联”的描述不再是当前证书配置状态。

推送专项代码修复尚未构建或部署，`NOTIFICATION_WORKER_ENABLED=false`。证书配置完成不等于整条计划提醒链路已经验收。

## 官方依据与版本

- [iOS SDK 集成指南](https://docs.getui.com/getui/mobile/ios/xcode/)：创建应用后取得 AppID、AppKey、AppSecret；开启 Push Notifications；添加 `-ObjC`；无广告应用可使用无 IDFA 基础库。
- [iOS SDK API](https://docs.getui.com/getui/mobile/ios/api/)：SDK 必须在主线程初始化；CID 从注册回调取得；`registerRemoteNotification` 会注册系统通知并由 SDK 自动关联 APNs Device Token 与 CID，不再手工调用已废弃的 token 绑定接口。
- [消息推送 SDK 合规指南](https://docs.getui.com/compliance/getui/)：取得 App 隐私政策同意后才能初始化 SDK，并需要在 App 隐私政策中披露个推处理的信息、目的、方式和范围。
- [个推用户隐私政策](https://docs.getui.com/privacy/)：上线隐私政策中应提供的第三方政策链接。
- 官方 SPM 仓库 [GTSDK](https://github.com/GetuiLaboratory/getui-sdk-ios-cocoapods) 固定 revision `464c86e453c9c06e23d71bcad3958d1f1b7a68ab`，对应 3.1.2.0。
- 官方 SPM 仓库 [GTCommonSDK](https://github.com/GetuiLaboratory/getui-gtcsdk-ios-cocoapods) 固定无 IDFA revision `80d402955ea0980730984c3d2d349dff9c2fe649`，对应 3.2.6.0-noidfa。当前产品未声明广告用途，因此不引入 IDFA 版本。

两个官方二进制包都包含 `PrivacyInfo.xcprivacy`。GTSDK 清单声明粗略位置用于 App 功能且不用于跟踪；所选 GTCommonSDK 为无 IDFA 版本。清单只能说明 SDK 自报的数据类别，不能替代本 App 的隐私政策披露和实际合规核对。

## 客户端实现

`QFGetuiPushService` 负责一条生命周期：

1. App 启动只保存 `launchOptions`，不立即启动个推。
2. 用户完成隐私同意、已有登录会话、服务端设置已读取且“计划提醒”开启后，才使用 AppID、AppKey、AppSecret 初始化 SDK。
3. SDK 统一申请/注册通知权限并自动关联 APNs token；CID 回调后通过现有 `PUT /me/push-devices/{deviceId}` 保存 `GETUI`、`IOS`、CID 和当前界面语言。
4. 界面语言改变时仅更新同一设备登记；没有把界面语言写入用户资料。
5. 关闭计划提醒或退出登录时，先尽力调用现有删除接口停用设备，再关闭 SDK。退出接口失败且会话仍有效时会恢复 SDK 并重新登记，已停用的本地 revision 可用于安全重启，不重复发送删除请求。
6. 前台可见通知按系统 badge、sound、banner、list 展示，不触发页面跳转；用户点击 `PLAN_REMINDER` 通知后，客户端按 `plannedMealId` 读取计划、切换到对应个人/家庭范围和日期。工程未开启 `remote-notification` Background Mode，不声明后台静默更新能力。

配置由 `Configuration/Getui.xcconfig` 注入 Info.plist。仓库只提交空值和 `Getui.local.xcconfig.example`；真实值写入已被 Git 忽略的 `Getui.local.xcconfig` 或 CI 密钥配置。AppSecret 是官方客户端 SDK 初始化参数，会进入签名 App，不能当作服务端机密；MasterSecret 绝不能进入客户端、Info.plist、xcconfig 或日志。

## 个推控制台配置进度（2026-09-28）

已在用户登录的 Chrome 个推控制台创建「恰饭有谱」，平台为 iOS，类型为生活休闲，Bundle ID 为 `com.talka.qiafanyoupu`。控制台返回「服务开通成功」，本次仅开通消息推送。

AppID、AppKey、AppSecret 已写入 `Configuration/Getui.local.xcconfig`；服务端所需值单独暂存于后端仓库已忽略的 `.env.getui`。两份文件权限均为 `0600`，不提交 Git。服务端暂存文件不会自动加载，`GETUI_ENABLED` 保持 `false`；该段记录 2026-09-28 的本地状态；2026-09-29 已注入服务器，见下方部署记录。真实发送与真机验证仍未完成。

已登录 Apple Developer 远端核实 Team ID 为 `B654WGMW63`，应用 `com.talka.qiafanyoupu` 的 Push Notifications 已开启，现有 Sign in with Apple 保持不变。签名描述文件及真机 Device Token 尚未验证。

## 个推参数对应关系

从与 Bundle ID `com.talka.qiafanyoupu` 对应的个推应用复制：

- `AppID` → `QF_GETUI_APP_ID`
- `AppKey` → `QF_GETUI_APP_KEY`
- `AppSecret` → `QF_GETUI_APP_SECRET`
- `MasterSecret`：只写入服务端密钥存储，用于 REST API 鉴权；不要发给客户端或提交 Git

服务端还需要确认个推 REST v2 的基础地址、鉴权缓存和发送环境配置。CID 是运行时回调值，不从控制台手工复制。

## Apple APNs 配置进度

2026-09-28 已创建并下载两份仅授权 `com.talka.qiafanyoupu` 的 Topic Specific APNs 密钥：

| 名称 | Key ID | 环境 | 个推配置 |
| --- | --- | --- | --- |
| Qiafan Youpu APNs Sandbox | `NYKZ2QPUR7` | Sandbox | 已上传并提交，控制台显示为不可编辑的已保存配置；待真机投递验证 |
| Qiafan Youpu APNs Production | `ND9U937Y5J` | Production | 仅安全保存本地，尚未关联 |

文件保存在后端仓库已忽略的 `secrets/apns/`，目录权限 `0700`、P8 文件权限 `0600`；已执行不输出密钥内容的私钥格式校验。`metadata.json` 记录环境与配置状态，P8 不进入客户端和 Git。苹果只允许下载一次，应另由负责人保存受保护的备份。

个推当前页面只有一个 P8 配置位。Apple 当前控制台的 Environment 下拉框实际提供 Sandbox、Production、Sandbox & Production，但双环境与 Topic Specific 的可组合性本轮尚未确认。切回 Apple 时出现 `ERR_CONNECTION_CLOSED`，有间隔地重试两次后页面仍未恢复。因此当前配置只用于 Sandbox 联调，不能声称支持 TestFlight/正式发布；网络恢复后需确认并配置能覆盖所需环境的凭据，或核实个推支持的其他分环境方案。现有两份密钥均保留，没有撤销原 Apple 登录密钥。

官方参考：[Apple 创建密钥](https://developer.apple.com/cn/help/account/keys/create-a-private-key)、[个推 P8 配置](https://docs.getui.com/getui/mobile/ios/apns/)。个推接受上传不能代替其对 Topic Specific 密钥的实际 APNs 投递验证。

### 2026-09-29 续接结果

- 使用本机已保存的服务端凭据调用个推官方 REST v2 `/auth`，返回 HTTP 200、业务码 `0`，并取得非空 token。只在进程内核验，未保存或输出 token，也未发送通知。此结果验证本机到个推的鉴权，不代表测试服已配置或 APNs 已投递。
- 再次核对 [Apple token 鉴权文档](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns)：Topic Specific 密钥限定单一环境，不能把控制台出现 `Sandbox & Production` 选项理解为它可以与 Topic Specific 组合。现有两份单环境密钥保持不变；需先确认个推如何分别承载两种环境，再落实发布配置，不能直接用 Production 密钥覆盖 Sandbox 后宣称两种环境都可用。
- 本轮浏览器控制未恢复：Chrome 运行、扩展启用、native-host manifest 检查正常，但标签页调用连接失败；内置浏览器可以列出个推服务总览标签页，DOM 与可访问性内容读取均超时。只凭标签页标题不能确认当前登录状态。本轮未修改 Apple/个推控制台，未操作远端服务器。
- 资源：复用现有浏览器，未新建标签页、浏览器或模拟器；一次性鉴权进程已退出，浏览器调用超时后 REPL 已重置。用户原有页面保留。

### 2026-09-29 测试服部署结果

- 新一轮阿里云 CLI 授权完成后，已部署 Java、管理后台、H5 和 V29—V35 迁移。上方“未操作远端服务器”仅对应此前的鉴权续接阶段。
- 服务器 `/etc/global-recipe/java.env` 已保存个推参数，权限 `0600`；`GETUI_ENABLED=true`，`NOTIFICATION_WORKER_ENABLED=false`。管理 API 报告个推配置完整、提供者可用；从测试服调用官方 `/auth` 也返回 HTTP 200、业务码 0 和非空 token，仅在进程内核验，未输出或保存 token、未发送通知。这不代表 APNs 实际投递成功。
- 服务端 `/api/v1/app/config` 已返回隐私政策 1.4 正文，公网十语隐私政策与本地 H5 逐字节相同。未创建测试用户，未伪造新同意快照。
- 本轮浏览器控制两次超时，未改动 Apple 或个推控制台，Production APNs 配置仍待完成。部署与资源清理记录见 `../../../运维/计划能力与个推配置部署-20260929.md`。

当前工程已为 Debug/Release 分别声明 development/production 的 `aps-environment`，但是否能获得 Device Token 仍取决于 Apple App ID、签名和 provisioning profile。模拟器或仅有个推参数不能替代真机 APNs 验收。

## 2026-09-29 推送专项续接（本地改动，未发布）

本轮只处理推送。内置浏览器标签页控制仍超时，但 `cua.getApp("Google Chrome")` 的原生窗口控制已实际读取并操作现有个推标签页；因此不能继续笼统描述为“Chrome 无法控制”。页面当前为个推登录页，已请用户在 Chrome 登录。本轮未新建浏览器或标签页，未修改个推/Apple 控制台、服务器开关或密钥。 收尾读取页面时，原生控制工具明确返回 Mac 已锁定、自动解锁失败；后续界面操作需要用户手动解锁，再完成个推登录。

核实 [个推 iOS 常见问题](https://docs.getui.com/getui/question/ios/) 和 [REST 公共参数](https://docs.getui.com/getui/server/rest_v2/common_args/) 后确认：默认策略在在线时传递 transmission，iOS 不会自动显示它；厂商通道策略在文档中属于 VIP 能力。本轮沿用当前默认策略与官方 SDK，以 Apple UserNotifications 展示在线提醒，不擅自升级付费服务。

本地修改：

- 服务器在线透传增加 `notificationId`、`title`、`body` 和原始 `payload`；APNs 的 alert 与计划路由保持现有结构。
- 客户端仅在已同意隐私、已登录且提醒开启时，将有效 `PLAN_REMINDER` 在线透传交给系统通知中心。`offLine=true` 的 APNs 后续回放不再次弹通知；用通知 ID 去重，并限制内存去重记录为 128 条。旧版本仅含路由的透传不会编造展示文案。
- SDK 启动后显式设置 `GeTuiSdk.runBackgroundEnable(false)`，进入后台主动断开个推在线连接，供默认路由选择 APNs。依据官方 API 第 25 节，未设置时会等系统关闭连接；这项修改不增加后台保活或静默推送能力，实际切换和投递仍需真机确认。
- outbox 发送前重新核对计划/提醒/设备版本、用户开关、家庭成员资格和时间窗；超出既有 15 分钟宽限的待发送消息取消，避免恢复服务后补发很久以前的提醒。
- “提前 0 分钟”不再要求调度器刚好在用餐时间那一瞬间运行，正常轮询延迟可在同一 15 分钟宽限内发送。

新增 Java 在线载荷、零提前时间和过期窗口用例，以及 Swift 载荷解析用例。按当前项目“用户负责测试”的约定，本轮未运行这些用例、iOS 构建、模拟器或真机测试；仅完成差异格式检查和 Xcode 工程 plist 结构校验。当前测试服仍为前一轮 r2，不能将这些本地改动描述为线上生效。

下一步依赖：证书配置已完成；使用负责人指定的 iPhone 检查通知授权、CID、在线提醒、后台 APNs、点击路由、离线回放不重复、关闭提醒和退出登录。部署推送修复并完成必要验证后，再启用通知 worker。本轮不推进其他计划能力或 AI。

### 用户重新登录后的控制台核查

已通过 Chrome 原生窗口读取“服务总览”和“恰饭有谱 → 消息推送 → 应用概览”，确认登录成功。概览显示今日新增、实时在线、百日联网数均为 0，并提示尚未集成 SDK；这是控制台当时的统计观察，页面也提示数据可能延迟，不能单凭此断言客户端完全没有接入。

点击“配置管理 → 应用配置”后窗口标题已切换，但原生可访问性持续返回旧菜单；取消、刷新和切换标签页没有恢复表单读取，截图不可用，Chrome 标签页通道也超时。已请求用户把鼠标移出菜单并点击空白处。本轮尚未读取到当前证书表单，因此没有改动 APNs、个推密钥或服务器开关，也没有发送通知；原有浏览器和标签页保留，未创建模拟器。

已搜索个推官方证书指南、控制台指南及 REST 文档，当前找到的是在控制台上传证书的说明，未找到可直接替代控制台的公开证书配置 API；这不等于个推绝对不存在其他配置渠道。观察记录见 `../../../运维/验证记录/20260929-push/console-progress.json`。

### 继续操作：已读到证书配置，编辑仍受浏览器焦点阻塞

用户手动移开菜单后，原生窗口读到完整“应用配置”：Bundle ID 正确，当前已保存的 P8 为 `AuthKey_NYKZ2QPUR7.p8`，Key ID、Team ID 均与本地记录一致。因此上文“未读取到表单”是此前阶段状态，已完成只读核实。

点击“修改配置”后出现 P8 推荐提示，确认提示后自动化再次只读到“配置管理”的悬浮菜单，无法取得编辑表单或截图。没有点击证书保存按钮，没有上传替代证书。重绑应用、关闭菜单及重置 CUA 会话未恢复，已请用户将鼠标移到 Chrome 地址栏并点击，避免再次停在悬浮菜单上。保留现有 Sandbox 凭据，不将仅下载的 Production P8 描述为已配置。

已核实一个不扩大到团队所有 App 的备选方案：Apple 的应用专属 `Apple Push Notification service SSL (Sandbox & Production)` 通用证书可覆盖两种环境，个推指南也支持此类 P12；它需要定期续期，且个推文档注明不支持灵动岛。当前计划提醒不依赖灵动岛。尚未进入 P12 表单确认字段，也未创建或切换证书，后续必须先验证个推当前支持的配置方式。

一手参考：[Apple APNs TLS 证书](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-a-tls-certificate)、[个推证书指南](https://docs.getui.com/getui/mobile/ios/apns/)、[个推后台连接设置](https://docs.getui.com/getui/mobile/ios/api/)。本轮新增的后台连接设置仅通过 `git diff --check`，没有执行编译或测试，没有部署。服务器 worker 保持关闭。

## 2026-09-29 正式环境证书配置续接

- 已在个推编辑表单确认 P12 有“开发环境”和“通用环境”两个选项；已上传 `QiafanYoupuAPNs-Universal.p12`、填写导出密码、选择通用环境并提交保存。
- Apple Developer 已签发该 App 专属的 `Apple Push Notification service SSL (Sandbox & Production)`，证书 ID `ADNWDY2SZM`，名称 `Apple Push Services: com.talka.qiafanyoupu`。不影响现有两份 P8 或 Apple 登录密钥。
- 实际有效期：2026-09-29 10:42:09 UTC 至 **2027-10-29 10:42:08 UTC**（北京时间 2027-10-29 18:42:08 到期）。应在到期前换新，建议维护窗口安排在 2027 年 9 月；没有自动创建提醒任务。
- 已校验证书 Bundle ID、证书公钥与本地私钥匹配，并生成和重新读取加密 P12。证书、私钥和随机导出密码位于后端已忽略的 `secrets/apns/universal-20260929/`，目录 0700、文件 0600。本文不记录密码。
- 用户移开鼠标后已恢复文件窗口操作并完成保存。提交后“确定”按钮经历加载态，随后表单变为只读并恢复“修改配置”，证书类型为 P12、名称为上传文件、环境为通用环境。刷新后的独立回读仍受 CUA 菜单读取异常干扰，未据此声称二次回读或真机验收通过。
- 两个任务创建的临时页（本地凭据读取、独立回读）均已关闭，用户原有个推和 Apple 标签页保留；未启动模拟器、构建或部署，服务器 worker 未开启。`/tmp/qf-apns-20260929/` 的三个上传暂存文件及目录、Downloads 中本轮下载的证书副本，已逐一核对与受保护原件一致后清理；内存密码引用已清除，永久凭据保留用于运行、续期和回滚。

## 隐私政策状态

- 本地 H5 与客户端内置的 10 个语言版本已升级为 `1.4-2026-09-28`，披露个推 SDK、每日互动股份有限公司、处理目的、启动条件、实际数据类别、关闭方式和个推用户隐私政策链接。
- `QFLaunchPolicy.completedKey` 已按 1.4 版本更新；已有安装不会沿用旧欢迎完成标记启动个推。服务端协议 TXT 和公网十语 H5 已于 2026-09-29 部署，`/app/config` 正文与本地核对一致；真实用户的新同意流程仍待客户端验收。

## 发布前阻塞项

- APNs 双环境配置已保存；在真实 iPhone 上分别核对开发/发布签名的授权、CID、Device Token、前台通知、后台 APNs、点击路由、关闭提醒和退出登录。
- Release 已声明 `APS_ENVIRONMENT=production`，但仓库内 `QF_API_BASE_URL` 仍为空，`QFAPIEnvironment.current` 直接读取该值。TestFlight 联调打包必须显式注入已确认的测试 API 地址；最终正式发布须注入实际正式 API 地址，否则登录和 CID 登记无法正常工作。本轮只配置 APNs，未擅自把测试 API 写成正式发布默认值。
- 服务端参数与新协议已部署。推送专项修复部署并完成真机验证后，再开启 `NOTIFICATION_WORKER_ENABLED`；当前仅 `GETUI_ENABLED=true`，outbox 调度尚未启动。
- `Package.resolved` 已手工写入两个官方精确 revision；本机两次在线解析分别遇到 SwiftPM 缓存目录冲突和 GitHub TLS 失败，因此这些 pin 尚未由 Xcode 在线依赖解析验证。网络恢复后应在 Xcode 中解析一次并审核锁文件变化，不能把当前状态描述为构建通过。

## 2026-09-30 构建依赖补充

Simulator 构建暴露 GTCommonSDK 的 `_res_9_*` 未定义符号。核对固定 revision 的 Package.swift 仅包含 binaryTarget，未传递系统库；官方 [iOS 集成指南](https://docs.getui.com/getui/mobile/ios/xcode/) 和相同仓库 podspec 要求 resolv、z、sqlite3、c++。因此仅在 XcodeGen 的 SDK dependencies 补齐对应四个系统 `.tbd`，未改变 SDK revision 或推送业务配置，不引入 CocoaPods。模拟器编译结果记录在本轮计划页面验证中；真机投递仍按用户要求留到 10 月 6 日。
