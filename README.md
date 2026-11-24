# VoxelRay

**VoxelRay** is a real-time ray-traced **Destructible Voxel Sandbox** for iPhone built with **SwiftUI**, **Metal 4 / Metal compute**, **MetalFX Temporal Upscaling**, procedural spatial audio (**AVFoundation**), and **StoreKit 2**.

## Architecture

### Adaptive Multi-Tier Rendering Pipeline (`< 1.2 GB` Memory Ceiling)
- **Apple9+ Physical iPhone (`Metal4DevicePipeline.swift` + `VoxelIntersect.metal`):**
  - Uses `MTL4CommandQueue`, triple-buffered `MTL4CommandAllocator`, `MTL4CommandBuffer`, `MTL4Compiler`, `MTL4ArgumentTable`, and `MTLResidencySet`.
  - Groups the `64x32x64` voxel grid into `2048` `4x4x4` bricks inside `MTL4AccelerationStructureBoundingBoxGeometryDescriptor` with in-place BVH `refit` and a custom `[[intersection(bounding_box)]]` shader via `MTLIntersectionFunctionTable`, upscaled by **`MTL4FXTemporalScaler`**.
- **A15 / A16 Physical iPhone (`ComputePathTracePipeline` + `SimulatorFallback.metal`):**
  - Guards Metal 4 RT cleanly with `device.supportsFamily(.apple9) && device.supportsFamily(.metal4)` so A15/A16 iPhones (e.g. `iPhone 13` / `13 mini`) execute 3D Amanatides-Woo DDA path tracing via `deviceComputePathTraceKernel` (emitting `.rgba16Float` HDR color, `.r32Float` reversed depth, and `.rg16Float` motion vectors) upscaled by hardware **`MTLFXTemporalScaler`**.
- **iOS Simulator (`#if targetEnvironment(simulator)`):**
  - Runs the shared `ComputePathTracePipeline` 3D DDA path tracer and `Lighting.metal` (`MTL_DEBUG_LAYER=1` verified), badged `"MetalFX (Device Only)"`.
- **Dynamic Refresh & Thermal Resolution Scaling (`50%–67%`):**
  - `MetalView.swift` adapts `CADisplayLink.preferredFrameRateRange` to `window?.screen.maximumFramesPerSecond` (`60 Hz` on iPhone 13 / 13 mini, up to `120 Hz` on ProMotion).
  - `ProcessInfo.processInfo.thermalState` scales internal resolution and bounce budget:
    - `.nominal` / `.fair` → `67%` scale, `3` bounces (`MetalFX · 67%`)
    - `.serious` → `58%` scale, `2` bounces (`MetalFX · 58% (Warm)`)
    - `.critical` → `50%` scale, `1` bounce (`MetalFX · 50% (Thermal)`)
- **Post-Processing (`Lighting.metal`):**
  - `bloomTonemapPresentKernel` runs a 13-tap dual-ring optical HDR bloom filter, ACES filmic tone mapping, and subtle edge vignette.

### Gameplay, Audio & Biomes
- **3 Procedural Biomes (`64x32x64`, `SplitMix64` seeds):**
  1. **Sunlit Courtyard** (Free) — Arched travertine colonnade, terraced turquoise water pool, golden obelisk, cypress planters.
  2. **Neon Cavern** (Architect Pro, 30s live preview included) — Basalt vault, cyan/magenta monoliths with optical bloom, chrome catwalks, dark mirror pool.
  3. **Glass Cathedral** (Architect Pro, 30s live preview included) — Golden Gothic ribs, prism crystal spire, stained-glass rose window, nave reflection canals.
- **Tactile Sculpting & Audio:** Tap-to-carve with 3D-projected physics debris (`DebrisSystem.swift`), damped impact micro-shake, 12-step world Undo, free **Gold / Neon / Glass** brushes alongside **Blast** & **Prism**, Dawn/Noon/Sunset/Night presets, off-main-thread procedural `AVAudioEngine` DSP foley (`SoundEngine.swift`), haptic feedback, and 64-sample Photo Mode export (`UIActivityViewController`).

### Zero-Backend Monetization (`StoreKit 2`)
- `com.voxelray.app.pro` — **Architect Pro** (`$4.99`, Non-Consumable): Unlocks Neon Cavern & Glass Cathedral biomes and watermark-free 4K Photo Mode exports.
- `com.voxelray.app.materials.crystal` — **Prism Material Pack** (`$1.99`, Non-Consumable): Unlocks the refractive Prism Crystal sculpting brush.

## Two-Stage CLI Test & Release Commands
```bash
# Regenerate XcodeGen project from project.yml
xcodegen generate

# Full Two-Stage CI Gate: Stage A (Simulator MTL_DEBUG_LAYER=1) -> Stage B (Unlocked Physical iPhone 13 via devicectl)
./scripts/ci_test_and_stage.sh

# Fast inner loop (Simulator Stage A only)
./scripts/ci_test_and_stage.sh --sim-only

# Capture & verify 6.9-inch landscape App Store screenshots (2868x1320, 24-bit opaque PNG)
./scripts/ci_test_and_stage.sh --screenshots

# Release Archive, ASC Upload (auto-incremented CFBundleVersion), TestFlight Internal & Draft Staging (HARD STOP)
./scripts/stage_release_and_upload.sh
```

## Measured Verification Telemetry
- **Simulator (`iPhone 18 Pro Max`, `iOS 27.2`):** `22/22` test cases passed (`0` failures, `MTL_DEBUG_LAYER=1`), `peakMemoryMB=69.7 MB`, `avgSampleMs=13.26 ms`.
- **Physical Device (`iPhone 13 mini`, `iOS 27.2.1`, A15 Bionic):** `21/21` test cases passed (`0` failures, `MTL_DEBUG_LAYER=1`), backend `A15ComputeDDA+MetalFX` (`MetalFX · 67%`), `peakMemoryMB=381.1 MB` (< 1.2 GB budget), `avgSampleMs=46.81 ms`.
