# 悬浮助手光球接入 · 2026-10-14

用户取消人形角色制作，确认独立手机 Demo 的光球后要求接入 App。本次替换助手展示及其效果选择，聊天、登录、通知和业务请求保持现有入口。

## 当前行为

- 原右下角助手位置显示三维光球，外围背景透明，球面保持浓郁青蓝色；每 3.4 秒收缩一次，随后发亮并恢复。主光圈同步收缩，外圈在发亮阶段向外扩散并淡出。
- 自动律动并围绕纵轴每 48 秒旋转一周，粒子以更慢速度相对流转。用户要求移除效果选择入口，现已移除按钮、面板和相关回调。既有问候、聊天事件只触发同色光波。
- 主色 `#078F8B`、辅色 `#2344A6`，降低发亮时混入白色的比例，增加球面不透明度，避免浅色页面把球体冲淡。原生备用渐变光球同步配色、旋转和心跳。
- 浮动问候、聊天欢迎、助手回复和思考消息共用深蓝→青色渐变气泡（`#102039`→`#133E48`），浅薄荷正文（`#D6F5F0`），青色细边与低强度光晕；支持 Dynamic Type。问候完整文案先布局，再 0.65 秒淡入、0.4 秒淡出，避免逐字出现使气泡变形；减弱动态时为 0.15 秒。用户消息保持既有区别。
- 点击光球沿用原生聊天按钮。光球网页自身不接收点击，不覆盖父按钮；独立非 key 窗口继续采用 `alert + 1`，空白区域穿透。
- 后台、场景失活及未挂载窗口时暂停；前台恢复继续。系统减弱动态时保留静态光球。网页 ready 前保存最新状态，避免后台加载完成后自启动。

## 实现与来源

`Packages/QFOrbRenderer` 是本地 SPM 包，使用系统 WebKit、现有 SnapKit 6.0.0 和离线资源。`QFAssistantCharacterView` 保留现有助手调用边界，内部改为光球；旧人物动作、表情与 Filament 切换入口已替换。

着色、粒子和周期沿用用户确认的 Demo，并按用户最新要求调整旋转、配色与白色高光。源文件增加嵌入暂停、结构化桥、首帧 ready、错误恢复和透明容器适配。Three.js 0.186.1（MIT）锁文件与官方许可证保存在包内，App 的第三方声明同步更新。

