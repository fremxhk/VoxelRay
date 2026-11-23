# VoxelRay Live Progress Ledger

## Resolved Identifiers & Environment
- **Development Team:** `3ZHSMUKPN8`
- **Bundle ID:** `com.voxelray.app`
- **ASC Bundle ID Resource ID:** `B296ZUS5P6`
- **IAP Product IDs:**
  - `com.voxelray.app.pro` (Architect Pro — `$4.99` Non-Consumable)
  - `com.voxelray.app.materials.crystal` (Prism Material Pack — `$1.99` Non-Consumable)
- **Xcode / SDK:** Xcode 27.2 (`27B52`), `iPhoneOS27.2.sdk`, Deployment Target `iOS 26.0`
- **Target Simulator:** Auto-selected highest-res 6.9" Pro Max (`iPhone 18 Pro Max` on `iOS 27.2`)
- **GitHub Repository:** Pending (Phase 5)
- **ASC App ID / Version / Build:** Pending (Phase 5)

---

## Phase Gates
- [x] **Phase 0:** Toolchain (`MetalToolchain` 27B47 / `metalfe-32023.922.4`), git init, ASC Bundle ID resolution (`com.voxelray.app` / `B296ZUS5P6`), scaffolding (`project.yml`, `PLAN.md`, `PROGRESS.md`, `StoreConfig.swift`, `Info.plist`, `Assets.xcassets`)
- [ ] **Phase 1:** Headless CI script (`scripts/ci_test_and_stage.sh`), `ShaderTypes.h`, `Camera.swift`, `Renderer.swift`, `MetalView.swift`, `HUDView.swift`, `CameraTests`, `RendererSmokeTests`
- [ ] **Phase 2:** `VoxelWorld.swift` (3 biomes), `Metal4DevicePipeline.swift` + `VoxelIntersect.metal`, `SimulatorComputePipeline.swift` + `SimulatorFallback.metal`, `VoxelWorldTests`
- [ ] **Phase 3:** `Lighting.metal` (multi-bounce GI, sky, refraction, ACES, temporal accum), tap-to-destroy + haptics, MetalFX thermal scaling, Photo Mode, `DestructionTests`, `VoxelRayUITests`
- [ ] **Phase 4:** `StoreManager.swift`, `VoxelRay.storekit`, `PaywallView.swift`, `PrivacyInfo.xcprivacy`, `generate_icon.swift` (1024x1024 no-alpha), `StoreKitTests`, `ScreenshotCaptureUITests`
- [ ] **Phase 5:** `README.md`, `PRIVACY.md`, `SUPPORT.md`, GitHub push (`fremxhk/VoxelRay`), Release archive & upload, `scripts/asc_stage_draft.py` -> `PREPARE_FOR_SUBMISSION` Draft (HARD STOP)
