import Foundation
import Metal
import QuartzCore
import Combine

/// Core renderer coordinating triple-buffered uniforms, offscreen safe blit readbacks, and HUD telemetry.
public final class Renderer: ObservableObject {
    public static let maxFramesInFlight = 3
    public static let uniformStride = MemoryLayout<FrameUniforms>.stride

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let camera: Camera

    @Published public var fps: Double = 60.0
    @Published public var sampleCount: UInt32 = 0
    @Published public var thermalBadgeText: String = {
        #if targetEnvironment(simulator)
        return "MetalFX (Device Only)"
        #else
        return "MetalFX · 75%"
        #endif
    }()
    @Published public var sunElevation: Float = 0.72 {
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

    private let smokePipeline: MTLComputePipelineState
    private var displayTexture: MTLTexture?
    private var displayTextureSize: (Int, Int) = (0, 0)

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let dev = device else {
            NSLog("VoxelRay Renderer init failed: MTLCreateSystemDefaultDevice() returned nil")
            return nil
        }
        guard let queue = dev.makeCommandQueue() else {
            NSLog("VoxelRay Renderer init failed: makeCommandQueue() returned nil")
            return nil
        }
        guard let library = dev.makeDefaultLibrary() else {
            NSLog("VoxelRay Renderer init failed: makeDefaultLibrary() returned nil")
            return nil
        }
        guard let smokeFn = library.makeFunction(name: "rayDirSmokeKernel") else {
            NSLog("VoxelRay Renderer init failed: rayDirSmokeKernel not found")
            return nil
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try dev.makeComputePipelineState(function: smokeFn)
        } catch {
            NSLog("VoxelRay Renderer init failed: makeComputePipelineState error: \(error)")
            return nil
        }
        guard let ring = dev.makeBuffer(
            length: Self.uniformStride * Self.maxFramesInFlight,
            options: .storageModeShared
        ) else {
            NSLog("VoxelRay Renderer init failed: makeBuffer for uniforms returned nil")
            return nil
        }

        self.device = dev
        self.commandQueue = queue
        self.camera = Camera()
        self.smokePipeline = pipeline
        self.uniformRingBuffer = ring
        self.uniformRingBuffer.label = "FrameUniformsRing"
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
            biomeRawValue: 0,
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
              ),
              let commandBuffer = commandQueue.makeCommandBuffer()
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

            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.label = "ComputeSmokePass"
                encoder.setComputePipelineState(smokePipeline)
                encoder.setTexture(targetTex, index: 0)
                encoder.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
                Self.dispatch2D(encoder: encoder, pipeline: smokePipeline, width: width, height: height)
                encoder.endEncoding()
            }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "PresentBlitCopy"
            blit.copy(
                from: targetTex,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        let sem = frameSemaphore
        commandBuffer.addCompletedHandler { _ in
            sem.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        camera.advanceFrame()
        let currentSample = camera.frameIndex
        let currentFPS = smoothedFPS
        DispatchQueue.main.async { [weak self] in
            self?.sampleCount = currentSample
            self?.fps = currentFPS
        }
    }

    /// Renders an offscreen RGBA8 image using a .private texture and explicit MTLBlitCommandEncoder staging readback.
    public func renderOffscreen(width: Int, height: Int, samples: Int = 1) -> [UInt8] {
        precondition(width > 0 && height > 0)
        let bytesPerRow = width * 4
        let totalBytes = bytesPerRow * height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderWrite, .shaderRead]

        guard let privateTarget = device.makeTexture(descriptor: desc),
              let stagingBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared)
        else {
            return []
        }
        privateTarget.label = "OffscreenPrivateTarget"
        stagingBuffer.label = "OffscreenReadbackStaging"

        camera.updateAspect(Float(width) / Float(height))
        let count = max(1, samples)

        for s in 0..<count {
            frameSemaphore.wait()
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                frameSemaphore.signal()
                return []
            }
            let slot = ringIndex
            ringIndex = (ringIndex + 1) % Self.maxFramesInFlight
            let uniformOffset = writeUniforms(
                slot: slot,
                internalWidth: width,
                internalHeight: height,
                outputWidth: width,
                outputHeight: height,
                timeSec: Float(s) * (1.0 / 60.0)
            )

            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(smokePipeline)
                encoder.setTexture(privateTarget, index: 0)
                encoder.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
                Self.dispatch2D(encoder: encoder, pipeline: smokePipeline, width: width, height: height)
                encoder.endEncoding()
            }

            if s == count - 1, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: privateTarget,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: stagingBuffer,
                    destinationOffset: 0,
                    destinationBytesPerRow: bytesPerRow,
                    destinationBytesPerImage: totalBytes
                )
                blit.endEncoding()
            }

            let sem = frameSemaphore
            commandBuffer.addCompletedHandler { _ in
                sem.signal()
            }
            commandBuffer.commit()
            if s == count - 1 {
                commandBuffer.waitUntilCompleted()
            }
            camera.advanceFrame()
        }

        let ptr = stagingBuffer.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: totalBytes))
    }
}