本次复核现有 Three.js 与系统 Core Animation 能力，采用既有 [Object3D rotation](https://threejs.org/docs/pages/Object3D.html)、[ShaderMaterial 色彩管理](https://threejs.org/manual/pages/color-management.html)与 [Core Animation](https://developer.apple.com/documentation/quartzcore)，保留现有 SDK 和版本，不增加动画框架。原生文字仅改变展示样式，不改聊天模式、消息内容或请求。

采用 [Apple WKWebView 本地文件加载](https://developer.apple.com/documentation/webkit/wkwebview/loadfileurl(_:allowingreadaccessto:)) 与 [Swift Package 资源](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package)。将原 ES 模块经 [esbuild IIFE 格式](https://esbuild.github.io/api/#format)打包成普通脚本，避免本地模块加载的 CORS 问题；不开放文件访问私有开关、不启动本地 HTTP 服务。导航限制在资源目录，CSP 禁止网络连接。

运行文件约 535 KiB，实际字节数和 SHA-256 见 `Packages/QFOrbRenderer/runtime-manifest.json`。源文件与工具版本锁保留在 `WebSource`，不进入运行资源包。重建方式：`python3 scripts/build_assistant_orb.py --esbuild <已核实的 0.28.2 CLI>`；正常 Xcode 构建无需 Node、网络或打包工具。

弱消息转发器避免持有环；WebGL 初始化失败时保留原生渐变光球，非零尺寸有效首帧后才切入网页；内容进程终止只在前台有界重载一次。原生调用使用结构化参数，不拼接聊天内容到 JavaScript。

## 验证

- Debug / generic iOS Simulator 架构客户端编译通过（未启动模拟器或 App）。首次编译发现 WebKit 参数标签错误，已修正，第二次编译退出码 0。
- SwiftPM 打包的 HTML、JavaScript、许可证三个文件全部与源运行清单的 SHA-256 一致。
- JavaScript bundle 语法检查通过；十语文案校验通过（1356 条文案，8 个非中英文资源表）。
- `recipe-home-r7` 源哈希与源码合同校验通过，未改首页业务布局。
- 尚未做真机显示、聊天点击、后台恢复或能耗验收，不能把编译通过当作手机视觉通过。

上述客户端构建和页面检查记录属于风格修改前的版本。本次旋转、加深颜色、移除选择和统一气泡完成后，已重建离线 bundle，运行资源和源文件 SHA-256 一致；十语文案校验通过（1350 条文案，8 个非中英文资源表）。无助手对应的 RAG baseline；本次局部展示变化以用户明确要求为依据。

本次未追加客户端构建、App 运行、浏览器或真机验收。人工验收：重新运行最新 App，观察光纹缓慢旋转，收缩、发亮及扩散仍为单次慢循环；确认效果选择按钮已移除，问候与聊天回复气泡统一且文字完整；切后台和回前台确认暂停与恢复。独立 Demo 的三个入口同步更新，刷新当前页面即可查看。

## Xcode 本地包加载修复

用户报告 `Couldn't load project` 与 `Missing package product`。Xcode 26.3 日志确认同一个包目录被同时作为 Folder 和 Swift Package Dependency 打开，导致容器类型冲突。命令行编译通过不能证明 Xcode 界面已成功加载包。

XcodeGen 2.46.0 为本地包生成了真实的 `XCLocalSwiftPackageReference`，同时生成 `PBXFileReference` Folder。修复移除两个重复的导航 Folder 对象及其 group children，原样保留真实包、产品、构建阶段和远程依赖。[生成器源码](https://github.com/yonaskolb/XcodeGen/blob/2.46.0/Sources/XcodeGenKit/SourceGenerator.swift#L57)中 Folder 是自动创建的；`excludeFromProject` 会同时移除真实本地依赖，因此不采用。

`project.yml` 使用官方支持的 [postGenCommand](https://github.com/yonaskolb/XcodeGen/blob/2.46.0/Docs/ProjectSpec.md#options)，执行 `scripts/remove_duplicate_local_package_folders.py`。脚本通过系统 plutil 解析，按类型和路径识别重复对象，不固定 UUID；写入前比较完整工程图，只允许上述删除，其他用途或缺失包声明均拒绝修改。重复执行不写文件。

实际验证：修复前 `--check` 退出码 1，准确指出两个重复 Folder；`xcodegen generate` 触发挂钩后退出码 0，`--check` 通过，再次修正时 SHA-256 未改变。重新打开工程后，Xcode 导航已显示两个 local Package Dependencies。21:13 在 Xcode 内以 Any iOS Simulator Device 执行 Build，显示 Build Succeeded，错误导航为空，两条 Missing package product 已消失。随后恢复用户原来的 Shu 真机目标。

本次仅验证工程加载与编译，没有 Run、启动模拟器或安装 App；真机显示仍交用户验收。复用既有 Xcode 和 DerivedData，构建已结束，工程窗口保留供用户继续使用。脚本临时文件在成功和异常路径均释放，未清空缓存或创建新服务。

## 资源与清理边界

复用现有 DerivedData，编译进程已结束，未创建模拟器、浏览器页、服务器或持续 watcher。已释放任务自有临时 esbuild 和一次性修改脚本。原 Demo 服务 PID 95694 保留供比对，App 完全不依赖该服务；安全停止方式位于独立 Demo 的 `stop-demo.py`，会核对进程身份。

取消的人物 Debug 预览构建阶段已移除，当前编译产物没有 `AssistantPreview/cooking-fairy.glb`。旧角色源资产、旧渲染源代码与相关历史依赖保留；整个项目的后续清理仍以 App 验收后的范围为准。
