import Foundation
import Metal
import QuartzCore
import UIKit
import Combine

/// Active interaction brush in the voxel sandbox.
public enum VoxelBrushMode: String, CaseIterable, Identifiable {
    case carve
    case prismCrystal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .carve: return "Carve"
        case .prismCrystal: return "Prism"
        }
    }
}

/// Core renderer coordinating VoxelWorld state, triple-buffered uniforms, MetalFX thermal scaling,
/// tap-to-destroy interaction, Photo Mode convergence, and dual Device/Simulator ray tracing.
public final class Renderer: ObservableObject {
    public static let maxFramesInFlight = 3
    public static let uniformStride = MemoryLayout<FrameUniforms>.stride

    public let device: MTLDevice
    public let camera: Camera
    public let world: VoxelWorld

    @Published public var fps: Double = 60.0
    @Published public var sampleCount: UInt32 = 0
    @Published public var activeBiome: VoxelBiome = .sunlitCourtyard
    @Published public var brushMode: VoxelBrushMode = .carve
    @Published public var thermalBadgeText: String = "MetalFX (Device Only)"
    @Published public var sunElevation: Float = VoxelBiome.sunlitCourtyard.defaultSunElevation {
        didSet {
            if abs(oldValue - sunElevation) > 1e-4 {
                camera.resetAccumulation()
            }
        }
    }
    @Published public var blastRadius: Float = 3.0
    @Published public var isPhotoModeActive: Bool = false
    @Published public var isCapturingPhoto: Bool = false
    @Published public var capturedPhotoImage: UIImage?
    @Published public var showShareSheet: Bool = false
    @Published public var lastCarvedVoxelCount: Int = 0

    public var moveInput: SIMD2<Float> = .zero

    private let uniformRingBuffer: MTLBuffer
    private let frameSemaphore = DispatchSemaphore(value: Renderer.maxFramesInFlight)
    private var ringIndex: Int = 0
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var smoothedFPS: Double = 60.0
    private var thermalObserver: NSObjectProtocol?
    private var activeScale: Float = 1.0
    private var activeMaxBounces: UInt32 = 3

    private var displayTexture: MTLTexture?
    private var displayTextureSize: (Int, Int) = (0, 0)

    #if targetEnvironment(simulator)
    private let simPipeline: SimulatorComputePipeline
    #else
    private let devicePipeline: Metal4DevicePipeline?
    private let fallbackQueue: MTLCommandQueue
    private let fallbackSmokePipeline: MTLComputePipelineState
    #endif

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let dev = device else {
            NSLog("VoxelRay Renderer init failed: MTLCreateSystemDefaultDevice() returned nil")
            return nil
        }
        guard let library = dev.makeDefaultLibrary() else {
            NSLog("VoxelRay Renderer init failed: makeDefaultLibrary() returned nil")
            return nil
        }
        guard let ring = dev.makeBuffer(
            length: Self.uniformStride * Self.maxFramesInFlight,
            options: .storageModeShared
        ) else {
            NSLog("VoxelRay Renderer init failed: uniform ring allocation failed")
            return nil
        }
        ring.label = "FrameUniformsRing"

        #if targetEnvironment(simulator)
        guard let sim = SimulatorComputePipeline(device: dev, library: library) else {
            return nil
        }
        self.simPipeline = sim
        #else
        guard let q = dev.makeCommandQueue(),
              let smokeFn = library.makeFunction(name: "rayDirSmokeKernel"),
              let smokePSO = try? dev.makeComputePipelineState(function: smokeFn)
        else {
            return nil
        }
        self.fallbackQueue = q
        self.fallbackSmokePipeline = smokePSO
        self.devicePipeline = Metal4DevicePipeline(device: dev, library: library, uniformRingBuffer: ring)
        #endif

