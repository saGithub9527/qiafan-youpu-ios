# 小票扫码与印字识别（2026-10-09）

用户要求在没有商家二维码样本时识别小票上的商品、数量和价格。`receipt-scanner-r2` 记录了相对已确认 `r1` 页面的明确例外：保留深绿色扫描页、固定导航和扫描框，在底部增加系统文档拍摄入口。

## 已实现

- 相机或相册读取二维码。台湾财政部电子发票 v1.9 的左右双码按固定表头、笔数、编码类型、品名、数量和单价解析；只导入完整编码的项目。卖方统一编号与票面总额仅作为本地核对提示，不冒充商家名称，也不声称已验证发票真伪。
- 普通小票二维码若只含链接、交易号或其他无法解出的内容，不访问其 URL，不从编码推测商品。可转用系统文档相机拍摄印字小票。相册照片也会尝试本机文字识别。Apple Vision 识别文字后，同一行的“品名、数量、金额”、带单价的四列格式，以及品名与“数量 × 单价、金额”分成相邻两行的格式可以进入草稿。带单价的格式要求乘积与行金额吻合；无法明确对应的文字不自动补出商品，扫描失败提供手动录入。
- 识别结果仅写入本地采购草稿。用户需核对商家、币种、品名、数量、单位、价格，并把需要入库的商品逐项绑定到食材目录。保存前不调用采购写入接口；未绑定食材不能保存或入库。已有未保存采购草稿时阻止导入第二张，避免混单。
- 沿用现有采购 `PUT /api/v1/me/purchase-receipts/{id}`、幂等请求和库存事务；没有新增服务器接口或数据库表。扫描卖方编号和票面总额不进入该 API 请求。

## 依据和选型

- [台湾财政部电子发票一维及二维条码规格 v1.9](https://www.einvoice.nat.gov.tw/static/ptl/ein_upload/attachments/1575448081679_0.pdf)：明确双码结构、商品笔数、品名、数量与单价；规范没有商家名称字段。
- [Apple Vision 条码读取](https://developer.apple.com/documentation/vision/detecting-objects-in-still-images)、[Vision 文字识别](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)、[VisionKit 文档相机](https://developer.apple.com/documentation/visionkit/vndocumentcameraviewcontroller)：复用系统能力，不增加扫码或 OCR SDK。
- 检索过 [InvoiceQR_ios](https://github.com/CookieNotSession/InvoiceQR_ios)（旧项目、外部专用 API）、[QRCodeReader.swift](https://github.com/YannickL/QRCodeReader.swift)（重复现有 Apple 解码）、[einvoice_sdk](https://github.com/kevinchung0921/einvoice_sdk)（Android/Kotlin，且 API 查询需密钥）；均不适合作为当前 UIKit/SPM 解析依赖。

## 验证边界

- iOS 模拟器定向 `QFPurchaseCostTests` 29/29 通过，含财政部示例双码、模糊文本拒绝、清晰模拟小票 Vision 识别、分行及四列印字格式、草稿隔离与现有采购流程；结果见 `协作流程/自主开发-20260930-20261006/runs/2026-10-09/receipt-layout-test.xcresult`。调试版构建、十语文案校验 1183 项、`receipt-scanner-r2` 设计源校验已通过。
- 尚无真实商家小票样本，不能宣称所有商家或各国语言的印字小票都能准确识别。二维码没有商品明细时，扫码本身无法产生商品。OCR 对折扣、退货、税额、连字、多列及低质量照片仍需用户逐项核对；商品单位不在台湾二维码规范内，默认以“件”作为待核对草稿值。
- 当前采购账单是“食材采购并入库”模型。非食材商品可以从扫描结果中看到，但不能未经目录匹配直接入库存；需要删除该行或另行设计非库存支出模型。真机相机拍摄、真实商家样本与实际入库端到端尚未通过，不能用模拟器测试代替。
