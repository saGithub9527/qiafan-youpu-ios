# Hunyuan3D 料理精灵运行时资产设计

## 目标

将 `协作流程/角色资产/hunyuan3d-pro-v1-20261012/cooking-fairy-v1-pbr.glb` 作为唯一外观基准，补齐移动端可用的拓扑、骨骼、表情目标和稳定节点，并接入现有 UIKit + SceneKit 饮食助手浮层。角色点击区域、问候气泡、对话接口、无障碍入口和旧模型回退行为保持不变。

## 已核实事实与边界

- Hunyuan 资产由 Tencent Hunyuan3D Studio 的 `3D Generation - V3.1` 多视图几何和 `Image-to-Texture / Multi-View` PBR 流程生成。
- 主 GLB 当前约 1,499,694 面、749,823 顶点，只有 1 个网格节点和 1 个材质，包含 base-color、normal、metallic-roughness 纹理。
- 当前 GLB 的 `skins=0`、`animations=0`，原文件没有骨骼、动画或表情目标；不能通过复制文件或增加空节点直接满足运行时需求。
- Hunyuan Retopology/Bone Binding 当前受 500,000 面上限阻塞；已有 mobile candidate 仍是静态单网格，不能当作已绑定交付。
- 当前 App 的 `QFAssistantRigView` 从 `assistant-character` Data Set 加载旧 `.scn`，并通过命名节点驱动姿势、眨眼和情绪；该入口必须继续可用。
- iOS 最低版本保持 15.0；不增加第三方 SPM 包，不加入网络模型下载，不修改助手业务 API。

## 设计选择

### 资产生产

保留 Hunyuan PBR GLB 为只读源资产和视觉基准，在离线资产生产阶段生成一个独立的运行时交付包。运行时包的网格预算为不超过 500,000 个三角面，并保留正面、三分之四、侧面和背面轮廓，以及帽子、头发、眼睛、围裙、领巾、花饰和鞋等识别细节。重拓扑或减面后重新建立 UV，并重新烘焙/保留 base-color、normal、metallic-roughness 三条材质通道；所有纹理必须内嵌或位于 USDZ 包内。

最终运行时资产必须使用真实的骨骼蒙皮数据：网格 primitive 需要包含 `JOINTS_0` 和 `WEIGHTS_0`，而不是只有挂在骨骼节点下的刚体网格。骨骼名称固定为：

```text
root, pelvis, spine, chest, neck, head,
upper_arm.L, forearm.L, hand.L,
upper_arm.R, forearm.R, hand.R,
thigh.L, shin.L, foot.L,
thigh.R, shin.R, foot.R
```

面部使用可独立组合的 blendshape/SCNMorpher 通道，名称固定为：

```text
face_neutral, face_happy,
face_blink_L, face_blink_R,
face_surprised, face_thinking
```

中性状态要求双眼睁开、左右眼对称、默认视线正前方、嘴部轻微自然微笑。表情目标不能改变头部比例或污染帽子、头发、围裙和其他服装权重。需要为运行时定位建立稳定 locator 节点，至少包括：

```text
character.root, character.head,
character.left-eye, character.right-eye,
character.left-brow, character.right-brow,
character.mouth,
character.left-arm, character.right-arm,
character.left-leg, character.right-leg
```

动画至少提供 `CookingFairy_Idle`；欢迎、挥手、思考、兴奋等短动作可由 App 在骨骼节点上叠加，但不能覆盖当前面部形变权重。

### App 运行时

新增 `QFAssistantModelAsset` 适配层，职责是读取运行时 USDZ、检查必要节点和 morph 通道、归一化模型尺度/朝向、提供节点映射，并返回结构化诊断。适配层不包含聊天业务和页面布局。

加载顺序为：

1. 从 `cooking-fairy-mobile` Data Set 读取 USDZ 数据。
2. 优先通过 Model I/O 创建 `MDLAsset`，再转换为 SceneKit 场景；若系统支持且可验证，也允许直接使用 SceneKit 场景源。
3. 校验根节点、骨骼、locator 和表情通道；任何必需项缺失、纹理不可读或场景为空时，返回失败诊断。
4. `QFAssistantRigView` 使用新适配器的节点映射驱动表情和姿势；失败时完整回退现有 `assistant-character.scn` 和程序化模型。

