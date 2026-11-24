import Foundation
import Metal
import QuartzCore
#if canImport(MetalFX) && !targetEnvironment(simulator)
import MetalFX
#endif

/// Cross-platform Metal compute path-tracing pipeline (3D Amanatides-Woo DDA + 13-tap HDR bloom).
/// Used on iOS Simulator and on physical A15/A16 iPhones (paired with hardware MTLFXTemporalScaler
/// upscaling when scaling internal resolution 50%–67% to native display resolution).
final class ComputePathTracePipeline {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private let smokePipeline: MTLComputePipelineState
    private let rayTracePipeline: MTLComputePipelineState
    private let bloomTonemapPipeline: MTLComputePipelineState
    private let parityPipeline: MTLComputePipelineState

    #if canImport(MetalFX) && !targetEnvironment(simulator)
    private let deviceRTWithMotionPipeline: MTLComputePipelineState?
    private var temporalScaler: MTLFXTemporalScaler?
    private var scalerInputSize: (Int, Int) = (0, 0)
    private var scalerOutputSize: (Int, Int) = (0, 0)
    private var scalerNeedsReset = true

    private var depthTexture: MTLTexture?
    private var motionTexture: MTLTexture?
    private var upscaledColorTexture: MTLTexture?

    private var offscreenDepthTexture: MTLTexture?
    private var offscreenMotionTexture: MTLTexture?
    private var offscreenUpscaledTexture: MTLTexture?
    #endif

    let supportsMetalFX: Bool

    private let voxelBuffer: MTLBuffer
    private var lastUploadedRevision: UInt64 = 0

    private var accumTextures: [MTLTexture] = []
    private var accumSize: (Int, Int) = (0, 0)
    private var accumFlip: Int = 0
    private var hdrTexture: MTLTexture?
    private var hdrSize: (Int, Int) = (0, 0)

    private var offscreenAccumTextures: [MTLTexture] = []
    private var offscreenAccumSize: (Int, Int) = (0, 0)
    private var offscreenFlip: Int = 0
    private var offscreenHDRTexture: MTLTexture?
    private var offscreenHDRSize: (Int, Int) = (0, 0)

    init?(device: MTLDevice, library: MTLLibrary) {
        guard let queue = device.makeCommandQueue(),
              let smokeFn = library.makeFunction(name: "rayDirSmokeKernel"),
              let rtFn = library.makeFunction(name: "simulatorPathTraceKernel"),
              let bloomFn = library.makeFunction(name: "bloomTonemapPresentKernel"),
              let parityFn = library.makeFunction(name: "raycastParityKernel"),
              let voxBuf = device.makeBuffer(length: VoxelWorld.voxelCount, options: .storageModeShared)
        else {
            NSLog("ComputePathTracePipeline init failed: missing queue/functions/voxelBuffer")
            return nil
        }

        do {
            self.smokePipeline = try device.makeComputePipelineState(function: smokeFn)
            self.rayTracePipeline = try device.makeComputePipelineState(function: rtFn)
            self.bloomTonemapPipeline = try device.makeComputePipelineState(function: bloomFn)
            self.parityPipeline = try device.makeComputePipelineState(function: parityFn)
        } catch {
            NSLog("ComputePathTracePipeline pipeline creation failed: \(error)")
            return nil
        }

        #if canImport(MetalFX) && !targetEnvironment(simulator)
        if MTLFXTemporalScalerDescriptor.supportsDevice(device),
           let devFn = library.makeFunction(name: "deviceComputePathTraceKernel"),
           let devPSO = try? device.makeComputePipelineState(function: devFn) {
            self.deviceRTWithMotionPipeline = devPSO
            self.supportsMetalFX = true
        } else {
            self.deviceRTWithMotionPipeline = nil
            self.supportsMetalFX = false
        }
        #else
        self.supportsMetalFX = false
        #endif

        self.device = device
        self.commandQueue = queue
        self.voxelBuffer = voxBuf
        self.voxelBuffer.label = "ComputeVoxelGridBuffer"
    }

