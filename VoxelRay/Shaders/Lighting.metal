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

/// Returns balanced biome direct sunlight calibrated for ACES highlight preservation.
inline float3 evaluateBiomeSunColor(float3 sunDir, uint biomeId) {
    float elevationT = smoothstep(0.08f, 0.58f, clamp(sunDir.y, 0.0f, 1.0f));
    if (biomeId == 1u) {
        return mix(float3(0.32f, 0.46f, 0.85f), float3(0.45f, 0.68f, 1.15f), elevationT);
    }
    if (biomeId == 2u) {
        float3 goldenHour = float3(2.25f, 1.32f, 0.72f);
        float3 highNoon = float3(1.98f, 1.78f, 1.48f);
        return mix(goldenHour, highNoon, elevationT);
    }
    float3 twilight = float3(0.65f, 0.62f, 0.95f);
    float3 sunset = float3(2.15f, 1.28f, 0.68f);
    float3 noon = float3(1.88f, 1.72f, 1.46f);
    return mix(mix(twilight, sunset, smoothstep(0.06f, 0.25f, sunDir.y)), noon, elevationT);
}

/// Multi-bounce Monte Carlo path tracer using Amanatides-Woo 3D DDA (Simulator & compute fallback path).
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
    float timeSec = uniforms.resolutionAndTime.w;

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
        float2 aoBevel = evaluateVoxelAOAndBevel(hitPos, hit.normal, hit.voxelCoord, voxels);
        float ao = aoBevel.x;
        float bevelGlint = aoBevel.y;

        radiance += throughput * mat.emissive;
        radiance += throughput * mat.albedo * evaluateBlastDynamicLight(hitPos, hit.normal, uniforms);

        float3 n = hit.normal;
        float nDotL = dot(n, sunDir);
        float3 sunColor = evaluateBiomeSunColor(sunDir, biomeId);

        if (hit.materialId == MAT_WATER) {
            float3 wn = evaluateWaterRippleNormal(hitPos, timeSec, n);
            float cosV = clamp(dot(-curDir, wn), 0.0f, 1.0f);
            float reflProb = clamp(0.28f + 0.68f * pow(1.0f - cosV, 4.0f), 0.28f, 0.96f);

            VoxelHit waterShadow = traceVoxelDDA(hitPos + n * 0.02f, sunDir, 150.0f, voxels);
            float litFactor = waterShadow.hit ? 0.22f : 1.0f;
            if (!waterShadow.hit) {
                float3 halfVec = normalize(sunDir - curDir);
                float spec = pow(max(dot(wn, halfVec), 0.0f), 110.0f);
                radiance += throughput * sunColor * spec * 2.4f;
            }

            float caustic = 0.62f + 0.38f * sin(hitPos.x * 2.1f + timeSec * 1.8f) * cos(hitPos.z * 2.1f - timeSec * 1.5f);
            float3 basinBase = (biomeId == 1u) ? float3(0.05f, 0.26f, 0.36f) : float3(0.10f, 0.60f, 0.72f);
            float3 skyAmb = evaluateNishitaSky(float3(0.0f, 1.0f, 0.0f), sunDir, biomeId);
            radiance += throughput * (1.0f - reflProb) * basinBase * (0.45f + 0.55f * caustic)
                      * (0.42f * skyAmb + 0.58f * litFactor * sunColor * 0.35f) * ao;

            float3 rDir = reflect(curDir, wn);
            if (rDir.y < 0.02f) rDir.y = 0.02f;
            curDir = normalize(rDir);
            curOrigin = hitPos + n * 0.02f;
            throughput *= reflProb * float3(0.86f, 0.95f, 1.0f);
            continue;
        }

        if (nDotL > 0.0f && mat.transmission < 0.5f) {
            VoxelHit shadow = traceVoxelDDA(hitPos + n * 0.015f, sunDir, 150.0f, voxels);
            if (!shadow.hit) {
                radiance += throughput * mat.albedo * sunColor * nDotL * (1.0f - mat.metallic * 0.40f) * (1.0f + bevelGlint);
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

            // Crisp dielectric sun specular glint
            float3 halfVec = normalize(sunDir - curDir);
            float spec = pow(max(dot(orientN, halfVec), 0.0f), 96.0f);
            radiance += throughput * sunColor * spec * 1.4f;

            float3 refracted = refract(curDir, orientN, eta);
            if (length(refracted) < 1e-4f || randFloatLight(rng) < (fresnel * 0.85f + 0.08f)) {
                curDir = reflect(curDir, orientN);
                curOrigin = hitPos + orientN * 0.02f;
                throughput *= mix(float3(0.85f, 0.94f, 1.0f), mat.albedo, 0.35f);
            } else {
                float3 bentDir = normalize(mix(curDir, normalize(refracted), 0.28f));
                float3 bMin = float3(hit.voxelCoord);
                float3 bMax = bMin + 1.0f;
                float3 invR = float3(
                    fabs(bentDir.x) > 1e-5f ? (1.0f / bentDir.x) : 1e6f,
                    fabs(bentDir.y) > 1e-5f ? (1.0f / bentDir.y) : 1e6f,
                    fabs(bentDir.z) > 1e-5f ? (1.0f / bentDir.z) : 1e6f
                );
                float3 tExit3 = max((bMin - hitPos) * invR, (bMax - hitPos) * invR);
                float tx = (fabs(bentDir.x) > 1e-5f && tExit3.x > 1e-4f) ? tExit3.x : 1e6f;
                float ty = (fabs(bentDir.y) > 1e-5f && tExit3.y > 1e-4f) ? tExit3.y : 1e6f;
                float tz = (fabs(bentDir.z) > 1e-5f && tExit3.z > 1e-4f) ? tExit3.z : 1e6f;
                float exitStep = clamp(min(tx, min(ty, tz)), 0.02f, 1.74f);
                curDir = bentDir;
                curOrigin = hitPos + bentDir * (exitStep + 0.02f);
                throughput *= mix(float3(0.88f, 0.95f, 1.0f), mat.albedo, 0.55f) * exp(-mat.absorption * 0.55f);
            }
            if (bounce == maxBounces - 1u) {
                radiance += throughput * evaluateNishitaSky(curDir, sunDir, biomeId);
            }
        } else if (mat.metallic > 0.5f) {
            float3 refl = reflect(curDir, n);
            float3 diff = cosineSampleHemisphereLight(n, rng);
            curDir = normalize(mix(refl, diff, mat.roughness * mat.roughness));
            curOrigin = hitPos + n * 0.015f;
            throughput *= mat.albedo * (0.75f + 0.25f * ao);
        } else {
            // Subtle crevice AO on diffuse indirect path + soft sky fill on final bounce
            float3 sampleDir = cosineSampleHemisphereLight(n, rng);
            if (bounce == maxBounces - 1u) {
                radiance += throughput * mat.albedo * evaluateNishitaSky(n, sunDir, biomeId) * 0.28f * ao;
                break;
            }
            curDir = sampleDir;
            curOrigin = hitPos + n * 0.015f;
            throughput *= mat.albedo * (0.55f + 0.45f * ao);
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

kernel void bloomTonemapPresentKernel(
    constant FrameUniforms& uniforms [[buffer(0)]],
    texture2d<float, access::sample> hdrTex [[texture(0)]],
    texture2d<float, access::write> displayTex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint2 dims = uint2(displayTex.get_width(), displayTex.get_height());
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    constexpr sampler linSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(dims);
    float2 texel = 1.0f / float2(max(hdrTex.get_width(), 1u), max(hdrTex.get_height(), 1u));

    float3 hdr = hdrTex.sample(linSampler, uv).rgb;

    // 13-tap dual-ring optical bloom for neon emitters, sun glints, and crystal flares
    const float2 offsets[12] = {
        float2( 1.5f,  1.5f), float2(-1.5f,  1.5f), float2( 1.5f, -1.5f), float2(-1.5f, -1.5f),
        float2( 4.0f,  0.0f), float2(-4.0f,  0.0f), float2( 0.0f,  4.0f), float2( 0.0f, -4.0f),
        float2( 6.5f,  6.5f), float2(-6.5f,  6.5f), float2( 6.5f, -6.5f), float2(-6.5f, -6.5f)
    };
    const float weights[12] = {
        0.12f, 0.12f, 0.12f, 0.12f,
        0.08f, 0.08f, 0.08f, 0.08f,
        0.05f, 0.05f, 0.05f, 0.05f
    };

    float3 bloom = max(hdr - 1.05f, 0.0f) * 0.25f;
    for (int i = 0; i < 12; ++i) {
        float3 s = hdrTex.sample(linSampler, uv + offsets[i] * texel).rgb;
        bloom += max(s - 1.02f, 0.0f) * weights[i];
    }

    float bloomStrength = uniforms.extra2.x > 0.0f ? uniforms.extra2.x : 0.38f;
    float3 combined = hdr + bloom * bloomStrength;

    // Subtle filmic saturation boost before ACES
    float lum = dot(combined, float3(0.2126f, 0.7152f, 0.0722f));
    combined = mix(float3(lum), combined, 1.07f);
    combined = max(combined, 0.0f);

    float3 mapped = acesFilmicToneMap(combined);

    // Subtle edge vignette for depth & framing
    float2 vigUV = uv - 0.5f;
    float vigStrength = uniforms.extra2.y > 0.0f ? uniforms.extra2.y : 0.16f;
    float vignette = 1.0f - dot(vigUV, vigUV) * vigStrength;
    mapped *= clamp(vignette, 0.72f, 1.0f);

    displayTex.write(float4(linearToSRGB(mapped), 1.0f), gid);
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
