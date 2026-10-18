# 饮食助手 3D 角色实现记录（2026-10-11）

## 本次交付

原来的助手是 `UIImageView` 图片，再叠加一层骨骼线条。现在 `QFDigitalAssistantOverlay` 从 `assistant-character.dataset` 加载独立的 `assistant-character.scn` 角色模型，通过透明 `SCNView` 渲染。模型内的头部、眼睛、瞳孔、眉毛、嘴部、躯干、围裙、手臂、前臂、手、腿和鞋都是独立节点；角色的动作和表情直接改变这些节点的 3D 变换和可见状态，因此不会再出现“静态图片不动、骨骼在图片外面”的效果。

已加入的角色状态：

- 表情：`happy`、`thinking`、`calm`、`excited`、`sad`、`angry`；眼睛、眉毛和嘴部会同步变化。
- 姿势：欢迎、挥手、思考、平静、兴奋、难过、生气。
- 动作：入场问候挥手和轻微抬升、打开对话时兴奋动作、待机状态随机姿势、独立眨眼循环。
- 动效：透明背景、物理材质、三点灯光、抗锯齿、30 FPS 上限；开启“减弱动态效果”时停用循环动画。
- 无障碍：浮层标识为 `assistant.3d-character`，当前表情写入 accessibility value。

本轮新增角色资产：

- `QiafanYoupu/Resources/Assets.xcassets/assistant-character.dataset/assistant-character.scn`：依据现有静态吉祥物 `qf-assistant-mascot.png` 重做的独立可复用角色模型资产，客户端优先加载它，资源不可用时才使用同色系程序化构建作为开发回退。
- `QiafanYoupu/Resources/Assets.xcassets/assistant-badge.imageset/assistant-badge.png`：仅作为角色胸前的附属品牌饰件挂载在 `SCNPlane` 上；它不是角色本体，也不承担角色显示。

## 静态资源到模型的对应关系

模型不是凭空生成的通用人形，而是按现有静态资源的可辨识特征重建：

| 静态资源特征 | 3D 模型对应 | 运行时节点 |
| --- | --- | --- |
| 桃色/橙色大体积头发、刘海、两侧卷发和顶部发束 | 多个球体、盒体与胶囊体组成的发型轮廓 | `assistant.hair`、`assistant.fringe`、`assistant.left-curl`、`assistant.right-curl` |
| 深绿色叶片发带与侧边白色花饰 | 发带、叶片、花瓣和金色花心 | `assistant.headband`、`assistant.leaf-*`、`assistant.hair-flower-*` |
| 夸张的绿/琥珀色大眼、眼神高光和脸颊红晕 | 分离的眼白、虹膜、高光和腮红节点 | `assistant.left-eye`、`assistant.right-eye`、`assistant.*-pupil` |
| 奶油色厨师上衣、深绿色围裙与口袋 | 分层躯干、围裙和口袋几何 | `assistant.torso`、`assistant.apron`、`assistant.apron-pocket` |
| 橙色围巾/蝴蝶结和金色点缀 | 颈部三角巾、腰部蝴蝶结、金色中心 | `assistant.neckerchief`、`assistant.waist-bow` |
| 手持餐勺的料理助手姿态 | 随右前臂绑定的勺柄和勺碗 | `assistant.spoon`、`assistant.spoon-handle`、`assistant.spoon-bowl` |

生成入口是 `scripts/generate_assistant_character_model.swift`。这样替换角色资产时仍保留现有命名节点和动作接口，不需要改浮层、气泡或对话业务。

## 选型依据

当前工程最低支持 iOS 15，现有依赖已经足够。SceneKit 是系统框架，`SCNView` 可嵌入 UIKit，`SCNNode` 提供层级化 3D 场景节点，`SCNAction`/SceneKit 事务负责节点动画，因此本次没有新增 SPM 包，也没有引入未确认授权的第三方角色模型。

官方资料：

- Apple `SCNView`：[https://developer.apple.com/documentation/scenekit/scnview](https://developer.apple.com/documentation/scenekit/scnview)
- Apple 场景节点组织：[https://developer.apple.com/documentation/scenekit/organizing-a-scene-with-nodes](https://developer.apple.com/documentation/scenekit/organizing-a-scene-with-nodes)
- Apple `SCNAction`：[https://developer.apple.com/documentation/scenekit/scnaction](https://developer.apple.com/documentation/scenekit/scnaction)

## 边界和后续替换点

这一步是可运行的、按静态吉祥物重建的低多边形 3D 角色模型资产和动作系统，不等于真人扫描或带复杂蒙皮权重的高模数字人。当前角色本体是独立 SceneKit 资产，胸牌只是可选附属饰件；尚未加入面部捕捉、口型同步、语音驱动、用户换装和远程模型下载。`QFAssistantRigView` 只负责加载模型和驱动命名节点，后续如果确定授权清晰的 USDZ/SceneKit 高模资产，可替换数据集而不改浮层点击、气泡和对话接口。

## 验证

- `xcodebuild ... build-for-testing`：`/tmp/qf-assistant-reference-build-20261011.log`，结果为 `TEST BUILD SUCCEEDED`。
- 角色模型生成脚本：`scripts/generate_assistant_character_model.swift`，生成结果已加入 Data asset，客户端优先从 `NSDataAsset(name: "assistant-character")` 加载。
- 静态资源对应模型节点检查：`/tmp/verify-assistant-model`，`loaded=true nodes=13/13`。
- 本轮没有启动模拟器，也没有占用用户的 `ceshi3`；Shu 真机的视觉验收仍需设备可用后定向检查。

## Hunyuan3D 角色当前接入（2026-10-14）

上述 2026-10-11 的程序化 SCN 角色作为回退保留；当前首选是用户选择的 Hunyuan3D PBR 料理精灵。原始 2026-10-12 模型是静态高精度输入，本轮制作独立的 85,000 面移动运行文件、18 根骨骼、真实连续权重与 10 个表情通道，并修正胸前徽章。

旧运行文件的坐标/权重与空表情存在真实缺陷，此前“6/6 加载检查通过”不能证明显示正确。当前资源已经重新制作，浮层使用原模型彩色基础贴图的独立 constant 材质，补充随头骨运动的眼睑；保留原始 PBR 主文件。动作由唯一 bind-pose 控制器按动作族随机选择片段，包含抬手、手腕摆动、手到脸前与单腿抬脚，人物整体上下浮动已移除。

实际生产场景在 iPhone 16 Pro / iOS 18.6 Simulator 中完成 13 项定向检查、8 个动作帧和 40 帧连续挥手。真机最终观感与性能仍由用户验收。资源、数值反例、同文件 hash、预览与证据边界见 [当前验收记录](assistant-character-runtime-acceptance-20261012.md)。原始资源生成来源仍保存在协作流程/角色资产/hunyuan3d-pro-v1-20261012/asset-manifest.json。
