#if !targetEnvironment(simulator)
import Foundation
import Metal
import QuartzCore

/// Physical-device Metal 4 pipeline using MTL4CommandQueue, MTL4Compiler, MTLResidencySet,
/// MTL4AccelerationStructureBoundingBoxGeometryDescriptor, and MTLIntersectionFunctionTable.
final class Metal4DevicePipeline {
    let device: MTLDevice
    let commandQueue: MTL4CommandQueue
    let compiler: MTL4Compiler
    let rtPipeline: MTLComputePipelineState
    let intersectionTable: MTLIntersectionFunctionTable
    let accelerationStructure: MTLAccelerationStructure
    let residencySet: MTLResidencySet
    let argumentTable: MTL4ArgumentTable

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
    private var textureSize: (Int, Int) = (0, 0)

    init?(device: MTLDevice, library: MTLLibrary, uniformRingBuffer: MTLBuffer) {
        guard device.supportsRaytracing,
              let queue = device.makeMTL4CommandQueue(),
              let cmdBuf = device.makeCommandBuffer(),
              let ev = device.makeSharedEvent()
        else {
            NSLog("Metal4DevicePipeline unavailable on this device")
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
        resDesc.initialCapacity = 16
        let argDesc = MTL4ArgumentTableDescriptor()
        argDesc.label = "VoxelRayArgumentTable"
        argDesc.maxBufferBindCount = 6
        argDesc.maxTextureBindCount = 8

        let resSet: MTLResidencySet
        let argTable: MTL4ArgumentTable
        do {
            resSet = try device.makeResidencySet(descriptor: resDesc)
            argTable = try device.makeArgumentTable(descriptor: argDesc)
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
        self.intersectionTable = ift
        self.accelerationStructure = accel
        self.residencySet = resSet
        self.argumentTable = argTable
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

    private func ensureTextures(width: Int, height: Int) -> Bool {
        if textureSize.0 == width, textureSize.1 == height,
           accumTextures.count == 2, colorTexture != nil, depthTexture != nil, motionTexture != nil {
            return true
        }

        func makePrivateTex(_ format: MTLPixelFormat, _ usage: MTLTextureUsage, _ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format,
                width: width,
                height: height,
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

        guard let a0 = makePrivateTex(.rgba32Float, [.shaderRead, .shaderWrite], "DevAccum_0"),
              let a1 = makePrivateTex(.rgba32Float, [.shaderRead, .shaderWrite], "DevAccum_1"),
              let color = makePrivateTex(.rgba16Float, [.shaderRead, .shaderWrite], "DevColorHDR"),
              let depth = makePrivateTex(.r32Float, [.shaderRead, .shaderWrite], "DevDepth"),
              let motion = makePrivateTex(.rg16Float, [.shaderRead, .shaderWrite], "DevMotion")
        else {
            return false
        }

        residencySet.addAllocations([a0, a1, color, depth, motion])
        residencySet.commit()

        accumTextures = [a0, a1]
        colorTexture = color
        depthTexture = depth
        motionTexture = motion
        textureSize = (width, height)
        return true
    }

    func encodeDisplayFrame(
        world: VoxelWorld,
        uniformRingBuffer: MTLBuffer,
        uniformOffset: Int,
        slot: Int,
        drawable: CAMetalDrawable,
        displayTarget: MTLTexture,
        width: Int,
        height: Int,
        frameSemaphore: DispatchSemaphore
    ) {
        let dirty = syncWorldIfNeeded(world)
        guard ensureTextures(width: width, height: height),
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
                threadgroupsPerGrid: MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
            )
            encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .blit, visibilityOptions: .device)
            encoder.copy(sourceTexture: displayTarget, destinationTexture: drawable.texture)
            encoder.endEncoding()
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

        guard ensureTextures(width: width, height: height),
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
                    encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .blit, visibilityOptions: .device)
                    encoder.copy(
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
                }
                encoder.endEncoding()
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
