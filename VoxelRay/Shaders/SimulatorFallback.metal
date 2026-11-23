#include <metal_stdlib>
#include "VoxelCommon.h"

using namespace metal;

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
