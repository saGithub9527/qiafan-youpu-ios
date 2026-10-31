# 订阅审核账号登录 r4

用户2026-10-31要求提供能实际登录并查看完整功能的审核账号，同时保留订阅内容。本补充只增加必要的正常账号密码登录；r3的订阅和AI暂停边界不变。

- 登录页保留快捷登录、Apple登录、现有协议同意和关闭。服务器明确声明password能力时，显示“账号密码登录”；点开后原位展开账号与密码输入框。键盘出现时内容可滚动，不遮挡提交。
- 账号为已经绑定的账号，密码为用户已经设置的密码。密码不落盘、不记录日志；错误密码/不存在/停用/未设密码统一提示。加载期间不重复提交。
- 所有用户使用同一路径；不按审核人员、IP、日期或设备显示隐藏能力。不新增审核专用万能密码，不自动生成或绑定账号，不授予付费权益。
- 通过现有协议勾选后，单次POST登录；服务端复用既有幂等、加密回执、会话与设备隔离。密码登录使用独立账号会话，不覆盖本机快捷登录凭证和Apple绑定。
- 登录成功仍经过同账号服务端订阅核验；不能以登录成功代替已解锁。已解锁审核账号和独立未订阅/已过期购买审核账号仍需实际配置与联调。
- 旧服务器缺少能力字段时不展示未就绪入口；退出后可选择其他登录方式。UI使用UIKit/SnapKit，十语文案、无障碍标签和安全密码填充沿用系统机制。

复用Spring Security DelegatingPasswordEncoder/PBKDF2、既有Caffeine限流和数据库事务，不新增依赖。审阅依据：https://docs.spring.io/spring-security/reference/features/authentication/password-storage.html 和 https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review 。源码与定向检查不等同于线上账号或真实支付通过。
