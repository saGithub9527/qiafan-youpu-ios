# 恰饭有谱 · iOS 客户端

Swift + UIKit + SnapKit；iOS 15 起，iPhone 竖屏及 iPad 横竖屏，Xcode 26.3 / Swift 5 语言模式。原 OC 实现保存在 Git 标签 `oc-uikit-baseline`。

已接入启动配置、快速登录、原生 Apple 授权、会话刷新、退出、基本资料恢复和设置页；菜谱首页、搜索与详情，以及个人／家庭计划、备菜、库存、采购单、提醒、家庭管理、库存扣减任务和个人 AI 周计划均已调用服务端接口。个推客户端薄适配和设备登记调用已实现，十语隐私政策本地副本也已升级；真实个推参数、APNs 控制台配置、线上 H5/服务端协议激活、SPM 在线解析与真机推送链路仍未完成。因此当前是“客户端接口代码已接入，外部服务尚未完成端到端配置”，不能写成已可真实推送。[实现范围](docs/实现范围.md)、[个推接入记录](docs/getui-ios-integration-20260928.md)与[验证记录](docs/验证记录.md)分别记录边界和实测结果。

## 打开与运行

```bash
cd '/Users/talka/Documents/恰饭有谱/客户端/qiafan-youpu-ios'
open QiafanYoupu.xcodeproj
```

选择 `QiafanYoupu` scheme 和 iPhone 模拟器运行。真机需要匹配团队 `B654WGMW63` 和 Bundle ID `com.talka.qiafanyoupu` 的签名与 Sign in with Apple 能力。第三方依赖使用 SPM；不需要 CocoaPods。

```bash
xcodebuild -project QiafanYoupu.xcodeproj -scheme QiafanYoupu \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

模拟器也要保留 ad-hoc 签名；`CODE_SIGNING_ALLOWED=NO` 会导致 Keychain 缺少应用标识，返回 `-34018`。真机不要使用上述模拟器签名覆盖。

`project.yml` 是工程配置来源，修改后执行 `xcodegen generate --spec project.yml`；提交工程、共享 scheme 和 SPM 的 `Package.resolved`。生成后的挂钩会移除两个本地包在导航中的重复 Folder 引用，保留 SwiftPM 依赖，避免 Xcode 26.3 的包加载冲突；可用 `python3 scripts/remove_duplicate_local_package_folders.py --check` 检查。

## 接口与环境

- Debug：`https://test-api.yzsalingo.com/api/v1`，国内公网 HTTPS 测试服务。
- Release：`QF_API_BASE_URL` 暂留空、环境为 `production`，拒绝请求。正式 HTTPS 地址与正式协议确认后再配置；不会自动回退到测试环境。
- 测试与正式的设备登录凭证和会话分别保存在 Keychain。`Device-Id` 是本 App 生成并保存在 Keychain 的 UUID，每次请求携带；不是硬件序列号，也不能替代登录凭证。卸载、恢复设备或 Keychain 丢失后不保证恢复同一身份。
- 用户协议、隐私政策、图片授权和图片权利规则使用有版本号的完整正文，并随 App 提供离线副本；服务端启动配置应指向同版本公开 H5。协议内容仍需运营者在实际发布前完成法律审阅和部署核对。

| 请求 | 使用时机 |
| --- | --- |
| `GET /app/config` | 启动读取登录开关、协议正文和协议 H5 地址；失败可在登录页或调试菜单重试 |
| `POST /auth/quick/sessions` | 用户同意协议后，提交设备凭证进行一次快速登录 |
| `POST /auth/apple/sessions` | 系统 Apple 授权成功后，提交授权码和设备凭证 |
| `POST /auth/sessions/refresh` | 受保护请求的会话需要刷新时，集中执行一次刷新 |
| `GET /me` | 启动时恢复已保存会话的基本用户资料 |
| `GET /me/settings` | 登录用户首次打开设置页时读取两类通知偏好；忽略服务端历史主题值 |
| `PUT /me/settings` | 同步两类通知偏好，不上传本机主题或界面语言 |
| `PATCH /me` | 保存昵称、国家代码、地区和个人简介 |
| `POST /me/feedback` | 提交登录用户的分类反馈 |
| `DELETE /auth/sessions/current` | 从设置页或 Debug 菜单退出当前会话 |

