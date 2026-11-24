#if !targetEnvironment(simulator)
import Foundation
import Metal
import QuartzCore
#if canImport(MetalFX)
import MetalFX
#endif

/// Physical-device Metal 4 pipeline with hardware BVH AABB traversal, residency sets,
/// and thermally adaptive MetalFX Temporal Upscaling.
final class Metal4DevicePipeline {
    struct ThermalConfig {
        let scale: Float
        let maxBounces: UInt32
        let badge: String
    }

    static func thermalConfig(for state: ProcessInfo.ThermalState) -> ThermalConfig {
        switch state {
        case .nominal, .fair:
            return ThermalConfig(scale: 0.75, maxBounces: 3, badge: "MetalFX · 75%")
        case .serious:
            return ThermalConfig(scale: 0.58, maxBounces: 2, badge: "MetalFX · 58% (Warm)")
        case .critical:
            return ThermalConfig(scale: 0.50, maxBounces: 1, badge: "MetalFX · 50% (Thermal)")
        @unknown default:
            return ThermalConfig(scale: 0.75, maxBounces: 3, badge: "MetalFX · 75%")
        }
    }

    let device: MTLDevice
    let commandQueue: MTL4CommandQueue
    let compiler: MTL4Compiler
    let rtPipeline: MTLComputePipelineState
    let tonemapPipeline: MTLComputePipelineState
    let intersectionTable: MTLIntersectionFunctionTable
    let accelerationStructure: MTLAccelerationStructure
    let residencySet: MTLResidencySet
    let argumentTable: MTL4ArgumentTable
    let tonemapArgTable: MTL4ArgumentTable

    private let allocators: [MTL4CommandAllocator]
    private let commandBuffer: MTL4CommandBuffer
    private let sharedEvent: MTLSharedEvent
    private var eventValue: UInt64 = 0

    private let voxelBuffer: MTLBuffer
    private let aabbBuffer: MTLBuffer
    private let scratchBuffer: MTLBuffer
    private let bboxDescriptor: MTL4AccelerationStructureBoundingBoxGeometryDescriptor
    private let accelDescriptor: MTL4PrimitiveAccelerationStructureDescriptor

    private var lastUploadedRevision: UInt64 = 0
    private var hasBuiltAccelerationStructure = false

    private var accumTextures: [MTLTexture] = []
    private var accumFlip: Int = 0
    private var colorTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var motionTexture: MTLTexture?
    private var upscaledColorTexture: MTLTexture?
    private var internalTextureSize: (Int, Int) = (0, 0)
    private var outputTextureSize: (Int, Int) = (0, 0)
    private var scalerNeedsReset = true

    #if canImport(MetalFX)
    private var temporalScaler: MTL4FXTemporalScaler?
    #endif

