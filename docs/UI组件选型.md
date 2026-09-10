# SwiftUI 组件与依赖选型

日期：2026-09-10。客户端已选择 Swift + SwiftUI 为主、UIKit 按需补充，依赖统一使用 SPM。当前欢迎、登录及四个一级页全部采用原生 SwiftUI，没有外部包。

## 当前采用的能力

| 能力 | 当前实现 |
| --- | --- |
| App 生命周期与页面组织 | `App`、`WindowGroup`、状态驱动根视图与自定义底部 Tab |
| 布局 | `VStack`、`HStack`、`ZStack`、`GeometryReader`、`safeAreaInset` |
| 欢迎横向分页 | `TabView` + `PageTabViewStyle` |
| 分类、搜索与列表 | 原生按钮、`TextField`、`ScrollView`、`ForEach` 与本地状态 |
| 月历 | Foundation `Calendar`、SwiftUI 网格与日期选择状态 |
| 通知、协议和提示 | SwiftUI 叠层、`fullScreenCover`、`alert` |
| 主题与图片 | `QFTheme`、语义颜色、SF Symbols、本地 Assets |
| UI 状态 | `@State`、`Binding`；引导完成和协议选择使用 `UserDefaults` |

现有页面可由这些能力完成。UIKit 在特定系统能力或复杂组件确有需要时，通过 `UIViewRepresentable` / `UIViewControllerRepresentable` 等薄适配层接入；当前页面没有以 UIKit 容器替代 SwiftUI 实现。

## 后续包接入原则

- 先确认实际能力缺口，再选择成熟框架；核查官方仓库、维护/归档状态、许可证、传递依赖与最低系统版本，确认可通过 SPM 接入。
- 同时检查 Xcode 26.3、Swift 6 编译器、当前 Swift 5 语言模式和 iOS 15 起的兼容性。星数作为参考，不替代验证；长期少更新本身不等于存在漏洞。
- 固定选定版本，提交 Xcode 实际生成的 `Package.resolved`，同步维护第三方依赖和许可证记录。当前零外部包，不创建占位锁文件或虚构许可证清单。
- 每次新增依赖后验证受影响页面及构建。页面样式、协议门禁与已确认业务规则保持明确，不随框架示例改变。

未来需要远程图片缓存、复杂富文本或嵌套滚动时，再针对具体场景比较原生能力与支持 SPM 的候选。下拉刷新、上拉加载只处理交互和加载状态；真实页码/cursor、请求、合并与错误处理仍属于未来业务数据层，当前不创建接口占位。

## 历史参考

旧 OC/UIKit 组件研究保存在 [历史：OC 组件选型](历史-OC组件选型.md)，对应代码基线为 Git 标签 `oc-uikit-baseline`。其中 CocoaPods、Masonry、QMUI、JX、YY 等结论描述当时的候选与使用状态，不构成当前 SwiftUI 工程的依赖清单。需要采用其中任一能力时，重新核查 Swift/SPM 集成及维护兼容。
