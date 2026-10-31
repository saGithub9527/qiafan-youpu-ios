# TestFlight 订阅验证

`QiafanYoupu-TestFlight` 使用独立 `TestFlight` 配置，继承 Release 的优化、源文件排除、权限和 Info.plist；只将业务接口固定到现有测试后台。不编入 `DEBUG` 诊断入口，不改变 AI 关闭及订阅校验规则。

正式 `Release` 继续要求真实生产地址，不能使用测试后台。未配置正式地址时仍会阻止正式归档。

本轮只分发内部测试。归档后使用 `Export-TestFlightInternal.plist` 上传；其中 `testFlightInternalTestingOnly=true` 由 Apple 限制该包不能提交 App Store 或外部测试。不要改成普通 App Store 分发来处理上传失败。上传前检查唯一构建号、签名团队和归档中 `QFAPIEnvironment=test`、`QFAPIBaseURL=https://test-api.yzsalingo.com/api/v1`。

Apple 处理成功后，将该构建手动加入 `Qiafan Subscription Testing`，由已接受团队邀请的测试员安装。TestFlight 内购使用 Apple 沙盒，不产生实际费用；需实际完成购买、服务端验证和恢复购买才能记录支付链路通过。测试组或邀请创建成功不代表这些步骤完成。

参考：
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers
- https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight
