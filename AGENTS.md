# 恰饭有谱工程约定

- 这是商业项目。按已确认页面和接口逐项推进，不擅自增加产品能力或对外 API。
- 通用能力优先使用官方 SDK 或成熟开源框架，避免重复实现网络、认证、持久化、迁移、图片缓存、刷新等机制；保留产品业务规则和必要的薄适配层。
- GitHub 星数只作参考，同时核查维护/归档状态、版本兼容、许可证及传递依赖。已归档库不作为新项目默认选型。稳定小库可在兼容验证后采用。
- 客户端使用 Swift + SwiftUI 为主、UIKit 按需补充；第三方依赖统一由 Xcode 内置 Swift Package Manager（SPM）管理，使用 .xcodeproj 构建；有外部依赖时提交 Package.resolved。按实际功能安装依赖，禁止不必要的批量 SDK 引入。
- Java 沿用 Spring Boot / Spring Security / MyBatis / Flyway，依赖尽量由 Boot BOM 管理；不另建同功能认证或持久化框架。
- 框架接入不改变已确认的请求头、请求体、返回信息、一次绑定账号或会话规则；不会因为加入运维组件就自动开放其接口。
- 每次依赖变化更新锁文件和许可证记录，完成对应构建与受影响页面/功能检查。未运行的检查不能写成通过。
- 当前客户端处于本地 UI 阶段：欢迎、登录和四个一级 Tab；没有接口、真实认证或 Token。Debug 每次启动展示欢迎，Release 完成首次引导后不重复。


当前页面采用 SwiftUI 原生布局和分页，未引入外部包。后续按实际能力核查成熟 Swift/SPM 框架；不叠加 CocoaPods。修改 project.yml 后执行 xcodegen generate，同步工程与共享 scheme。历史 OC/CocoaPods 实现保存在 Git 标签 oc-uikit-baseline。