    func syncWorldIfNeeded(_ world: VoxelWorld) {
        guard world.revision != lastUploadedRevision else { return }
        world.voxels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(voxelBuffer.contents(), base, VoxelWorld.voxelCount)
            }
        }
        lastUploadedRevision = world.revision
    }

    private func ensurePingPongTextures(
        current: inout [MTLTexture],
        currentSize: inout (Int, Int),
        width: Int,
        height: Int,
        labelPrefix: String
    ) -> (MTLTexture, MTLTexture)? {
        if current.count == 2 && currentSize.0 == width && currentSize.1 == height {
            return (current[0], current[1])
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        guard let t0 = device.makeTexture(descriptor: desc),
              let t1 = device.makeTexture(descriptor: desc)
        else {
            return nil
        }
        t0.label = "\(labelPrefix)_0"
        t1.label = "\(labelPrefix)_1"
        current = [t0, t1]
        currentSize = (width, height)
        return (t0, t1)
    }

    private func ensurePrivateTexture(
        current: inout MTLTexture?,
        currentSize: inout (Int, Int),
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        usage: MTLTextureUsage,
        label: String
    ) -> MTLTexture? {
        if let tex = current,
           currentSize.0 == width,
           currentSize.1 == height,
           tex.pixelFormat == format,
           tex.usage.contains(usage) {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
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

    #if canImport(MetalFX) && !targetEnvironment(simulator)
    private func ensureTemporalScaler(
        internalWidth: Int,
        internalHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    ) -> MTLFXTemporalScaler? {
        guard supportsMetalFX, (internalWidth != outputWidth || internalHeight != outputHeight) else {
            temporalScaler = nil
            return nil
        }
        if let existing = temporalScaler,
           scalerInputSize == (internalWidth, internalHeight),
           scalerOutputSize == (outputWidth, outputHeight) {
            return existing
        }

        let fxDesc = MTLFXTemporalScalerDescriptor()
        fxDesc.colorTextureFormat = .rgba16Float
        fxDesc.depthTextureFormat = .r32Float
        fxDesc.motionTextureFormat = .rg16Float
        fxDesc.outputTextureFormat = .rgba16Float
        fxDesc.inputWidth = internalWidth
        fxDesc.inputHeight = internalHeight
        fxDesc.outputWidth = outputWidth
        fxDesc.outputHeight = outputHeight
        fxDesc.isAutoExposureEnabled = true

        guard let scaler = fxDesc.makeTemporalScaler(device: device) else {
            temporalScaler = nil
            return nil
        }
        temporalScaler = scaler
        scalerInputSize = (internalWidth, internalHeight)
        scalerOutputSize = (outputWidth, outputHeight)
        scalerNeedsReset = true
        return scaler
    }

    private func makeMetalFXTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ label: String) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = usage
        let tex = device.makeTexture(descriptor: desc)
        tex?.label = label
        return tex
    }
    #endif

    func encodeDisplayFrame(
        world: VoxelWorld,
        uniformRingBuffer: MTLBuffer,
        uniformOffset: Int,
        drawable: CAMetalDrawable,
        displayTarget: MTLTexture,
        internalWidth: Int,
        internalHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        jitter: SIMD2<Float> = .zero,
        resetHistory: Bool = false,
        frameSemaphore: DispatchSemaphore
    ) {
        syncWorldIfNeeded(world)
        guard let (a0, a1) = ensurePingPongTextures(
            current: &accumTextures,
            currentSize: &accumSize,
            width: internalWidth,
            height: internalHeight,
            labelPrefix: "ComputeAccum"
        ),
        let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            frameSemaphore.signal()
            return
        }

        let readTex = accumFlip == 0 ? a0 : a1
        let writeTex = accumFlip == 0 ? a1 : a0
        accumFlip = 1 - accumFlip

        #if canImport(MetalFX) && !targetEnvironment(simulator)
        if let motionPSO = deviceRTWithMotionPipeline,
           let scaler = ensureTemporalScaler(
                internalWidth: internalWidth,
                internalHeight: internalHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight
           ) {
            let cUsage = MTLTextureUsage([.shaderRead, .shaderWrite]).union(scaler.colorTextureUsage)
            let dUsage = MTLTextureUsage([.shaderRead, .shaderWrite]).union(scaler.depthTextureUsage)
            let mUsage = MTLTextureUsage([.shaderRead, .shaderWrite]).union(scaler.motionTextureUsage)
            let oUsage = MTLTextureUsage([.shaderRead, .shaderWrite]).union(scaler.outputTextureUsage)

            var dSize = (depthTexture?.width ?? 0, depthTexture?.height ?? 0)
            var mSize = (motionTexture?.width ?? 0, motionTexture?.height ?? 0)
            var uSize = (upscaledColorTexture?.width ?? 0, upscaledColorTexture?.height ?? 0)

            if let hdrTex = ensurePrivateTexture(current: &hdrTexture, currentSize: &hdrSize, format: .rgba16Float, width: internalWidth, height: internalHeight, usage: cUsage, label: "A15ComputeHDR"),
               let dTex = ensurePrivateTexture(current: &depthTexture, currentSize: &dSize, format: .r32Float, width: internalWidth, height: internalHeight, usage: dUsage, label: "A15ComputeDepth"),
               let mTex = ensurePrivateTexture(current: &motionTexture, currentSize: &mSize, format: .rg16Float, width: internalWidth, height: internalHeight, usage: mUsage, label: "A15ComputeMotion"),
               let upTex = ensurePrivateTexture(current: &upscaledColorTexture, currentSize: &uSize, format: .rgba16Float, width: outputWidth, height: outputHeight, usage: oUsage, label: "A15MetalFXUpscaled") {
                if let encoder = commandBuffer.makeComputeCommandEncoder() {
                    encoder.label = "A15ComputePathTracePass"
                    encoder.setComputePipelineState(motionPSO)
                    encoder.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
                    encoder.setBuffer(voxelBuffer, offset: 0, index: 1)
                    encoder.setTexture(readTex, index: 0)
                    encoder.setTexture(writeTex, index: 1)
                    encoder.setTexture(hdrTex, index: 2)
                    encoder.setTexture(dTex, index: 3)
                    encoder.setTexture(mTex, index: 4)
                    Renderer.dispatch2D(encoder: encoder, pipeline: motionPSO, width: internalWidth, height: internalHeight)
                    encoder.endEncoding()
                }

                scaler.colorTexture = hdrTex
                scaler.depthTexture = dTex
                scaler.motionTexture = mTex
                scaler.outputTexture = upTex
                scaler.inputContentWidth = internalWidth
                scaler.inputContentHeight = internalHeight
                scaler.jitterOffsetX = jitter.x
                scaler.jitterOffsetY = jitter.y
                scaler.motionVectorScaleX = 1.0
                scaler.motionVectorScaleY = 1.0
                scaler.isDepthReversed = true
                scaler.reset = resetHistory || scalerNeedsReset
                scalerNeedsReset = false
                scaler.encode(commandBuffer: commandBuffer)

                if let postEncoder = commandBuffer.makeComputeCommandEncoder() {
                    postEncoder.label = "A15BloomTonemapPass"
                    postEncoder.setComputePipelineState(bloomTonemapPipeline)
                    postEncoder.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
                    postEncoder.setTexture(upTex, index: 0)
                    postEncoder.setTexture(displayTarget, index: 1)
                    Renderer.dispatch2D(encoder: postEncoder, pipeline: bloomTonemapPipeline, width: outputWidth, height: outputHeight)
                    postEncoder.endEncoding()
                }

                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.label = "A15PresentBlit"
                    blit.copy(
                        from: displayTarget,
                        sourceSlice: 0,
                        sourceLevel: 0,
                        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                        sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                        to: drawable.texture,
                        destinationSlice: 0,
                        destinationLevel: 0,
                        destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                    )
                    blit.endEncoding()
                }

                commandBuffer.addCompletedHandler { _ in
                    frameSemaphore.signal()
                }
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
        }
        #endif

        guard let hdrTex = ensurePrivateTexture(
            current: &hdrTexture,
            currentSize: &hdrSize,
            format: .rgba16Float,
            width: internalWidth,
            height: internalHeight,
            usage: [.shaderRead, .shaderWrite],
            label: "ComputeHDR"
        ) else {
            frameSemaphore.signal()
            return
        }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "ComputeVoxelPathTracePass"
            encoder.setComputePipelineState(rayTracePipeline)
            encoder.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
            encoder.setBuffer(voxelBuffer, offset: 0, index: 1)
            encoder.setTexture(readTex, index: 0)
            encoder.setTexture(writeTex, index: 1)
            encoder.setTexture(hdrTex, index: 2)
            Renderer.dispatch2D(encoder: encoder, pipeline: rayTracePipeline, width: internalWidth, height: internalHeight)
            encoder.endEncoding()
        }

        if let postEncoder = commandBuffer.makeComputeCommandEncoder() {
            postEncoder.label = "ComputeBloomTonemapPass"
            postEncoder.setComputePipelineState(bloomTonemapPipeline)
            postEncoder.setBuffer(uniformRingBuffer, offset: uniformOffset, index: 0)
            postEncoder.setTexture(hdrTex, index: 0)
            postEncoder.setTexture(displayTarget, index: 1)
            Renderer.dispatch2D(encoder: postEncoder, pipeline: bloomTonemapPipeline, width: outputWidth, height: outputHeight)
            postEncoder.endEncoding()
        }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "ComputePresentBlit"
            blit.copy(
                from: displayTarget,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: outputWidth, height: outputHeight, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        commandBuffer.addCompletedHandler { _ in
            frameSemaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func renderOffscreen(
        world: VoxelWorld,
        uniformRingBuffer: MTLBuffer,
        uniformOffsetProvider: (Int) -> Int,
        internalWidth: Int? = nil,
        internalHeight: Int? = nil,
        width: Int,
        height: Int,
        samples: Int,
        smokeOnly: Bool,
        jitterProvider: ((Int) -> SIMD2<Float>)? = nil,
        frameSemaphore: DispatchSemaphore
    ) -> [UInt8] {
        syncWorldIfNeeded(world)
        let inW = max(64, internalWidth ?? width)
        let inH = max(64, internalHeight ?? height)
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
              let stagingBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared),
              let (a0, a1) = ensurePingPongTextures(
                current: &offscreenAccumTextures,
                currentSize: &offscreenAccumSize,
                width: inW,
                height: inH,
                labelPrefix: "ComputeOffscreenAccum"
              )
        else {
            return []
        }

        #if canImport(MetalFX) && !targetEnvironment(simulator)
        var offScaler: MTLFXTemporalScaler? = nil
        var offDepth: MTLTexture? = nil
        var offMotion: MTLTexture? = nil
        var offUpscaled: MTLTexture? = nil
        var hdrUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        if !smokeOnly, (inW != width || inH != height), let _ = deviceRTWithMotionPipeline,
           let scaler = ensureTemporalScaler(internalWidth: inW, internalHeight: inH, outputWidth: width, outputHeight: height) {
            offScaler = scaler
            hdrUsage.formUnion(scaler.colorTextureUsage)
            var dSz = (offscreenDepthTexture?.width ?? 0, offscreenDepthTexture?.height ?? 0)
            var mSz = (offscreenMotionTexture?.width ?? 0, offscreenMotionTexture?.height ?? 0)
            var uSz = (offscreenUpscaledTexture?.width ?? 0, offscreenUpscaledTexture?.height ?? 0)
            offDepth = ensurePrivateTexture(current: &offscreenDepthTexture, currentSize: &dSz, format: .r32Float, width: inW, height: inH, usage: MTLTextureUsage([.shaderRead, .shaderWrite]).union(scaler.depthTextureUsage), label: "OffscreenDepth")
            offMotion = ensurePrivateTexture(current: &offscreenMotionTexture, currentSize: &mSz, format: .rg16Float, width: inW, height: inH, usage: MTLTextureUsage([.shaderRead, .shaderWrite]).union(scaler.motionTextureUsage), label: "OffscreenMotion")
            offUpscaled = ensurePrivateTexture(current: &offscreenUpscaledTexture, currentSize: &uSz, format: .rgba16Float, width: width, height: height, usage: MTLTextureUsage([.shaderRead, .shaderWrite]).union(scaler.outputTextureUsage), label: "OffscreenUpscaled")
        }
        #else
        let hdrUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        #endif

        guard let hdrTex = ensurePrivateTexture(
            current: &offscreenHDRTexture,
            currentSize: &offscreenHDRSize,
            format: .rgba16Float,
            width: inW,
            height: inH,
            usage: hdrUsage,
            label: "ComputeOffscreenHDR"
        ) else {
            return []
        }

        let count = max(1, samples)
        for s in 0..<count {
            frameSemaphore.wait()
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                frameSemaphore.signal()
                return []
            }
            let offset = uniformOffsetProvider(s)
            let readTex = offscreenFlip == 0 ? a0 : a1
            let writeTex = offscreenFlip == 0 ? a1 : a0
            offscreenFlip = 1 - offscreenFlip

            var tonemapInputTex: MTLTexture = hdrTex

            if smokeOnly {
                if let encoder = commandBuffer.makeComputeCommandEncoder() {
                    encoder.setComputePipelineState(smokePipeline)
                    encoder.setTexture(privateTarget, index: 0)
                    encoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                    Renderer.dispatch2D(encoder: encoder, pipeline: smokePipeline, width: width, height: height)
                    encoder.endEncoding()
                }
            } else {
                #if canImport(MetalFX) && !targetEnvironment(simulator)
                if let motionPSO = deviceRTWithMotionPipeline,
                   let scaler = offScaler,
                   let dTex = offDepth,
                   let mTex = offMotion,
                   let upTex = offUpscaled {
                    if let encoder = commandBuffer.makeComputeCommandEncoder() {
                        encoder.setComputePipelineState(motionPSO)
                        encoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                        encoder.setBuffer(voxelBuffer, offset: 0, index: 1)
                        encoder.setTexture(readTex, index: 0)
                        encoder.setTexture(writeTex, index: 1)
                        encoder.setTexture(hdrTex, index: 2)
                        encoder.setTexture(dTex, index: 3)
                        encoder.setTexture(mTex, index: 4)
                        Renderer.dispatch2D(encoder: encoder, pipeline: motionPSO, width: inW, height: inH)
                        encoder.endEncoding()
                    }
                    let jit = jitterProvider?(s) ?? .zero
                    scaler.colorTexture = hdrTex
                    scaler.depthTexture = dTex
                    scaler.motionTexture = mTex
                    scaler.outputTexture = upTex
                    scaler.inputContentWidth = inW
                    scaler.inputContentHeight = inH
                    scaler.jitterOffsetX = jit.x
                    scaler.jitterOffsetY = jit.y
                    scaler.motionVectorScaleX = 1.0
                    scaler.motionVectorScaleY = 1.0
                    scaler.isDepthReversed = true
                    scaler.reset = (s == 0)
                    scaler.encode(commandBuffer: commandBuffer)
                    tonemapInputTex = upTex
                } else if let encoder = commandBuffer.makeComputeCommandEncoder() {
                    encoder.setComputePipelineState(rayTracePipeline)
                    encoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                    encoder.setBuffer(voxelBuffer, offset: 0, index: 1)
                    encoder.setTexture(readTex, index: 0)
                    encoder.setTexture(writeTex, index: 1)
                    encoder.setTexture(hdrTex, index: 2)
                    Renderer.dispatch2D(encoder: encoder, pipeline: rayTracePipeline, width: inW, height: inH)
                    encoder.endEncoding()
                }
                #else
                if let encoder = commandBuffer.makeComputeCommandEncoder() {
                    encoder.setComputePipelineState(rayTracePipeline)
                    encoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                    encoder.setBuffer(voxelBuffer, offset: 0, index: 1)
                    encoder.setTexture(readTex, index: 0)
                    encoder.setTexture(writeTex, index: 1)
                    encoder.setTexture(hdrTex, index: 2)
                    Renderer.dispatch2D(encoder: encoder, pipeline: rayTracePipeline, width: inW, height: inH)
                    encoder.endEncoding()
                }
                #endif
            }

            if !smokeOnly && s == count - 1, let postEncoder = commandBuffer.makeComputeCommandEncoder() {
                postEncoder.setComputePipelineState(bloomTonemapPipeline)
                postEncoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                postEncoder.setTexture(tonemapInputTex, index: 0)
                postEncoder.setTexture(privateTarget, index: 1)
                Renderer.dispatch2D(encoder: postEncoder, pipeline: bloomTonemapPipeline, width: width, height: height)
                postEncoder.endEncoding()
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

            commandBuffer.addCompletedHandler { _ in
                frameSemaphore.signal()
            }
            commandBuffer.commit()
            if s == count - 1 {
                commandBuffer.waitUntilCompleted()
            }
        }

        let ptr = stagingBuffer.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: totalBytes))
    }

    /// Executes GPU DDA raycasts for CPU/GPU parity tests.
    func raycastParity(world: VoxelWorld, rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]) -> [RayParityResult] {
        guard !rays.isEmpty else { return [] }
        syncWorldIfNeeded(world)

        let queryStride = MemoryLayout<RayParityQuery>.stride
        let resultStride = MemoryLayout<RayParityResult>.stride

        guard let queryBuf = device.makeBuffer(length: queryStride * rays.count, options: .storageModeShared),
              let resultBuf = device.makeBuffer(length: resultStride * rays.count, options: .storageModeShared),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder()
        else {
            return []
        }

        let qPtr = queryBuf.contents().assumingMemoryBound(to: RayParityQuery.self)
        for (i, r) in rays.enumerated() {
            qPtr[i] = RayParityQuery(
                origin: SIMD4<Float>(r.origin, 0),
                direction: SIMD4<Float>(r.direction, 0)
            )
        }

        var count = UInt32(rays.count)
        enc.setComputePipelineState(parityPipeline)
        enc.setBuffer(voxelBuffer, offset: 0, index: 0)
        enc.setBuffer(queryBuf, offset: 0, index: 1)
        enc.setBuffer(resultBuf, offset: 0, index: 2)
        enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 3)
        let tgW = min(64, max(1, rays.count))
        let tgCount = (rays.count + tgW - 1) / tgW
        enc.dispatchThreadgroups(
            MTLSize(width: tgCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: tgW, height: 1, depth: 1)
        )
        enc.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        let rPtr = resultBuf.contents().assumingMemoryBound(to: RayParityResult.self)
        return Array(UnsafeBufferPointer(start: rPtr, count: rays.count))
    }
}

typealias SimulatorComputePipeline = ComputePathTracePipeline
