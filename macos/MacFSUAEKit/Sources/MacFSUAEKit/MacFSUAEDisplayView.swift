import AppKit
import CMacFSUAEEngine
import CoreGraphics
import MetalKit
import SwiftUI

@MainActor
public struct MacFSUAEInputControls {
    public let key: (UInt16, Bool) -> Bool
    public let mouseMove: (Int32, Int32) -> Bool
    public let mouseButton: (UInt32, Bool) -> Bool

    public init(key: @escaping (UInt16, Bool) -> Bool,
                mouseMove: @escaping (Int32, Int32) -> Bool,
                mouseButton: @escaping (UInt32, Bool) -> Bool) {
        self.key = key
        self.mouseMove = mouseMove
        self.mouseButton = mouseButton
    }

    public static let local = MacFSUAEInputControls(
        key: { MacFSUAEEngineQueueKey($0, $1 ? 1 : 0) != 0 },
        mouseMove: { MacFSUAEEngineQueueMouseMove($0, $1) != 0 },
        mouseButton: { MacFSUAEEngineQueueMouseButton($0, $1 ? 1 : 0) != 0 })
}

public struct MacFSUAEDisplayView: NSViewRepresentable {
    private let source: MacFSUAEFrameSource
    private let capturesMouse: Bool
    private let capturesMouseOnFocus: Bool
    private let controls: MacFSUAEInputControls?

    public init(source: MacFSUAEFrameSource, capturesMouse: Bool = true,
                capturesMouseOnFocus: Bool = false,
                controls: MacFSUAEInputControls? = .local) {
        self.source = source
        self.capturesMouse = capturesMouse
        self.capturesMouseOnFocus = capturesMouseOnFocus
        self.controls = controls
    }

    public func makeCoordinator() -> MacFSUAEMetalRenderer {
        MacFSUAEMetalRenderer(source: source)
    }

    public func makeNSView(context: Context) -> MTKView {
        let view: MTKView
        if let controls {
            let inputView = MacFSUAEInputView(controls: controls)
            inputView.capturesMouse = capturesMouse
            inputView.capturesMouseOnFocus = capturesMouseOnFocus
            view = inputView
        } else {
            view = MTKView()
        }
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.025, green: 0.028, blue: 0.027, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.setAccessibilityLabel(controls == nil ? "Amiga spectator display" : "Amiga display")
        return view
    }

    public func updateNSView(_ nsView: MTKView, context: Context) {
        (nsView as? MacFSUAEInputView)?.capturesMouse = capturesMouse
        (nsView as? MacFSUAEInputView)?.capturesMouseOnFocus = capturesMouseOnFocus
    }
}

private final class MacFSUAEInputView: MTKView {
    private let controls: MacFSUAEInputControls
    var capturesMouse = true {
        didSet {
            if !capturesMouse { setMouseCaptured(false) }
        }
    }
    var capturesMouseOnFocus = false
    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var isMouseCaptured = false
    private var isCursorHidden = false
    private var pressedKeys: [UInt16: UInt16] = [:]

