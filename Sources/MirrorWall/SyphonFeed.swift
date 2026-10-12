import CoreGraphics
import CoreVideo
import Foundation

#if canImport(Syphon)
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

    private let lock = NSLock()
    // Guarded by `lock`.
    private var waiting: CVImageBuffer?
    private var busy = false

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
            lock.unlock()
            send(image)
        }
    }

    private func send(_ image: CVImageBuffer) {
        // Sent even with no OBS source listening: the server keeps the latest frame, so a source
        // added later shows the current picture at once, even if the phone's screen is still.
        guard let bgra = convert(image), let textureCache else { return }
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
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
        guard let output, VTPixelTransferSessionTransferImage(transfer, from: image, to: output) == noErr else { return nil }
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
    func publish(_ image: CVImageBuffer) {}
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
