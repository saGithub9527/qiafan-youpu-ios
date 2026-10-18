# 计划09：记录原位修改与撤销

2026-10-01。依据设计档案 `04-计划与备菜/09-修改做菜记录.png` 和 `16-撤销做菜打卡确认.png`，合同 `plan-record-edit-r1`。保留奶油白背景、橙绿主色、四列表格、固定底部操作和 push 返回。此页的主流程已通过定向验证，不代表计划与食材模块整体完成。

## 页面与请求时机

历史记录的 ACTUAL_MATERIALS 类型进入新详情页。顶部修改/收起在当前页展开，日期、餐次、用量和单位先写本地草稿；没有变更点保存只收起，不发请求。数量变化立即隐藏旧成本，缺少库存价格时显示“成本待补全”，每项成本显示未知。

入页读取缓存中的单位；旧记录缺 revision 时获取一次详情。正常保存使用 PUT 返回值，并让关联记录、计划、库存、统计和采购缓存失效；不进行无条件整页刷新。发生不明确网络失败，原 requestId、expectedRevision 和完整请求留在本地并冻结，重试保持完全相同的载荷。此类重试成功后额外读取一次当前记录，因为幂等回执可能早于其他已提交修改。

409/404 读取服务器当前状态，只有用户明确选择重新载入才放弃本地更改；不自动提升版本覆盖别人修改。撤销使用居中遮罩确认卡片，确认后发送 DELETE 和当前 expectedRevision。服务端恢复原批次净剩余消耗；没有关联计划时不会创建计划。

请求参数及库存算法见后端 `docs/cooking-record-delta-edit-20261001.md` 和 OpenAPI。客户端增加 CookingRecord.revision、CookingDraft.expectedRevision/requestId；首次完成的 expectedPlanRevision 与历史编辑版本分开。NONE 仍使用原编辑页、不扣库存；LEGACY 的材料保持只读。

## 现有能力复用

已核查现有 SPM 依赖，继续使用 SnapKit 6.0.0、UIKit UIDatePicker/UIAlertController、现有会话缓存和本地草稿层，无新增依赖。对照 [UIDatePicker 官方文档](https://developer.apple.com/documentation/uikit/uidatepicker) 与 [SnapKit 官方仓库](https://github.com/SnapKit/SnapKit)，只写页面业务和设计卡片，不新增日期、网络或持久化框架。后端继续使用 Spring TransactionTemplate、MyBatis、Flyway。

## 验证

最终证据在项目 `协作流程/自主开发-20260930-20261006/runs/2026-10-01/`：

- `plan-ios-173321/test-summary.json`：17项定向流程全部通过（其中记录编辑/撤销5项），iPhone17Pro/iOS26.3.1，URLProtocol隔离响应；实际运行并检查了编辑和撤销截图。
- `backend-record-edit/result.json`：84项不重复服务/Mapper检查通过。此项不是MySQL实库验收。
- 本地化1038条、8份翻译资源加源码中英，共10语言通过；新增14条可见文案全部补齐。
- `design_rag.py verify plan-record-edit-r1`：源文件哈希、代码常量通过。

修复了首次编译的闭包self限定、测试等待API的iOS15兼容、确认卡片误用push、回调早于重试刷新、完成徽标被拉宽、修改数量后旧成本未隐藏等问题。早期失败日志保留，最终结果不覆盖失败历史。动画截图等待过短的问题通过等待过渡完成重新核查，没有为截图关闭生产动画。

## 部署、后台和剩余边界

必须先运行V39迁移并部署新后端，再交付依赖记录版本的客户端。V39真实MySQL/Flyway执行、真实HTTP差额链路、跨家庭成员并发、进程中断恢复及App真实网络联调尚未验证；本轮没有部署。

库存价格/币种来源、逐项成本、过期批次策略尚未完成；材料增删后端已支持，09页面目前只修改已有材料的数量和单位。后台尚无库存流水审计页，既有单位/换算维护继续使用。没有新增对应H5页面或公开接口，也未把后台与H5记成已验收。下一步优先完成V39隔离数据库验证，再核对07/08与库存价格直接依赖。
