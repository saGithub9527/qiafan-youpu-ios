# Hunyuan3D 料理精灵运行时接入实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Hunyuan3D PBR 料理精灵制作成带真实蒙皮骨骼、独立表情目标、稳定节点和 PBR 材质的移动端 USDZ/GLB，并安全接入现有 UIKit + SceneKit 助手浮层。

**Architecture:** Hunyuan PBR GLB 只读保留为外观基准；离线资产生产输出一个不超过 500,000 三角面的运行时包。Swift 侧新增 `QFAssistantModelAsset` 负责 USDZ/Model I/O 加载、节点与 morph 诊断和旧资源回退，`QFAssistantRigView` 只消费映射后的节点/表情接口，浮层业务接口保持不变。

**Tech Stack:** Swift 5 / UIKit / SceneKit / ModelIO（iOS 15+）；Python 标准库、现有 USD 工具（`usdcat`、`usdchecker`、`usdzip`）和可用的离线 3D authoring tool；XcodeGen + `.xcodeproj`；Assets.xcassets Data Set。

**Spec:** `docs/superpowers/specs/2026-10-12-cooking-fairy-hunyuan-runtime-design.md`

## Global Constraints

- 保持 UIKit + SceneKit；不新增第三方 SPM 包，不改变助手浮层、会话或网络接口。
- iOS 最低版本保持 15.0；不加入网络模型下载或远程运行时资源。
- Hunyuan 源 GLB 约 1,499,694 面、`skins=0`、`animations=0`；不得把源文件或静态 proxy 伪装成已绑定资源。
- 运行时资产必须包含 `JOINTS_0`/`WEIGHTS_0`、18 根固定骨骼、6 个表情目标、固定 locator 节点和 `CookingFairy_Idle`。
- 旧 `assistant-character.scn` 保留为加载失败回退，用户验收前不得删除或替换其内容。
- 重型资产处理、构建和模拟器/真机检查串行执行；未执行的检查不写成通过。

## Review Focus

- **工具链可复现：** 资产生成必须记录工具路径、版本、输入 SHA-256 和命令；缺少导出工具时保留阻塞证据，不生成伪造 USDZ。
- **蒙皮真实性：** GLB primitive 必须有 `JOINTS_0`/`WEIGHTS_0`；仅有骨骼节点层级不能算完成。
- **表情完整性：** 6 个 morph 名称可被发现和独立组合，眨眼左右分离，姿势动画不会清空表情权重。
- **PBR 包完整性：** USDZ 内的 base-color、normal、metallic-roughness 和引用路径完整，不能依赖源机绝对路径。
- **回退安全：** 缺资源、缺节点、材质失败、场景为空或格式不支持时仍显示旧角色，点击和对话流程不受影响。

### Task 1: Asset toolchain preflight and deterministic manifest

**Files:**
- Create: `协作流程/角色资产/hunyuan3d-pro-v1-20261012/inspect_runtime_asset.py`
- Modify: `协作流程/角色资产/hunyuan3d-pro-v1-20261012/asset-manifest.json`
- Modify: `协作流程/角色资产/hunyuan3d-pro-v1-20261012/README.md`
- Create: `客户端/qiafan-youpu-ios/docs/assistant-character-concepts-20261012/cooking-fairy-runtime/production-report.json`

**Interfaces:**
- Consumes: Hunyuan PBR GLB, geometry USDZ, four-view references and any generated runtime candidates.
- Produces: stable metadata inspection output with file hashes, mesh counts, PBR channels, skin attributes, morph names, skeleton names, tool versions and blockers.

