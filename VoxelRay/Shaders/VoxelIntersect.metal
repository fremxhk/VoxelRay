#include <metal_stdlib>
#include "VoxelCommon.h"

using namespace metal;

#if !defined(__METAL_IOS_SIMULATOR__) && !defined(__APPLE_EMBEDDED_SIMULATOR__)
#include <metal_raytracing>
using namespace metal::raytracing;

struct BoundingBoxResult {
    bool accept [[accept_intersection]];
    float distance [[distance]];
};

struct VoxelRayPayload {
    float3 normal;
    int3 voxelCoord;
    uint materialId;
};

[[intersection(bounding_box)]]
BoundingBoxResult voxelBoxIntersection(
    float3 origin [[origin]],
    float3 direction [[direction]],
    float minDistance [[min_distance]],
    float maxDistance [[max_distance]],
    uint primitiveIndex [[primitive_id]],
    ray_data VoxelRayPayload& payload [[payload]],
    const device uint8_t* voxels [[buffer(0)]]
) {
    BoundingBoxResult outResult;
    outResult.accept = false;
    outResult.distance = maxDistance;

    int bx = int(primitiveIndex & 15u);
    int by = int((primitiveIndex >> 4) & 7u);
    int bz = int(primitiveIndex >> 7);

    int3 brickOrigin = int3(bx * VR_BRICK_SIZE, by * VR_BRICK_SIZE, bz * VR_BRICK_SIZE);
    float3 bMin = float3(brickOrigin);
    float3 bMax = bMin + float3(float(VR_BRICK_SIZE));

    float3 invDir = float3(
        fabs(direction.x) > 1e-6f ? (1.0f / direction.x) : (direction.x >= 0.0f ? 1e30f : -1e30f),
        fabs(direction.y) > 1e-6f ? (1.0f / direction.y) : (direction.y >= 0.0f ? 1e30f : -1e30f),
        fabs(direction.z) > 1e-6f ? (1.0f / direction.z) : (direction.z >= 0.0f ? 1e30f : -1e30f)
    );

    float3 t0 = (bMin - origin) * invDir;
    float3 t1 = (bMax - origin) * invDir;
    float3 tSmaller = min(t0, t1);
    float3 tLarger = max(t0, t1);

    float tEnter = max(max(tSmaller.x, tSmaller.y), max(tSmaller.z, minDistance));
    float tExit = min(min(tLarger.x, tLarger.y), min(tLarger.z, maxDistance));
    if (tEnter >= tExit) {
        return outResult;
    }

    float startDist = (tEnter > minDistance) ? (tEnter + 1e-4f) : (minDistance + 1e-4f);
    float3 p = origin + direction * startDist;

    int lx = clamp(int(floor(p.x)) - brickOrigin.x, 0, VR_BRICK_SIZE - 1);
    int ly = clamp(int(floor(p.y)) - brickOrigin.y, 0, VR_BRICK_SIZE - 1);
    int lz = clamp(int(floor(p.z)) - brickOrigin.z, 0, VR_BRICK_SIZE - 1);

    float3 normal = float3(0.0f, 1.0f, 0.0f);
    if (tSmaller.x >= tSmaller.y && tSmaller.x >= tSmaller.z) {
        normal = float3(direction.x > 0.0f ? -1.0f : 1.0f, 0.0f, 0.0f);
    } else if (tSmaller.y >= tSmaller.z) {
        normal = float3(0.0f, direction.y > 0.0f ? -1.0f : 1.0f, 0.0f);
    } else {
        normal = float3(0.0f, 0.0f, direction.z > 0.0f ? -1.0f : 1.0f);
    }

    int stepX = direction.x >= 0.0f ? 1 : -1;
    int stepY = direction.y >= 0.0f ? 1 : -1;
    int stepZ = direction.z >= 0.0f ? 1 : -1;

    float nextX = float(brickOrigin.x + lx + (stepX > 0 ? 1 : 0));
    float nextY = float(brickOrigin.y + ly + (stepY > 0 ? 1 : 0));
    float nextZ = float(brickOrigin.z + lz + (stepZ > 0 ? 1 : 0));

    float tMaxX = fabs(direction.x) > 1e-6f ? (nextX - origin.x) * invDir.x : 1e30f;
    float tMaxY = fabs(direction.y) > 1e-6f ? (nextY - origin.y) * invDir.y : 1e30f;
    float tMaxZ = fabs(direction.z) > 1e-6f ? (nextZ - origin.z) * invDir.z : 1e30f;

    float tDeltaX = fabs(direction.x) > 1e-6f ? fabs(invDir.x) : 1e30f;
    float tDeltaY = fabs(direction.y) > 1e-6f ? fabs(invDir.y) : 1e30f;
    float tDeltaZ = fabs(direction.z) > 1e-6f ? fabs(invDir.z) : 1e30f;

    float currentT = startDist;

    for (int step = 0; step < 16; ++step) {
        int wx = brickOrigin.x + lx;
        int wy = brickOrigin.y + ly;
        int wz = brickOrigin.z + lz;
        uint mat = uint(voxels[voxelIndex(wx, wy, wz)]);
        if (mat != MAT_AIR && currentT >= minDistance && currentT <= maxDistance) {
            outResult.accept = true;
            outResult.distance = currentT;
            payload.normal = normal;
            payload.voxelCoord = int3(wx, wy, wz);
            payload.materialId = mat;
            return outResult;
        }

        if (tMaxX < tMaxY && tMaxX < tMaxZ) {
            currentT = tMaxX;
            tMaxX += tDeltaX;
            lx += stepX;
            normal = float3(float(-stepX), 0.0f, 0.0f);
        } else if (tMaxY < tMaxZ) {
            currentT = tMaxY;
            tMaxY += tDeltaY;
            ly += stepY;
            normal = float3(0.0f, float(-stepY), 0.0f);
        } else {
            currentT = tMaxZ;
            tMaxZ += tDeltaZ;
            lz += stepZ;
            normal = float3(0.0f, 0.0f, float(-stepZ));
        }

        if (lx < 0 || lx >= VR_BRICK_SIZE || ly < 0 || ly >= VR_BRICK_SIZE || lz < 0 || lz >= VR_BRICK_SIZE || currentT > tExit) {
            break;
        }
    }

    return outResult;
}

