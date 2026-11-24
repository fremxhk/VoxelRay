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
            m.albedo = float3(0.84f, 0.77f, 0.66f) * micro;
            m.roughness = 0.86f;
            break;
        case MAT_TERRACOTTA:
            m.albedo = float3(0.75f, 0.34f, 0.21f) * micro;
            m.roughness = 0.80f;
            break;
        case MAT_MOSS:
            m.albedo = float3(0.20f, 0.52f, 0.23f) * micro;
            m.roughness = 0.90f;
            break;
        case MAT_BASALT:
            m.albedo = float3(0.13f, 0.14f, 0.18f) * micro;
            m.roughness = 0.74f;
            break;
        case MAT_GOLD:
            m.albedo = float3(0.98f, 0.78f, 0.30f);
            m.roughness = 0.16f;
            m.metallic = 1.0f;
            break;
        case MAT_CHROME:
            m.albedo = float3(0.88f, 0.92f, 0.97f);
            m.roughness = 0.08f;
            m.metallic = 1.0f;
            break;
        case MAT_GLASS:
            m.albedo = float3(0.86f, 0.95f, 1.0f);
            m.roughness = 0.03f;
            m.transmission = 0.92f;
            m.ior = 1.50f;
            m.absorption = float3(0.03f, 0.01f, 0.008f);
            break;
        case MAT_WATER:
            m.albedo = float3(0.16f, 0.72f, 0.84f);
            m.roughness = 0.04f;
            m.transmission = 0.84f;
            m.ior = 1.333f;
            m.absorption = float3(0.16f, 0.04f, 0.02f);
            break;
        case MAT_NEON_CYAN:
            m.albedo = float3(0.15f, 0.96f, 1.0f);
            m.emissive = float3(0.22f, 2.95f, 3.65f);
            m.roughness = 0.25f;
            break;
        case MAT_NEON_MAGENTA:
            m.albedo = float3(1.0f, 0.20f, 0.78f);
            m.emissive = float3(3.55f, 0.28f, 2.35f);
            m.roughness = 0.25f;
            break;
        case MAT_AMBER_LANTERN:
            m.albedo = float3(1.0f, 0.74f, 0.28f);
            m.emissive = float3(3.25f, 1.85f, 0.48f);
            m.roughness = 0.30f;
            break;
        case MAT_PRISM_CRYSTAL: {
            float3 prismTint = 0.55f + 0.45f * cos(float3(0.0f, 2.1f, 4.2f) + dot(floor(worldPos), float3(0.42f, 0.27f, 0.35f)));
            m.albedo = mix(float3(0.72f, 0.92f, 1.0f), prismTint, 0.55f);
            m.emissive = prismTint * 0.62f;
            m.roughness = 0.02f;
            m.transmission = 0.90f;
            m.ior = 1.65f;
            m.absorption = float3(0.04f, 0.015f, 0.02f);
            break;
        }
        default:
            break;
    }
    return m;
}

inline int isSolidNeighbor(int3 coord, const device uint8_t* voxels) {
    if (!inGridBounds(coord.x, coord.y, coord.z)) {
        return 0;
    }
    uint m = uint(voxels[voxelIndex(coord.x, coord.y, coord.z)]);
    return (m != MAT_AIR && m != MAT_WATER && m != MAT_GLASS) ? 1 : 0;
}

