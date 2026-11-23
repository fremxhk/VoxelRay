import Foundation
import simd

/// Touch-controlled perspective camera with aspect-correct ray generation and temporal reset tracking.
public final class Camera: ObservableObject {
    public private(set) var position: SIMD3<Float>
    public private(set) var yaw: Float
    public private(set) var pitch: Float
    public var fovY: Float
    public var aspect: Float
    public private(set) var frameIndex: UInt32 = 0

    private var prevPosition: SIMD3<Float>
    private var prevForward: SIMD3<Float>
    private var prevRight: SIMD3<Float>
    private var prevUp: SIMD3<Float>

    public static let minPitch: Float = -1.35
    public static let maxPitch: Float = 1.35

    public init(
        position: SIMD3<Float> = SIMD3<Float>(32, 14, 58),
        yaw: Float = 0,
        pitch: Float = -0.22,
        fovY: Float = Float.pi / 3.0,
        aspect: Float = 16.0 / 9.0
    ) {
        self.position = position
        self.yaw = yaw
        self.pitch = min(max(pitch, Self.minPitch), Self.maxPitch)
        self.fovY = fovY
        self.aspect = max(aspect, 0.2)

        let basis = Self.computeBasis(yaw: self.yaw, pitch: self.pitch)
        self.prevPosition = position
        self.prevForward = basis.forward
        self.prevRight = basis.right
        self.prevUp = basis.up
    }

    public var forward: SIMD3<Float> {
        Self.computeBasis(yaw: yaw, pitch: pitch).forward
    }

    public var right: SIMD3<Float> {
        Self.computeBasis(yaw: yaw, pitch: pitch).right
    }

    public var up: SIMD3<Float> {
        Self.computeBasis(yaw: yaw, pitch: pitch).up
    }

    private static func computeBasis(yaw: Float, pitch: Float) -> (forward: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        let cp = cos(pitch)
        let sp = sin(pitch)
        let sy = sin(yaw)
        let cy = cos(yaw)

        let fwd = simd_normalize(SIMD3<Float>(sy * cp, sp, -cy * cp))
        let worldUp = SIMD3<Float>(0, 1, 0)
        let rgt = simd_normalize(simd_cross(fwd, worldUp))
        let u = simd_normalize(simd_cross(rgt, fwd))
        return (fwd, rgt, u)
    }