inline uint wangHashRT(uint s) {
    s = (s ^ 61u) ^ (s >> 16u);
    s *= 9u;
    s = s ^ (s >> 4u);
    s *= 0x27d4eb2du;
    s = s ^ (s >> 15u);
    return s;
}

inline float randFloatRT(thread uint& state) {
    state = wangHashRT(state);
    return float(state & 0x00FFFFFFu) / float(0x01000000u);
}

inline float3 cosineSampleHemisphereRT(float3 n, thread uint& rng) {
    float u1 = randFloatRT(rng);
    float u2 = randFloatRT(rng);
    float r = sqrt(u1);
    float theta = 6.2831853f * u2;
    float x = r * cos(theta);
    float y = r * sin(theta);
    float z = sqrt(max(0.0f, 1.0f - u1));
    float3 up = fabs(n.z) < 0.999f ? float3(0.0f, 0.0f, 1.0f) : float3(1.0f, 0.0f, 0.0f);
    float3 tangent = normalize(cross(up, n));
    float3 bitangent = cross(n, tangent);
    return normalize(tangent * x + bitangent * y + n * z);
}

kernel void metal4PathTraceKernel(
    constant FrameUniforms& uniforms [[buffer(0)]],
    const device uint8_t* voxels [[buffer(1)]],
    primitive_acceleration_structure accel [[buffer(2)]],
    intersection_function_table<> ift [[buffer(3)]],
    texture2d<float, access::read> accumReadTex [[texture(0)]],
    texture2d<float, access::write> accumWriteTex [[texture(1)]],
    texture2d<float, access::write> colorTex [[texture(2)]],
    texture2d<float, access::write> depthTex [[texture(3)]],
    texture2d<float, access::write> motionTex [[texture(4)]],
    texture2d<float, access::write> displayTex [[texture(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 dims = uint2(uint(uniforms.resolutionAndTime.x), uint(uniforms.resolutionAndTime.y));
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    uint frameIndex = uniforms.renderParams.x;
    uint maxBounces = max(1u, min(uniforms.renderParams.y, 4u));
    uint biomeId = uniforms.gridSizeAndBiome.w;
    float3 sunDir = normalize(uniforms.sunDirAndElevation.xyz);

    uint rng = wangHashRT(gid.x * 1973u ^ gid.y * 9277u ^ (frameIndex + 1u) * 26699u);
    float2 jitter = float2(uniforms.cameraRight.w, uniforms.cameraUp.w);
    if (frameIndex > 0u) {
        jitter += float2(randFloatRT(rng) - 0.5f, randFloatRT(rng) - 0.5f) * 0.75f;
    }

    float3 rayOrigin = uniforms.cameraPos.xyz;
    float3 rayDir = computePrimaryRayDir(gid, dims, jitter, uniforms);

    intersector<> rt;
    rt.assume_geometry_type(geometry_type::bounding_box);

    float3 radiance = float3(0.0f);
    float3 throughput = float3(1.0f);
    float firstHitDist = 200.0f;
    float3 firstHitPos = rayOrigin + rayDir * 200.0f;

    for (uint bounce = 0u; bounce < maxBounces; ++bounce) {
        ray r(rayOrigin, rayDir, 0.001f, 200.0f);
        VoxelRayPayload payload;
        auto hit = rt.intersect(r, accel, ift, payload);
        if (hit.type == intersection_type::none) {
            radiance += throughput * evaluateNishitaSky(rayDir, sunDir, biomeId);
            break;
        }

        float3 hitPos = rayOrigin + rayDir * hit.distance;
        if (bounce == 0u) {
            firstHitDist = hit.distance;
            firstHitPos = hitPos;
        }

        MaterialProps mat = getMaterialProps(payload.materialId, float3(payload.voxelCoord) + 0.5f);
        radiance += throughput * mat.emissive;

        // Direct sun Next Event Estimation shadow test via hardware BVH
        float3 n = payload.normal;
        float nDotL = dot(n, sunDir);
        if (nDotL > 0.0f && mat.transmission < 0.5f) {
            ray shadowRay(hitPos + n * 0.015f, sunDir, 0.001f, 160.0f);
            VoxelRayPayload shadowPayload;
            auto shadowHit = rt.intersect(shadowRay, accel, ift, shadowPayload);
            if (shadowHit.type == intersection_type::none) {
                float3 sunColor = (biomeId == 1u) ? float3(0.55f, 0.75f, 1.25f) : float3(2.8f, 2.55f, 2.2f);
                radiance += throughput * mat.albedo * sunColor * nDotL * (1.0f - mat.metallic * 0.5f);
            }
        }

        if (mat.transmission > 0.5f) {
            bool entering = dot(rayDir, n) < 0.0f;
            float3 orientN = entering ? n : -n;
            float eta = entering ? (1.0f / mat.ior) : mat.ior;
            float cosTheta = min(dot(-rayDir, orientN), 1.0f);
            float r0 = (1.0f - eta) / (1.0f + eta);
            r0 = r0 * r0;
            float fresnel = r0 + (1.0f - r0) * pow(1.0f - cosTheta, 5.0f);
            float3 refracted = refract(rayDir, orientN, eta);
            if (length(refracted) < 1e-4f || randFloatRT(rng) < fresnel) {
                rayDir = reflect(rayDir, orientN);
                rayOrigin = hitPos + orientN * 0.015f;
            } else {
                rayDir = normalize(refracted);
                rayOrigin = hitPos - orientN * 0.015f;
                throughput *= exp(-mat.absorption * 0.8f);
            }
            throughput *= mat.albedo;
        } else if (mat.metallic > 0.5f) {
            float3 refl = reflect(rayDir, n);
            float3 jitterDir = cosineSampleHemisphereRT(n, rng);
            rayDir = normalize(mix(refl, jitterDir, mat.roughness * mat.roughness));
            rayOrigin = hitPos + n * 0.015f;
            throughput *= mat.albedo;
        } else {
            rayDir = cosineSampleHemisphereRT(n, rng);
            rayOrigin = hitPos + n * 0.015f;
            throughput *= mat.albedo;
        }

        float maxC = max(radiance.r, max(radiance.g, radiance.b));
        if (maxC > uniforms.outputAndExposure.w) {
            radiance *= (uniforms.outputAndExposure.w / maxC);
            break;
        }
    }

    float maxLum = max(radiance.r, max(radiance.g, radiance.b));
    if (maxLum > uniforms.outputAndExposure.w) {
        radiance *= (uniforms.outputAndExposure.w / maxLum);
    }

    float4 prev = (frameIndex == 0u) ? float4(0.0f) : accumReadTex.read(gid);
    float weight = 1.0f / float(frameIndex + 1u);
    float3 accumulated = mix(prev.rgb, radiance, weight);
    accumWriteTex.write(float4(accumulated, 1.0f), gid);

    float3 exposed = accumulated * uniforms.outputAndExposure.y;
    colorTex.write(float4(exposed, 1.0f), gid);

    float normDepth = clamp(1.0f / max(firstHitDist, 0.1f), 0.0f, 1.0f);
    depthTex.write(float4(normDepth, 0.0f, 0.0f, 1.0f), gid);

    // Motion vector in pixels (previous projection - current)
    float3 toPrev = firstHitPos - uniforms.prevCameraPos.xyz;
    float pz = dot(toPrev, uniforms.prevCameraForward.xyz);
    float2 motion = float2(0.0f);
    if (pz > 0.01f) {
        float tanHalf = tan(uniforms.prevCameraPos.w * 0.5f);
        float px = dot(toPrev, uniforms.prevCameraRight.xyz) / (pz * max(uniforms.prevCameraForward.w, 0.2f) * tanHalf);
        float py = dot(toPrev, uniforms.prevCameraUp.xyz) / (pz * tanHalf);
        float2 prevUV = float2(px * 0.5f + 0.5f, 0.5f - py * 0.5f);
        float2 currUV = (float2(gid) + 0.5f) / float2(dims);
        motion = (prevUV - currUV) * float2(dims);
    }
    motionTex.write(float4(motion, 0.0f, 1.0f), gid);

    float3 srgb = linearToSRGB(acesFilmicToneMap(exposed));
    displayTex.write(float4(srgb, 1.0f), gid);
}
#endif
