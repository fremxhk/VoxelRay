# VoxelRay Live Progress Ledger

## Resolved Identifiers & Environment
- **Development Team:** `3ZHSMUKPN8`
- **Bundle ID:** `com.voxelray.app`
- **ASC Bundle ID Resource ID:** `B296ZUS5P6`
- **IAP Product IDs:**
  - `com.voxelray.app.pro` (Architect Pro — `$4.99` Non-Consumable)
  - `com.voxelray.app.materials.crystal` (Prism Material Pack — `$1.99` Non-Consumable)
- **Xcode / SDK:** Xcode 27.2 (`27B52`), `iPhoneOS27.2.sdk`, Deployment Target `iOS 26.0`
- **Target Simulator:** Auto-selected highest-res 6.9" Pro Max (`iPhone 18 Pro Max` on `iOS 27.2`, UDID `568FBCE6-F535-4C1D-B451-236865D061B4`)
- **GitHub Repository:** Pending (Phase 5)
- **ASC App ID / Version / Build:** Pending (Phase 5)

---

## Phase Gates
- [x] **Phase 0:** Toolchain (`MetalToolchain` 27B47 / `metalfe-32023.922.4`), git init, ASC Bundle ID resolution (`com.voxelray.app` / `B296ZUS5P6`), scaffolding (`project.yml`, `PLAN.md`, `PROGRESS.md`, `StoreConfig.swift`, `Info.plist`, `Assets.xcassets`)
- [x] **Phase 1:** Headless CI script (`scripts/ci_test_and_stage.sh`), `ShaderTypes.h`, `Camera.swift`, `Renderer.swift`, `MetalView.swift`, `HUDView.swift`, `CameraTests` (5), `RendererSmokeTests` (2), `VoxelRayUITests` (1) — 8/8 passed (`MTL_DEBUG_LAYER=1`, `generic/platform=iOS` built)
- [x] **Phase 2:** `VoxelWorld.swift` (3 biomes), `Metal4DevicePipeline.swift` + `VoxelIntersect.metal`, `SimulatorComputePipeline.swift` + `SimulatorFallback.metal`, `VoxelWorldTests` (3), expanded `RendererSmokeTests` (3) — 12/12 passed (`MTL_DEBUG_LAYER=1`, `generic/platform=iOS` built)
- [x] **Phase 3:** `Lighting.metal` (multi-bounce GI, Nishita sky, dielectric refraction, firefly clamp, ACES, temporal accum), tap-to-destroy + haptics, MetalFX thermal scaling, Photo Mode (`PhotoShareSheet.swift`), `DestructionTests` (3), expanded `VoxelRayUITests` (1) — 15/15 passed (`MTL_DEBUG_LAYER=1`, `generic/platform=iOS` built)
- [ ] **Phase 4:** `StoreManager.swift`, `VoxelRay.storekit`, `PaywallView.swift`, `PrivacyInfo.xcprivacy`, `generate_icon.swift` (1024x1024 no-alpha), `StoreKitTests`, `ScreenshotCaptureUITests`
- [ ] **Phase 5:** `README.md`, `PRIVACY.md`, `SUPPORT.md`, GitHub push (`fremxhk/VoxelRay`), Release archive & upload, `scripts/asc_stage_draft.py` -> `PREPARE_FOR_SUBMISSION` Draft (HARD STOP)