- [ ] **Step 1: Add the inspector** with standard-library GLB JSON parsing, USDZ archive checks, SHA-256 calculation and explicit exit codes for missing files, static source, incomplete skin, missing morphs and accepted runtime output.
- [ ] **Step 2: Run it against the current source** and record the known baseline (`skins=0`, `animations=0`, one mesh, PBR channels, 1.5M-face budget blocker) without changing source assets.
- [ ] **Step 3: Record the available authoring tools** (`blender`, `usdcat`, `usdchecker`, `usdzip` or their absence) and the exact command that will generate the runtime package.
- [ ] **Step 4: Verify** the report is deterministic by running the inspector twice and comparing normalized JSON output.

### Task 2: Build the Hunyuan runtime asset

**Files:**
- Create: `协作流程/角色资产/hunyuan3d-pro-v1-20261012/build_runtime_asset.py` or the checked-in offline authoring script selected by the toolchain preflight.
- Create: `客户端/qiafan-youpu-ios/QiafanYoupu/Resources/Assets.xcassets/cooking-fairy-mobile.dataset/cooking-fairy-mobile.usdz`
- Create: `协作流程/角色资产/hunyuan3d-pro-v1-20261012/cooking-fairy-mobile.glb`
- Modify: `客户端/qiafan-youpu-ios/docs/assistant-character-concepts-20261012/cooking-fairy-runtime/production-report.json`

**Interfaces:**
- Consumes: immutable Hunyuan PBR GLB and the approved four-view reference set.
- Produces: mobile PBR USDZ/GLB with weighted rig, named morphs, locators and idle action.

- [ ] **Step 1: Retopologize/decimate** to no more than 500,000 triangles, preserving the face, hat, hair, apron, scarf, flower and shoe silhouette; keep a source-to-runtime mapping in the report.
- [ ] **Step 2: Preserve or rebake PBR** textures and validate that all image references are packaged and relative.
- [ ] **Step 3: Create and bind `CookingFairy_Rig`** with the 18 exact bone names; verify every runtime mesh primitive exposes `JOINTS_0` and `WEIGHTS_0` with normalized weights.
- [ ] **Step 4: Create morph targets** `face_neutral`, `face_happy`, `face_blink_L`, `face_blink_R`, `face_surprised`, `face_thinking`; keep clothing and props outside face morph deformation.
- [ ] **Step 5: Add locators and `CookingFairy_Idle`**, then export both GLB and USDZ with the chosen toolchain.
- [ ] **Step 6: Run the inspector and `usdchecker`**; stop before App changes if the runtime asset is still static, exceeds the face budget, or has invalid USD skeleton structure.

### Task 3: Add the SceneKit/ModelIO asset adapter

**Files:**
- Create: `客户端/qiafan-youpu-ios/QiafanYoupu/Features/Assistant/QFAssistantModelAsset.swift`
- Create: `客户端/qiafan-youpu-ios/QiafanYoupuTests/QFAssistantModelAssetTests.swift`
- Create: `客户端/qiafan-youpu-ios/QiafanYoupu/Resources/Assets.xcassets/cooking-fairy-mobile.dataset/Contents.json`

**Interfaces:**
- Produces `QFAssistantModelAsset.load(bundle:resourceName:) -> QFAssistantModelAssetLoadResult`.
- `QFAssistantModelAssetLoadResult` carries either a validated `SCNNode` root plus `QFAssistantNodeMap`, or a typed diagnostic and fallback reason.
- `QFAssistantNodeMap` exposes `head`, left/right arm chains, left/right leg chains, face locator nodes and optional morph channels without vertex-index coupling.

- [ ] **Step 1: Write tests** for missing Data Set, empty/unsupported scene, missing required locator, missing morph, valid resource and deterministic diagnostic codes.
- [ ] **Step 2: Implement loading** from the Data Set using ModelIO `MDLAsset` to SceneKit conversion, with a direct SceneKit source path only when the runtime check confirms it works on the target OS.
- [ ] **Step 3: Normalize** scale, forward axis, camera framing and PBR material flags at the adapter boundary; do not alter the source asset on disk.
- [ ] **Step 4: Validate and map** required bones, locators, morph channels and idle animation; reject partial assets instead of silently accepting a static mesh.
- [ ] **Step 5: Run the adapter unit tests** and verify the old resource path is untouched.