    /// Sets camera pose immediately via eye and look-at target.
    public func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) {
        let delta = target - eye
        let dist = simd_length(delta)
        guard dist > 1e-4 else { return }
        let dir = delta / dist
        position = eye
        pitch = min(max(asin(min(max(dir.y, -1), 1)), Self.minPitch), Self.maxPitch)
        yaw = atan2(dir.x, -dir.z)
        resetAccumulation()
        syncPreviousBasis()
    }

    /// Moves the camera relative to its look direction and resets temporal accumulation if changed.
    public func applyMoveInput(forward forwardInput: Float, strafe strafeInput: Float, dt: Float, speed: Float = 18.0) {
        guard dt > 0 else { return }
        let magSq = forwardInput * forwardInput + strafeInput * strafeInput
        guard magSq > 1e-6 else { return }

        let basis = Self.computeBasis(yaw: yaw, pitch: pitch)
        let delta = (basis.forward * forwardInput + basis.right * strafeInput) * (speed * dt)
        guard simd_length_squared(delta) > 1e-10 else { return }

        var next = position + delta
        next.x = min(max(next.x, -16), 80)
        next.y = min(max(next.y, 1.5), 44)
        next.z = min(max(next.z, -16), 80)
        if next != position {
            position = next
            resetAccumulation()
        }
    }

    /// Rotates camera yaw/pitch from screen-space touch pan deltas and resets accumulation if changed.
    public func applyLookDelta(dx: Float, dy: Float, sensitivity: Float = 0.005) {
        guard abs(dx) > 1e-6 || abs(dy) > 1e-6 else { return }
        let newYaw = yaw + dx * sensitivity
        let newPitch = min(max(pitch - dy * sensitivity, Self.minPitch), Self.maxPitch)
        if abs(newYaw - yaw) > 1e-7 || abs(newPitch - pitch) > 1e-7 {
            yaw = newYaw
            pitch = newPitch
            resetAccumulation()
        }
    }

    /// Updates aspect ratio cleanly and resets accumulation when aspect changes meaningfully.
    public func updateAspect(_ newAspect: Float) {
        let clamped = max(newAspect, 0.2)
        if abs(clamped - aspect) > 1e-4 {
            aspect = clamped
            resetAccumulation()
        }
    }

    /// Resets progressive Monte Carlo accumulation back to frame 0.
    public func resetAccumulation() {
        frameIndex = 0
    }

    /// Advances temporal sample index and records previous frame basis for motion vectors.
    public func advanceFrame() {
        let basis = Self.computeBasis(yaw: yaw, pitch: pitch)
        prevPosition = position
        prevForward = basis.forward
        prevRight = basis.right
        prevUp = basis.up
        frameIndex &+= 1
    }

    private func syncPreviousBasis() {
        let basis = Self.computeBasis(yaw: yaw, pitch: pitch)
        prevPosition = position
        prevForward = basis.forward
        prevRight = basis.right
        prevUp = basis.up
    }

    /// Computes a unit ray direction for normalized screen coordinates (0,0 top-left .. 1,1 bottom-right).
    public func rayDirection(normalizedScreenPoint point: SIMD2<Float>) -> SIMD3<Float> {
        let basis = Self.computeBasis(yaw: yaw, pitch: pitch)
        let ndcX = point.x * 2.0 - 1.0
        let ndcY = 1.0 - point.y * 2.0
        let tanHalfFov = tan(fovY * 0.5)
        let dir = basis.forward
            + basis.right * (ndcX * aspect * tanHalfFov)
            + basis.up * (ndcY * tanHalfFov)
        return simd_normalize(dir)
    }

    /// Writes current and previous camera state into 256-byte FrameUniforms.
    public func populateUniforms(
        _ uniforms: inout FrameUniforms,
        jitter: SIMD2<Float>,
        internalWidth: Int,
        internalHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        sunElevation: Float,
        biomeRawValue: UInt32,
        maxBounces: UInt32,
        renderMode: UInt32,
        flags: UInt32,
        timeSec: Float
    ) {
        let basis = Self.computeBasis(yaw: yaw, pitch: pitch)
        uniforms.cameraPos = SIMD4<Float>(position, fovY)
        uniforms.cameraForward = SIMD4<Float>(basis.forward, aspect)
        uniforms.cameraRight = SIMD4<Float>(basis.right, jitter.x)
        uniforms.cameraUp = SIMD4<Float>(basis.up, jitter.y)

        uniforms.prevCameraPos = SIMD4<Float>(prevPosition, fovY)
        uniforms.prevCameraForward = SIMD4<Float>(prevForward, aspect)
        uniforms.prevCameraRight = SIMD4<Float>(prevRight, 0)
        uniforms.prevCameraUp = SIMD4<Float>(prevUp, 0)

        let elev = min(max(sunElevation, 0.05), 1.50)
        let sunAzimuth: Float = 0.68
        let sunDir = simd_normalize(SIMD3<Float>(
            cos(elev) * sin(sunAzimuth),
            sin(elev),
            cos(elev) * cos(sunAzimuth)
        ))
        uniforms.sunDirAndElevation = SIMD4<Float>(sunDir, elev)
        uniforms.gridSizeAndBiome = SIMD4<UInt32>(64, 32, 64, biomeRawValue)
        uniforms.renderParams = SIMD4<UInt32>(frameIndex, maxBounces, renderMode, flags)
        uniforms.resolutionAndTime = SIMD4<Float>(
            Float(internalWidth),
            Float(internalHeight),
            Float(outputWidth),
            timeSec
        )
        uniforms.outputAndExposure = SIMD4<Float>(Float(outputHeight), 1.15, 2.0, 8.0)
        uniforms.extra0 = .zero
        uniforms.extra1 = .zero
        uniforms.extra2 = .zero
    }
}