所有请求由 `QFAPIClient` 统一设置 `App-Platform`、`App-Version`、`Accept-Language`、`Device-Id` 和 `Authorization`。未登录时 Authorization 为空；登录后为 Bearer accessToken。JSON 请求带 Content-Type，登录及刷新带 Idempotency-Key。

快速登录凭证与 Device-Id 分开存储；服务端用秘密凭证识别账号，不凭一个可复制的设备号登录。认证 Token、设备凭证均不放 UserDefaults。登录返回的系统账号、绑定账号、昵称、头像、地区等由 `QFUserProfile` 接收，“我的”展示真实基本信息；未实现的业务统计显示占位。

## Debug 请求日志

点击页面右下角 **接口** 打开日志列表，每页 20 条，按时间倒序；支持上一页、下一页和进入详情。详情含请求时间、接口、方法、请求头、请求参数、HTTP 状态、返回头、返回参数及耗时。调试菜单可重取配置、查看沙盒日志目录和退出当前测试会话。

沙盒路径：`Library/Application Support/Diagnostics/Requests`。

- 仅 Debug 编译和记录，Release 无入口和请求日志实现。
- 按用户要求保留原始请求头、参数与响应值，包括 Authorization、Token、设备凭证、有效期和密码配置状态；仅在本机 Debug 日志中展示，不再按字段名脱敏。
- 最多 500 条或 10 MiB，单段正文最多 16 KiB；超过限制会截断或省略，不无限写盘。
- 请求开始/结束各更新一次文件，不使用高频后台轮询；日志排除系统备份并采用受限权限和文件保护。
- 列表分页是本地日志分页，不新增服务端日志 API。

## 崩溃记录

Debug（未连接调试器）和 Release 启用 PLCrashReporter 1.12.2。发生可捕获崩溃后，下一次启动将原始报告转存为 `.crashbundle`：原始 `raw.plcrash`、可读 `report.crash` 和 `metadata.json`。

沙盒路径：`Library/Application Support/Diagnostics/Crashes`。最多 20 条 / 20 MiB（包括待转存预算），不自动上传。Xcode → Devices and Simulators → 下载应用容器后可取出。分析需保留同次构建的 `.xcarchive` 和 dSYM，按报告中的二进制 UUID 匹配。

连接 Xcode 调试器运行时不安装崩溃采集器，避免干扰调试。SIGKILL、系统强杀、部分 OOM / watchdog 等退出不保证生成报告。文件结构、保护、转存失败处理和符号化方法见[本地崩溃报告说明](QiafanYoupu/Core/Diagnostics/CRASH-REPORTS.md)。

## 欢迎与调试参数

Debug 默认每次展示欢迎；Release 完成首次安全通知后不重复。登录协议默认未选，勾选及取消均缓存；根据实际正文生成本地修订，正文变化后重新选择。请求体仍只提交 `agreementAccepted`，不添加协议版本字段。

以下参数仅 Debug 生效：

| 参数 | 作用 |
| --- | --- |
| `-QFResetUIState` | 清除本 App 的 UserDefaults；不删除 Keychain 账号或会话 |
| `-QFSkipWelcome` | 本次跳过欢迎，不写完成标记 |
| `-QFStartTab recipe` | 起始 Tab，可选 recipe / plan / ingredient / profile |
| `-QFPreviewSignedIn` | 仅预览旧设计登录态，不生成账号 |

## 工程目录与依赖

```text
QiafanYoupu/
├── App/                 AppDelegate / SceneDelegate、启动规则、Tab、会话协调
├── Core/
│   ├── Networking/      Alamofire 请求、公共头、响应模型
│   ├── Media/           Kingfisher 远程图片、分环境/用户缓存
│   ├── Session/         Keychain、设备标识、真实登录与会话
│   └── Diagnostics/     Debug 请求日志与本地崩溃归档
├── Features/
│   ├── Auth/            欢迎、协议、登录、Apple 原生授权
│   ├── Diagnostics/     Debug 分页列表和详情
│   ├── Recipe/ Plan/ Ingredient/ Profile/
├── DesignSystem/        语义颜色、布局与公共组件
└── Resources/           素材、隐私清单、第三方许可证
```

