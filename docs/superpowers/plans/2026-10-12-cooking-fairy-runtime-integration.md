# Cooking Fairy Runtime Asset Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Hunyuan3D Pro 生成的料理精灵候选资产，经过可加载格式、移动端优化、骨骼/表情和运行时验收后，安全接入现有 UIKit + SceneKit 助手浮层。

**Architecture:** 保留 `QFDigitalAssistantOverlay` 的业务接口、气泡和点击区域不变，将角色渲染资源抽象为独立的 SceneKit USDZ 数据资产。Hunyuan 的 PBR GLB 作为交换与视觉基准；只有完成 USDZ 转换、LOD、骨骼、表情和真机材质检查后，才替换现有 `assistant-character.scn`。加载失败继续使用当前 SceneKit 程序化回退，避免启动阻断。

**Tech Stack:** Swift 5 / UIKit / SceneKit（系统框架，iOS 15+）、XcodeGen + `.xcodeproj`、Assets.xcassets Data Set、Blender 或 Reality Converter（仅用于离线资产生产，不新增 App 依赖）。

**Spec:** `协作流程/角色资产/hunyuan3d-pro-v1-20261012/README.md`、`客户端/qiafan-youpu-ios/docs/assistant-3d-character-20261011.md`、`客户端/qiafan-youpu-ios/docs/assistant-character-concepts-20261012/cooking-fairy-model-reference-v2.md`

## Global Constraints

- 保持 UIKit + SceneKit；不新增第三方 SPM 包，不改变现有助手浮层、会话或接口。
- iOS 最低版本保持 15.0；所有可见文案、错误和无障碍文案继续遵守十语言约定。
- Hunyuan GLB 当前为约 1,499,694 面、无 `skins`、无 `animations` 的静态 PBR 候选，不能直接当作可动画生产资产。
- 移动端运行时目标：优先单角色实例、压缩纹理、可接受的内存/帧率；具体预算以真机定向检查结果为准，未测不得宣称通过。
- 用户负责最终视觉与功能验收；本计划不自动启动模拟器或全量构建，除非用户明确要求或自动研发授权覆盖该次检查。

## Review Focus

- **格式兼容：** iOS SceneKit 能否从资源包加载 USDZ 及其纹理；失败时必须落到现有程序化模型。
- **视觉一致性：** 眼睛位置、厨师帽、桃色头发、绿色围裙、橙色领巾、花饰、鞋和背面细节必须逐项对照静态四视图。
- **表情可变：** 中性、开心、眨眼、惊讶、思考至少可独立驱动；不可把固定表情烘焙成唯一贴图。
- **性能：** 纹理尺寸、顶点数、加载时间、内存峰值和滚动/浮层帧率必须在目标真机检查，不能只看桌面预览。
- **资产治理：** 来源、授权、SHA-256、导出工具版本和回滚文件必须记录，避免把临时候选误放入 Release。

### Task 1: Lock the asset manifest and visual acceptance gate

**Files:**
- Create: `协作流程/角色资产/hunyuan3d-pro-v1-20261012/asset-manifest.json`
- Modify: `协作流程/角色资产/hunyuan3d-pro-v1-20261012/README.md`
- Modify: `客户端/qiafan-youpu-ios/docs/assistant-3d-character-20261011.md`

**Interfaces:**
- Consumes: `cooking-fairy-v1-pbr.glb`, four-view input files, Hunyuan task metadata.
- Produces: a machine-readable manifest naming the candidate, source views, hashes, face/vertex counts, PBR channels, and explicit blockers.

- [x] **Step 1: Write the manifest** with asset id, provenance, file hashes, four-view slot mapping, PBR channel list, and the current blockers (`skins=0`, `animations=0`, `left.png` AI-inferred side).
- [x] **Step 2: Add an acceptance table** to the README covering silhouette, eyes, costume, back view, material, expression, topology, and runtime status.
- [x] **Step 3: Verify file hashes and glTF metadata** with a read-only script; record the actual output in the manifest.

### Task 2: Produce a runtime-ready mobile asset offline

**Files:**
- Create: `客户端/qiafan-youpu-ios/Resources/Models/cooking-fairy-mobile.usdz`
- Create: `客户端/qiafan-youpu-ios/Resources/Models/cooking-fairy-mobile.glb`
- Create: `客户端/qiafan-youpu-ios/docs/assistant-character-concepts-20261012/cooking-fairy-runtime/production-report.json`

**Interfaces:**
- Consumes: Hunyuan PBR GLB as the visual source plus the approved turnaround/reference sheet.
- Produces: a textured USDZ for SceneKit, an exchange GLB, a documented mobile LOD, and a report of bones, blendshapes, textures, and export tool versions.

