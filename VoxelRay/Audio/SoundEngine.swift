import Foundation
import AVFoundation
import Combine

/// Zero-asset procedural DSP audio engine providing tactile material foley,
/// pentatonic sculpting melodies, and subtle spatial biome atmospheres.
public final class SoundEngine: ObservableObject {
    public static let sampleRate: Double = 44_100.0
    private static let muteDefaultsKey = "voxelray.audio.muted"
    private static let pentatonicHz: [Double] = [523.25, 587.33, 659.25, 783.99, 880.00, 1046.50, 1174.66, 1318.51]

    @Published public var isMuted: Bool {
        didSet {
            let muted = isMuted
            UserDefaults.standard.set(muted, forKey: Self.muteDefaultsKey)
            voiceQueue.async { [weak self] in
                self?.mainMixerVolume(muted ? 0.0 : 0.85)
            }
        }
    }

    public private(set) var lastPlayedCue: String = ""

    private let engine = AVAudioEngine()
    private var sfxNodes: [AVAudioPlayerNode] = []
    private let ambientNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    private let voiceQueue = DispatchQueue(label: "com.voxelray.sound", qos: .userInitiated)
    private var nextVoiceIndex: Int = 0
    private var isEngineConfigured = false
    private var activeBiome: VoxelBiome?

