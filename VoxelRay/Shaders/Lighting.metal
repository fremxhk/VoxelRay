#include <metal_stdlib>
#include "VoxelCommon.h"

using namespace metal;

inline uint wangHashLight(uint s) {
    s = (s ^ 61u) ^ (s >> 16u);
    s *= 9u;
    s = s ^ (s >> 4u);
    s *= 0x27d4eb2du;
    s = s ^ (s >> 15u);
    return s;
}

inline float randFloatLight(thread uint& state) {
    state = wangHashLight(state);
    return float(state & 0x00FFFFFFu) / float(0x01000000u);
}

inline float3 cosineSampleHemisphereLight(float3 n, thread uint& rng) {
    float u1 = randFloatLight(rng);
    float u2 = randFloatLight(rng);
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

/// Analytical Nishita-inspired atmospheric sky dome with Rayleigh & Mie scattering.
float3 evaluateNishitaSky(float3 dir, float3 sunDir, uint biomeId) {
    float mu = clamp(dir.y, -0.15f, 1.0f);
    float sunHeight = clamp(sunDir.y, 0.02f, 1.0f);
    float sunDot = max(dot(dir, sunDir), 0.0f);

    if (biomeId == 1u) {
        // Neon Cavern: deep obsidian twilight sky with cyan/violet aurora horizon
        float3 zenith = float3(0.015f, 0.025f, 0.075f);
        float3 horizon = mix(float3(0.08f, 0.025f, 0.14f), float3(0.03f, 0.16f, 0.24f), sunHeight);
        float3 sky = mix(horizon, zenith, pow(clamp(mu, 0.0f, 1.0f), 0.6f));
        sky += float3(0.08f, 0.28f, 0.48f) * pow(sunDot, 20.0f);
        return sky;
    }

    if (biomeId == 2u) {
        // Glass Cathedral: warm sunset-gold horizon fading into deep sapphire zenith
        float3 zenith = float3(0.11f, 0.29f, 0.72f);
        float3 horizon = mix(float3(0.95f, 0.58f, 0.34f), float3(0.86f, 0.80f, 0.70f), sunHeight);
        float3 sky = mix(horizon, zenith, pow(clamp(mu, 0.0f, 1.0f), 0.52f));
        float mie = pow(sunDot, 48.0f) * 3.5f + pow(sunDot, 8.0f) * 0.45f;
        sky += float3(1.0f, 0.84f, 0.56f) * mie;
        return sky;
    }

    // Sunlit Courtyard: Nishita Rayleigh blue + warm golden Mie scattering
    float3 rayleighZenith = mix(float3(0.08f, 0.18f, 0.45f), float3(0.14f, 0.41f, 0.88f), sunHeight);
    float3 rayleighHorizon = mix(float3(0.96f, 0.62f, 0.38f), float3(0.72f, 0.85f, 0.98f), smoothstep(0.05f, 0.45f, sunHeight));
    float t = pow(clamp(mu, 0.0f, 1.0f), 0.55f);
    float3 sky = mix(rayleighHorizon, rayleighZenith, t);
    float mieDisk = smoothstep(0.9985f, 0.9998f, sunDot) * 8.0f;
    float mieHalo = pow(sunDot, 28.0f) * 1.4f + pow(sunDot, 6.0f) * 0.22f;
    float3 sunTint = mix(float3(1.0f, 0.58f, 0.28f), float3(1.0f, 0.92f, 0.78f), sunHeight);
    sky += sunTint * (mieDisk + mieHalo);
    return sky;
}

/// Multi-bounce Monte Carlo path tracer using Amanatides-Woo 3D DDA (Simulator & fallback path).
float3 traceMonteCarloDDA(
    float3 rayOrigin,
    float3 rayDir,
    uint2 gid,
    constant FrameUniforms& uniforms,
    const device uint8_t* voxels
) {
    uint frameIndex = uniforms.renderParams.x;
    uint maxBounces = max(1u, min(uniforms.renderParams.y, 4u));
    uint biomeId = uniforms.gridSizeAndBiome.w;
    float3 sunDir = normalize(uniforms.sunDirAndElevation.xyz);

    uint rng = wangHashLight(gid.x * 1973u ^ gid.y * 9277u ^ (frameIndex + 1u) * 26699u);

    float3 radiance = float3(0.0f);
    float3 throughput = float3(1.0f);
    float3 curOrigin = rayOrigin;
    float3 curDir = rayDir;

    for (uint bounce = 0u; bounce < maxBounces; ++bounce) {
        VoxelHit hit = traceVoxelDDA(curOrigin, curDir, 200.0f, voxels);
        if (!hit.hit) {
            radiance += throughput * evaluateNishitaSky(curDir, sunDir, biomeId);
            break;
        }

        float3 hitPos = curOrigin + curDir * hit.distance;
        MaterialProps mat = getMaterialProps(hit.materialId, float3(hit.voxelCoord) + 0.5f);
        radiance += throughput * mat.emissive;

        float3 n = hit.normal;
        float nDotL = dot(n, sunDir);
        if (nDotL > 0.0f && mat.transmission < 0.5f) {
            VoxelHit shadow = traceVoxelDDA(hitPos + n * 0.015f, sunDir, 150.0f, voxels);
            if (!shadow.hit) {
                float3 sunColor = (biomeId == 1u)
                    ? float3(0.55f, 0.78f, 1.25f)
                    : (biomeId == 2u ? float3(2.6f, 2.35f, 2.0f) : float3(2.9f, 2.6f, 2.2f));
                radiance += throughput * mat.albedo * sunColor * nDotL * (1.0f - mat.metallic * 0.45f);
            }
        }

        if (mat.transmission > 0.5f) {
            bool entering = dot(curDir, n) < 0.0f;
            float3 orientN = entering ? n : -n;
            float eta = entering ? (1.0f / mat.ior) : mat.ior;
            float cosTheta = min(dot(-curDir, orientN), 1.0f);
            float r0 = (1.0f - eta) / (1.0f + eta);
            r0 = r0 * r0;
            float fresnel = r0 + (1.0f - r0) * pow(1.0f - cosTheta, 5.0f);
            float3 refracted = refract(curDir, orientN, eta);

            if (length(refracted) < 1e-4f || randFloatLight(rng) < fresnel) {
                curDir = reflect(curDir, orientN);
                curOrigin = hitPos + orientN * 0.015f;
            } else {
                curDir = normalize(refracted);
                curOrigin = hitPos - orientN * 0.015f;
                throughput *= exp(-mat.absorption * 0.75f);
            }
            throughput *= mat.albedo;
        } else if (mat.metallic > 0.5f) {
            float3 refl = reflect(curDir, n);
            float3 diff = cosineSampleHemisphereLight(n, rng);
            curDir = normalize(mix(refl, diff, mat.roughness * mat.roughness));
            curOrigin = hitPos + n * 0.015f;
            throughput *= mat.albedo;
        } else {
            curDir = cosineSampleHemisphereLight(n, rng);
            curOrigin = hitPos + n * 0.015f;
            throughput *= mat.albedo;
        }

        // Russian roulette / firefly clamp
        float maxC = max(radiance.r, max(radiance.g, radiance.b));
        if (maxC > uniforms.outputAndExposure.w) {
            radiance *= (uniforms.outputAndExposure.w / maxC);
            break;
        }
    }

    float clampLimit = max(uniforms.outputAndExposure.w, 1.0f);
    float maxLum = max(radiance.r, max(radiance.g, radiance.b));
    if (maxLum > clampLimit) {
        radiance *= (clampLimit / maxLum);
    }
    return radiance;
}

kernel void tonemapPresentKernel(
    constant FrameUniforms& uniforms [[buffer(0)]],
    texture2d<float, access::read> hdrTex [[texture(0)]],
    texture2d<float, access::write> displayTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 dims = uint2(displayTex.get_width(), displayTex.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    float3 hdr = hdrTex.read(gid).rgb;
    float3 srgb = linearToSRGB(acesFilmicToneMap(hdr));
    displayTex.write(float4(srgb, 1.0f), gid);
}
