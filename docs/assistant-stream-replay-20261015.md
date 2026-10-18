# 流式聊天重放边界修正（2026-10-15）

旧逻辑用 `QFAPIError.code == 40100 && !received` 判断刷新；但 received 只在业务认可的 status/delta/reasoning 回调中置位。首个SSE事件若为 error40100，或先出现未知事件再出 error40100，就可能触发刷新并重新提交该POST。正文中的错误码不具备授权重放的资格。

修正仅涉及 `QFAssistantStream.swift` 与 `QFAppSession.swift`：流终止时必须同时满足**可信HTTP状态为401、没有收到任何完整SSE事件、错误为已解析HTTP错误**，才产生内部 `QFAssistantStreamHTTPUnauthorized` 标记。Session只捕获此标记，沿用既有刷新与作用域/取消检查，最多重新发起一次同编号请求。第二次HTTP401还原为既有QFAPIError向页面报告，不循环刷新。

所有SSE事件在识别名称、校验ID、解析正文之前置位，包括未知/error/done。非2xx的SSE也会被有界解析以关闭重放资格，但不会把其delta/done提升为成功。HTTP200 JSON正文即使写code40100也不能触发刷新；取消、超时和无HTTP响应亦不获得资格。请求头、API路径、SPM依赖、Alamofire无重连配置、积分编号及页面文案保持既有合同。

新增6个URLProtocol定向用例，放入已在工程内的 `QFAlamofireTransportTests.swift`，避免新增工程文件引用：前置HTTP401、无JSON的401、其他HTTP状态携带code40100、首个SSE error40100、未知SSE后HTTP401、非2xx的伪done。它们拦截测试专有 `.invalid` 主机，不连接外网。**本子任务未运行XCTest、构建、模型、服务或手机操作**。

优先的纯Swift宿主入口（由主任务等重任务空闲后串行执行）：

```sh
python3 scripts/tests/assistant_stream_replay_check.py
```

该入口提取**实际生产** finish 函数及HTTP拒绝标记，使用Foundation宿主替代无关DTO和continuation/cancel句柄，覆盖18个失败场景与成功终止的幂等性；同时精确检查生产SSE循环先置位、Session仅捕获专用标记。没有复制重放判断，也不执行App或模型；编译/运行有45/10秒上限，任务临时目录与模块缓存退出即清理。这个检查验证终止分类与源码接线，不能代替真实Alamofire流顺序、会话刷新、代理或手机联调。需要完整运行时验证时，可定向执行现有test target中的6个新增方法。

当前仅静态读取及 `git diff --check` 完成；运行结果待主任务记录。源码在交接后冻结，后续主任务统一增量构建与XR离线检查。后端8类39项通过的实测结果已同步至后端 `docs/assistant-streaming-chat-20261015.md`，不将其当作客户端新用例的通过证据。
