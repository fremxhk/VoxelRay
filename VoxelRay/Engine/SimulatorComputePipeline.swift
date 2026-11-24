import Foundation
import Metal
import QuartzCore

/// Cross-platform Metal compute path-tracing pipeline (3D Amanatides-Woo DDA + 13-tap HDR bloom).
/// Used on iOS Simulator and as a rock-solid full-featured compute fallback on physical iPhones
/// when Metal 4 hardware command queues (e.g. A15 iPhone 13) are unavailable.
final class ComputePathTracePipeline {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private let smokePipeline: MTLComputePipelineState
    private let rayTracePipeline: MTLComputePipelineState
    private let bloomTonemapPipeline: MTLComputePipelineState
    private let parityPipeline: MTLComputePipelineState

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

    private func ensureHDRTexture(
        current: inout MTLTexture?,
        currentSize: inout (Int, Int),
        width: Int,
        height: Int,
        label: String
    ) -> MTLTexture? {
        if let tex = current, currentSize.0 == width && currentSize.1 == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .private
        desc.usage = [.shaderRead, .shaderWrite]
        let created = device.makeTexture(descriptor: desc)
        created?.label = label
        current = created
        currentSize = (width, height)
        return created
    }

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
        let hdrTex = ensureHDRTexture(
            current: &hdrTexture,
            currentSize: &hdrSize,
            width: internalWidth,
            height: internalHeight,
            label: "ComputeHDR"
        ),
        let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            frameSemaphore.signal()
            return
        }

        let readTex = accumFlip == 0 ? a0 : a1
        let writeTex = accumFlip == 0 ? a1 : a0
        accumFlip = 1 - accumFlip

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
        width: Int,
        height: Int,
        samples: Int,
        smokeOnly: Bool,
        frameSemaphore: DispatchSemaphore
    ) -> [UInt8] {
        syncWorldIfNeeded(world)
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
                width: width,
                height: height,
                labelPrefix: "ComputeOffscreenAccum"
              ),
              let hdrTex = ensureHDRTexture(
                current: &offscreenHDRTexture,
                currentSize: &offscreenHDRSize,
                width: width,
                height: height,
                label: "ComputeOffscreenHDR"
              )
        else {
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

            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                if smokeOnly {
                    encoder.setComputePipelineState(smokePipeline)
                    encoder.setTexture(privateTarget, index: 0)
                    encoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                    Renderer.dispatch2D(encoder: encoder, pipeline: smokePipeline, width: width, height: height)
                } else {
                    encoder.setComputePipelineState(rayTracePipeline)
                    encoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                    encoder.setBuffer(voxelBuffer, offset: 0, index: 1)
                    encoder.setTexture(readTex, index: 0)
                    encoder.setTexture(writeTex, index: 1)
                    encoder.setTexture(hdrTex, index: 2)
                    Renderer.dispatch2D(encoder: encoder, pipeline: rayTracePipeline, width: width, height: height)
                }
                encoder.endEncoding()
            }

            if !smokeOnly && s == count - 1, let postEncoder = commandBuffer.makeComputeCommandEncoder() {
                postEncoder.setComputePipelineState(bloomTonemapPipeline)
                postEncoder.setBuffer(uniformRingBuffer, offset: offset, index: 0)
                postEncoder.setTexture(hdrTex, index: 0)
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