- [x] **Step 1: Retopologize/decimate** the Hunyuan mesh to the agreed mobile budget while retaining the reference silhouette and accessory separation.
- [x] **Step 2: Preserve/rebuild PBR channels** as base color, normal, and metallic-roughness; validate that no texture path points outside the package.
- [x] **Step 3: Bind `CookingFairy_Rig`** with stable names for `root`, `pelvis`, `spine`, `chest`, `neck`, `head`, both arms/hands, and both legs/feet.
- [x] **Step 4: Create blendshape targets** named `face_neutral`, `face_happy`, `face_blink_L`, `face_blink_R`, `face_surprised`, and `face_thinking`; keep neutral eyes symmetric and forward-facing.
- [x] **Step 5: Export USDZ and GLB** and inspect both package contents before any App resource replacement.
- [x] **Step 6: Record unresolved differences** instead of claiming a 1:1 match if any hidden/back or cloth detail is inferred.

### Task 3: Add a safe SceneKit asset adapter

**Files:**
- Create: `客户端/qiafan-youpu-ios/QiafanYoupu/Features/Assistant/QFAssistantModelAsset.swift`
- Modify: `客户端/qiafan-youpu-ios/QiafanYoupu/Features/Assistant/QFDigitalAssistant.swift`
- Create: `客户端/qiafan-youpu-ios/QiafanYoupu/Resources/Assets.xcassets/cooking-fairy-mobile.dataset/Contents.json`
- Add: `客户端/qiafan-youpu-ios/Resources/Assets.xcassets/cooking-fairy-mobile.dataset/cooking-fairy-mobile.usdz`

**Interfaces:**
- Produces `QFAssistantModelAsset.load() -> QFAssistantModelAssetLoadResult` and a node map consumed by `QFAssistantRigView`.
- Node map must expose `head`, both arm/elbow chains, both legs, eyes, brows, mouth, and optional `SCNMorpher` channels without hard-coding vertex indices.

- [x] **Step 1: Add a loader test seam** that can report missing resource, unsupported scene, missing required node, and successful load without presenting UI.
- [x] **Step 2: Load the USDZ Data Set** through `NSDataAsset`/`SCNSceneSource`; set PBR materials, lighting, camera framing, and scale at the adapter boundary.
- [x] **Step 3: Map the stable rig and morph names** to the existing pose/emotion API; keep existing procedural fallback when any required node is absent.
- [x] **Step 4: Do not add network loading** or remote model download; the first release remains bundled and deterministic.

### Task 4: Wire expressions and actions without freezing the face

**Files:**
- Modify: `客户端/qiafan-youpu-ios/QiafanYoupu/Features/Assistant/QFDigitalAssistant.swift`
- Create: `客户端/qiafan-youpu-ios/QiafanYoupuTests/QFAssistantModelAssetTests.swift`

**Interfaces:**
- `setEmotion(_:)` drives morph weights when present and falls back to node visibility/transform for the legacy model.
- `startBlinking()` drives `face_blink_L`/`face_blink_R` independently, with Reduce Motion respected.

- [x] **Step 1: Add tests** for the loader, rig channels and missing-morph fallback; direct UI-private emotion tests remain covered by the adapter channel contract.
- [x] **Step 2: Implement morph-weight helpers** with clamping to `0...1` and reset of unrelated targets before applying a new emotion.
- [x] **Step 3: Keep pose animation separate** from facial expression so head/arm motion cannot overwrite eye or mouth state.
- [x] **Step 4: Preserve accessibility value** as the current localized/semantic emotion name.

### Task 5: Run scoped asset/runtime checks and hand off for user acceptance

**Files:**
- Create: `客户端/qiafan-youpu-ios/docs/assistant-character-runtime-acceptance-20261012.md`
- Modify: `客户端/qiafan-youpu-ios/docs/assistant-3d-character-20261011.md`

**Interfaces:**
- Consumes: runtime USDZ, adapter diagnostics, and user-visible acceptance steps.
- Produces: a dated result table with actual commands/checks and explicit unverified items.

- [x] **Step 1: Check package integrity** (USDZ archive, embedded textures, no external paths, SHA-256).
- [x] **Step 2: Run only the scoped iOS resource/loader check** requested for this page; do not claim simulator or device success if it was not run.
- [x] **Step 3: Provide manual checks**: front/three-quarter/side/back, neutral/happy/blink/surprised/thinking, Reduce Motion, light/dark background, memory, and fallback.
- [x] **Step 4: Keep the existing asset as rollback** until the user approves the visual and runtime result.

## Completion Criteria

- Hunyuan source remains available as the visual reference and exchange asset.
- A runtime USDZ with PBR, stable rig names, and independent facial expressions loads through the adapter or cleanly falls back.
- No third-party dependency or public API change is introduced.
- Acceptance documentation states exactly what was checked and what still requires user/device verification.
