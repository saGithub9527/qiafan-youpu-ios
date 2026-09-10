# 本地崩溃报告

应用启动时调用 `QFCrashRecorder.shared.start()`，保存返回状态便于排查初始化失败；重复调用不会重复安装采集器。`QFCrashRecorder.shared.reportsDirectory` 返回本次安装的真实沙盒 URL：

`Library/Application Support/Diagnostics/Crashes`

此功能只写本地文件，没有上传、网络服务或主动触发崩溃的入口。Debug 启动时检测到调试器便跳过采集（仍会处理上次 pending），避免干扰 Xcode 调试。Debug 无法查询调试器状态时也不安装采集器。连接调试器前已经启动的采集器无法通过这个启动检查追溯停用。

## SwiftPM 集成

- 官方仓库：<https://github.com/microsoft/plcrashreporter.git>
- 锁定版本：`1.12.2`，product / Swift module：`CrashReporter`。
- [版本发布](https://github.com/microsoft/plcrashreporter/releases/tag/1.12.2)于 2025-11-12；核对时仓库未归档。SwiftPM 清单要求 Swift tools 5.3 / iOS 11，README 支持 iOS 12 起，均覆盖本项目 iOS 15。
- [许可证](https://github.com/microsoft/plcrashreporter/blob/1.12.2/LICENSE)主体为 MIT 式许可；编码器含 Apache 2.0 部分，随包 protobuf-c 1.4.0 源码另有 BSD-2-Clause 声明。`Resources/ThirdPartyAcknowledgements.txt` 保留顶层 LICENSE、这些源码版权声明以及 Apache 2.0 全文，随 App 资源打包。

由 PLCrashReporter 安装 Mach 异常、信号和未捕获 Objective-C 异常采集。应用没有自写 signal handler 或异常处理器；Swift 转换、JSON 编码与归档清理只在正常启动执行。

## 文件及转存

SDK 在 `.pending` 下保存最多 2 MiB 的原始报告。下次启动读取并生成一个 `report-<SHA256>.crashbundle` 文件夹：

- `raw.plcrash`：原始 PLCrashReporter protobuf 报告，保留原始堆栈供离线分析。
- `report.crash`：Apple 风格可读文本，包含堆栈和 Binary Images；未符号化地址需要 dSYM。
- `metadata.json`：采集库版本、崩溃时的应用版本 / build、时间、报告 UUID、信号、每个二进制镜像的 UUID / 加载地址 / 大小 / CPU 信息。

完整写入暂存目录并重命名成功后才删除 SDK pending。失败时保留 pending，停止本次采集启动，防止下一次崩溃覆盖未转存记录。重复转存按原始报告 SHA256 去重。解码失败也保留原始文件，并把失败原因写入文本和 JSON。

目录排除 iCloud / iTunes 备份；应用创建的目录权限 0700、归档文件 0600，使用 `completeUntilFirstUserAuthentication` 文件保护。SDK 的原始文件继承受保护父目录的文件保护，首次解锁前不可读，首次解锁后允许锁屏期间写入。

已归档记录最多 19 条、文件内容合计 18 MiB，按文件夹修改时间删除最旧整条记录，为下一份 pending 预留 1 条 / 2 MiB；总上限 20 条 / 20 MiB（文件内容字节数，不含文件系统块和目录元数据）。超预算的单条转换结果保留 pending 并返回失败，不截掉原始报告。没有待处理崩溃时不会制造空报告。

## 离线分析

使用 Xcode Devices and Simulators 下载应用容器，在上述目录取出整个记录文件夹。报告可能含线程、符号、异常原因和本地路径，应只交给参与排查的人；功能本身不向外发送。

保留产生该崩溃的 `.xcarchive` 及其 `dSYMs`。用 `dwarfdump --uuid <binary-or-dSYM>` 对照 `metadata.json` 的 `binaryImages[].uuid` / 文本 Binary Images，匹配相同 UUID 的构建。应用更新后的 dSYM 不能替代旧版本 dSYM。dSYM 不会打包进 App，也不写进崩溃目录。

PLCrashReporter 记录的异常/信号崩溃不等于所有退出原因：SIGKILL、系统强杀、部分内存耗尽或 watchdog 终止没有机会执行采集器。正常退出不生成报告。不在单元测试中安装采集器或制造进程崩溃；归档测试使用隔离临时目录验证转存、去重、保护和容量淘汰，并通过 SDK 的进程快照 API 验证 UUID 转换。模拟器验证文件权限和排除备份；硬件 Data Protection 属性需在真机验证。
