# VoxelRay Live Progress Ledger

## Resolved Identifiers & Environment
- **Development Team:** `3ZHSMUKPN8`
- **Bundle ID:** `com.voxelray.app`
- **ASC Bundle ID Resource ID:** `B296ZUS5P6`
- **ASC App ID:** `6838516763`
- **ASC App Store Version ID (`1.0.0`):** `7acc415c-23da-4836-b21e-fa81119d1838` (`appStoreState = WAITING_FOR_REVIEW`, `releaseType = MANUAL`; `reviewSubmission` `c4acf778-1ee8-457a-a076-5ac84e43f8bb`, `submittedDate = 2026-11-24T03:09:45.045Z`, `3` items)
- **ASC Latest Uploaded Build (`1.0.0 (2)`):** `38f96ea3-cab8-4396-96fc-df1b0ec7d7d1` (`processingState = VALID`, `usesNonExemptEncryption = false`, attached to Draft `1.0.0`)
- **ASC Prior Build (`1.0.0 (1)`):** `3f7e43d7-dc89-4f8f-b6d2-670d9f06ca21`
- **TestFlight Internal Group ID:** `f13f8408-aa45-4c02-996f-66d46df9970f` (`internalBuildState = IN_BETA_TESTING`, `externalBuildState = READY_FOR_BETA_SUBMISSION`, `autoNotifyEnabled = True`, `testerCount = 1`)
- **TestFlight External Group ID:** `4294bb1e-f89c-48d4-98bd-6556a1adf674` (`VoxelRay Device QA`, `publicLinkEnabled = True`, `publicLink = https://testflight.apple.com/join/S6f8GAgk`, Build `2` attached, `testerCount = 2`, `betaLicenseAgreement = 30bbde27-080d-46c1-9ff5-4696fa293d98`, `externalBuildState = READY_FOR_BETA_SUBMISSION`, `betaAppReviewSubmission = null` — `POST /v1/betaAppReviewSubmissions` returns Apple HTTP 422 `ENTITY_UNPROCESSABLE`)
- **IAP Product IDs & Live ASC IDs:**
  - `com.voxelray.app.pro` (Architect Pro — `$4.99` Non-Consumable, ASC ID `6838538722`, state `WAITING_FOR_REVIEW`)
  - `com.voxelray.app.materials.crystal` (Prism Material Pack — `$1.99` Non-Consumable, ASC ID `6838539136`, state `WAITING_FOR_REVIEW`)
- **Xcode / SDK:** Xcode 27.2 (`27B52`), `iPhoneOS27.2.sdk`, Deployment Target `iOS 26.0`
- **Target Simulator:** Auto-selected highest-res 6.9" Pro Max (`iPhone 18 Pro Max` on `iOS 27.2`, UDID `568FBCE6-F535-4C1D-B451-236865D061B4`)
- **Physical Device Verified:** `iPhone 13 mini` (`iPhone14,4`, UDID `00008110-000164D402C3801E`, iOS `27.2.1`, A15 Bionic)
- **GitHub Repository:** `https://github.com/fremxhk/VoxelRay` (branch `main`)

---

