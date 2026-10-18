# 欢迎与登录

Swift + UIKit + SnapKit。QFWelcomeViewController提供五页原生分页，QFLoginViewController提供快速/Apple登录，QFSafetyNoticeViewController复用底部安全通知，QFAuthAgreementViewController显示服务端协议正文。表单最大宽520pt，窄/矮窗口与iPad横竖屏通过SnapKit和滚动容器适配。

AUTH-01（2026-09-12，G1/G2/G3）：Apple 登录使用官方 ASAuthorizationAppleIDButton（signIn），55pt 高、login.apple 标识；经典橙/自然绿浅底使用黑色，深色主题使用白色。保留官方标题和内部视图，按钮外预留状态行：授权时“正在等待 Apple 授权”，提交时“正在登录”，结束停止等待。快速登录和配置重试保留按钮内 Loading。配置或必要协议未就绪、Apple 渠道关闭时禁用 Apple 按钮；渠道关闭显示“Apple 登录暂不可用”，配置失败显示“登录信息加载失败，请重试”及原重试入口。

协议复选框与完整文字块垂直居中，默认未选，勾选/取消勾选写本地缓存；正文改变后重新确认。未勾选点击可用登录入口先显示安全通知，同意后只提交一次原登录请求。取消静默返回，不提交、不自动重新授权；失败按阶段及业务码展示冻结文案，不透传底层错误。40101 不解释为 Apple 授权失效，40903 仅提示“当前 Apple 身份无法用于此设备的账号登录。”及“知道了”，无绑定指引。

QFAppSession保持原会话规则，Combine驱动界面，Alamofire执行请求；Keychain设备号/秘密凭证不因UIKit迁移而变化。QFAppleAuthorization使用AuthenticationServices并处理取消与迟到回调；未在客户端加入Apple服务端私钥。

欢迎Debug每次显示；Release完成首次通知后不重复。登录成功才更新用户状态，不做本地假登录；当前协议仍为内部测试文本，真机Apple授权与正式环境验收另行完成。

本轮变更、定向检查与最终真机步骤见 [AUTH-01 iOS交付记录](../../../docs/auth-01-ios.md)。历史验证不代表本轮运行验收。