        self.device = dev
        self.camera = Camera()
        self.world = VoxelWorld(biome: .sunlitCourtyard)
        self.uniformRingBuffer = ring
        applyDefaultPose(for: .sunlitCourtyard)
        refreshThermalProfile()

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshThermalProfile()
        }
    }

    deinit {
        if let obs = thermalObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public func refreshThermalProfile() {
        #if targetEnvironment(simulator)
        activeScale = 1.0
        activeMaxBounces = 3
        thermalBadgeText = "MetalFX (Device Only)"
        #else
        let cfg = Metal4DevicePipeline.thermalConfig(for: ProcessInfo.processInfo.thermalState)
        if abs(activeScale - cfg.scale) > 1e-3 {
            camera.resetAccumulation()
        }
        activeScale = cfg.scale
        activeMaxBounces = cfg.maxBounces
        thermalBadgeText = cfg.badge
        #endif
    }

    /// Dispatches uniform-sized 2D threadgroups so Simulator and all iOS GPUs execute cleanly under MTL_DEBUG_LAYER=1.
    public static func dispatch2D(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let maxThreads = max(1, pipeline.maxTotalThreadsPerThreadgroup)
        let w = max(1, min(8, pipeline.threadExecutionWidth))
        let h = max(1, min(8, maxThreads / w))
        let tgSize = MTLSize(width: w, height: h, depth: 1)
        let tgCount = MTLSize(
            width: (width + w - 1) / w,
            height: (height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(tgCount, threadsPerThreadgroup: tgSize)
    }

    public func applyDefaultPose(for biome: VoxelBiome) {
        let pose = VoxelWorld.defaultCameraPose(for: biome)
        camera.lookAt(eye: pose.eye, target: pose.target)
        sunElevation = biome.defaultSunElevation
    }

    public func selectBiome(_ biome: VoxelBiome) {
        world.generate(biome: biome)
        activeBiome = biome
        applyDefaultPose(for: biome)
        camera.resetAccumulation()
    }

    public func resetWorld() {
        world.generate(biome: activeBiome)
        camera.resetAccumulation()
    }

    /// Casts a pick ray from normalized screen coordinates and carves or places crystal voxels.
    @discardableResult
    public func handleViewportTap(at normalizedPoint: SIMD2<Float>, isPrismUnlocked: Bool) -> Bool {
        let dir = camera.rayDirection(normalizedScreenPoint: normalizedPoint)
        guard let hit = world.raycast(origin: camera.position, direction: dir) else {
            return false
        }

        let modifiedCount: Int
        if brushMode == .prismCrystal && isPrismUnlocked {
            let placeCenter = hit.hitPoint + hit.normal * 0.75
            modifiedCount = world.placeMaterialSphere(
                center: placeCenter,
                radius: min(blastRadius, 2.5),
                material: .prismCrystal
            )
        } else {
            modifiedCount = world.carveSphere(center: hit.hitPoint, radius: blastRadius)
        }

        guard modifiedCount > 0 else { return false }
        lastCarvedVoxelCount = modifiedCount
        camera.resetAccumulation()

        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        }
        return true
    }

    private static func halton(_ index: UInt32, base: UInt32) -> Float {
        var f: Float = 1.0
        var r: Float = 0.0
        var i = index
        while i > 0 {
            f /= Float(base)
            r += f * Float(i % base)
            i /= base
        }
        return r - 0.5
    }

    private func ensurePrivateTexture(
        current: inout MTLTexture?,
        currentSize: inout (Int, Int),
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        label: String
    ) -> MTLTexture? {
        if let tex = current, currentSize.0 == width, currentSize.1 == height, tex.pixelFormat == pixelFormat {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = usage
        let created = device.makeTexture(descriptor: desc)
        created?.label = label
        current = created
        currentSize = (width, height)
        return created
    }

    private func writeUniforms(
        slot: Int,
        jitter: SIMD2<Float>,
        internalWidth: Int,
        internalHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        maxBounces: UInt32,
        timeSec: Float
    ) -> Int {
        let offset = slot * Self.uniformStride
        let ptr = uniformRingBuffer.contents().advanced(by: offset).assumingMemoryBound(to: FrameUniforms.self)
        var u = FrameUniforms()
        camera.populateUniforms(
            &u,
            jitter: jitter,
            internalWidth: internalWidth,
            internalHeight: internalHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            sunElevation: sunElevation,
            biomeRawValue: world.biome.rawValue,
            maxBounces: maxBounces,
            renderMode: 0,
            flags: 0,
            timeSec: timeSec
        )
        ptr.pointee = u
        return offset
    }

    /// Renders a frame to a Metal layer drawable via a private render target + blit copy.
    public func draw(to layer: CAMetalLayer, drawableSize: CGSize) {
        let outWidth = Int(drawableSize.width)
        let outHeight = Int(drawableSize.height)
        guard outWidth > 0, outHeight > 0 else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 1.0 / 240.0), 0.1))
        lastFrameTime = now

        camera.updateAspect(Float(outWidth) / Float(outHeight))
        camera.applyMoveInput(forward: moveInput.y, strafe: moveInput.x, dt: dt)

        let instFPS = 1.0 / Double(max(dt, 0.001))
        smoothedFPS = smoothedFPS * 0.9 + instFPS * 0.1

        frameSemaphore.wait()
        guard let drawable = layer.nextDrawable(),
              let targetTex = ensurePrivateTexture(
                current: &displayTexture,
                currentSize: &displayTextureSize,
                width: outWidth,
                height: outHeight,
                pixelFormat: layer.pixelFormat,
                usage: [.shaderWrite, .shaderRead],
                label: "PrivateDisplayTarget"
              )
        else {
            frameSemaphore.signal()
            return
        }

        let inWidth: Int
        let inHeight: Int
        let jitter: SIMD2<Float>
        #if targetEnvironment(simulator)
        inWidth = outWidth
        inHeight = outHeight
        jitter = .zero
        #else
        inWidth = max(64, Int(round(Float(outWidth) * activeScale)))
        inHeight = max(64, Int(round(Float(outHeight) * activeScale)))
        let jIdx = (camera.frameIndex % 16) + 1
        jitter = SIMD2<Float>(Self.halton(jIdx, base: 2), Self.halton(jIdx, base: 3))
        #endif

        let slot = ringIndex
        ringIndex = (ringIndex + 1) % Self.maxFramesInFlight
        let uniformOffset = writeUniforms(
            slot: slot,
            jitter: jitter,
            internalWidth: inWidth,
            internalHeight: inHeight,
            outputWidth: outWidth,
            outputHeight: outHeight,
            maxBounces: activeMaxBounces,
            timeSec: Float(now - startTime)
        )

        let resetHistory = (camera.frameIndex == 0)

        #if targetEnvironment(simulator)
        simPipeline.encodeDisplayFrame(
            world: world,
            uniformRingBuffer: uniformRingBuffer,
            uniformOffset: uniformOffset,
            drawable: drawable,
            displayTarget: targetTex,
            width: outWidth,
            height: outHeight,
            frameSemaphore: frameSemaphore
        )
        #else
        if let devicePipeline = devicePipeline {
            devicePipeline.encodeDisplayFrame(
                world: world,
                uniformRingBuffer: uniformRingBuffer,
                uniformOffset: uniformOffset,
                slot: slot,
                drawable: drawable,
                displayTarget: targetTex,
                internalWidth: inWidth,
                internalHeight: inHeight,
                outputWidth: outWidth,
                outputHeight: outHeight,
                jitter: jitter,
                resetHistory: resetHistory,
                frameSemaphore: frameSemaphore
            )
        } else if let cmdBuf = fallbackQueue.makeCommandBuffer() {
            if let enc = cmdBuf.makeComputeCommandEncoder() {
                enc.setComputePipelineState(fallbackSmokePipeline)
                enc.setTexture(targetTex, index: 0)
                enc.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
                Self.dispatch2D(encoder: enc, pipeline: fallbackSmokePipeline, width: outWidth, height: outHeight)
                enc.endEncoding()
            }
            if let blit = cmdBuf.makeBlitCommandEncoder() {
                blit.copy(from: targetTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: outWidth, height: outHeight, depth: 1), to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
            }
            let sem = frameSemaphore
            cmdBuf.addCompletedHandler { _ in sem.signal() }
            cmdBuf.present(drawable)
            cmdBuf.commit()
        } else {
            frameSemaphore.signal()
        }
        #endif

        camera.advanceFrame()
        let currentSample = camera.frameIndex
        let currentFPS = smoothedFPS
        DispatchQueue.main.async { [weak self] in
            self?.sampleCount = currentSample
            self?.fps = currentFPS
        }
    }

    /// Renders an offscreen RGBA8 image using a .private texture and explicit staging readback.
    public func renderOffscreen(
        width: Int,
        height: Int,
        samples: Int = 1,
        biome: VoxelBiome? = nil,
        smokeOnly: Bool = false
    ) -> [UInt8] {
        precondition(width > 0 && height > 0)
        if let biome = biome {
            selectBiome(biome)
        }
        camera.updateAspect(Float(width) / Float(height))
        camera.resetAccumulation()

        let offsetProvider: (Int) -> Int = { [weak self] sampleIdx in
            guard let self = self else { return 0 }
            let slot = self.ringIndex
            self.ringIndex = (self.ringIndex + 1) % Self.maxFramesInFlight
            let off = self.writeUniforms(
                slot: slot,
                jitter: .zero,
                internalWidth: width,
                internalHeight: height,
                outputWidth: width,
                outputHeight: height,
                maxBounces: 3,
                timeSec: Float(sampleIdx) * (1.0 / 60.0)
            )
            self.camera.advanceFrame()
            return off
        }

        #if targetEnvironment(simulator)
        return simPipeline.renderOffscreen(
            world: world,
            uniformRingBuffer: uniformRingBuffer,
            uniformOffsetProvider: offsetProvider,
            width: width,
            height: height,
            samples: samples,
            smokeOnly: smokeOnly,
            frameSemaphore: frameSemaphore
        )
        #else
        if let devicePipeline = devicePipeline, !smokeOnly {
            return devicePipeline.renderOffscreen(
                world: world,
                uniformRingBuffer: uniformRingBuffer,
                uniformOffsetProvider: offsetProvider,
                width: width,
                height: height,
                samples: samples
            )
        }
        return []
        #endif
    }

    /// Triggers Photo Mode convergence (64 samples), optional watermark, and UIActivityViewController presentation.
    public func enterPhotoMode(isProUnlocked: Bool) {
        guard !isCapturingPhoto else { return }
        isPhotoModeActive = true
        isCapturingPhoto = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            #if targetEnvironment(simulator)
            let targetWidth = isProUnlocked ? 1920 : 1280
            let targetHeight = isProUnlocked ? 1080 : 720
            #else
            let targetWidth = isProUnlocked ? 3840 : 1920
            let targetHeight = isProUnlocked ? 2160 : 1080
            #endif

            let pixels = self.renderOffscreen(width: targetWidth, height: targetHeight, samples: 64)
            let image = Self.buildOpaqueImage(
                rgbaBytes: pixels,
                width: targetWidth,
                height: targetHeight,
                addWatermark: !isProUnlocked
            )

            DispatchQueue.main.async {
                self.isCapturingPhoto = false
                if let img = image {
                    self.capturedPhotoImage = img
                    self.showShareSheet = true
                } else {
                    self.isPhotoModeActive = false
                }
            }
        }
    }

    public func exitPhotoMode() {
        showShareSheet = false
        capturedPhotoImage = nil
        isCapturingPhoto = false
        isPhotoModeActive = false
    }

    /// Converts RGBA8 bytes into an opaque 24-bit UIImage, optionally stamping a subtle corner watermark.
    public static func buildOpaqueImage(
        rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        addWatermark: Bool
    ) -> UIImage? {
        guard rgbaBytes.count == width * height * 4, width > 0, height > 0 else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else {
            return nil
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            UIImage(cgImage: cgImage).draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            if addWatermark {
                let fontSize = max(24.0, CGFloat(height) * 0.032)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.82),
                ]
                let text = "VoxelRay" as NSString
                let textSize = text.size(withAttributes: attrs)
                let pad: CGFloat = max(18.0, CGFloat(height) * 0.025)
                let pillRect = CGRect(
                    x: CGFloat(width) - textSize.width - pad * 2.2,
                    y: CGFloat(height) - textSize.height - pad * 1.6,
                    width: textSize.width + pad * 1.2,
                    height: textSize.height + pad * 0.6
                )
                ctx.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
                let path = UIBezierPath(roundedRect: pillRect, cornerRadius: pillRect.height * 0.5)
                path.fill()
                text.draw(
                    at: CGPoint(x: pillRect.minX + pad * 0.6, y: pillRect.minY + pad * 0.3),
                    withAttributes: attrs
                )
            }
        }
    }

    #if targetEnvironment(simulator)
    /// Runs GPU DDA raycast parity check for tests.
    public func gpuRaycastParity(rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]) -> [RayParityResult] {
        simPipeline.raycastParity(world: world, rays: rays)
    }
    #endif
}
