# VoxelRay

**VoxelRay** is a real-time ray-traced **Destructible Voxel Sandbox** for iPhone built with **SwiftUI**, **Metal 4 + MetalFX** (physical iOS devices), a unified **Metal Compute 3D DDA fallback** (iOS Simulator), and **StoreKit 2**.

## Architecture

### Dual-Target Rendering Pipeline
- **Physical iPhone (`#if !targetEnvironment(simulator)`):**
  - `Metal4DevicePipeline.swift` + `VoxelIntersect.metal`:
    - Uses `MTL4CommandQueue`, triple-buffered `MTL4CommandAllocator`, `MTL4CommandBuffer`, `MTL4Compiler`, `MTL4ArgumentTable`, and `MTLResidencySet`.
    - Groups the `64x32x64` voxel world into `2048` `4x4x4` bricks inside a `MTL4AccelerationStructureBoundingBoxGeometryDescriptor` BVH with in-place `refit` after sculpting/carving and a custom `[[intersection(bounding_box)]]` shader via `MTLIntersectionFunctionTable`.
    - **MetalFX Temporal Upscaling (`MTL4FXTemporalScaler`):** Dynamically scales internal ray-tracing resolution and bounce count from `ProcessInfo.processInfo.thermalState`:
      - `.nominal` / `.fair` -> `75%` internal resolution, `3` bounces
      - `.serious` -> `58%` internal resolution, `2` bounces
      - `.critical` -> `50%` internal resolution, `1` bounce
- **iOS Simulator (`#if targetEnvironment(simulator)`):**
  - `SimulatorComputePipeline.swift` + `SimulatorFallback.metal`:
    - Branch-minimal 3D Amanatides-Woo DDA voxel traversal sharing the same `256`-byte `FrameUniforms` contract (`ShaderTypes.h`) and multi-bounce Monte Carlo `Lighting.metal` path tracer.

### Path Tracer & World Features
- **3 Procedural Biomes (`64x32x64` voxels, `SplitMix64` deterministic seeds):**
  1. **Sunlit Courtyard** (Free) — Travertine colonnade, terracotta eaves, reflective pool, golden obelisk, cypress planters.
  2. **Neon Cavern** (Architect Pro) — Dark basalt vault, emissive cyan/magenta pylons, central prism spire, chrome catwalks.
  3. **Glass Cathedral** (Architect Pro) — Golden Gothic ribs, dielectric glass arches, refractive prism altar, amber nave channels.
- **Monte Carlo GI (`Lighting.metal`):** Analytical Nishita sky dome, explicit sun Next Event Estimation shadow rays, Schlick Fresnel & Snell refraction (`glass`, `water`, `prismCrystal`), emissive GI bounce, firefly clamping, ACES filmic tone mapping, and progressive temporal accumulation.
- **Interactive Sculpting & Photo Mode:** Virtual joystick navigation, touch pan-look, tap-to-carve / Prism Crystal brush with haptics, and 64-sample Photo Mode share export (`UIActivityViewController`).

### Zero-Backend Monetization (`StoreKit 2`)
- `com.voxelray.app.pro` — **Architect Pro** (`$4.99`, Non-Consumable): Unlocks Neon Cavern & Glass Cathedral biomes and watermark-free 4K Photo Mode exports.
- `com.voxelray.app.materials.crystal` — **Prism Material Pack** (`$1.99`, Non-Consumable): Unlocks the refractive Prism Crystal brush.

## Build & Test CLI
```bash
# Generate Xcode project from project.yml
xcodegen generate

# Run physical-device Metal 4 compile check + full Simulator CI suite (MTL_DEBUG_LAYER=1)
./scripts/ci_test_and_stage.sh

# Capture & verify 6.9-inch landscape App Store screenshots
./scripts/ci_test_and_stage.sh --screenshots

# Regenerate 1024x1024 24-bit RGB App Icon (no alpha channel)
swift -O scripts/generate_icon.swift
```
