# 欢迎、协议与真实登录

SwiftUI 保留五页欢迎、协议通知与两种登录方式；通过根视图的 `QFAppSession` 环境对象使用网络和 Keychain，不在 View 内拼请求。

- `QFWelcomeView(onCompleted:)`：五页左右滑动；跳过及末页进入都先经过安全通知。仅完成后写欢迎标记。
- `QFLoginView(onClose:)`：默认不选协议，缓存勾选与取消；未选点击登录会打开既有安全通知，同意后执行一次所选方式。取消不保留待执行动作。
- `QFAuthViews`：共用通知、选择行、服务端协议正文与本地选择缓存。实际文本的 SHA256 修订只用于本地缓存失效；请求只传 agreementAccepted。
- `QFAppleAuthorization`：AuthenticationServices 原生授权，校验请求 state；只向后端交付 authorizationCode，不在客户端包含服务端 Apple 私钥。
- `QFAppSession`：配置开关、账号和凭证、会话刷新与恢复。登录成功才更新用户状态；配置未就绪、协议缺失、服务器失败不会产生本地假登录。

登录期间在对应按钮内部显示 Loading 并防重复操作；Apple 授权和随后网络请求全程保持等待状态。协议复选框与完整文字块垂直居中。关闭登录不删除已保存的设备凭证。设备号以公共头 Device-Id 发送，设备秘密凭证仅按已确认登录请求体发送。

测试环境的协议文本标明内部测试用途；正式文本和后台编辑页仍待确认与实现。欢迎 Debug / Release 规则、环境、诊断入口和真实联调方式见[项目 README](../../../README.md)。
