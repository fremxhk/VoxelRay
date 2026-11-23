#ifndef VoxelCommon_h
#define VoxelCommon_h

#include <metal_stdlib>
#include "../Engine/ShaderTypes.h"

using namespace metal;

constant int VR_GRID_W = 64;
constant int VR_GRID_H = 32;
constant int VR_GRID_D = 64;

constant int VR_BRICK_SIZE = 4;
constant int VR_BRICKS_X = 16;
constant int VR_BRICKS_Y = 8;
constant int VR_BRICKS_Z = 16;

enum VoxelMaterialID : uint {
    MAT_AIR = 0,
    MAT_TRAVERTINE = 1,
    MAT_TERRACOTTA = 2,
    MAT_MOSS = 3,
    MAT_BASALT = 4,
    MAT_GOLD = 5,
    MAT_CHROME = 6,
    MAT_GLASS = 7,
    MAT_WATER = 8,
    MAT_NEON_CYAN = 9,
    MAT_NEON_MAGENTA = 10,
    MAT_AMBER_LANTERN = 11,
    MAT_PRISM_CRYSTAL = 12
};

struct VoxelHit {
    bool hit;
    float distance;
    float3 normal;
    int3 voxelCoord;
    uint materialId;
};

struct MaterialProps {
    float3 albedo;
    float3 emissive;
    float roughness;
    float metallic;
    float transmission;
    float ior;
    float3 absorption;
};

inline int voxelIndex(int x, int y, int z) {
    return x + VR_GRID_W * (y + VR_GRID_H * z);
}

inline bool inGridBounds(int x, int y, int z) {
    return x >= 0 && x < VR_GRID_W && y >= 0 && y < VR_GRID_H && z >= 0 && z < VR_GRID_D;
}

inline MaterialProps getMaterialProps(uint matId, float3 worldPos) {
    MaterialProps m;
    m.albedo = float3(0.8f);
    m.emissive = float3(0.0f);
    m.roughness = 0.85f;
    m.metallic = 0.0f;
    m.transmission = 0.0f;
    m.ior = 1.5f;
    m.absorption = float3(0.0f);

    float grain = fract(sin(dot(floor(worldPos), float3(12.9898f, 78.233f, 37.719f))) * 43758.5453f);
    float micro = 0.94f + 0.12f * grain;

    switch (matId) {
        case MAT_TRAVERTINE:
            m.albedo = float3(0.89f, 0.83f, 0.72f) * micro;
            m.roughness = 0.88f;
            break;
        case MAT_TERRACOTTA:
            m.albedo = float3(0.76f, 0.36f, 0.22f) * micro;
            m.roughness = 0.82f;
            break;
        case MAT_MOSS:
            m.albedo = float3(0.22f, 0.50f, 0.24f) * micro;
            m.roughness = 0.92f;
            break;
        case MAT_BASALT:
            m.albedo = float3(0.11f, 0.12f, 0.15f) * micro;
            m.roughness = 0.78f;
            break;
        case MAT_GOLD:
            m.albedo = float3(0.96f, 0.76f, 0.32f);
            m.roughness = 0.18f;
            m.metallic = 1.0f;
            break;
        case MAT_CHROME:
            m.albedo = float3(0.86f, 0.89f, 0.94f);
            m.roughness = 0.10f;
            m.metallic = 1.0f;
            break;
        case MAT_GLASS:
            m.albedo = float3(0.92f, 0.97f, 1.0f);
            m.roughness = 0.04f;
            m.transmission = 0.92f;
            m.ior = 1.50f;
            m.absorption = float3(0.04f, 0.015f, 0.01f);
            break;
        case MAT_WATER:
            m.albedo = float3(0.32f, 0.74f, 0.88f);
            m.roughness = 0.05f;
            m.transmission = 0.82f;
            m.ior = 1.333f;
            m.absorption = float3(0.22f, 0.06f, 0.03f);
            break;
        case MAT_NEON_CYAN:
            m.albedo = float3(0.15f, 0.95f, 1.0f);
            m.emissive = float3(0.25f, 3.6f, 4.4f);
            m.roughness = 0.3f;
            break;
        case MAT_NEON_MAGENTA:
            m.albedo = float3(1.0f, 0.18f, 0.75f);
            m.emissive = float3(4.2f, 0.35f, 2.8f);
            m.roughness = 0.3f;
            break;
        case MAT_AMBER_LANTERN:
            m.albedo = float3(1.0f, 0.72f, 0.25f);
            m.emissive = float3(4.0f, 2.2f, 0.55f);
            m.roughness = 0.35f;
            break;
        case MAT_PRISM_CRYSTAL: {
            float3 prismTint = 0.55f + 0.45f * cos(float3(0.0f, 2.1f, 4.2f) + dot(floor(worldPos), float3(0.35f)));
            m.albedo = mix(float3(0.75f, 0.92f, 1.0f), prismTint, 0.45f);
            m.emissive = prismTint * 0.45f;
            m.roughness = 0.03f;
            m.transmission = 0.88f;
            m.ior = 1.75f;
            m.absorption = float3(0.05f, 0.02f, 0.03f);
            break;
        }
        default:
            break;
    }
    return m;
}

