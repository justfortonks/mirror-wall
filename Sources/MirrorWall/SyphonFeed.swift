import CoreGraphics
import CoreVideo
import Foundation
import MirrorCore

#if canImport(Syphon)
import CoreImage
import Metal
import Syphon
import VideoToolbox

/// Publishes a slot's picture to OBS through Syphon, so an OBS "Syphon Client" source gets each
/// frame directly instead of capturing a window. OBS lists it as "[Mirror Wall] <name>".
///
/// Pictures arrive from the slot's renderer as they're shown. Each is converted from the
/// decoder's YUV to BGRA (what Syphon carries) on the GPU and handed over as a Metal texture.
/// While one is being converted, newer ones replace older ones waiting, so a busy GPU drops
/// frames rather than falling behind.
final class SyphonFeed {
    static let isAvailable = true

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let server: SyphonMetalServer
    private var textureCache: CVMetalTextureCache?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private let queue = DispatchQueue(label: "Mirror Wall Syphon", qos: .userInteractive)
    // Framing, used on `queue` only.
    private lazy var ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var overlay: PhoneBezelDrawing.Overlay?
    private var overlayFor: OverlayKey?
    private var framedPool: CVPixelBufferPool?
    private var framedPoolSize = (width: 0, height: 0)

    private struct OverlayKey: Equatable {
        let style: BezelStyle
        let aspect: Double?
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    private var waiting: CVImageBuffer?
    private var busy = false
    private var framesOn = true
    private var frameStyle: BezelStyle?
    private var frameAspect: Double?

    /// The phone frame drawn around each picture, with see-through corners; nil for the bare
    /// picture. Applies from the next picture sent.
    var bezelStyle: BezelStyle? {
        get { lock.lock(); defer { lock.unlock() }; return frameStyle }
        set { lock.lock(); frameStyle = newValue; lock.unlock() }
    }

    func setBezel(style: BezelStyle?, portraitAspect: Double?) {
        lock.withLock { frameStyle = style; frameAspect = portraitAspect }
    }

    /// Whether the phone's frames get through. Turned off the moment the phone leaves, so its
    /// last few frames, still being decoded or held for Smoother Motion, can't land on top of
    /// the standby picture. Stills sent with `publish` always get through.
    var passesFrames: Bool {
        get { lock.lock(); defer { lock.unlock() }; return framesOn }
        set { lock.lock(); framesOn = newValue; lock.unlock() }
    }

    /// Hands one of the phone's frames to OBS, unless `passesFrames` is off.
    func publishFrame(_ image: CVImageBuffer) {
        lock.lock()
        let on = framesOn
        lock.unlock()
        if on { publish(image) }
    }

    /// Nil if this Mac has no Metal device (every Mac that runs macOS 14 does).
    init?(name: String) {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        server = SyphonMetalServer(name: name, device: device, options: nil)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
    }

    /// The name OBS lists it under. It only changes when the slot's window title does, and OBS
    /// sources set to the old name then lose it, as a window capture would.
    var name: String {
        get { server.name ?? "" }
        set { if newValue != server.name { server.name = newValue } }
    }

    /// Hands a picture to OBS. Called from whatever thread shows the picture; returns at once.
    func publish(_ image: CVImageBuffer) {
        lock.lock()
        waiting = image
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func stop() {
        queue.sync { server.stop() }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let image = waiting else {
                busy = false
                lock.unlock()
                return
            }
            waiting = nil
            let style = frameStyle
            let aspect = frameAspect
            lock.unlock()
            send(image, style: style, aspect: aspect)
        }
    }

    private func send(_ image: CVImageBuffer, style: BezelStyle?, aspect: Double?) {
        // Sent even with no OBS source listening: the server keeps the latest frame, so a source
        // added later shows the current picture at once, even if the phone's screen is still.
        guard var bgra = convert(image), let textureCache else { return }
        if let style {
            guard let framed = framed(bgra, style: style, aspect: aspect) else { return }
            bgra = framed
        }
        let width = CVPixelBufferGetWidth(bgra)
        let height = CVPixelBufferGetHeight(bgra)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, bgra, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        server.publishFrameTexture(texture, on: commandBuffer, imageRegion: NSRect(x: 0, y: 0, width: width, height: height), flipped: true)
        // Keep the pixel buffer and its texture alive until the GPU has copied them.
        commandBuffer.addCompletedHandler { _ in _ = (bgra, cvTexture) }
        commandBuffer.commit()
    }

    /// The picture as BGRA in an IOSurface-backed buffer that Metal can read.
    private func convert(_ image: CVImageBuffer) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA { return image }
        guard let transfer else { return nil }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard let output = Self.makeBuffer(from: &pool, size: &poolSize, width: width, height: height),
              VTPixelTransferSessionTransferImage(transfer, from: image, to: output) == noErr else { return nil }
        return output
    }

    /// The picture inside its phone frame, on the GPU, with see-through corners.
    private func framed(_ picture: CVPixelBuffer, style: BezelStyle, aspect: Double?) -> CVPixelBuffer? {
        let key = OverlayKey(style: style, aspect: aspect, width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture))
        if overlayFor != key {
            overlay = PhoneBezelDrawing.overlay(style: style, width: key.width, height: key.height, portraitAspect: key.aspect)
            overlayFor = key
        }
        guard let overlay,
              let output = Self.makeBuffer(from: &framedPool, size: &framedPoolSize, width: overlay.image.width, height: overlay.image.height)
        else { return nil }
        // Core Image counts y from the bottom.
        let screen = CIImage(cvPixelBuffer: picture)
            .transformed(by: CGAffineTransform(translationX: CGFloat(overlay.left), y: CGFloat(overlay.bottom)))
        let phone = CIImage(cgImage: overlay.image).composited(over: screen)
        ciContext.render(phone, to: output, bounds: CGRect(x: 0, y: 0, width: overlay.image.width, height: overlay.image.height), colorSpace: nil)
        return output
    }

    /// A BGRA buffer Metal can read, from a pool kept for that size.
    private static func makeBuffer(from pool: inout CVPixelBufferPool?, size: inout (width: Int, height: Int), width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || size != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            size = (width, height)
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        return output
    }
}

#else

/// Stand-in when the app is built without Syphon (no Vendor/Syphon.xcframework): the OBS feed
/// option is hidden.
final class SyphonFeed {
    static let isAvailable = false
    init?(name: String) { return nil }
    var name = ""
    var passesFrames = true
    var bezelStyle: BezelStyle?
    func setBezel(style: BezelStyle?, portraitAspect: Double?) { bezelStyle = style }
    func publish(_ image: CVImageBuffer) {}
    func publishFrame(_ image: CVImageBuffer) {}
    func stop() {}
}

#endif

/// A still picture (the standby picture) as a BGRA pixel buffer, so it can go down a slot's
/// OBS feed like a phone's frame.
func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    let width = image.width
    let height = image.height
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ]
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}
