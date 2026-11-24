# VoxelRay — Architectural & Autonomous Release Plan

## Overview
VoxelRay is a ray-traced **Destructible Voxel Sandbox** for iPhone built with **SwiftUI**, **Metal 4 + MetalFX** (Apple9+), **Metal Compute DDA + MetalFX** (A15/A16 hardware & iOS Simulator fallback), off-main-thread **AVFoundation** procedural audio, and **StoreKit 2** for zero-backend commercialization.

## Core Architecture
1. **Deterministic Project Generation (`XcodeGen`):**
   - Managed via `project.yml` (`IPHONEOS_DEPLOYMENT_TARGET: 26.0`, `TARGETED_DEVICE_FAMILY: 1`, landscape-only).
   - Targets: `VoxelRay` (App), `VoxelRayTests` (Unit / Render / Performance / Audio / StoreKit), `VoxelRayUITests` (UI & Screenshot Automation).

2. **Adaptive Multi-Tier Rendering Pipeline:**
   - **Shared Shader Contract (`VoxelRay/Engine/ShaderTypes.h`, `VoxelRay/Shaders/VoxelCommon.h`, `VoxelRay/Shaders/Lighting.metal`):**
     - `FrameUniforms` strictly 256-byte aligned (`_Static_assert(sizeof(FrameUniforms) == 256)`), triple-buffered via `DispatchSemaphore(value: 3)`.
     - Monte Carlo path tracer (1–3 bounces) with analytical Nishita atmospheric sky dome, animated water ripples + Schlick Fresnel mirror reflections + underwater caustics, dielectric glass/prism refraction, voxel crevice AO & edge bevels, 13-tap optical HDR bloom + ACES filmic tone mapping (`bloomTonemapPresentKernel`), transient blast flash light, and progressive `1 / (frameIndex + 1)` temporal accumulation.
   - **Dynamic Display Sync & Thermal Scaling:**
     - `MetalView.swift` matches `window?.screen.maximumFramesPerSecond` (`60 Hz` on iPhone 13 / 13 mini, up to `120 Hz` on ProMotion), keeping `framebufferOnly = false`.
     - Both hardware paths dynamically scale internal resolution via `ProcessInfo.processInfo.thermalState`: `67%` (`.nominal`/`.fair`), `58%` (`.serious`), `50%` (`.critical`), keeping `phys_footprint` far below the `1.2 GB` ceiling for 4 GB RAM iPhones.
   - **Apple9+ Physical Devices:** `Metal4DevicePipeline.swift` + `VoxelRay/Shaders/VoxelIntersect.metal` (`MTL4CommandQueue`, `MTLResidencySet`, `MTL4AccelerationStructureBoundingBoxGeometryDescriptor`, `MTLIntersectionFunctionTable`, `MTL4FXTemporalScaler`).
   - **A15/A16 Physical Devices & iOS Simulator:** `ComputePathTracePipeline` (`SimulatorComputePipeline.swift` + `VoxelRay/Shaders/SimulatorFallback.metal`): runs 3D Amanatides-Woo DDA with `deviceComputePathTraceKernel` outputting HDR color, reversed depth, and pixel motion vectors into hardware **`MTLFXTemporalScaler`** on physical iPhones, and uniform-dispatched `simulatorPathTraceKernel` on Simulator.
   - **Safe Readback:** Explicit `MTLBlitCommandEncoder` copy from `.private` GPU textures to `.storageModeShared` staging buffers so `MTL_DEBUG_LAYER=1` passes cleanly everywhere.

3. **Procedural Audio, Gameplay & Biomes (`64x32x64` = 131,072 voxels):**
   - `VoxelWorld.swift`: **Sunlit Courtyard** (Free), **Neon Cavern** (Pro), **Glass Cathedral** (Pro) with 12-step Undo stack, carving/sculpting (`Blast`, `Gold`, `Neon`, `Glass`, `Prism`), and CPU/GPU DDA parity.
   - `DebrisSystem.swift` + `Camera.swift` + `SoundEngine.swift`: 3D bouncing voxel debris Canvas overlay, damped camera shake, and off-main-thread DSP sound synthesis (`AVAudioSession` on `voiceQueue`).

4. **Two-Stage CI, Commercialization & App Store Connect Staging:**
   - **StoreKit 2 (`StoreManager.swift`, `StoreConfig.swift`, `VoxelRay.storekit`):** `com.voxelray.app.pro` (`$4.99`) and `com.voxelray.app.materials.crystal` (`$1.99`) with `SKTestSession` verification.
   - **Compliance:** `PrivacyInfo.xcprivacy` (zero tracking, zero collection), `ITSAppUsesNonExemptEncryption = NO`, procedural `1024x1024` 24-bit opaque App Icon.
   - **Two-Stage Gate (`scripts/ci_test_and_stage.sh`):** Stage A (Simulator `generic/platform=iOS` + `MTL_DEBUG_LAYER=1`) -> Stage B (Auto-discovered unlocked physical iPhone 13 via `xcrun devicectl`).
   - **Release & ASC Draft Stager (`scripts/stage_release_and_upload.sh` + `scripts/asc_stage_draft.py`):** Archives Release, increments `CFBundleVersion`, uploads `.ipa`, configures TestFlight Internal Testing, and stages Draft `1.0.0` at **HARD STOP (`PREPARE_FOR_SUBMISSION`)**.