## Phase Gates
- [x] **Phase 0:** Toolchain (`MetalToolchain` 27B47 / `metalfe-32023.922.4`), git init, ASC Bundle ID resolution (`com.voxelray.app` / `B296ZUS5P6`), scaffolding (`project.yml`, `PLAN.md`, `PROGRESS.md`, `StoreConfig.swift`, `Info.plist`, `Assets.xcassets`)
- [x] **Phase 1:** Two-stage CI script (`scripts/ci_test_and_stage.sh`: Stage A Simulator + `--sim-only` -> Stage B unlocked physical iPhone 13 via `devicectl`), `ShaderTypes.h`, `Camera.swift`, `Renderer.swift`, `MetalView.swift` (dynamic `maximumFramesPerSecond` 60/120 Hz), `HUDView.swift`
- [x] **Phase 2:** `VoxelWorld.swift` (3 biomes + undo stack), `Metal4DevicePipeline.swift` (Apple9+ Metal 4 BVH + `MTL4FXTemporalScaler`) + `VoxelIntersect.metal`, `SimulatorComputePipeline.swift` (`ComputePathTracePipeline` with A15 hardware `MTLFXTemporalScaler` depth+motion support + Simulator fallback) + `SimulatorFallback.metal`
- [x] **Phase 3:** `Lighting.metal` (multi-bounce GI, Nishita sky, animated water ripples + reflections/caustics, 13-tap optical bloom, ACES), tap-to-destroy + 3D debris (`DebrisSystem.swift`) + camera shake + spatial audio (`SoundEngine.swift`), `50%–67%` thermal scaling (`0.67 / 0.58 / 0.50`), Photo Mode (`PhotoShareSheet.swift`), `DestructionTests`, `DevicePerformanceTests` (`< 1.2 GB` `phys_footprint` gate)
- [x] **Phase 4:** `StoreManager.swift`, `VoxelRay.storekit`, `PaywallView.swift`, `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption = false`, `AppIcon-1024.png`, `StoreKitTests` (`SKTestSession`), 5x `2868x1320` opaque PNG screenshots in `artifacts/screenshots/`
- [x] **Two-Stage CI Verification:**
  - **Stage A (Simulator `iPhone 18 Pro Max`, `task-818`):** `generic/platform=iOS` build succeeded; **`22/22` passed, `0` failed, `0` skipped** (`MTL_DEBUG_LAYER=1`), `peakMemoryMB=69.7`, `avgSampleMs=13.26`; screenshots mode (`task-827`) captured **5/5** `2868x1320` (`hasAlpha: no`).
  - **Stage B (Physical `iPhone 13 mini` iOS `27.2.1`, unlocked, `task-818`):** **`21/21` passed, `0` failed, `0` skipped** (`MTL_DEBUG_LAYER=1`), `backend=A15ComputeDDA+MetalFX`, `badge="MetalFX · 67%"`, `peakMemoryMB=381.1` (< 1200 MB budget), `avgSampleMs=46.81`.
- [x] **Phase 5 (Submitted Build `2` to App Review):**
  - Signed Release IPA `1.0.0 (2)` (`CFBundleVersion = 2`) archived & uploaded -> Build ID `38f96ea3-cab8-4396-96fc-df1b0ec7d7d1` (`VALID`), attached to Version `1.0.0` (`7acc415c-23da-4836-b21e-fa81119d1838`), now **`WAITING_FOR_REVIEW`** (`releaseType = MANUAL`) alongside both IAPs (`com.voxelray.app.pro` `6838538722`, `com.voxelray.app.materials.crystal` `6838539136`, both **`WAITING_FOR_REVIEW`**) via `reviewSubmission` `c4acf778-1ee8-457a-a076-5ac84e43f8bb` (`submittedDate = 2026-11-24T03:09:45.045Z`, `3` items).
  - TestFlight Internal Testing live (`IN_BETA_TESTING`, `Internal Testers` group `f13f8408-aa45-4c02-996f-66d46df9970f`, `autoNotifyEnabled = True`, invitation `5ac3b50b-87c4-42d1-b173-0d2f0365dcf6` sent). External group `VoxelRay Device QA` (`4294bb1e-f89c-48d4-98bd-6556a1adf674`, public link `https://testflight.apple.com/join/S6f8GAgk`) has Build `2` attached, `testerCount = 2` (`817e2803-3be2-4192-8903-7d46e6563351` & `4e67748a-4219-488c-ab57-d6cd29f234c8`), `betaLicenseAgreement` `30bbde27-080d-46c1-9ff5-4696fa293d98`, and `betaAppLocalizations` with `PRIVACY.md`; `POST /v1/betaAppReviewSubmissions` still returns Apple `HTTP 422 ENTITY_UNPROCESSABLE` ("Please try again later.") via public v1 API despite disabling `publicLinkEnabled` and re-attaching Build `2`.
  - All API checks green: Content Rights, `FOUR_PLUS` Age Rating, Free Pricing + 175-Territory Availability, `GAMES` Categories, Review Details, 5/5 Screenshots `COMPLETE`, and App Store submission `WAITING_FOR_REVIEW`.