/// Evaluates soft corner ambient occlusion and subtle machined block bevel highlight.
inline float2 evaluateVoxelAOAndBevel(
    float3 hitPos,
    float3 normal,
    int3 voxelCoord,
    const device uint8_t* voxels
) {
    int3 nInt = int3(round(normal));
    int3 ext = voxelCoord + nInt;
    float3 local = clamp(hitPos - float3(voxelCoord), 0.0f, 1.0f);

    float u = 0.5f;
    float v = 0.5f;
    int3 t1 = int3(1, 0, 0);
    int3 t2 = int3(0, 1, 0);

    if (abs(nInt.x) > 0) {
        u = local.y;
        v = local.z;
        t1 = int3(0, 1, 0);
        t2 = int3(0, 0, 1);
    } else if (abs(nInt.y) > 0) {
        u = local.x;
        v = local.z;
        t1 = int3(1, 0, 0);
        t2 = int3(0, 0, 1);
    } else {
        u = local.x;
        v = local.y;
        t1 = int3(1, 0, 0);
        t2 = int3(0, 1, 0);
    }

    int sP1 = isSolidNeighbor(ext + t1, voxels);
    int sN1 = isSolidNeighbor(ext - t1, voxels);
    int sP2 = isSolidNeighbor(ext + t2, voxels);
    int sN2 = isSolidNeighbor(ext - t2, voxels);

    float occ = 0.0f;
    if (sP1 != 0) occ += 0.34f * pow(u, 1.6f);
    if (sN1 != 0) occ += 0.34f * pow(1.0f - u, 1.6f);
    if (sP2 != 0) occ += 0.34f * pow(v, 1.6f);
    if (sN2 != 0) occ += 0.34f * pow(1.0f - v, 1.6f);

    if (isSolidNeighbor(ext + t1 + t2, voxels) != 0) occ += 0.16f * pow(u * v, 1.5f);
    if (isSolidNeighbor(ext - t1 + t2, voxels) != 0) occ += 0.16f * pow((1.0f - u) * v, 1.5f);
    if (isSolidNeighbor(ext + t1 - t2, voxels) != 0) occ += 0.16f * pow(u * (1.0f - v), 1.5f);
    if (isSolidNeighbor(ext - t1 - t2, voxels) != 0) occ += 0.16f * pow((1.0f - u) * (1.0f - v), 1.5f);

    float ao = clamp(1.0f - occ, 0.38f, 1.0f);

    // Subtle sunlit seam & outer bevel accent on exposed edges
    float edgeU = abs(u - 0.5f);
    float edgeV = abs(v - 0.5f);
    float bevelMask = max(
        (sP1 == 0 && u > 0.88f) || (sN1 == 0 && u < 0.12f) ? smoothstep(0.41f, 0.495f, edgeU) : 0.0f,
        (sP2 == 0 && v > 0.88f) || (sN2 == 0 && v < 0.12f) ? smoothstep(0.41f, 0.495f, edgeV) : 0.0f
    );
    return float2(ao, bevelMask * 0.11f);
}

inline float3 evaluateWaterRippleNormal(float3 hitPos, float timeSec, float3 baseNormal) {
    if (fabs(baseNormal.y) < 0.5f) {
        return baseNormal;
    }
    float dx = 0.042f * cos(hitPos.x * 2.15f + timeSec * 2.3f + sin(hitPos.z * 1.4f - timeSec * 1.2f))
             + 0.022f * cos((hitPos.x + hitPos.z) * 3.1f - timeSec * 2.8f);
    float dz = -0.042f * sin(hitPos.z * 2.45f - timeSec * 2.0f + cos(hitPos.x * 1.3f + timeSec * 1.1f))
             + 0.022f * sin((hitPos.z - hitPos.x) * 2.9f + timeSec * 2.5f);
    return normalize(float3(dx, baseNormal.y >= 0.0f ? 1.0f : -1.0f, dz));
}

inline float3 evaluateBlastDynamicLight(float3 hitPos, float3 normal, constant FrameUniforms& u) {
    float intensity = u.extra0.w;
    if (intensity <= 1e-4f) {
        return float3(0.0f);
    }
    float3 delta = u.extra0.xyz - hitPos;
    float distSq = dot(delta, delta);
    float dist = sqrt(max(distSq, 1e-4f));
    float3 lDir = delta / dist;
    float atten = 1.0f / (1.0f + 0.075f * distSq);
    float wrap = clamp((dot(normal, lDir) + 0.35f) / 1.35f, 0.0f, 1.0f);
    float shockR = u.extra1.w;
    float ringDelta = fabs(dist - shockR);
    float ring = (shockR > 0.05f) ? exp(-ringDelta * ringDelta * 3.8f) * 1.35f : 0.0f;
    return u.extra1.xyz * intensity * (atten * wrap * 5.8f + ring);
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

// Functions implemented in Lighting.metal
float3 evaluateNishitaSky(float3 dir, float3 sunDir, uint biomeId);
float3 traceMonteCarloDDA(
    float3 origin,
    float3 dir,
    uint2 gid,
    constant FrameUniforms& u,
    const device uint8_t* voxels
);

#endif /* VoxelCommon_h */