inline float3 computePrimaryRayDir(uint2 gid, uint2 dims, float2 jitter, constant FrameUniforms& u) {
    float2 pixel = float2(gid) + float2(0.5f) + jitter;
    float2 uv = pixel / float2(dims);
    float ndcX = uv.x * 2.0f - 1.0f;
    float ndcY = 1.0f - uv.y * 2.0f;
    float tanHalfFov = tan(u.cameraPos.w * 0.5f);
    float aspect = max(u.cameraForward.w, 0.2f);
    float3 dir = u.cameraForward.xyz
        + u.cameraRight.xyz * (ndcX * aspect * tanHalfFov)
        + u.cameraUp.xyz * (ndcY * tanHalfFov);
    return normalize(dir);
}

inline VoxelHit traceVoxelDDA(float3 origin, float3 direction, float maxDistance, const device uint8_t* voxels) {
    VoxelHit result;
    result.hit = false;
    result.distance = maxDistance;
    result.normal = float3(0.0f, 1.0f, 0.0f);
    result.voxelCoord = int3(0);
    result.materialId = MAT_AIR;

    float len = length(direction);
    if (len < 1e-6f) {
        return result;
    }
    float3 dir = direction / len;

    float3 invDir = float3(
        fabs(dir.x) > 1e-6f ? (1.0f / dir.x) : (dir.x >= 0.0f ? 1e30f : -1e30f),
        fabs(dir.y) > 1e-6f ? (1.0f / dir.y) : (dir.y >= 0.0f ? 1e30f : -1e30f),
        fabs(dir.z) > 1e-6f ? (1.0f / dir.z) : (dir.z >= 0.0f ? 1e30f : -1e30f)
    );

    float3 boxMin = float3(0.0f);
    float3 boxMax = float3(float(VR_GRID_W), float(VR_GRID_H), float(VR_GRID_D));

    float3 t0 = (boxMin - origin) * invDir;
    float3 t1 = (boxMax - origin) * invDir;
    float3 tSmaller = min(t0, t1);
    float3 tLarger = max(t0, t1);

    float tEnter = max(max(tSmaller.x, tSmaller.y), max(tSmaller.z, 0.0f));
    float tExit = min(min(tLarger.x, tLarger.y), min(tLarger.z, maxDistance));
    if (tEnter >= tExit) {
        return result;
    }

    float startDist = (tEnter > 0.0f) ? (tEnter + 1e-4f) : 0.0f;
    float3 startPos = origin + dir * startDist;

    int vx = clamp(int(floor(startPos.x)), 0, VR_GRID_W - 1);
    int vy = clamp(int(floor(startPos.y)), 0, VR_GRID_H - 1);
    int vz = clamp(int(floor(startPos.z)), 0, VR_GRID_D - 1);

    float3 lastNormal = float3(0.0f, 1.0f, 0.0f);
    if (tEnter > 0.0f) {
        if (tSmaller.x >= tSmaller.y && tSmaller.x >= tSmaller.z) {
            lastNormal = float3(dir.x > 0.0f ? -1.0f : 1.0f, 0.0f, 0.0f);
        } else if (tSmaller.y >= tSmaller.z) {
            lastNormal = float3(0.0f, dir.y > 0.0f ? -1.0f : 1.0f, 0.0f);
        } else {
            lastNormal = float3(0.0f, 0.0f, dir.z > 0.0f ? -1.0f : 1.0f);
        }
    }

    int stepX = dir.x >= 0.0f ? 1 : -1;
    int stepY = dir.y >= 0.0f ? 1 : -1;
    int stepZ = dir.z >= 0.0f ? 1 : -1;

    float nextBoundaryX = float(vx + (stepX > 0 ? 1 : 0));
    float nextBoundaryY = float(vy + (stepY > 0 ? 1 : 0));
    float nextBoundaryZ = float(vz + (stepZ > 0 ? 1 : 0));

    float tMaxX = fabs(dir.x) > 1e-6f ? (nextBoundaryX - origin.x) * invDir.x : 1e30f;
    float tMaxY = fabs(dir.y) > 1e-6f ? (nextBoundaryY - origin.y) * invDir.y : 1e30f;
    float tMaxZ = fabs(dir.z) > 1e-6f ? (nextBoundaryZ - origin.z) * invDir.z : 1e30f;

    float tDeltaX = fabs(dir.x) > 1e-6f ? fabs(invDir.x) : 1e30f;
    float tDeltaY = fabs(dir.y) > 1e-6f ? fabs(invDir.y) : 1e30f;
    float tDeltaZ = fabs(dir.z) > 1e-6f ? fabs(invDir.z) : 1e30f;

    float currentT = startDist;

    for (int iter = 0; iter < 256; ++iter) {
        uint mat = uint(voxels[voxelIndex(vx, vy, vz)]);
        if (mat != MAT_AIR) {
            result.hit = true;
            result.distance = currentT;
            result.normal = lastNormal;
            result.voxelCoord = int3(vx, vy, vz);
            result.materialId = mat;
            return result;
        }

        if (tMaxX < tMaxY && tMaxX < tMaxZ) {
            currentT = tMaxX;
            tMaxX += tDeltaX;
            vx += stepX;
            lastNormal = float3(float(-stepX), 0.0f, 0.0f);
        } else if (tMaxY < tMaxZ) {
            currentT = tMaxY;
            tMaxY += tDeltaY;
            vy += stepY;
            lastNormal = float3(0.0f, float(-stepY), 0.0f);
        } else {
            currentT = tMaxZ;
            tMaxZ += tDeltaZ;
            vz += stepZ;
            lastNormal = float3(0.0f, 0.0f, float(-stepZ));
        }

        if (currentT > tExit || !inGridBounds(vx, vy, vz)) {
            break;
        }
    }
    return result;
}

