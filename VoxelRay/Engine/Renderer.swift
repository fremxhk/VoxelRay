import Foundation
import Metal
import QuartzCore
import Combine

/// Core renderer coordinating VoxelWorld state, triple-buffered uniforms, and dual Device/Simulator ray-tracing pipelines.
public final class Renderer: ObservableObject {
    public static let maxFramesInFlight = 3
    public static let uniformStride = MemoryLayout<FrameUniforms>.stride

    public let device: MTLDevice
    public let camera: Camera
    public let world: VoxelWorld

    @Published public var fps: Double = 60.0
    @Published public var sampleCount: UInt32 = 0
    @Published public var activeBiome: VoxelBiome = .sunlitCourtyard
    @Published public var thermalBadgeText: String = {
        #if targetEnvironment(simulator)
        return "MetalFX (Device Only)"
        #else
        return "MetalFX · 75%"
        #endif
    }()
    @Published public var sunElevation: Float = VoxelBiome.sunlitCourtyard.defaultSunElevation {
        didSet {
            if abs(oldValue - sunElevation) > 1e-4 {
                camera.resetAccumulation()
            }
        }
    }
    @Published public var blastRadius: Float = 3.0

    public var moveInput: SIMD2<Float> = .zero

    private let uniformRingBuffer: MTLBuffer
    private let frameSemaphore = DispatchSemaphore(value: Renderer.maxFramesInFlight)
    private var ringIndex: Int = 0
    private let startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var smoothedFPS: Double = 60.0

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
        internalWidth: Int,
        internalHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        timeSec: Float
    ) -> Int {
        let offset = slot * Self.uniformStride
        let ptr = uniformRingBuffer.contents().advanced(by: offset).assumingMemoryBound(to: FrameUniforms.self)
        var u = FrameUniforms()
        camera.populateUniforms(
            &u,
            jitter: .zero,
            internalWidth: internalWidth,
            internalHeight: internalHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            sunElevation: sunElevation,
            biomeRawValue: world.biome.rawValue,
            maxBounces: 3,
            renderMode: 0,
            flags: 0,
            timeSec: timeSec
        )
        ptr.pointee = u
        return offset
    }

    /// Renders a frame to a Metal layer drawable via a private render target + blit copy.
    public func draw(to layer: CAMetalLayer, drawableSize: CGSize) {
        let width = Int(drawableSize.width)
        let height = Int(drawableSize.height)
        guard width > 0, height > 0 else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastFrameTime, 1.0 / 240.0), 0.1))
        lastFrameTime = now

        camera.updateAspect(Float(width) / Float(height))
        camera.applyMoveInput(forward: moveInput.y, strafe: moveInput.x, dt: dt)

        let instFPS = 1.0 / Double(max(dt, 0.001))
        smoothedFPS = smoothedFPS * 0.9 + instFPS * 0.1

        frameSemaphore.wait()
        guard let drawable = layer.nextDrawable(),
              let targetTex = ensurePrivateTexture(
                current: &displayTexture,
                currentSize: &displayTextureSize,
                width: width,
                height: height,
                pixelFormat: layer.pixelFormat,
                usage: [.shaderWrite, .shaderRead],
                label: "PrivateDisplayTarget"
              )
        else {
            frameSemaphore.signal()
            return
        }

        let slot = ringIndex
        ringIndex = (ringIndex + 1) % Self.maxFramesInFlight
        let uniformOffset = writeUniforms(
            slot: slot,
            internalWidth: width,
            internalHeight: height,
            outputWidth: width,
            outputHeight: height,
            timeSec: Float(now - startTime)
        )

        #if targetEnvironment(simulator)
        simPipeline.encodeDisplayFrame(
            world: world,
            uniformRingBuffer: uniformRingBuffer,
            uniformOffset: uniformOffset,
            drawable: drawable,
            displayTarget: targetTex,
            width: width,
            height: height,
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
                width: width,
                height: height,
                frameSemaphore: frameSemaphore
            )
        } else if let cmdBuf = fallbackQueue.makeCommandBuffer() {
            if let enc = cmdBuf.makeComputeCommandEncoder() {
                enc.setComputePipelineState(fallbackSmokePipeline)
                enc.setTexture(targetTex, index: 0)
                enc.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
                Self.dispatch2D(encoder: enc, pipeline: fallbackSmokePipeline, width: width, height: height)
                enc.endEncoding()
            }
            if let blit = cmdBuf.makeBlitCommandEncoder() {
                blit.copy(from: targetTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1), to: drawable.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
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
                internalWidth: width,
                internalHeight: height,
                outputWidth: width,
                outputHeight: height,
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

    #if targetEnvironment(simulator)
    /// Runs GPU DDA raycast parity check for tests.
    public func gpuRaycastParity(rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]) -> [RayParityResult] {
        simPipeline.raycastParity(world: world, rays: rays)
    }
    #endif
}
