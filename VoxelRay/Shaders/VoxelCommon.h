#ifndef VoxelCommon_h
#define VoxelCommon_h

#include <metal_stdlib>
#include "../Engine/ShaderTypes.h"

using namespace metal;

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

#endif /* VoxelCommon_h */