    public init() {
        let savedMuted = UserDefaults.standard.bool(forKey: Self.muteDefaultsKey)
        self.isMuted = savedMuted
        voiceQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureEngineIfNeeded()
            self.mainMixerVolume(savedMuted ? 0.0 : 0.85)
        }
    }

    deinit {
        engine.stop()
    }

    private func mainMixerVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = volume
    }

    private func configureEngineIfNeeded() {
        guard !isEngineConfigured else { return }
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Keep running cleanly in headless/test environments
        }
        #endif

        for _ in 0..<6 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sfxNodes.append(node)
        }
        engine.attach(ambientNode)
        engine.connect(ambientNode, to: engine.mainMixerNode, format: format)
        isEngineConfigured = true
        ensureRunning()
    }

    private func ensureRunning() {
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Safe no-op on CI environments without audio hardware
        }
    }

    @discardableResult
    public func toggleMute() -> Bool {
        isMuted.toggle()
        lastPlayedCue = isMuted ? "mute" : "unmute"
        if !isMuted {
            playUIButton()
        }
        return isMuted
    }

    public func playCarveImpact(material: VoxelMaterial, blastRadius: Float, combo: Int) {
        lastPlayedCue = "carve.\(material.rawValue).r\(Int(round(blastRadius))).c\(combo)"
        guard !isMuted else { return }
        let samples = Self.synthesizeImpactStereo(material: material, blastRadius: blastRadius, combo: combo)
        playStereoFrames(samples.left, samples.right, volume: 0.92)
    }

    public func playSculptPlace(material: VoxelMaterial, stepIndex: Int) {
        lastPlayedCue = "place.\(material.rawValue).s\(stepIndex)"
        guard !isMuted else { return }
        let samples = Self.synthesizeSculptStereo(material: material, stepIndex: stepIndex)
        playStereoFrames(samples.left, samples.right, volume: 0.78)
    }

    public func playBiomeAmbience(for biome: VoxelBiome) {
        guard activeBiome != biome else { return }
        activeBiome = biome
        lastPlayedCue = "ambience.\(biome.rawValue)"

        let (left, right) = Self.synthesizeAmbienceStereo(biome: biome)
        guard let buffer = makePCMBuffer(left: left, right: right) else { return }

        voiceQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureEngineIfNeeded()
            self.ensureRunning()
            self.ambientNode.stop()
            self.ambientNode.volume = 0.24
            self.ambientNode.scheduleBuffer(buffer, at: nil, options: .loops)
            if self.engine.isRunning {
                self.ambientNode.play()
            }
        }
    }

    public func playUIButton() {
        lastPlayedCue = "ui.tap"
        guard !isMuted else { return }
        let s = Self.synthesizeToneBurst(freqStart: 760, freqEnd: 980, duration: 0.045, gain: 0.16, pan: 0)
        playStereoFrames(s.left, s.right, volume: 0.55)
    }

    public func playUndoSwoosh() {
        lastPlayedCue = "ui.undo"
        guard !isMuted else { return }
        let s = Self.synthesizeToneBurst(freqStart: 620, freqEnd: 290, duration: 0.16, gain: 0.28, pan: -0.15)
        playStereoFrames(s.left, s.right, volume: 0.70)
    }

    public func playPhotoShutter() {
        lastPlayedCue = "photo.shutter"
        guard !isMuted else { return }
        let s = Self.synthesizeShutterStereo()
        playStereoFrames(s.left, s.right, volume: 0.85)
    }

    public func playMilestoneFanfare() {
        lastPlayedCue = "milestone.fanfare"
        guard !isMuted else { return }
        let s = Self.synthesizeChordArpeggio(frequencies: [523.25, 659.25, 783.99, 1046.50], duration: 0.52, gain: 0.26)
        playStereoFrames(s.left, s.right, volume: 0.85)
    }

    public func playUnlockFanfare() {
        lastPlayedCue = "store.unlock"
        guard !isMuted else { return }
        let s = Self.synthesizeChordArpeggio(frequencies: [587.33, 739.99, 880.00, 1174.66], duration: 0.60, gain: 0.30)
        playStereoFrames(s.left, s.right, volume: 0.90)
    }

    private func playStereoFrames(_ left: [Float], _ right: [Float], volume: Float) {
        guard let buffer = makePCMBuffer(left: left, right: right) else { return }
        voiceQueue.async { [weak self] in
            guard let self = self, !self.sfxNodes.isEmpty else { return }
            self.configureEngineIfNeeded()
            self.ensureRunning()
            let node = self.sfxNodes[self.nextVoiceIndex % self.sfxNodes.count]
            self.nextVoiceIndex = (self.nextVoiceIndex + 1) % self.sfxNodes.count
            node.stop()
            node.volume = volume
            node.scheduleBuffer(buffer, at: nil, options: [])
            if self.engine.isRunning {
                node.play()
            }
        }
    }

    private func makePCMBuffer(left: [Float], right: [Float]) -> AVAudioPCMBuffer? {
        let count = min(left.count, right.count)
        guard count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let chData = buf.floatChannelData
        else {
            return nil
        }
        buf.frameLength = AVAudioFrameCount(count)
        left.withUnsafeBufferPointer { srcL in
            if let base = srcL.baseAddress {
                chData[0].update(from: base, count: count)
            }
        }
        right.withUnsafeBufferPointer { srcR in
            if let base = srcR.baseAddress {
                chData[1].update(from: base, count: count)
            }
        }
        return buf
    }

    // MARK: - Pure DSP Waveform Synthesis (Testable Without Hardware)

    public static func synthesizeTestSamples(for material: VoxelMaterial) -> [Float] {
        synthesizeImpactStereo(material: material, blastRadius: 3.0, combo: 2).left
    }

    public static func synthesizeImpactStereo(
        material: VoxelMaterial,
        blastRadius: Float,
        combo: Int
    ) -> (left: [Float], right: [Float]) {
        let sr = sampleRate
        let radiusNorm = min(max(Double(blastRadius) / 6.0, 0.25), 1.0)
        let duration = 0.28 + 0.16 * radiusNorm
        let n = Int(sr * duration)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)

        var seed: UInt64 = UInt64(material.rawValue) &* 0x9E37_79B9_7F4A_7C15 &+ 17
        let comboPitch = pentatonicHz[max(0, min(combo - 1, pentatonicHz.count - 1))]

        let subFreqStart = 125.0 - 40.0 * radiusNorm
        let subFreqEnd = 38.0 - 8.0 * radiusNorm

        for i in 0..<n {
            let t = Double(i) / sr
            let subEnv = exp(-t * (12.0 - 4.0 * radiusNorm))
            let subFreq = subFreqEnd + (subFreqStart - subFreqEnd) * exp(-t * 22.0)
            let sub = sin(2.0 * .pi * subFreq * t) * subEnv * (0.48 + 0.20 * radiusNorm)

            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let white = (Double((seed >> 33) & 0xFFFF) / 32767.5) - 1.0

            let materialSampleL: Double
            let materialSampleR: Double

            switch material {
            case .glass, .prismCrystal:
                let cEnv = exp(-t * 9.5)
                let shimmer =
                    sin(2.0 * .pi * 1380.0 * t) * 0.22 +
                    sin(2.0 * .pi * 2140.0 * t + 0.4) * 0.18 +
                    sin(2.0 * .pi * 3190.0 * t + 0.9) * 0.14 +
                    sin(2.0 * .pi * 4680.0 * t) * 0.10
                let sparkle = white * exp(-t * 24.0) * 0.22
                materialSampleL = (shimmer + sparkle) * cEnv + sub * 0.45
                materialSampleR = (shimmer * 0.96 - sparkle * 0.85) * cEnv + sub * 0.45

            case .gold, .chrome:
                let mEnv = exp(-t * 6.5)
                let ring =
                    sin(2.0 * .pi * 520.0 * t) * 0.26 +
                    sin(2.0 * .pi * 1410.0 * t) * 0.18 +
                    sin(2.0 * .pi * 2650.0 * t) * 0.10
                materialSampleL = ring * mEnv + sub * 0.65
                materialSampleR = ring * mEnv * 0.94 + sub * 0.65

            case .water:
                let wEnv = exp(-t * 10.0)
                let bloopFreq = 320.0 + 540.0 * (1.0 - exp(-t * 14.0))
                let bloop = sin(2.0 * .pi * bloopFreq * t) * 0.25
                let spray = white * exp(-t * 14.0) * 0.28
                materialSampleL = (bloop + spray) * wEnv + sub * 0.35
                materialSampleR = (bloop - spray * 0.7) * wEnv + sub * 0.35

            case .neonCyan, .neonMagenta, .amberLantern:
                let zEnv = exp(-t * 11.0)
                let zapFreq = 880.0 * exp(-t * 16.0) + 190.0
                let zap = tanh(sin(2.0 * .pi * zapFreq * t) * 2.2) * 0.28
                materialSampleL = zap * zEnv + sub * 0.55
                materialSampleR = zap * zEnv + sub * 0.55

            default:
                // Crisp multi-crackle architectural stone collapse
                let noiseEnv = exp(-t * 15.0)
                let pebbles = (t > 0.045 && t < 0.22) ? (white * sin(2.0 * .pi * 34.0 * t) * 0.24) : 0.0
                let grit = white * noiseEnv * 0.32 + pebbles
                materialSampleL = sub + grit
                materialSampleR = sub + grit * 0.85
            }

            let comboPing = combo >= 2
                ? sin(2.0 * .pi * comboPitch * t) * exp(-t * 14.0) * 0.16
                : 0.0

            left[i] = Float(max(-0.96, min(0.96, materialSampleL + comboPing)))
            right[i] = Float(max(-0.96, min(0.96, materialSampleR + comboPing * 0.92)))
        }
        return (left, right)
    }

    public static func synthesizeSculptStereo(
        material: VoxelMaterial,
        stepIndex: Int
    ) -> (left: [Float], right: [Float]) {
        let baseFreq = pentatonicHz[abs(stepIndex) % pentatonicHz.count]
        let mult = (material == .prismCrystal) ? 1.5 : (material == .glass ? 1.25 : 1.0)
        return synthesizeToneBurst(
            freqStart: baseFreq * mult * 0.98,
            freqEnd: baseFreq * mult,
            duration: 0.24,
            gain: 0.32,
            pan: 0.08
        )
    }

    public static func synthesizeAmbienceStereo(biome: VoxelBiome) -> (left: [Float], right: [Float]) {
        let sr = sampleRate
        let loopSeconds = 4.0
        let n = Int(sr * loopSeconds)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)

        let baseHz: Double
        let fifthHz: Double
        let airHz: Double
        switch biome {
        case .sunlitCourtyard:
            baseHz = 196.0
            fifthHz = 294.0
            airHz = 392.0
        case .neonCavern:
            baseHz = 65.5
            fifthHz = 98.25
            airHz = 262.0
        case .glassCathedral:
            baseHz = 131.0
            fifthHz = 196.5
            airHz = 524.0
        }

        // Frequencies rounded cleanly so 4.0s fits exact integer periods (zero loop click)
        let f1 = round(baseHz * loopSeconds) / loopSeconds
        let f2 = round(fifthHz * loopSeconds) / loopSeconds
        let f3 = round(airHz * loopSeconds) / loopSeconds

        for i in 0..<n {
            let t = Double(i) / sr
            let breathe = 0.72 + 0.28 * sin(2.0 * .pi * (1.0 / loopSeconds) * t)
            let sL = (sin(2.0 * .pi * f1 * t) * 0.08 + sin(2.0 * .pi * f2 * t + 0.5) * 0.05 + sin(2.0 * .pi * f3 * t) * 0.025) * breathe
            let sR = (sin(2.0 * .pi * f1 * t + 0.3) * 0.08 + sin(2.0 * .pi * f2 * t) * 0.05 + sin(2.0 * .pi * f3 * t + 0.7) * 0.025) * breathe
            left[i] = Float(max(-0.5, min(0.5, sL)))
            right[i] = Float(max(-0.5, min(0.5, sR)))
        }
        return (left, right)
    }

    private static func synthesizeToneBurst(
        freqStart: Double,
        freqEnd: Double,
        duration: Double,
        gain: Double,
        pan: Double
    ) -> (left: [Float], right: [Float]) {
        let sr = sampleRate
        let n = Int(sr * duration)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        let lGain = sqrt(max(0.0, 0.5 - pan * 0.5)) * 1.414
        let rGain = sqrt(max(0.0, 0.5 + pan * 0.5)) * 1.414
        var phase = 0.0

        for i in 0..<n {
            let t = Double(i) / sr
            let frac = t / max(duration, 1e-4)
            let freq = freqStart + (freqEnd - freqStart) * frac
            phase += 2.0 * .pi * freq / sr
            let attack = min(1.0, t / 0.005)
            let decay = exp(-t * (6.5 / max(duration, 0.04)))
            let s = (sin(phase) * 0.8 + sin(phase * 2.0) * 0.2) * attack * decay * gain
            left[i] = Float(max(-0.96, min(0.96, s * lGain)))
            right[i] = Float(max(-0.96, min(0.96, s * rGain)))
        }
        return (left, right)
    }

    private static func synthesizeShutterStereo() -> (left: [Float], right: [Float]) {
        let sr = sampleRate
        let n = Int(sr * 0.22)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        var seed: UInt64 = 0x5048_4F54_4F01
        for i in 0..<n {
            let t = Double(i) / sr
            seed = seed &* 6364136223846793005 &+ 1
            let nVal = (Double((seed >> 33) & 0xFFFF) / 32767.5) - 1.0
            let click1 = exp(-t * 140.0) * (nVal * 0.4 + sin(2.0 * .pi * 1900.0 * t) * 0.25)
            let click2 = (t > 0.075) ? exp(-(t - 0.075) * 140.0) * (nVal * 0.35 + sin(2.0 * .pi * 2400.0 * t) * 0.2) : 0.0
            let bell = (t > 0.08) ? sin(2.0 * .pi * 1046.5 * (t - 0.08)) * exp(-(t - 0.08) * 14.0) * 0.22 : 0.0
            let sample = click1 + click2 + bell
            left[i] = Float(max(-0.95, min(0.95, sample)))
            right[i] = Float(max(-0.95, min(0.95, sample)))
        }
        return (left, right)
    }

    private static func synthesizeChordArpeggio(
        frequencies: [Double],
        duration: Double,
        gain: Double
    ) -> (left: [Float], right: [Float]) {
        let sr = sampleRate
        let n = Int(sr * duration)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            var sum = 0.0
            for (idx, f) in frequencies.enumerated() {
                let start = Double(idx) * 0.065
                if t >= start {
                    let dt = t - start
                    let env = min(1.0, dt / 0.008) * exp(-dt * 8.0)
                    sum += (sin(2.0 * .pi * f * dt) * 0.75 + sin(2.0 * .pi * f * 2.0 * dt) * 0.25) * env
                }
            }
            let sample = max(-0.95, min(0.95, sum * gain))
            left[i] = Float(sample)
            right[i] = Float(sample)
        }
        return (left, right)
    }
}