inline float3 evaluateSkyColor(float3 dir, float3 sunDir, uint biomeId) {
    float mu = clamp(dir.y, -0.2f, 1.0f);
    float sunDot = max(dot(dir, sunDir), 0.0f);

    if (biomeId == 1u) {
        // Neon Cavern: deep midnight indigo sky with faint aurora rim
        float3 zenith = float3(0.02f, 0.03f, 0.09f);
        float3 horizon = float3(0.07f, 0.03f, 0.14f);
        float3 sky = mix(horizon, zenith, pow(clamp(mu, 0.0f, 1.0f), 0.65f));
        sky += float3(0.05f, 0.25f, 0.45f) * pow(sunDot, 16.0f);
        return sky;
    }

    if (biomeId == 2u) {
        // Glass Cathedral: golden-cerulean luminous sky
        float3 zenith = float3(0.14f, 0.34f, 0.78f);
        float3 horizon = float3(0.88f, 0.76f, 0.58f);
        float3 sky = mix(horizon, zenith, pow(clamp(mu, 0.0f, 1.0f), 0.55f));
        sky += float3(1.6f, 1.35f, 0.9f) * pow(sunDot, 24.0f);
        return sky;
    }

    // Sunlit Courtyard: bright Mediterranean Nishita-like sky
    float3 zenith = float3(0.16f, 0.42f, 0.88f);
    float3 horizon = float3(0.72f, 0.84f, 0.96f);
    float3 sky = mix(horizon, zenith, pow(clamp(mu, 0.0f, 1.0f), 0.58f));
    float mie = pow(sunDot, 36.0f) * 2.2f + pow(sunDot, 6.0f) * 0.25f;
    sky += float3(1.0f, 0.88f, 0.68f) * mie;
    return sky;
}

inline float3 acesFilmicToneMap(float3 x) {
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), 0.0f, 1.0f);
}

inline float3 linearToSRGB(float3 c) {
    return pow(clamp(c, 0.0f, 1.0f), float3(1.0f / 2.2f));
}

// Declaration for Phase 3 Lighting.metal path tracer / Phase 2 forward shading
float3 shadeVoxelPath(
    float3 origin,
    float3 dir,
    uint2 gid,
    constant FrameUniforms& u,
    const device uint8_t* voxels
);

#endif /* VoxelCommon_h */
