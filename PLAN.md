# VoxelRay — Architectural & Autonomous Release Plan

## Overview
VoxelRay is a ray-traced **Destructible Voxel Sandbox** for iPhone built with **SwiftUI**, **Metal 4 / MetalFX** (on physical iOS devices), a unified **Metal compute 3D DDA fallback** (on iOS Simulator), and **StoreKit 2** for zero-backend commercialization.

## Core Architecture
1. **Deterministic Project Generation (`XcodeGen`):**
   - Managed via `project.yml` (`IPHONEOS_DEPLOYMENT_TARGET: 26.0`, `TARGETED_DEVICE_FAMILY: 1`, landscape-only).
   - `VoxelRay` (App), `VoxelRayTests` (Unit / Render / StoreKit), `VoxelRayUITests` (UI & Screenshot Automation).

2. **Dual-Target Rendering Pipeline:**
   - **Shared Shader Contract (`VoxelRay/Engine/ShaderTypes.h`, `VoxelRay/Shaders/VoxelCommon.h`, `VoxelRay/Shaders/Lighting.metal`):**
     - `FrameUniforms` strictly 256-byte aligned (`_Static_assert(sizeof(FrameUniforms) == 256)`), triple-buffered via `DispatchSemaphore(value: 3)`.
     - Monte Carlo path tracer (up to 3 bounces) with analytical Nishita atmospheric sky dome, Schlick Fresnel dielectric glass/water/prism refraction, emissive voxel GI, firefly clamping, ACES filmic tone mapping, and progressive `1 / (frameIndex + 1)` temporal accumulation.
   - **Physical Device (`#if !targetEnvironment(simulator)` / `#if !defined(__METAL_IOS_SIMULATOR__)`):**
     - `Metal4DevicePipeline.swift` + `VoxelRay/Shaders/VoxelIntersect.metal`:
     - `MTL4CommandQueue`, `MTL4CommandAllocator`, `MTL4CommandBuffer`, `MTL4Compiler`, `MTL4ArgumentTable`, `MTLResidencySet`.
     - `4x4x4` brick AABB acceleration structure (`MTL4AccelerationStructureBoundingBoxGeometryDescriptor`, `2048` primitives, in-place refit on carve/place) + `MTLIntersectionFunctionTable` custom ray-AABB intersection.
     - Device-only `MTL4FXTemporalScaler` / `MTLFXTemporalScaler` driven by `ProcessInfo.processInfo.thermalState` (`nominal`/`fair` = 75%, `serious` = 58%, `critical` = 50% + reduced bounces).
   - **iOS Simulator (`#if targetEnvironment(simulator)` / `#if defined(__METAL_IOS_SIMULATOR__)`):**
     - `SimulatorComputePipeline.swift` + `VoxelRay/Shaders/SimulatorFallback.metal`:
     - Branch-minimal 3D Amanatides-Woo DDA voxel traversal over the packed `64x32x64` voxel buffer.
   - **Safe Readback:**
     - Offscreen test renders and Photo Mode exports encode an explicit `MTLBlitCommandEncoder` copy from `.private` GPU textures into `.storageModeShared` staging buffers so `MTL_DEBUG_LAYER=1` passes cleanly.

3. **Procedural Voxel World (`64x32x64` = 131,072 voxels):**
   - **Sunlit Courtyard** (Free): Travertine plaza, colonnade arches, water basin, moss beds, golden braziers.
   - **Neon Cavern** (Architect Pro): Dark basalt vaulted grotto, cyan/magenta emissive crystals, chrome bridges, reflective pool.
   - **Glass Cathedral** (Architect Pro): Dielectric glass nave arches, prism crystal spires, gold structural ribs, inlaid amber light floor.
   - Deterministic `SplitMix64` world generation, spherical blast carving & prism crystal placement, dirty-region tracking, and analytical CPU 3D DDA raycast matching GPU traversal.

4. **Commercialization & App Store Compliance:**
   - **StoreKit 2 (`StoreManager.swift`, `StoreConfig.swift`, `VoxelRay.storekit`):**
     - `com.voxelray.app.pro` — **Architect Pro** (`$4.99`, Non-Consumable)
     - `com.voxelray.app.materials.crystal` — **Prism Material Pack** (`$1.99`, Non-Consumable)
   - `PrivacyInfo.xcprivacy` (zero tracking, zero data collection, required-reason API declarations), `ITSAppUsesNonExemptEncryption = NO`, procedural `1024x1024` 24-bit RGB no-alpha App Icon.
   - Headless CI verification via `./scripts/ci_test_and_stage.sh` and idempotent ASC draft staging via `scripts/asc_stage_draft.py` (strictly stopping at `PREPARE_FOR_SUBMISSION` Draft).
