# QFFilament — native character preview

Local Swift Package for the official Filament **1.78.0** iOS release. The APP uses UIKit/SnapKit and one transparent Metal surface. It does not embed a Unity runtime or migrate business pages.

## Source and reproducibility

- Official archive: https://github.com/google/filament/releases/download/v1.78.0/filament-v1.78.0-ios.tgz
- SHA-256: `a5476b14496401847854f9aa26a1c11e2e6b3d77a3834d1deedc762abf025242`
- `filament.lock.json` records the archive and every selected binary's digest, length and path. `Package.swift` declares the local binary targets and iOS 15 minimum. Existing remote SPM dependencies remain in the project's `Package.resolved`.
- `Binaries/lib*.xcframework` and `Sources/QFFilamentBridge/FilamentHeaders/include` come from that archive. Retain device and simulator slices for development; Xcode links the selected slice into each build.
- Runtime components only: filament/backend/glTF loader, static ubershader archive, image/texture/mesh decoders and their required dependencies. No runtime shader compiler, sample viewer, debug server or conversion tools are linked.

The repository's source SDK payload is about 31.03 MiB for binaries and 1.79 MiB for headers. This is not the installed APP or App Store download contribution. The current Debug build also includes a 38.70 MiB character preview; the staging build phase excludes it from Release.

## Bridge contract

Call on the main thread. Load one GLB; use baked clips and named morph channels. `startRendering`/`stopRendering` preserve playback time. `setMorph` holds a channel after animation evaluation; `clearMorphOverride` releases it back to the clip. Crossfade uses Filament's skeletal TRS blending; it does not promise facial morph crossfade.

`dispose` is idempotent and releases the loader, materials, model, GPU objects and engine. The display link uses a weak target proxy. Stop rendering when the APP backgrounds. `captureFrame` and `cameraYaw` support scoped rendering diagnostics and are unused in normal product rendering.

## Asset and license boundaries

The Hunyuan preview is still a rest/expression asset with zero approved body clips. The menu disables unavailable actions and unapproved painted-eye closure targets. Loading it successfully is not full character acceptance.

Filament is Apache 2.0; preserve `LICENSE` and `Licenses/`. The APP's `ThirdPartyAcknowledgements.txt` includes notices for the linked SDK dependencies. The tiny Fox and AnimatedMorphCube reference models are confined to the test target; their provenance is retained separately and they are not product avatars.

## Verified and unverified

The initial five native renderer tests and two APP overlay UI tests passed on iPhone 16 Pro / iOS 18.6 simulator. Evidence is in `docs/assistant-character-concepts-20261012/filament-preview-20261014/`. Later pause/morph ownership fixes require their own updated check record. Physical iPhone, iOS 15 execution, Release IPA size, power, peak memory and final Hunyuan action quality have not been verified.
