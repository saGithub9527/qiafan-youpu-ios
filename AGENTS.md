# 恰饭有谱工程约定

- 这是商业项目。按已确认页面和接口逐项推进，不擅自增加产品能力或对外 API。
- 通用能力优先使用官方 SDK 或成熟开源框架，避免重复实现网络、认证、持久化、迁移、图片缓存、刷新等机制；保留产品业务规则和必要的薄适配层。
- GitHub 星数只作参考，同时核查维护/归档状态、版本兼容、许可证及传递依赖。已归档库不作为新项目默认选型。稳定小库可在兼容验证后采用。
- 客户端使用 Objective-C + UIKit，第三方框架统一由 CocoaPods 管理；提交 Podfile.lock，通过 .xcworkspace 构建。按实际功能安装依赖，禁止不必要的批量 SDK 引入。
- Java 沿用 Spring Boot / Spring Security / MyBatis / Flyway，依赖尽量由 Boot BOM 管理；不另建同功能认证或持久化框架。
- 框架接入不改变已确认的请求头、请求体、返回信息、一次绑定账号或会话规则；不会因为加入运维组件就自动开放其接口。
- 每次依赖变化更新锁文件和许可证记录，完成对应构建与受影响页面/功能检查。未运行的检查不能写成通过。
- 当前客户端处于本地 UI 阶段：欢迎、登录和四个一级 Tab；没有接口、真实认证或 Token。Debug 每次启动展示欢迎，Release 完成首次引导后不重复。

当前已使用 Masonry；SDWebImage、MJRefresh 是后续候选，接入前重新核对版本。更改 project.yml 后先 xcodegen generate，再 pod install --deployment 恢复 CocoaPods 集成。

现有页面约束已统一 Masonry，新增布局采用同一风格。UIScrollView 的 content/frame LayoutGuide 通过 QFLayoutGuideAttribute 桥接 Masonry，不能混淆内容大小与可视范围。QMUI/JX/YY 等候选的范围和维护记录见 docs/UI组件选型.md；它们尚未全部接入。
