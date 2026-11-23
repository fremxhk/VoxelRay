#include <metal_stdlib>
#include "VoxelCommon.h"

using namespace metal;

inline uint wangHashSim(uint s) {
    s = (s ^ 61u) ^ (s >> 16u);
    s *= 9u;
    s = s ^ (s >> 4u);
    s *= 0x27d4eb2du;
    s = s ^ (s >> 15u);
    return s;
}

inline float randFloatSim(thread uint& state) {
    state = wangHashSim(state);
    return float(state & 0x00FFFFFFu) / float(0x01000000u);
}

kernel void rayDirSmokeKernel(
    texture2d<float, access::write> outTex [[texture(0)]],
    constant FrameUniforms& uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 dims = uint2(outTex.get_width(), outTex.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    float3 dir = computePrimaryRayDir(gid, dims, float2(0.0f), uniforms);
    float3 rgb = clamp(dir * 0.5f + 0.5f, 0.0f, 1.0f);
    outTex.write(float4(rgb, 1.0f), gid);
}

kernel void raycastParityKernel(
    const device uint8_t* voxels [[buffer(0)]],
    const device RayParityQuery* queries [[buffer(1)]],
    device RayParityResult* results [[buffer(2)]],
    constant uint& queryCount [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= queryCount) {
        return;
    }

    RayParityQuery q = queries[gid];
    VoxelHit hit = traceVoxelDDA(q.origin.xyz, q.direction.xyz, 200.0f, voxels);

    RayParityResult out;
    out.voxelAndHit = int4(hit.voxelCoord, hit.hit ? 1 : 0);
    out.normalAndDist = float4(hit.normal, hit.distance);
    out.materialAndPad = uint4(hit.materialId, 0u, 0u, 0u);
    results[gid] = out;
}

kernel void simulatorPathTraceKernel(
    constant FrameUniforms& uniforms [[buffer(0)]],
    const device uint8_t* voxels [[buffer(1)]],
    texture2d<float, access::read> accumReadTex [[texture(0)]],
    texture2d<float, access::write> accumWriteTex [[texture(1)]],
    texture2d<float, access::write> displayTex [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 dims = uint2(displayTex.get_width(), displayTex.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    uint frameIndex = uniforms.renderParams.x;
    uint biomeId = uniforms.gridSizeAndBiome.w;
    float3 sunDir = normalize(uniforms.sunDirAndElevation.xyz);

    uint rng = wangHashSim(gid.x * 1973u ^ gid.y * 9277u ^ (frameIndex + 1u) * 26699u);
    float2 jitter = (frameIndex > 0u)
        ? float2(randFloatSim(rng) - 0.5f, randFloatSim(rng) - 0.5f) * 0.75f
        : float2(0.0f);

    float3 rayOrigin = uniforms.cameraPos.xyz;
    float3 rayDir = computePrimaryRayDir(gid, dims, jitter, uniforms);

    VoxelHit hit = traceVoxelDDA(rayOrigin, rayDir, 200.0f, voxels);
    float3 radiance = float3(0.0f);

    if (!hit.hit) {
        radiance = evaluateSkyColor(rayDir, sunDir, biomeId);
    } else {
        float3 hitPos = rayOrigin + rayDir * hit.distance;
        MaterialProps mat = getMaterialProps(hit.materialId, float3(hit.voxelCoord) + 0.5f);
        float3 n = hit.normal;

        float3 skyAmbient = evaluateSkyColor(normalize(n + float3(0.0f, 0.35f, 0.0f)), sunDir, biomeId);
        radiance += mat.emissive + mat.albedo * skyAmbient * (biomeId == 1u ? 0.35f : 0.42f);

        float nDotL = dot(n, sunDir);
        if (nDotL > 0.0f) {
            VoxelHit shadow = traceVoxelDDA(hitPos + n * 0.015f, sunDir, 150.0f, voxels);
            if (!shadow.hit) {
                float3 sunCol = (biomeId == 1u)
                    ? float3(0.45f, 0.65f, 1.15f)
                    : (biomeId == 2u ? float3(2.4f, 2.2f, 2.0f) : float3(2.8f, 2.5f, 2.15f));
                radiance += mat.albedo * sunCol * nDotL;
            }
        }

        if (mat.metallic > 0.5f || mat.transmission > 0.5f) {
            float3 reflDir = reflect(rayDir, n);
            VoxelHit reflHit = traceVoxelDDA(hitPos + n * 0.015f, reflDir, 140.0f, voxels);
            float3 reflCol = reflHit.hit
                ? (getMaterialProps(reflHit.materialId, float3(reflHit.voxelCoord) + 0.5f).emissive
                   + getMaterialProps(reflHit.materialId, float3(reflHit.voxelCoord) + 0.5f).albedo * 0.85f)
                : evaluateSkyColor(reflDir, sunDir, biomeId);
            float fresnel = mat.metallic > 0.5f ? 0.85f : (0.08f + 0.92f * pow(1.0f - max(dot(-rayDir, n), 0.0f), 4.0f));
            radiance = mix(radiance, reflCol * mat.albedo, fresnel);
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

    float3 srgb = linearToSRGB(acesFilmicToneMap(accumulated * uniforms.outputAndExposure.y));
    displayTex.write(float4(srgb, 1.0f), gid);
}