网络使用 Alamofire 5.12.2；远程头像使用 Kingfisher 8.12.0；全部页面约束使用 SnapKit 6.0.0，欢迎、登录、四 Tab 和日志均迁移到 UIKit。凭证用 Security Keychain，Apple 授权用 AuthenticationServices；所有页面使用 UIKit，约束使用 SnapKit，欢迎分页使用系统 UIScrollView。窗口按可用宽高适配，主内容宽屏居中、窄屏换行，iPad 支持横竖屏。完整规则见 [第三方框架与布局适配](docs/第三方框架与布局适配.md)。崩溃采集复用 [Microsoft PLCrashReporter](https://github.com/microsoft/plcrashreporter/tree/1.12.2)，固定 1.12.2，并提交锁文件和完整许可证。素材映射见 [ASSET-SOURCES](QiafanYoupu/Resources/ASSET-SOURCES.md)。

设置页按已确认的 `04-设置` 和 `05-主题设置` 实现。经典橙、自然绿、深色使用同一套语义颜色；应用主题后重建四个一级页面并保留登录会话。主题和界面语言只通过 `UserDefaults` 保存在本机，切换语言不请求设置接口；业务内容请求通过 `Accept-Language` 携带当前 code。界面支持简体中文、繁體中文、English、日本語、한국어、Русский、Español、Français、Deutsch 和 Português (Brasil)。两类通知偏好与 `/me/settings` 同步。编辑资料、账号与隐私、帮助与反馈和界面语言均使用独立页面。清缓存只清除可重新下载的图片与 URL 缓存，不清除账号、设备凭证、请求/崩溃日志或未发布草稿。设置与登录入口统一打开当前应用语言的内置完整协议，服务端启动配置只控制协议可用状态和同意修订。

新增或修改用户可见文案时必须同时提供简中和英文源文，并补齐另外八种语言资源。运行 `python3 scripts/validate_localizations.py --write-source` 更新源清单，再运行 `python3 scripts/validate_localizations.py` 检查缺键、空译文和格式参数一致性。

## 测试

`QiafanYoupu` scheme 包含单元测试和普通 UI 回归；单元测试使用隔离 Keychain / URLProtocol，不访问真实账号。

```bash
xcodebuild test -project QiafanYoupu.xcodeproj -scheme QiafanYoupu \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:QiafanYoupuTests -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

`QiafanYoupu-LiveTests` 是显式运行的真实快速登录测试，只选择快速登录恢复及日志界面两个联调用例，会在测试服务创建或复用该模拟器设备的账号；不要用于正式环境。普通 UI 用例涉及登录协议时需测试配置可用；协议回归会先退出指定测试模拟器的当前会话，保留设备凭证。`QiafanYoupu-ReleaseUI` 保留 Release 引导回归入口，首次安装测试需准备干净应用容器。

实际 Apple 账号授权、真机硬件文件保护和发布签名应在真机验收；未执行项目不会写成已通过。管理后台保持独立部署，不把后台权限或页面打进客户端。

隐私清单已对应当前 Device-Id、账号标识、服务诊断及本 App 文件时间戳访问同步声明；本地崩溃未上传。发布归档时仍需核对 Xcode 聚合报告，并在 App Store Connect 按最终数据流填写。声明依据见 [Apple 数据类型定义](https://developer.apple.com/app-store/app-privacy-details/)和[Required Reason API](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。

2026-09-11 调整：协议复选框与整段文字垂直居中；快速/Apple 登录、配置重试、调试菜单的网络动作均显示对应按钮内 Loading，结束后恢复并防止重复点击。旧日志已保存的 `[REDACTED]` 不会自动还原，需使用更新后的 App 重新发起请求。

当前悬浮助手已改为离线动态光球，保留原聊天入口；接入与验收记录见 [光球接入](docs/assistant-light-orb-20261014.md)。
