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
    texture2d<float, access::write> hdrOutTex [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 dims = uint2(hdrOutTex.get_width(), hdrOutTex.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    uint frameIndex = uniforms.renderParams.x;
    uint rng = wangHashSim(gid.x * 1973u ^ gid.y * 9277u ^ (frameIndex + 1u) * 26699u);
    float2 jitter = (frameIndex > 0u)
        ? float2(randFloatSim(rng) - 0.5f, randFloatSim(rng) - 0.5f) * 0.75f
        : float2(0.0f);

    float3 rayOrigin = uniforms.cameraPos.xyz;
    float3 rayDir = computePrimaryRayDir(gid, dims, jitter, uniforms);

    float3 radiance = traceMonteCarloDDA(rayOrigin, rayDir, gid, uniforms, voxels);

    float4 prev = (frameIndex == 0u) ? float4(0.0f) : accumReadTex.read(gid);
    float weight = 1.0f / float(frameIndex + 1u);
    float3 accumulated = mix(prev.rgb, radiance, weight);
    accumWriteTex.write(float4(accumulated, 1.0f), gid);

    float3 exposed = accumulated * uniforms.outputAndExposure.y;
    hdrOutTex.write(float4(exposed, 1.0f), gid);
}
