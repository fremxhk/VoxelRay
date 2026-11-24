# VoxelRay Live Progress Ledger

## Resolved Identifiers & Environment
- **Development Team:** `3ZHSMUKPN8`
- **Bundle ID:** `com.voxelray.app`
- **ASC Bundle ID Resource ID:** `B296ZUS5P6`
- **ASC App ID:** `6838516763`
- **ASC App Store Version ID (`1.0.0`):** `7acc415c-23da-4836-b21e-fa81119d1838` (`appStoreState = PREPARE_FOR_SUBMISSION`, Hard Stop)
- **ASC Uploaded Build ID (`1.0.0 (1)`):** `3f7e43d7-dc89-4f8f-b6d2-670d9f06ca21` (`processingState = VALID`, `usesNonExemptEncryption = false`)
- **TestFlight Internal Group ID:** `f13f8408-aa45-4c02-996f-66d46df9970f` (`internalBuildState = IN_BETA_TESTING`, `externalBuildState = READY_FOR_BETA_SUBMISSION`, `autoNotifyEnabled = True`, `testerCount = 1`)
- **IAP Product IDs & Live ASC IDs:**
  - `com.voxelray.app.pro` (Architect Pro — `$4.99` Non-Consumable, ASC ID `6838538722`, state `READY_TO_SUBMIT`)
  - `com.voxelray.app.materials.crystal` (Prism Material Pack — `$1.99` Non-Consumable, ASC ID `6838539136`, state `READY_TO_SUBMIT`)
- **Xcode / SDK:** Xcode 27.2 (`27B52`), `iPhoneOS27.2.sdk`, Deployment Target `iOS 26.0`
- **Target Simulator:** Auto-selected highest-res 6.9" Pro Max (`iPhone 18 Pro Max` on `iOS 27.2`, UDID `568FBCE6-F535-4C1D-B451-236865D061B4`)
- **Physical Device Verified:** `iPhone 13 mini` (`iPhone14,4`, UDID `00008110-000164D402C3801E`, iOS `27.2.1`)
- **GitHub Repository:** `https://github.com/fremxhk/VoxelRay` (branch `main`)

---