### Task 4: Wire pose, emotion and fallback behavior

**Files:**
- Modify: `客户端/qiafan-youpu-ios/QiafanYoupu/Features/Assistant/QFDigitalAssistant.swift`
- Modify: `客户端/qiafan-youpu-ios/QiafanYoupuTests/QFAssistantModelAssetTests.swift`

**Interfaces:**
- `QFAssistantRigView` consumes `QFAssistantNodeMap` and keeps its existing `playGreeting()`, `playExcited()`, `beginRigAnimation()` and accessibility contract.
- Morph helpers clamp weights to `0...1`, reset unrelated targets and keep pose transforms separate from face state.

- [ ] **Step 1: Add tests** for calm, happy, excited, thinking, surprised, independent left/right blink, Reduce Motion, and missing-morph fallback.
- [ ] **Step 2: Add the new asset load path** before the legacy `assistant-character` path; preserve procedural fallback when either load fails.
- [ ] **Step 3: Implement emotion mapping** from current `QFAssistantEmotion` values to the six named morph targets, with eyebrow/locator transforms only for states without dedicated morphs.
- [ ] **Step 4: Implement independent blinking** and ensure the idle action cannot overwrite face weights; preserve `accessibilityValue` and existing localized labels.
- [ ] **Step 5: Run focused unit tests** and inspect diagnostics for both success and fallback paths.

### Task 5: Package resources and update project metadata

**Files:**
- Modify: `客户端/qiafan-youpu-ios/project.yml` only if XcodeGen requires an explicit resource entry.
- Modify: `客户端/qiafan-youpu-ios/QiafanYoupu.xcodeproj/project.pbxproj` only through `xcodegen generate` when needed.
- Modify: `客户端/qiafan-youpu-ios/QiafanYoupu/Resources/Assets.xcassets/cooking-fairy-mobile.dataset/Contents.json`.

**Interfaces:**
- Produces an app bundle that contains the validated USDZ Data Set and existing legacy assets.

- [ ] **Step 1: Add the Data Set** without removing or renaming `assistant-character.dataset`.
- [ ] **Step 2: Run `xcodegen generate`** only if project.yml changed; inspect the diff for unrelated target or package changes.
- [ ] **Step 3: Run the scoped resource compilation check** requested for this page and verify the Data Set is present in the built app resources.

### Task 6: Record acceptance evidence and hand off

**Files:**
- Create: `客户端/qiafan-youpu-ios/docs/assistant-character-runtime-acceptance-20261013.md`
- Modify: `客户端/qiafan-youpu-ios/docs/assistant-3d-character-20261011.md`

**Interfaces:**
- Consumes: inspector report, adapter diagnostics and scoped build/test output.
- Produces: dated evidence with actual pass/fail/unverified state and user manual checks.

- [ ] **Step 1: Record** USDZ archive integrity, PBR texture references, GLB attributes, bone names, morph names and SHA-256 values.
- [ ] **Step 2: Record** the focused Swift test/build result; never label simulator or device checks as passed unless executed.
- [ ] **Step 3: Add manual checks** for front/three-quarter/side/back, neutral/happy/blink/surprised/thinking, Reduce Motion, backgrounds, touch target, accessibility and fallback.
- [ ] **Step 4: Keep the legacy resource as rollback** and state whether the new asset is ready for user acceptance or still blocked by authoring/runtime evidence.

## Completion Criteria

- Hunyuan source remains unchanged and referenced by hash.
- A runtime USDZ/GLB meets the triangle budget, contains weighted skin data, 18 exact bones, 6 exact morph targets, fixed locator names and `CookingFairy_Idle`.
- `QFAssistantModelAsset` loads the new resource or returns a typed reason and the old model remains visible.
- Focused checks and documentation report real evidence; unresolved device or visual checks remain explicit.