    init?(device: MTLDevice, library: MTLLibrary, uniformRingBuffer: MTLBuffer) {
        guard device.supportsRaytracing,
              device.supportsFamily(.apple9),
              device.supportsFamily(.metal4),
              let queue = device.makeMTL4CommandQueue(),
              let cmdBuf = device.makeCommandBuffer(),
              let ev = device.makeSharedEvent()
        else {
            NSLog("Metal4DevicePipeline unavailable on this device (requires Apple9+ & Metal4 ray tracing); using ComputePathTracePipeline")
            return nil
        }

        var allocs = [MTL4CommandAllocator]()
        for i in 0..<Renderer.maxFramesInFlight {
            let allocDesc = MTL4CommandAllocatorDescriptor()
            allocDesc.label = "MTL4Allocator_\(i)"
            guard let alloc = try? device.makeCommandAllocator(descriptor: allocDesc) else { return nil }
            allocs.append(alloc)
        }

        let compDesc = MTL4CompilerDescriptor()
        compDesc.label = "VoxelRayMTL4Compiler"
        let mtl4Compiler: MTL4Compiler
        let rtPSO: MTLComputePipelineState
        let tonePSO: MTLComputePipelineState
        do {
            mtl4Compiler = try device.makeCompiler(descriptor: compDesc)

            let rayFnDesc = MTL4LibraryFunctionDescriptor()
            rayFnDesc.library = library
            rayFnDesc.name = "metal4PathTraceKernel"

            let isectFnDesc = MTL4LibraryFunctionDescriptor()
            isectFnDesc.library = library
            isectFnDesc.name = "voxelBoxIntersection"

            let staticLink = MTL4StaticLinkingDescriptor()
            staticLink.functionDescriptors = [isectFnDesc]

            let pipeDesc = MTL4ComputePipelineDescriptor()
            pipeDesc.label = "Metal4VoxelPathTracePSO"
            pipeDesc.computeFunctionDescriptor = rayFnDesc
            pipeDesc.staticLinkingDescriptor = staticLink

            rtPSO = try mtl4Compiler.makeComputePipelineState(descriptor: pipeDesc)

            let toneFnDesc = MTL4LibraryFunctionDescriptor()
            toneFnDesc.library = library
            toneFnDesc.name = "bloomTonemapPresentKernel"
            let toneDesc = MTL4ComputePipelineDescriptor()
            toneDesc.label = "BloomTonemapPresentPSO"
            toneDesc.computeFunctionDescriptor = toneFnDesc
            tonePSO = try mtl4Compiler.makeComputePipelineState(descriptor: toneDesc)
        } catch {
            NSLog("Metal4DevicePipeline compiler/PSO failed: \(error)")
            return nil
        }

        let iftDesc = MTLIntersectionFunctionTableDescriptor()
        iftDesc.functionCount = 1
        guard let ift = rtPSO.makeIntersectionFunctionTable(descriptor: iftDesc),
              let voxBuf = device.makeBuffer(length: VoxelWorld.voxelCount, options: .storageModeShared),
              let boxBuf = device.makeBuffer(
                length: VoxelWorld.brickCount * MemoryLayout<MTLAxisAlignedBoundingBox>.stride,
                options: .storageModeShared
              )
        else {
            return nil
        }

        voxBuf.label = "DeviceVoxelBuffer"
        boxBuf.label = "DeviceBrickAABBBuffer"

        if let handle = rtPSO.functionHandle(withName: "voxelBoxIntersection") {
            ift.setFunction(handle, index: 0)
        }
        ift.setBuffer(voxBuf, offset: 0, index: 0)

        let bbox = MTL4AccelerationStructureBoundingBoxGeometryDescriptor()
        bbox.boundingBoxBuffer = MTL4BufferRangeMake(boxBuf.gpuAddress, UInt64(boxBuf.length))
        bbox.boundingBoxStride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride
        bbox.boundingBoxCount = VoxelWorld.brickCount
        bbox.opaque = true
        bbox.intersectionFunctionTableOffset = 0

        let asDesc = MTL4PrimitiveAccelerationStructureDescriptor()
        asDesc.geometryDescriptors = [bbox]
        asDesc.usage = [.refit, .preferFastIntersection]

        let sizes = device.accelerationStructureSizes(descriptor: asDesc)
        let scratchLen = max(sizes.buildScratchBufferSize, sizes.refitScratchBufferSize)
        guard let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(256, scratchLen), options: .storageModePrivate)
        else {
            return nil
        }
        accel.label = "VoxelBrickBVH"
        scratch.label = "VoxelBVHScratch"

        let resDesc = MTLResidencySetDescriptor()
        resDesc.label = "VoxelRayResidencySet"
        resDesc.initialCapacity = 24
        let argDesc = MTL4ArgumentTableDescriptor()
        argDesc.label = "VoxelRayArgumentTable"
        argDesc.maxBufferBindCount = 6
        argDesc.maxTextureBindCount = 8

