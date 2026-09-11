# UIKit 组件与依赖选型

更新：2026-09-11。用户已确认全部采用 Swift + UIKit + SnapKit，SPM管理第三方依赖；不使用SwiftUI页面或UIHostingController包装旧界面。

| 能力 | 当前实现 |
| --- | --- |
| 生命周期 | UIApplicationDelegate / UIWindowSceneDelegate |
| 页面与底部Tab | 原生UIViewController容器；4页实例保留，切换收起键盘 |
| 全部程序化约束 | SnapKit6.0.0；Safe Area、滚动内容、最大宽度、窗口尺寸判断 |
| 欢迎横向分页 | UIScrollView paging；5页独立纵向滚动内容 |
| 分类与搜索 | UIScrollView、UIButton、UITextField |
| 月历 | Foundation Calendar、UIKit栈布局；完整月日期 |
| 须知与协议 | 原生模态控制器、UITextView、滚动内容与勾选按钮 |
| 网络 | Alamofire5.12.2 + Codable + async/await |
| 会话状态 | Combine + Security Keychain + AuthenticationServices |
| 图片 | Kingfisher8.12.0；原有本地默认图/SF Symbols/Emoji |
| 按钮Loading | UIKit原生转圈/UIButton.Configuration + SnapKit |
| Debug日志 | UITableView、分页按钮、可选择文本详情 |
| 崩溃 | PLCrashReporter1.12.2、本地归档和容量控制 |

详细接入规则、精确版本和兼容来源见[第三方框架与布局适配](第三方框架与布局适配.md)。后台业务列表尚未接入，不在本地样例上增加假刷新/分页请求；真正接入时优先UIRefreshControl等原生成熟能力，必要时再核查SPM库。

旧OC组件研究见[历史记录](历史-OC组件选型.md)，旧代码在oc-uikit-baseline；SwiftUI上一版在Git历史fa6f5c7。旧规则不代表当前布局框架。
