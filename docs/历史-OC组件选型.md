# 历史：OC UI 组件选型

历史核查日期：2026-09-10。本文保留 OC/UIKit 阶段的研究，对应代码基线为 Git 标签 `oc-uikit-baseline`。当时依赖使用 CocoaPods，除 Masonry 外的候选尚未安装；以下内容不代表当前 SwiftUI/SPM 工程的依赖或兼容结果。

现行选择见 [SwiftUI 组件与依赖选型](UI组件选型.md)。文中版本、星数和“已接入”状态均以历史核查时点为准。

## 当时建议

| 能力 | 建议 | GitHub 星数约值 | 在本项目的使用位置 |
| --- | --- | --- | --- |
| 约束布局 | Masonry 1.1.0，已接入 | 1.81 万 | 欢迎、登录、四个一级页、容器、公共组件；页面约束全部采用 Masonry |
| UI 基础组件、主题、输入和提示 | QMUI，先验证兼容再接入需要的组件 | 7,192 | 主题色、按钮、表单、弹窗；不改变已确认设计和协议操作规则 |
| 分类栏与横向分页 | JXCategoryView | 6,150 | 菜谱顶部分类、左右切页；需要列表容器时使用 JXCategoryListContainerView |
| 吸顶头部与嵌套滚动 | JXPagingView/Pager，仅出现该页面需求时使用 | 3,049 | 带共享头部的纵横滚动页面；普通分类栏不必一起安装 |
| 下拉刷新、上拉加载 | MJRefresh | 13,806 | 菜谱等真实分页列表的加载状态与手势 |
| 图片加载与缓存 | SDWebImage | 约 2.56 万 | 菜谱、作品、用户贡献图片；不再叠加另一套图片缓存管线 |
| JSON 模型转换 | YYModel，按 DTO 需求评估 | 4,348 | 接入真实接口时再确定；当前 UI 本地数据阶段不安装 |

Masonry 处理约束语法，QMUI 提供 UIKit 基础能力，两者可以共用。各框架的默认样式需要适配本项目，不能直接用示例 App 的页面替代确认设计。MJRefresh 只负责刷新/加载状态，服务端分页、去重、失败处理和请求仍按业务契约实现。

## 有没有比 QMUI 更合适的

在本次核查的候选中，没有发现适合把本项目整套 UI 直接迁移过去的明显替代：

- **QMUI**：覆盖全局样式、UIKit 扩展、输入与弹窗等，接近本项目需求且用户有使用经验。最新发布 4.8.0、主分支最新提交均为 2024-09-21；未归档。iOS 13+、OC、MIT，Pod 名 QMUIKit。接入前需要在当前 iOS 26 / Xcode 26 的安全区、导航、主题、键盘及弹窗场景做兼容检查。
- **IGListKit**：约 13,066 星，最新 5.2.0（2026-02-17），主分支近期仍有维护。它是数据驱动的 UICollectionView 列表框架，不是 QMUI 同层级的主题/表单/弹窗组件库；出现复杂混合列表后再考虑。OC、iOS 11+、MIT。
- **Texture**：约 8,180 星，最新 3.2.0（2024-05-21），主分支 2026 年仍有维护。主要解决复杂图文的异步布局与渲染，采用 Node 体系，迁移现有 UIKit 页面有成本。没有性能测量依据时不引入。OC API、Objective-C++ 实现，3.2.0 podspec 为 iOS 14+、Apache-2.0。

来源：[QMUI](https://github.com/Tencent/QMUI_iOS)、[QMUI 4.8.0](https://github.com/Tencent/QMUI_iOS/releases/tag/4.8.0)、[IGListKit](https://github.com/Instagram/IGListKit)、[Texture](https://github.com/TextureGroup/Texture)。

## JX 系列的区别

- [JXCategoryView](https://github.com/pujiaxin33/JXCategoryView)：OC 分类、指示器及横向列表容器；当前已发布 Pod 1.6.8。
- [JXPagingView](https://github.com/pujiaxin33/JXPagingView)：嵌套滚动；OC 使用 JXPagingView/Pager，主要类为 JXPagerView。当前已发布 Pod/tag 为 2.1.3，master podspec 虽写 2.1.4，不能把它当作已发布稳定版本。
- [JXSegmentedView](https://github.com/pujiaxin33/JXSegmentedView)：Swift 对应方案，当前 Pod 1.4.1；本项目优先 OC 的 JXCategoryView。
- [MJRefresh](https://github.com/CoderMJLee/MJRefresh)：当前 Pod 3.7.9，官方最低 iOS 12；提供刷新、加载和无更多数据状态，不替代后台分页 API。

以上 JX 仓库官方账号为 pujiaxin33，均未归档。版本是在本次核查时的发布情况，安装时仍应重新核对。

## YY 系列

| 组件 | 作用 | 建议 |
| --- | --- | --- |
| [YYModel](https://github.com/ibireme/YYModel) 1.0.4 | JSON 与 Model 转换 | 真实 DTO 出现后按需评估 |
| [YYText](https://github.com/ibireme/YYText) 1.0.7 | 复杂富文本显示、编辑、异步排版 | 普通标题和协议文本先用现有能力；复杂富文本需求成立时再验证 |
| [YYCache](https://github.com/ibireme/YYCache) 1.0.4 | 内存、磁盘缓存 | 明确业务缓存场景后评估，不与图片缓存或数据库重复承担同一数据的存储 |
| [YYKit](https://github.com/ibireme/YYKit) 1.0.9 | 多个 YY 组件及大量 Category 的合集 | 不整套引入，按实际需要选择独立组件 |

YY 四个仓库均未归档，但主分支最近提交停在 2017-08-06；仓库 push 时间更新不代表主线仍在持续维护。少更新不等于已存在漏洞，但需要为现代系统兼容预留验证和维护成本。作者已拆分独立组件，不需要为了其中一个功能装整套 YYKit。
