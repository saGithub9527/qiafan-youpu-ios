# HOME-01 首页实现记录

更新：2026-09-16。首页使用 Swift、UIKit、SnapKit、JXSegmentedView、Diffable Data Source、Kingfisher 与 MJRefresh，数据来自服务端公开菜谱接口，不再展示本地样例数据。

## 已实现

- 首页按服务端分类展示菜谱。顶部分类与下方列表通过 JXSegmentedView 双向联动：点击分类切换列表，横滑列表同步分类、字体和 32×3 指示条；搜索、箭头、筛选与栏目标题保持固定。
- 每个分类拥有独立列表控制器，保留纵向滚动位置、下拉刷新和上拉自动分页状态。公共筛选只立即刷新当前分类，其他已创建分类标记为待刷新；屏幕边缘返回手势优先于横向分页。
- 搜索页支持本地搜索历史与 350ms 防抖；国家／地区、菜系、口味和最低评分筛选均由服务端选项生成。
- 列表首次读取有效缓存，再按规则静默校正；下拉刷新当前查询，上拉自动分页，不提供手动翻页按钮。
- 无缓存的首次读取使用三行与菜谱卡片同尺寸的静态骨架占位，不再显示覆盖页面的加载 HUD；成功后原位替换为真实列表。
- 首屏失败使用列表内容区中的图标、说明和 44pt“重试”按钮，仍支持下拉刷新；不会再在列表顶部放“加载失败，请下拉重试”提示行。空列表、分页错误和无更多数据继续分别展示对应状态，已有内容不会因后台刷新而整体闪烁。
- 菜谱卡片只展示服务端已有的地区、时间、份量、真实评分和收藏数据；没有评分时显示“暂无评分”。
- 登录用户按个人资料中的国家／地区获得推荐排序；游客可以浏览、搜索和查看详情，收藏、评分和加入计划在操作时进入登录页。
- 详情页展示公开媒体、材料、已有做法步骤、真实评分以及用户已发布作品；步骤为空时不显示空标题或占位。来源与许可只保存在服务端内部审计记录，不在普通详情页展示。没有公开图片时使用内置分类插画并明确标注“插画”。
- 收藏与评分使用局部乐观更新，失败时回滚；写操作后失效对应缓存并以服务端返回数据校正。
- 首页、搜索和详情按当前设备语言发送 `Accept-Language`，只展示该 code 已发布的名称、材料和步骤，不在同一页面混排或回退到另一种语言。支持的 code 为 `zh-Hans`、`zh-Hant`、`en`、`ja`、`ko`、`ru`、`es`、`fr`、`de`、`pt-BR`；没有已发布正文时显示该语言的空状态。

## 接口

- `GET /api/v1/home/recipe-options`
- `GET /api/v1/home/recipes`
- `GET /api/v1/home/recipes/{id}`
- `PUT|DELETE /api/v1/me/favorites/RECIPE/{id}`
- `PUT|DELETE /api/v1/me/recipe-ratings/{id}`
- `GET /api/v1/catalog/RECIPE/{id}/works`
- `GET /api/v1/media/{id}`

## 验证

- 本次接入后执行 `xcodebuild -project QiafanYoupu.xcodeproj -scheme QiafanYoupu -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`，构建通过。
- `scripts/validate_localizations.py` 已校验 789 个键在 8 个外置语言资源中完整；简体中文和英语仍由 Swift 源码提供。
- 工作区设计 RAG 的 `recipe-home-r7` 源文件哈希与源码尺寸合同校验通过。
- 未启动模拟器或执行视觉验收；首页的滚动、手势、登录门禁、缓存回显、筛选组合及十种语言展示由用户在真机或模拟器中验收。

## 设计基线与分页组件

- 页面结构以设计档案 `01-菜谱-推荐.png`、`页面与交互.json` 和同版本交付说明为权威依据。工作区 `docs/design-rag/page-baselines.json` 保存 `recipe-home-r7` 的源文件 SHA-256、390×844 几何合同、固定/滚动区域和允许变化范围；`docs/design-rag/design_rag.py` 提供检索与漂移校验。
- 采用 JXSegmentedView 1.4.1，使用 SPM 精确锁定到 `fbbf965d7396bd99ac1ce88a80b6c950b85313f6`。该库为 MIT 许可、无传递依赖、未归档并包含隐私清单；许可证已写入应用第三方声明。
- 列表容器选择 `.scrollView`。JXSegmentedView 官方说明 `.collectionView` 容器会因 cell 复用隐藏 MJRefresh 的离屏刷新视图，因此不适合当前每个分类都支持下拉刷新的需求。
- 未采用 Tabman/Pageboy、Parchment 或 XLPagerTabStrip：它们同样能分页，但对当前 UIKit/MJRefresh 列表架构改动更大，或维护活跃度和传递依赖不如本次选型合适。

## 2026-09-16 公网故障诊断与组件选择

- 对客户端当前 Debug 地址 `https://test-api.yzsalingo.com/api/v1` 做匿名只读核对：启动配置返回 200，但 `home/recipe-options` 与 `home/recipes` 均返回 401。当前源码已经把两个首页 GET 接口配置为游客可读，因此公网仍在运行 2026-09-14 的旧 Java 发布和 V18 数据库；首页依赖的 V19—V23 尚未部署。不能只替换 JAR，必须按顺序完成备份、迁移和最终服务切换。
- 本轮没有把本地 V19—V23 直接写入公网：已授权的服务器 SSH 连接超时，已登录的 Chrome 会话也未被当前浏览器控制桥接识别。公网首页数据要恢复，仍需在重新取得服务器通道后执行数据库备份、V19—V23 迁移、Java 切换及匿名接口回归；客户端状态修正不会掩盖这个服务端故障。
- 调研了 Apple Loading 指引、UIKit 内容不可用状态和 MIT 许可的 SkeletonView。SkeletonView 当前可通过 SPM 接入并支持 UITableView，但这一页已有 Diffable Data Source，接入会增加另一套数据源协议，而需求只需要三行固定结构占位；因此沿用 UIKit/SnapKit 做本页私有薄组件，不新增依赖。骨架只表示正在请求，确认失败后立即切换为可操作的错误状态，不持续闪动。
