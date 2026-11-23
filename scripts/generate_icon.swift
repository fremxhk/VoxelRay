#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// Procedural 1024x1024 ray-traced isometric voxel cube App Icon generator (24-bit RGB, NO alpha channel).
let size = 1024
let outPath = "VoxelRay/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

// Voxel block inside a 5x5x5 sculptural prism cube
enum BlockMat {
    case empty, travertine, gold, cyanCore, magentaCore, glass, prism
}

func materialAt(_ x: Int, _ y: Int, _ z: Int) -> BlockMat {
    // Carve dramatic cutaway notch in top-front-right corner to expose glowing core
    if x >= 3 && y >= 3 && z >= 3 {
        if x == 3 && y == 3 && z == 3 { return .prism }
        return .empty
    }
    if x == 2 && y == 2 && z == 2 { return .cyanCore }
    if (x == 3 && y == 2 && z == 2) || (x == 2 && y == 3 && z == 2) { return .magentaCore }
    if x == 2 && y == 2 && z == 3 { return .cyanCore }

    let isCornerFrame = (x == 0 || x == 4) && (y == 0 || y == 4) || (y == 0 || y == 4) && (z == 0 || z == 4) || (x == 0 || x == 4) && (z == 0 || z == 4)
    if isCornerFrame { return .gold }

    if (x == 4 && y == 2) || (z == 4 && y == 2) || (y == 4 && x == 2) {
        return .glass
    }
    return .travertine
}

func boxIntersect(ro: SIMD3<Float>, invDir: SIMD3<Float>, bmin: SIMD3<Float>, bmax: SIMD3<Float>) -> (tMin: Float, tMax: Float, normal: SIMD3<Float>)? {
    let t0 = (bmin - ro) * invDir
    let t1 = (bmax - ro) * invDir
    let tSmaller = simd_min(t0, t1)
    let tLarger = simd_max(t0, t1)
    let tEnter = max(max(tSmaller.x, tSmaller.y), tSmaller.z)
    let tExit = min(min(tLarger.x, tLarger.y), tLarger.z)
    guard tEnter < tExit && tExit > 0 else { return nil }
    var n = SIMD3<Float>(0, 0, 0)
    if tSmaller.x >= tSmaller.y && tSmaller.x >= tSmaller.z {
        n = SIMD3<Float>(invDir.x > 0 ? -1 : 1, 0, 0)
    } else if tSmaller.y >= tSmaller.z {
        n = SIMD3<Float>(0, invDir.y > 0 ? -1 : 1, 0)
    } else {
        n = SIMD3<Float>(0, 0, invDir.z > 0 ? -1 : 1)
    }
    return (tEnter, tExit, n)
}

func traceScene(ro: SIMD3<Float>, rd: SIMD3<Float>) -> SIMD3<Float> {
    let invDir = SIMD3<Float>(
        abs(rd.x) > 1e-6 ? 1 / rd.x : (rd.x >= 0 ? 1e30 : -1e30),
        abs(rd.y) > 1e-6 ? 1 / rd.y : (rd.y >= 0 ? 1e30 : -1e30),
        abs(rd.z) > 1e-6 ? 1 / rd.z : (rd.z >= 0 ? 1e30 : -1e30)
    )

    var bestT: Float = 1e30
    var bestN = SIMD3<Float>(0, 1, 0)
    var bestMat = BlockMat.empty
    var bestPos = SIMD3<Float>(0, 0, 0)

    let offset = SIMD3<Float>(-2.5, -2.5, -2.5)
    for z in 0..<5 {
        for y in 0..<5 {
            for x in 0..<5 {
                let mat = materialAt(x, y, z)
                if mat == .empty { continue }
                let bmin = offset + SIMD3<Float>(Float(x) + 0.04, Float(y) + 0.04, Float(z) + 0.04)
                let bmax = offset + SIMD3<Float>(Float(x) + 0.96, Float(y) + 0.96, Float(z) + 0.96)
                if let hit = boxIntersect(ro: ro, invDir: invDir, bmin: bmin, bmax: bmax),
                   hit.tMin > 0.001, hit.tMin < bestT {
                    bestT = hit.tMin
                    bestN = hit.normal
                    bestMat = mat
                    bestPos = ro + rd * hit.tMin
                }
            }
        }
    }

    if bestMat == .empty {
        return SIMD3<Float>(-1, -1, -1) // miss sentinel
    }

    let sunDir = simd_normalize(SIMD3<Float>(0.55, 0.85, 0.45))
    let viewDir = -rd
    let halfVec = simd_normalize(sunDir + viewDir)
    let ndotl = max(simd_dot(bestN, sunDir), 0)
    let ndoth = max(simd_dot(bestN, halfVec), 0)
    let fresnel = pow(1.0 - max(simd_dot(bestN, viewDir), 0), 4.0)

    // Core glow distance illumination
    let corePos = SIMD3<Float>(0.2, 0.2, 0.2)
    let toCore = corePos - bestPos
    let coreDist = max(simd_length(toCore), 0.35)
    let coreAtten = 1.0 / (0.4 + coreDist * coreDist * 0.55)
    let coreLight = (SIMD3<Float>(0.18, 0.95, 1.0) * 1.4 + SIMD3<Float>(1.0, 0.2, 0.78) * 0.8) * coreAtten

    var baseColor = SIMD3<Float>(0.88, 0.82, 0.72)
    var spec: Float = 0.2
    var emit = SIMD3<Float>(0, 0, 0)

    switch bestMat {
    case .travertine:
        baseColor = SIMD3<Float>(0.86, 0.82, 0.74)
        spec = pow(ndoth, 24) * 0.2
    case .gold:
        baseColor = SIMD3<Float>(0.98, 0.78, 0.30)
        spec = pow(ndoth, 48) * 1.15
    case .cyanCore:
        baseColor = SIMD3<Float>(0.2, 0.95, 1.0)
        emit = SIMD3<Float>(0.35, 1.45, 1.65)
    case .magentaCore:
        baseColor = SIMD3<Float>(1.0, 0.25, 0.75)
        emit = SIMD3<Float>(1.55, 0.32, 1.05)
    case .glass:
        baseColor = SIMD3<Float>(0.72, 0.90, 1.0)
        spec = pow(ndoth, 80) * 1.6
        emit = SIMD3<Float>(0.18, 0.45, 0.65) * (0.35 + fresnel * 1.2)
    case .prism:
        baseColor = SIMD3<Float>(0.85, 0.94, 1.0)
        spec = pow(ndoth, 90) * 2.0
        emit = SIMD3<Float>(0.45, 1.1, 1.4) * (0.6 + fresnel)
    case .empty:
        break
    }

    let ambient = SIMD3<Float>(0.14, 0.19, 0.30)
    var color = baseColor * (ambient + SIMD3<Float>(1.15, 1.05, 0.95) * ndotl + coreLight * 0.55)
    color += SIMD3<Float>(1.0, 0.95, 0.88) * spec + emit
    color += SIMD3<Float>(0.35, 0.82, 1.0) * fresnel * 0.45
    return color
}

