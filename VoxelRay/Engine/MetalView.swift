import SwiftUI
import UIKit
import Metal
import QuartzCore

/// ProMotion-capable CAMetalLayer surface with touch pan-look and tap callbacks.
public struct MetalView: UIViewRepresentable {
    @ObservedObject public var renderer: Renderer
    public var onViewportTap: ((SIMD2<Float>) -> Void)?

    public init(renderer: Renderer, onViewportTap: ((SIMD2<Float>) -> Void)? = nil) {
        self.renderer = renderer
        self.onViewportTap = onViewportTap
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer, onViewportTap: onViewportTap)
    }

    public func makeUIView(context: Context) -> MetalLayerUIView {
        let view = MetalLayerUIView(renderer: renderer)
        view.accessibilityIdentifier = "viewport.metal"
        view.isAccessibilityElement = true
        view.onDraw = { layer, size in
            context.coordinator.renderer.draw(to: layer, drawableSize: size)
        }

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    public func updateUIView(_ uiView: MetalLayerUIView, context: Context) {
        context.coordinator.onViewportTap = onViewportTap
    }

    public final class Coordinator: NSObject {
        let renderer: Renderer
        var onViewportTap: ((SIMD2<Float>) -> Void)?
        private var lastTranslation: CGPoint = .zero

        init(renderer: Renderer, onViewportTap: ((SIMD2<Float>) -> Void)?) {
            self.renderer = renderer
            self.onViewportTap = onViewportTap
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let t = gesture.translation(in: gesture.view)
            switch gesture.state {
            case .began:
                lastTranslation = .zero
            case .changed:
                let dx = Float(t.x - lastTranslation.x)
                let dy = Float(t.y - lastTranslation.y)
                lastTranslation = t
                renderer.camera.applyLookDelta(dx: dx, dy: dy)
            default:
                lastTranslation = .zero
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view else { return }
            let bounds = view.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let pt = gesture.location(in: view)
            let nx = Float(min(max(pt.x / bounds.width, 0), 1))
            let ny = Float(min(max(pt.y / bounds.height, 0), 1))
            onViewportTap?(SIMD2<Float>(nx, ny))
        }
    }
}

/// UIView backed by a 120Hz ProMotion CAMetalLayer.
public final class MetalLayerUIView: UIView {
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    public var onDraw: ((CAMetalLayer, CGSize) -> Void)?

    private var displayLink: CADisplayLink?

    public init(renderer: Renderer) {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            updateDrawableSize()
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let effectiveScale = max(scale, 1.0)
        metalLayer.contentsScale = effectiveScale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * effectiveScale,
            height: bounds.height * effectiveScale
        )
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        onDraw?(metalLayer, size)
    }

    deinit {
        stopDisplayLink()
    }
}