## Phase Gates
- [x] **Phase 0:** Toolchain (`MetalToolchain` 27B47 / `metalfe-32023.922.4`), git init, ASC Bundle ID resolution (`com.voxelray.app` / `B296ZUS5P6`), scaffolding (`project.yml`, `PLAN.md`, `PROGRESS.md`, `StoreConfig.swift`, `Info.plist`, `Assets.xcassets`)
- [x] **Phase 1:** Headless CI script (`scripts/ci_test_and_stage.sh`), `ShaderTypes.h`, `Camera.swift`, `Renderer.swift`, `MetalView.swift`, `HUDView.swift`, `CameraTests` (5), `RendererSmokeTests` (2), `VoxelRayUITests` (1) — 8/8 passed (`MTL_DEBUG_LAYER=1`, `generic/platform=iOS` built)
- [x] **Phase 2:** `VoxelWorld.swift` (3 biomes), `Metal4DevicePipeline.swift` + `VoxelIntersect.metal`, `SimulatorComputePipeline.swift` + `SimulatorFallback.metal`, `VoxelWorldTests` (3), expanded `RendererSmokeTests` (3) — 12/12 passed (`MTL_DEBUG_LAYER=1`, `generic/platform=iOS` built)
- [x] **Phase 3:** `Lighting.metal` (multi-bounce GI, Nishita sky, dielectric refraction, firefly clamp, ACES, temporal accum), tap-to-destroy + haptics, MetalFX thermal scaling, Photo Mode (`PhotoShareSheet.swift`), `DestructionTests` (3), expanded `VoxelRayUITests` (1) — 15/15 passed (`MTL_DEBUG_LAYER=1`, `generic/platform=iOS` built)
- [x] **Phase 4:** `StoreManager.swift`, `VoxelRay.storekit`, `PaywallView.swift`, `PrivacyInfo.xcprivacy`, `generate_icon.swift` (`1024x1024` 24-bit RGB `hasAlpha: no`), `StoreKitTests` (1), `ScreenshotCaptureUITests`
- [x] **Game Review Overhaul & Physical Device QA:**
  - **Graphics & Fallback Overhaul:** Calibrated biome exposure & golden-hour sun curves, rippling turquoise reflection pools + sky/colonnade/neon reflections (`MAT_WATER`), voxel crevice AO + bevel highlights, optical 13-tap HDR bloom + vignette (`bloomTonemapPresentKernel`), transient blast flash + shockwave, Courtyard colonnade arches, Glass Cathedral stained-glass Prism Rose Window, and cross-platform `ComputePathTracePipeline` fallback (`supportsFamily(.apple9)` + `supportsFamily(.metal4)` guard so A15/A16 iPhones render full path-traced blooms cleanly).
  - **Procedural Spatial Audio (`VoxelRay/Audio/SoundEngine.swift`):** Off-main-thread `AVAudioEngine` DSP synthesis for material foley (stone, glass/prism, gold, water, neon), ascending pentatonic sculpting notes, combo chimes, milestone/unlock fanfares, biome ambient loops, and HUD mute toggle.
  - **Gameplay & Conversion Polish (`DebrisSystem.swift`, `VoxelWorld.swift`, `HUDView.swift`, `PaywallView.swift`):** 3D bouncing physics debris particles, blast camera micro-shake, 12-step Undo stack, free `Gold`/`Neon`/`Glass` brushes alongside `Blast` & `Prism`, `Dawn`/`Noon`/`Sunset`/`Night` mood buttons, single-line landscape HUD fitting 5.4"–6.9" displays, 30s live Pro Biome Preview flow, and frosted glassmorphic Paywall (`BEST VALUE` badge + one-time purchase trust bar).
  - **Simulator CI (`task-648`):** `21/21` passed (`0` failures) with `MTL_DEBUG_LAYER=1`; `5/5` upright `2868x1320` 24-bit RGB PNG screenshots verified in `artifacts/screenshots/`.
  - **Physical iPhone 13 mini (`00008110-000164D402C3801E`, `task-654`):** `18/18` unit tests + `2/2` UI tests = `20/20` passed (`0` failures, `0` skips, `0` AVAudioSession warnings) on `ComputePathTracePipeline`; walkthrough video `artifacts/walkthrough/voxelray_iphone13_walkthrough.mp4` (`16.00s`, `1920x886`, `860,815` bytes) + 7 live `2436x1125` hardware frames captured in `artifacts/walkthrough/frames/`.
- [x] **Phase 5 (Staged at HARD STOP — Not Submitted to App Review):**
  - Signed Release IPA uploaded via `xcodebuild archive` + `xcodebuild -exportArchive` -> Build `1` (`3f7e43d7-dc89-4f8f-b6d2-670d9f06ca21`) `VALID`, attached to Draft Version `1.0.0` (`7acc415c-23da-4836-b21e-fa81119d1838`).
  - TestFlight Internal Testing enabled (`Internal Testers` group `f13f8408-aa45-4c02-996f-66d46df9970f`, `internalBuildState = IN_BETA_TESTING`, `autoNotifyEnabled = True`).
  - ASC Final Checks completed via API: Content Rights (`DOES_NOT_USE_THIRD_PARTY_CONTENT`), Age Rating (`FOUR_PLUS`), Price Schedule (`Free $0.00 USD`), Global Availability (`175` territories), Categories (`GAMES` / `GAMES_SIMULATION`), `en-US` Metadata + App Store Review Details (`da9afa83-fc39-44c6-87a5-efaf1abc7040`), `5/5` `APP_IPHONE_67` screenshots `COMPLETE`, and both Non-Consumable IAPs (`com.voxelray.app.pro` `$4.99`, `com.voxelray.app.materials.crystal` `$1.99`) `READY_TO_SUBMIT`.
  - **Remaining Safari Web UI Action (intentional per API limits & Hard Stop rule):** Complete the one-time **App Privacy** questionnaire (`Data Not Collected`) -> **Publish** in App Store Connect Safari, verify draft cards look good, and click **Add for Review** when ready.