let eye = SIMD3<Float>(7.2, 6.2, 7.6)
let target = SIMD3<Float>(0.15, -0.1, 0.15)
let fwd = simd_normalize(target - eye)
let right = simd_normalize(simd_cross(fwd, SIMD3<Float>(0, 1, 0)))
let up = simd_normalize(simd_cross(right, fwd))
let tanHalfFov = tan(Float.pi * 0.16)

var rgb = [UInt8](repeating: 0, count: size * size * 3)

for y in 0..<size {
    for x in 0..<size {
        let u = (Float(x) + 0.5) / Float(size)
        let v = (Float(y) + 0.5) / Float(size)
        let ndcX = u * 2.0 - 1.0
        let ndcY = 1.0 - v * 2.0

        // Backdrop radial gradient + subtle cyan/magenta volumetric glow
        let rDist: Float = hypot(ndcX, ndcY)
        let bgT: Float = min(max(rDist * 0.82, 0.0), 1.0)
        var bg = simd_mix(
            SIMD3<Float>(0.08, 0.14, 0.30),
            SIMD3<Float>(0.02, 0.03, 0.08),
            SIMD3<Float>(repeating: bgT)
        )
        let glow: Float = exp(-rDist * rDist * 3.4)
        bg += SIMD3<Float>(0.05, 0.32, 0.45) * glow

        let dir = simd_normalize(fwd + right * (ndcX * tanHalfFov) + up * (ndcY * tanHalfFov))
        let hitCol = traceScene(ro: eye, rd: dir)
        var col = (hitCol.x >= 0) ? hitCol : bg

        // ACES filmic tone map + sRGB gamma
        let a: Float = 2.51, b: Float = 0.03, c: Float = 2.43, d: Float = 0.59, e: Float = 0.14
        col = (col * (a * col + b)) / (col * (c * col + d) + e)
        col = simd_clamp(col, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        let rSrgb = pow(col.x, 1.0 / 2.2)
        let gSrgb = pow(col.y, 1.0 / 2.2)
        let bSrgb = pow(col.z, 1.0 / 2.2)

        let ri = min(max(Int(rSrgb * 255.0 + 0.5), 0), 255)
        let gi = min(max(Int(gSrgb * 255.0 + 0.5), 0), 255)
        let bi = min(max(Int(bSrgb * 255.0 + 0.5), 0), 255)
        let idx = (y * size + x) * 3
        rgb[idx] = UInt8(ri)
        rgb[idx + 1] = UInt8(gi)
        rgb[idx + 2] = UInt8(bi)
    }
}

let data = Data(rgb)
guard let provider = CGDataProvider(data: data as CFData),
      let cgImage = CGImage(
        width: size,
        height: size,
        bitsPerComponent: 8,
        bitsPerPixel: 24,
        bytesPerRow: size * 3,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      ),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    fputs("Failed to create 24-bit RGB icon\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(dest, cgImage, nil)
if !CGImageDestinationFinalize(dest) {
    fputs("Failed to write PNG\n", stderr)
    exit(1)
}
print("Generated 24-bit RGB AppIcon at \(outPath)")
