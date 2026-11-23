#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

#ifdef __METAL_VERSION__
#define VR_CONSTANT constant
#else
#include <stddef.h>
#endif

typedef struct {
    simd_float4 cameraPos;          // xyz: world pos, w: fovY (radians)
    simd_float4 cameraForward;      // xyz: forward, w: aspect
    simd_float4 cameraRight;        // xyz: right, w: jitterX
    simd_float4 cameraUp;           // xyz: up, w: jitterY
    simd_float4 prevCameraPos;      // xyz: prev pos, w: unused
    simd_float4 prevCameraForward;  // xyz: prev forward, w: unused
    simd_float4 prevCameraRight;    // xyz: prev right, w: unused
    simd_float4 prevCameraUp;       // xyz: prev up, w: unused
    simd_float4 sunDirAndElevation; // xyz: sun direction, w: elevation (radians)
    simd_uint4  gridSizeAndBiome;   // x: 64, y: 32, z: 64, w: biomeId
    simd_uint4  renderParams;       // x: frameIndex, y: maxBounces, z: renderMode, w: flags
    simd_float4 resolutionAndTime;  // x: internalW, y: internalH, z: outputW, w: timeSec
    simd_float4 outputAndExposure;  // x: outputH, y: exposure, z: waterLevel, w: fireflyClamp
    simd_float4 extra0;             // reserved / brush highlight xyz, radius w
    simd_float4 extra1;             // reserved
    simd_float4 extra2;             // reserved
} FrameUniforms;

#ifndef __METAL_VERSION__
_Static_assert(sizeof(FrameUniforms) == 256, "FrameUniforms must be 256 bytes");
#endif

#endif /* ShaderTypes_h */