Apple 的 `SCNScene` 提供从 `MDLAsset` 创建场景的系统接口，作为 USDZ 到 SceneKit 的适配边界：[SCNScene sceneWithMDLAsset](https://developer.apple.com/documentation/scenekit/scnscene/1419833-scenewithmdlasset?language=objc)。

现有情绪 API 继续使用 `happy`、`thinking`、`calm`、`excited`、`sad`、`angry`。适配层将这些状态映射到新表情目标：

| 现有状态 | 新表情组合 |
| --- | --- |
| `calm` | `face_neutral=1` |
| `happy` | `face_neutral=1` + `face_happy=1` |
| `excited` | `face_happy=1` + `face_surprised` 低权重 |
| `thinking` | `face_thinking=1` |
| `sad` | `face_neutral=1`，由眉毛/嘴部节点做轻微姿态调整 |
| `angry` | `face_neutral=1`，由眉毛节点做轻微姿态调整 |

眨眼由 `face_blink_L` 和 `face_blink_R` 独立驱动，遵守 `UIAccessibility.isReduceMotionEnabled`。表情权重始终限制在 `0...1`，切换前清理不相关目标，避免状态叠加后冻结或残留。

### 资源与回退

运行时交付包括：

- `cooking-fairy-mobile.usdz`：App 首选资源，包含 PBR、骨骼、蒙皮、表情和动作。
- `cooking-fairy-mobile.glb`：离线交换与诊断资源，不直接由当前 App 加载。
- `production-report.json`：记录拓扑、骨骼、表情、纹理、导出工具、SHA-256 和未验证项。

资源进入 `Assets.xcassets/cooking-fairy-mobile.dataset`。不删除或覆盖 `assistant-character.dataset`，以便资源损坏、USDZ 不兼容或必需节点缺失时安全回滚。首次接入不支持远程模型更新。

## 数据流

```text
Hunyuan PBR GLB（只读源）
  -> 离线重拓扑 / LOD / UV / PBR 复核
  -> 骨骼蒙皮 + 表情目标 + locator 节点 + Idle 动作
  -> cooking-fairy-mobile.usdz / .glb
  -> Assets.xcassets Data Set
  -> QFAssistantModelAsset
  -> QFAssistantRigView
  -> QFDigitalAssistantOverlay
```

场景加载失败只影响角色渲染资源，不影响浮层点击、问候气泡、对话面板、网络请求或本地回退角色。

## 文件边界

- 新增离线资产生产脚本或配置：放在 `协作流程/角色资产/hunyuan3d-pro-v1-20261012/`，不得将 Blender、重拓扑工具或服务端凭据放入 App。
- 新增运行时资产报告：放在 `客户端/qiafan-youpu-ios/docs/assistant-character-concepts-20261012/cooking-fairy-runtime/`。
- 新增 Swift 适配器：`客户端/qiafan-youpu-ios/QiafanYoupu/Features/Assistant/QFAssistantModelAsset.swift`。
- 修改角色渲染驱动：仅修改 `QFDigitalAssistant.swift` 中 `QFAssistantRigView` 的资源加载、节点绑定、表情和动作驱动部分。
- 新增资源目录：`客户端/qiafan-youpu-ios/QiafanYoupu/Resources/Assets.xcassets/cooking-fairy-mobile.dataset/`。
- 新增定向测试：`客户端/qiafan-youpu-ios/QiafanYoupuTests/QFAssistantModelAssetTests.swift`，覆盖缺资源、空场景、缺节点、表情映射和回退诊断。

## 错误处理

- 缺少 Data Set 或 USDZ 无法解码：记录本地诊断码，立即使用旧 `.scn`。
- 场景可加载但缺少任一必需 locator/骨骼/表情通道：拒绝部分接入，使用旧模型，报告缺失名称。
- 纹理资源缺失或路径越界：拒绝新资源，避免显示无材质角色。
- 表情通道不存在：仅允许在旧模型适配器中使用节点可见性回退；新模型不能静默把固定表情当成动态表情。
- 减弱动态效果开启：停止 idle、欢迎和眨眼循环，保留中性静态角色。

## 验收与证据

资产级检查：

- USDZ 包可解包，纹理全部存在且无外部绝对路径。
- GLB/检视报告确认三角面数、`JOINTS_0`、`WEIGHTS_0`、18 根骨骼、`CookingFairy_Idle` 和 6 个表情目标。
- 节点报告包含所有固定 locator 名称和骨骼名称。
- 正面、三分之四、侧面、背面与 Hunyuan 输入图逐项人工对照；无法证明的隐藏细节记录为未验证。

App 级检查：

- 资产加载成功时显示 Hunyuan 角色，失败时显示旧角色并保留点击/问候/对话流程。
- 中性、开心、思考、惊讶、左右独立眨眼均能切换，表情不会被姿势动画覆盖。
- `Reduce Motion`、浅色/深色背景、无障碍标签和当前情绪值保持正确。
- 仅运行当前页面需要的资源/加载检查；未执行的模拟器、真机或性能检查必须标记为未验证。

最终视觉和真机验收由用户完成；在用户确认前不删除旧资源，也不把新资产标记为 Release 唯一资源。

