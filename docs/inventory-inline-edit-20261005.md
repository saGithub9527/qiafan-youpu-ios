# 库存列表、原位编辑和归档（2026-10-05）

本次对应计划17/21/22与食材04–06，不是整个库存成本模块完成。以设计档案05-食材的三张PNG和Emoji规范为依据，新增RAG `inventory-preparation-r1`；未修改设计源。

## 客户端与接口

计划页「备菜」现在push进入与食材共用的库存页；导航固定，扫描入口、两个Tab、搜索、单列库存按源图排列。手动添加沿用已有食材选择/入库页。待采购仍复用既有采购单流程，未把原采购功能删掉或重写。

库存ellipsis在当前卡片展开。数量和位置的输入仅保存在本地，草稿按环境、账号、个人/家庭scope隔离。取消不写接口；保存时一次PATCH，返回后只替换对应批次卡片。数量允许0，单位沿用该批次已确认基础单位。输入期间不让列表刷新覆盖草稿；原列表刷新/分页继续复用UIRefreshControl及MJRefresh。

- PATCH `me/inventory/lots/{id}`：currentQuantity、unitCode、location、expectedRevision、idempotencyKey。
- DELETE同地址：expectedRevision、idempotencyKey。先底部sheet确认，服务端归档；已有流水不删除、归档量不计入可用余额。
- InventoryLot新增createdAt，显示录入日期，不冒充购买日期；兼容旧接口没有此字段时的未知日期。

草稿在首次请求前先保存冻结body与UUID回执。超时、断网及权限变化保留回执供重试；40000明确参数错误可解冻，40900须用户选择重新加载后再编辑，不静默覆盖新版本。删除确认绑定原lot和原上下文，切换账号/家庭即失效。恢复卡不计入服务器分页数量；删除后重叠读取前一页、按ID合并，避免offset改变漏项。

## 当前边界

食材身份与基础单位暂为只读；改变它们需要保留历史食材关联和计量转换的完整业务设计，不能把用户改名称写入全局食材目录。此项仍是设计能力缺口，未当作已完成。

扫描小票/采购明细确认、自动重算已有采购单、成本来源净额/币种/规格/业务日期/移动加权历史重算仍未完成。删除文案明确「重新生成采购单时」按剩余量计算，不假装已经自动变更旧采购单。后端已查实回执/流水保留；后台仍缺库存只读审计入口，H5没有本次库存原生页对应入口，不增加无关页面。

图标优先标准ID专属Emoji，缺映射用分类Emoji；本次未把全目录UUID映射成专属图标，也未完成全APP图标替换。复用已在App内的同款Emoji图像资产，避免当前模拟器虽可解析AppleColorEmoji却渲染缺字框；不新增图像素材。资产缺失时再走Unicode/字体检查及同尺寸SF Symbol回退。设计要求的纯Unicode优先实现仍待字体问题核实，不把该项标为通过。

## 依赖依据与验证

复用已安装SnapKit、MJRefresh、UIKit UISheetPresentationController和本项目增量列表/草稿/缓存；本次无新SPM依赖。实际查询 [SnapKit官方仓库](https://github.com/SnapKit/SnapKit)、[MJRefresh官方仓库](https://github.com/CoderMJLee/MJRefresh)、[Apple sheet](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller)、[CoreText字体匹配](https://developer.apple.com/documentation/coretext/ctfontcreateforstring(_:_:_:))。业务编辑和幂等仍是薄适配层，不另建网络或事务框架。

十语资源1068条静态验证通过。第一次模拟器检查发现其他卡片被全局busy版本重建；截图同时发现删除图标固定宽度与按钮等分约束导致整列收缩，均已修复。后续52项通过后，独立审查新增了恢复分页、遗失草稿退出、跨家庭旧弹窗三项边界修复及对应回归。最终测试结果见阶段runs/2026-10-05/progress.md，不将编译/URLProtocol模拟数据当作MySQL、真实App后端或部署成功。

最终55项唯一模拟器用例通过，视觉修正及页脚状态稳定后42流程复验通过；本页十语首屏、法俄确认框已核查。真实隔离MySQL42份迁移、16组HTTP/锁/归档检查通过，未部署业务环境，未做App真实网络联调。

后端V41/V42须先迁移并部署，再对App开放新接口。后端接口与回滚限制详见 `后端/qiafan-youpu-server/docs/inventory-lot-edit-archive-20261005.md`。