    init(controls: MacFSUAEInputControls) {
        self.controls = controls
        super.init(frame: .zero, device: nil)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        MainActor.assumeIsolated {
            NotificationCenter.default.removeObserver(self)
            setMouseCaptured(false)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        setMouseCaptured(false)
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFocusChanged),
            name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowFocusChanged),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuDidBeginTracking),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        window.acceptsMouseMovedEvents = true
        updateTrackingAreas()
        if capturesMouse && capturesMouseOnFocus {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isKeyWindow == true else { return }
                self.window?.makeFirstResponder(self)
                self.setMouseCaptured(true)
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            NotificationCenter.default.removeObserver(self)
            releaseKeys()
            setMouseCaptured(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved,
                      .mouseEnteredAndExited, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if !isMouseCaptured { isMouseInside = false }
        super.mouseExited(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let wasCaptured = isMouseCaptured
        captureMouseIfPossible()
        if wasCaptured && controls.mouseButton(0, true) { return }
        if wasCaptured { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if isMouseCaptured && controls.mouseButton(0, false) { return }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let wasCaptured = isMouseCaptured
        captureMouseIfPossible()
        if wasCaptured && controls.mouseButton(2, true) { return }
        if wasCaptured { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if isMouseCaptured && controls.mouseButton(2, false) { return }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if isMouseCaptured && event.buttonNumber == 2 {
            setMouseCaptured(false)
            return
        }
        window?.makeFirstResponder(self)
        let wasCaptured = isMouseCaptured
        captureMouseIfPossible()
        if wasCaptured && controls.mouseButton(1, true) { return }
        if wasCaptured { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if isMouseCaptured && controls.mouseButton(1, false) { return }
        super.otherMouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if handleMouseMotion(event) { return }
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if handleMouseMotion(event) { return }
        super.mouseDragged(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if handleMouseMotion(event) { return }
        super.rightMouseDragged(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if handleMouseMotion(event) { return }
        super.otherMouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat, pressedKeys[event.keyCode] == nil,
              let target = MacFSUAEKeyboardMapping.shared.target(for: event.keyCode) else { return }
        pressedKeys[event.keyCode] = target
        if !controls.key(target, true) {
            pressedKeys.removeValue(forKey: event.keyCode)
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let target = pressedKeys.removeValue(forKey: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        if !controls.key(target, false) {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let target = MacFSUAEKeyboardMapping.shared.target(for: event.keyCode) else {
            super.flagsChanged(with: event)
            return
        }
        if event.keyCode == 57 {
            _ = controls.key(target, true)
            _ = controls.key(target, false)
            return
        }

        let isPressed = CGEventSource.keyState(
            .combinedSessionState, key: CGKeyCode(event.keyCode))
        if isPressed {
            guard pressedKeys[event.keyCode] == nil else { return }
            if controls.key(target, true) {
                pressedKeys[event.keyCode] = target
            } else {
                super.flagsChanged(with: event)
            }
        } else if let pressed = pressedKeys.removeValue(forKey: event.keyCode) {
            _ = controls.key(pressed, false)
        }
    }

    private func handleMouseMotion(_ event: NSEvent) -> Bool {
        guard isMouseCaptured else { return false }
        let deltaX = Int32(min(63, max(-63, event.deltaX)).rounded())
        let deltaY = Int32(min(63, max(-63, event.deltaY)).rounded())
        guard deltaX != 0 || deltaY != 0 else { return true }
        return controls.mouseMove(deltaX, deltaY)
    }

    private func captureMouseIfPossible() {
        if capturesMouse && isMouseInside && window?.isKeyWindow == true {
            setMouseCaptured(true)
        }
    }

    private func setMouseCaptured(_ captured: Bool) {
        guard captured != isMouseCaptured else { return }
        isMouseCaptured = captured
        if captured {
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            isCursorHidden = true
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            releaseKeys()
            _ = controls.mouseButton(0, false)
            _ = controls.mouseButton(1, false)
            _ = controls.mouseButton(2, false)
            if isCursorHidden {
                NSCursor.unhide()
                isCursorHidden = false
            }
        }
    }

    @objc private func windowFocusChanged() {
        if window?.isKeyWindow == true {
            if capturesMouse && capturesMouseOnFocus {
                window?.makeFirstResponder(self)
                setMouseCaptured(true)
            }
        } else {
            releaseKeys()
            setMouseCaptured(false)
        }
    }

    @objc private func menuDidBeginTracking() {
        setMouseCaptured(false)
        releaseKeys()
    }

    private func releaseKeys() {
        for key in pressedKeys.values { _ = controls.key(key, false) }
        pressedKeys.removeAll()
    }
}

public final class MacFSUAEMetalRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice

    private struct Vertex {
        var position: SIMD2<Float>
        var texture: SIMD2<Float>
    }

    private let source: MacFSUAEFrameSource
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var frame: MacFSUAEFrame?
    private var sequence: UInt64 = 0

    public init(source: MacFSUAEFrameSource) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is unavailable")
        }
        self.device = device
        self.queue = queue
        self.source = source

        let library = try! device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct Vertex { float2 position; float2 texture; };
            struct Raster { float4 position [[position]]; float2 texture; };
            vertex Raster fsuae_vertex(const device Vertex *vertices [[buffer(0)]],
                                       uint id [[vertex_id]]) {
                return {float4(vertices[id].position, 0, 1), vertices[id].texture};
            }
            fragment float4 fsuae_fragment(Raster in [[stage_in]],
                                           texture2d<float> image [[texture(0)]]) {
                constexpr sampler nearest(mag_filter::nearest, min_filter::linear);
                return image.sample(nearest, in.texture);
            }
            """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fsuae_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "fsuae_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        updateTexture()
        guard let frame, let texture,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let vertices = makeVertices(frame: frame, drawableSize: view.drawableSize)
        encoder.setRenderPipelineState(pipeline)
        vertices.withUnsafeBytes {
            encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func updateTexture() {
        guard let next = source.latest(after: sequence) else { return }
        if texture?.width != next.width || texture?.height != next.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: next.width, height: next.height, mipmapped: false)
            descriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: descriptor)
        }
        next.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture?.replace(region: MTLRegionMake2D(0, 0, next.width, next.height),
                             mipmapLevel: 0, withBytes: base, bytesPerRow: next.stride)
        }
        frame = next
        sequence = next.sequence
    }

    private func makeVertices(frame: MacFSUAEFrame, drawableSize: CGSize) -> [Vertex] {
        let crop = frame.crop.isEmpty
            ? CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            : frame.crop
        let sourceAspect = frame.isRTG ? crop.width / crop.height : 4.0 / 3.0
        let viewAspect = drawableSize.width / max(drawableSize.height, 1)
        let x = Float(min(1, sourceAspect / viewAspect))
        let y = Float(min(1, viewAspect / sourceAspect))
        let left = Float(crop.minX / CGFloat(frame.width))
        let right = Float(crop.maxX / CGFloat(frame.width))
        let top = Float(crop.minY / CGFloat(frame.height))
        let bottom = Float(crop.maxY / CGFloat(frame.height))
        return [
            Vertex(position: [-x, -y], texture: [left, bottom]),
            Vertex(position: [ x, -y], texture: [right, bottom]),
            Vertex(position: [-x,  y], texture: [left, top]),
            Vertex(position: [ x,  y], texture: [right, top]),
        ]
    }
}
