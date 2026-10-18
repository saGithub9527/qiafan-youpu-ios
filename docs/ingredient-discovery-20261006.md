# 食材 01–03 接入记录

设计依据为当前 05-食材 PNG、设计说明与全局图标规范。原布局、两列目录、固定筛选与独立结果滚动保持。

先核对现有 UIKit/SnapKit/MJRefresh/SPM，复用 UICollectionViewDiffableDataSource 做可重用目录卡片，既有 MJRefreshAutoNormalFooter 做上拉加载，没有再加网络或分页库。官方检索：
- https://developer.apple.com/documentation/uikit/updating-collection-views-using-diffable-data-sources
- https://github.com/CoderMJLee/MJRefresh

目录使用既有 catalog 扩展分类、库存范围与 iconKey；组合独立只读接口由服务器做有界匹配和数量确认。客户端不发起 AI、不用本地名称猜测标准食材 ID。选材最多40项，浏览和筛选只读，加入计划前先在现有确认页选日期餐次。

库存原位编辑支持精确同维度单位换算；不改原批次食材身份。计数包装没有已确认净含量时，不把个、袋、盒相互换算。42207明确整笔回滚后解冻草稿，用户可以更正或取消；未知网络结果仍使用原幂等请求。

临期按服务器完整作用域汇总，不从已加载页推断全量；客户端携带本地 IANA 时区，不修改服务器用户设置。过期筛选不等于食品安全判断。

验证正在进行；不能将编译通过视作功能与部署完成。