        let toneArgDesc = MTL4ArgumentTableDescriptor()
        toneArgDesc.label = "TonemapArgumentTable"
        toneArgDesc.maxBufferBindCount = 2
        toneArgDesc.maxTextureBindCount = 4

        let resSet: MTLResidencySet
        let argTable: MTL4ArgumentTable
        let tArgTable: MTL4ArgumentTable
        do {
            resSet = try device.makeResidencySet(descriptor: resDesc)
            argTable = try device.makeArgumentTable(descriptor: argDesc)
            tArgTable = try device.makeArgumentTable(descriptor: toneArgDesc)
        } catch {
            NSLog("Metal4DevicePipeline residency/argTable error: \(error)")
            return nil
        }

        resSet.addAllocations([uniformRingBuffer, voxBuf, boxBuf, accel, scratch, ift])
        resSet.commit()
        resSet.requestResidency()
        queue.addResidencySet(resSet)

        self.device = device
        self.commandQueue = queue
        self.compiler = mtl4Compiler
        self.rtPipeline = rtPSO
        self.tonemapPipeline = tonePSO
        self.intersectionTable = ift
        self.accelerationStructure = accel
        self.residencySet = resSet
        self.argumentTable = argTable
        self.tonemapArgTable = tArgTable
        self.allocators = allocs
        self.commandBuffer = cmdBuf
        self.sharedEvent = ev
        self.voxelBuffer = voxBuf
        self.aabbBuffer = boxBuf
        self.scratchBuffer = scratch
        self.bboxDescriptor = bbox
        self.accelDescriptor = asDesc
    }

    private func syncWorldIfNeeded(_ world: VoxelWorld) -> Bool {
        guard world.revision != lastUploadedRevision else { return false }
        world.voxels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(voxelBuffer.contents(), base, VoxelWorld.voxelCount)
            }
        }
        let boxes = world.buildBrickAABBs()
        boxes.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(aabbBuffer.contents(), base, boxes.count * MemoryLayout<MTLAxisAlignedBoundingBox>.stride)
            }
        }
        lastUploadedRevision = world.revision
        return true
    }

    private func ensureTextures(
        internalWidth: Int,
        internalHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        useMetalFX: Bool
    ) -> Bool {
        if internalTextureSize.0 == internalWidth, internalTextureSize.1 == internalHeight,
           outputTextureSize.0 == outputWidth, outputTextureSize.1 == outputHeight,
           accumTextures.count == 2, colorTexture != nil, depthTexture != nil, motionTexture != nil {
            if !useMetalFX || upscaledColorTexture != nil {
                return true
            }
        }

        func makePrivateTex(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: w,
                height: h,
                mipmapped: false
            )
            d.storageMode = .private
            d.usage = usage
            let tex = device.makeTexture(descriptor: d)
            tex?.label = label
            return tex
        }

        for old in accumTextures { residencySet.removeAllocation(old) }
        if let old = colorTexture { residencySet.removeAllocation(old) }
        if let old = depthTexture { residencySet.removeAllocation(old) }
        if let old = motionTexture { residencySet.removeAllocation(old) }
        if let old = upscaledColorTexture { residencySet.removeAllocation(old) }

        var colorUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var depthUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var motionUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        var outUsage: MTLTextureUsage = [.shaderRead, .shaderWrite]

        #if canImport(MetalFX)
        if useMetalFX {
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
            if let scaler = fxDesc.makeTemporalScaler(device: device, compiler: compiler) {
                temporalScaler = scaler
                colorUsage.formUnion(scaler.colorTextureUsage)
                depthUsage.formUnion(scaler.depthTextureUsage)
                motionUsage.formUnion(scaler.motionTextureUsage)
                outUsage.formUnion(scaler.outputTextureUsage)
            } else {
                temporalScaler = nil
            }
        } else {
            temporalScaler = nil
        }
        #endif

        guard let a0 = makePrivateTex(.rgba32Float, internalWidth, internalHeight, [.shaderRead, .shaderWrite], "DevAccum_0"),
              let a1 = makePrivateTex(.rgba32Float, internalWidth, internalHeight, [.shaderRead, .shaderWrite], "DevAccum_1"),
              let color = makePrivateTex(.rgba16Float, internalWidth, internalHeight, colorUsage, "DevColorHDR"),
              let depth = makePrivateTex(.r32Float, internalWidth, internalHeight, depthUsage, "DevDepth"),
              let motion = makePrivateTex(.rg16Float, internalWidth, internalHeight, motionUsage, "DevMotion")
        else {
            return false
        }

        var allocs: [MTLAllocation] = [a0, a1, color, depth, motion]
        if useMetalFX {
            if let up = makePrivateTex(.rgba16Float, outputWidth, outputHeight, outUsage, "DevUpscaledHDR") {
                upscaledColorTexture = up
                allocs.append(up)
            }
        } else {
            upscaledColorTexture = nil
        }

        residencySet.addAllocations(allocs)
        residencySet.commit()

        accumTextures = [a0, a1]
        colorTexture = color
        depthTexture = depth
        motionTexture = motion
        internalTextureSize = (internalWidth, internalHeight)
        outputTextureSize = (outputWidth, outputHeight)
        scalerNeedsReset = true
        return true
    }

    func encodeDisplayFrame(
        world: VoxelWorld,
        uniformRingBuffer: MTLBuffer,
        uniformOffset: Int,
        slot: Int,
        drawable: CAMetalDrawable,
        displayTarget: MTLTexture,
        internalWidth: Int,
        internalHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        jitter: SIMD2<Float>,
        resetHistory: Bool,
        frameSemaphore: DispatchSemaphore
    ) {
        let dirty = syncWorldIfNeeded(world)
        let useMetalFX = (internalWidth != outputWidth || internalHeight != outputHeight)
        guard ensureTextures(
            internalWidth: internalWidth,
            internalHeight: internalHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            useMetalFX: useMetalFX
        ),
              accumTextures.count == 2,
              let color = colorTexture,
              let depth = depthTexture,
              let motion = motionTexture
        else {
            frameSemaphore.signal()
            return
        }

        if !residencySet.containsAllocation(displayTarget) {
            residencySet.addAllocation(displayTarget)
            residencySet.commit()
        }

        let readTex = accumFlip == 0 ? accumTextures[0] : accumTextures[1]
        let writeTex = accumFlip == 0 ? accumTextures[1] : accumTextures[0]
        accumFlip = 1 - accumFlip

        let alloc = allocators[slot]
        if eventValue >= UInt64(Renderer.maxFramesInFlight) {
            _ = sharedEvent.wait(untilSignaledValue: eventValue - UInt64(Renderer.maxFramesInFlight) + 1, timeoutMS: 1000)
        }
        alloc.reset()

        commandBuffer.beginCommandBuffer(allocator: alloc)
        commandBuffer.useResidencySet(residencySet)

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "Metal4VoxelPathTrace"
            let scratchRange = MTL4BufferRangeMake(scratchBuffer.gpuAddress, UInt64(scratchBuffer.length))
            if !hasBuiltAccelerationStructure {
                encoder.build(destinationAccelerationStructure: accelerationStructure, descriptor: accelDescriptor, scratchBuffer: scratchRange)
                encoder.barrier(afterEncoderStages: .accelerationStructure, beforeEncoderStages: .dispatch, visibilityOptions: .device)
                hasBuiltAccelerationStructure = true
            } else if dirty {
                encoder.refit(sourceAccelerationStructure: accelerationStructure, descriptor: accelDescriptor, destinationAccelerationStructure: accelerationStructure, scratchBuffer: scratchRange, options: [])
                encoder.barrier(afterEncoderStages: .accelerationStructure, beforeEncoderStages: .dispatch, visibilityOptions: .device)
            }

            argumentTable.setAddress(uniformRingBuffer.gpuAddress + UInt64(uniformOffset), index: 0)
            argumentTable.setAddress(voxelBuffer.gpuAddress, index: 1)
            argumentTable.setResource(accelerationStructure.gpuResourceID, bufferIndex: 2)
            argumentTable.setResource(intersectionTable.gpuResourceID, bufferIndex: 3)
            argumentTable.setTexture(readTex.gpuResourceID, index: 0)
            argumentTable.setTexture(writeTex.gpuResourceID, index: 1)
            argumentTable.setTexture(color.gpuResourceID, index: 2)
            argumentTable.setTexture(depth.gpuResourceID, index: 3)
            argumentTable.setTexture(motion.gpuResourceID, index: 4)
            argumentTable.setTexture(displayTarget.gpuResourceID, index: 5)

            encoder.setComputePipelineState(rtPipeline)
            encoder.setArgumentTable(argumentTable)
            let w = max(1, min(8, rtPipeline.threadExecutionWidth))
            let h = max(1, min(8, rtPipeline.maxTotalThreadsPerThreadgroup / w))
            encoder.dispatchThreadgroups(
                threadgroupsPerGrid: MTLSize(width: (internalWidth + w - 1) / w, height: (internalHeight + h - 1) / h, depth: 1),
                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
            )

            #if canImport(MetalFX)
            if let scaler = temporalScaler, let upTex = upscaledColorTexture {
                encoder.endEncoding()
                scaler.colorTexture = color
                scaler.depthTexture = depth
                scaler.motionTexture = motion
                scaler.outputTexture = upTex
                scaler.inputContentWidth = internalWidth
                scaler.inputContentHeight = internalHeight
                scaler.jitterOffsetX = jitter.x
                scaler.jitterOffsetY = jitter.y
                scaler.motionVectorScaleX = 1.0
                scaler.motionVectorScaleY = 1.0
                scaler.reset = resetHistory || scalerNeedsReset
                scalerNeedsReset = false
                scaler.encode(commandBuffer: commandBuffer)

                if let postEncoder = commandBuffer.makeComputeCommandEncoder() {
                    postEncoder.label = "BloomTonemapAfterMetalFX"
                    tonemapArgTable.setAddress(uniformRingBuffer.gpuAddress + UInt64(uniformOffset), index: 0)
                    tonemapArgTable.setTexture(upTex.gpuResourceID, index: 0)
                    tonemapArgTable.setTexture(displayTarget.gpuResourceID, index: 1)
                    postEncoder.setComputePipelineState(tonemapPipeline)
                    postEncoder.setArgumentTable(tonemapArgTable)
                    let tw = max(1, min(8, tonemapPipeline.threadExecutionWidth))
                    let th = max(1, min(8, tonemapPipeline.maxTotalThreadsPerThreadgroup / tw))
                    postEncoder.dispatchThreadgroups(
                        threadgroupsPerGrid: MTLSize(width: (outputWidth + tw - 1) / tw, height: (outputHeight + th - 1) / th, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1)
                    )
                    postEncoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .blit, visibilityOptions: .device)
                    postEncoder.copy(sourceTexture: displayTarget, destinationTexture: drawable.texture)
                    postEncoder.endEncoding()
                }
            } else {
                encoder.endEncoding()
                if let postEncoder = commandBuffer.makeComputeCommandEncoder() {
                    postEncoder.label = "BloomTonemapDirect"
                    tonemapArgTable.setAddress(uniformRingBuffer.gpuAddress + UInt64(uniformOffset), index: 0)
                    tonemapArgTable.setTexture(color.gpuResourceID, index: 0)
                    tonemapArgTable.setTexture(displayTarget.gpuResourceID, index: 1)
                    postEncoder.setComputePipelineState(tonemapPipeline)
                    postEncoder.setArgumentTable(tonemapArgTable)
                    let tw = max(1, min(8, tonemapPipeline.threadExecutionWidth))
                    let th = max(1, min(8, tonemapPipeline.maxTotalThreadsPerThreadgroup / tw))
                    postEncoder.dispatchThreadgroups(
                        threadgroupsPerGrid: MTLSize(width: (outputWidth + tw - 1) / tw, height: (outputHeight + th - 1) / th, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1)
                    )
                    postEncoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .blit, visibilityOptions: .device)
                    postEncoder.copy(sourceTexture: displayTarget, destinationTexture: drawable.texture)
                    postEncoder.endEncoding()
                }
            }
            #else
            encoder.endEncoding()
            if let postEncoder = commandBuffer.makeComputeCommandEncoder() {
                postEncoder.label = "BloomTonemapDirect"
                tonemapArgTable.setAddress(uniformRingBuffer.gpuAddress + UInt64(uniformOffset), index: 0)
                tonemapArgTable.setTexture(color.gpuResourceID, index: 0)
                tonemapArgTable.setTexture(displayTarget.gpuResourceID, index: 1)
                postEncoder.setComputePipelineState(tonemapPipeline)
                postEncoder.setArgumentTable(tonemapArgTable)
                let tw = max(1, min(8, tonemapPipeline.threadExecutionWidth))
                let th = max(1, min(8, tonemapPipeline.maxTotalThreadsPerThreadgroup / tw))
                postEncoder.dispatchThreadgroups(
                    threadgroupsPerGrid: MTLSize(width: (outputWidth + tw - 1) / tw, height: (outputHeight + th - 1) / th, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1)
                )
                postEncoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .blit, visibilityOptions: .device)
                postEncoder.copy(sourceTexture: displayTarget, destinationTexture: drawable.texture)
                postEncoder.endEncoding()
            }
            #endif
        }

        commandBuffer.endCommandBuffer()
        eventValue &+= 1
        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)
        commandQueue.signalEvent(sharedEvent, value: eventValue)
        drawable.present()
        frameSemaphore.signal()
    }

    func renderOffscreen(
        world: VoxelWorld,
        uniformRingBuffer: MTLBuffer,
        uniformOffsetProvider: (Int) -> Int,
        width: Int,
        height: Int,
        samples: Int
    ) -> [UInt8] {
        let dirty = syncWorldIfNeeded(world)
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

        guard ensureTextures(
            internalWidth: width,
            internalHeight: height,
            outputWidth: width,
            outputHeight: height,
            useMetalFX: false
        ),
              accumTextures.count == 2,
              let privateTarget = device.makeTexture(descriptor: desc),
              let stagingBuffer = device.makeBuffer(length: totalBytes, options: .storageModeShared),
              let color = colorTexture,
              let depth = depthTexture,
              let motion = motionTexture
        else {
            return []
        }

        residencySet.addAllocations([privateTarget, stagingBuffer])
        residencySet.commit()
        defer {
            residencySet.removeAllocations([privateTarget, stagingBuffer])
            residencySet.commit()
        }

        let count = max(1, samples)
        let scratchRange = MTL4BufferRangeMake(scratchBuffer.gpuAddress, UInt64(scratchBuffer.length))

        for s in 0..<count {
            let slot = s % Renderer.maxFramesInFlight
            let alloc = allocators[slot]
            if eventValue > 0 {
                _ = sharedEvent.wait(untilSignaledValue: eventValue, timeoutMS: 2000)
            }
            alloc.reset()

            let readTex = accumFlip == 0 ? accumTextures[0] : accumTextures[1]
            let writeTex = accumFlip == 0 ? accumTextures[1] : accumTextures[0]
            accumFlip = 1 - accumFlip

            commandBuffer.beginCommandBuffer(allocator: alloc)
            commandBuffer.useResidencySet(residencySet)

            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                if s == 0 && !hasBuiltAccelerationStructure {
                    encoder.build(destinationAccelerationStructure: accelerationStructure, descriptor: accelDescriptor, scratchBuffer: scratchRange)
                    encoder.barrier(afterEncoderStages: .accelerationStructure, beforeEncoderStages: .dispatch, visibilityOptions: .device)
                    hasBuiltAccelerationStructure = true
                } else if s == 0 && dirty {
                    encoder.refit(sourceAccelerationStructure: accelerationStructure, descriptor: accelDescriptor, destinationAccelerationStructure: accelerationStructure, scratchBuffer: scratchRange, options: [])
                    encoder.barrier(afterEncoderStages: .accelerationStructure, beforeEncoderStages: .dispatch, visibilityOptions: .device)
                }

                let offset = uniformOffsetProvider(s)
                argumentTable.setAddress(uniformRingBuffer.gpuAddress + UInt64(offset), index: 0)
                argumentTable.setAddress(voxelBuffer.gpuAddress, index: 1)
                argumentTable.setResource(accelerationStructure.gpuResourceID, bufferIndex: 2)
                argumentTable.setResource(intersectionTable.gpuResourceID, bufferIndex: 3)
                argumentTable.setTexture(readTex.gpuResourceID, index: 0)
                argumentTable.setTexture(writeTex.gpuResourceID, index: 1)
                argumentTable.setTexture(color.gpuResourceID, index: 2)
                argumentTable.setTexture(depth.gpuResourceID, index: 3)
                argumentTable.setTexture(motion.gpuResourceID, index: 4)
                argumentTable.setTexture(privateTarget.gpuResourceID, index: 5)

                encoder.setComputePipelineState(rtPipeline)
                encoder.setArgumentTable(argumentTable)
                let w = max(1, min(8, rtPipeline.threadExecutionWidth))
                let h = max(1, min(8, rtPipeline.maxTotalThreadsPerThreadgroup / w))
                encoder.dispatchThreadgroups(
                    threadgroupsPerGrid: MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
                )

                if s == count - 1 {
                    encoder.endEncoding()
                    if let postEncoder = commandBuffer.makeComputeCommandEncoder() {
                        tonemapArgTable.setAddress(uniformRingBuffer.gpuAddress + UInt64(offset), index: 0)
                        tonemapArgTable.setTexture(color.gpuResourceID, index: 0)
                        tonemapArgTable.setTexture(privateTarget.gpuResourceID, index: 1)
                        postEncoder.setComputePipelineState(tonemapPipeline)
                        postEncoder.setArgumentTable(tonemapArgTable)
                        let tw = max(1, min(8, tonemapPipeline.threadExecutionWidth))
                        let th = max(1, min(8, tonemapPipeline.maxTotalThreadsPerThreadgroup / tw))
                        postEncoder.dispatchThreadgroups(
                            threadgroupsPerGrid: MTLSize(width: (width + tw - 1) / tw, height: (height + th - 1) / th, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1)
                        )
                        postEncoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .blit, visibilityOptions: .device)
                        postEncoder.copy(
                            sourceTexture: privateTarget,
                            sourceSlice: 0,
                            sourceLevel: 0,
                            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                            sourceSize: MTLSize(width: width, height: height, depth: 1),
                            destinationBuffer: stagingBuffer,
                            destinationOffset: 0,
                            destinationBytesPerRow: bytesPerRow,
                            destinationBytesPerImage: totalBytes
                        )
                        postEncoder.endEncoding()
                    }
                } else {
                    encoder.endEncoding()
                }
            }

            commandBuffer.endCommandBuffer()
            eventValue &+= 1
            commandQueue.commit([commandBuffer])
            commandQueue.signalEvent(sharedEvent, value: eventValue)
        }

        _ = sharedEvent.wait(untilSignaledValue: eventValue, timeoutMS: 5000)
        let ptr = stagingBuffer.contents().assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: ptr, count: totalBytes))
    }
}
#endif
