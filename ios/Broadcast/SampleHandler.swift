import Foundation
import ImageIO
import MirrorCore
import ReplayKit

/// The broadcast upload extension: iOS starts it when the person taps Start Broadcast in Mirror
/// Wall Cast (or Control Center › Screen Recording › Mirror Wall Cast), and hands it every frame
/// of the screen. It sends them to the slot the app picked, as the Android app does.
final class SampleHandler: RPBroadcastSampleHandler {
    private var link: CastLink?
    private let encoder = ScreenEncoder()
    private var turns = -1
    private var welcomed = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let target = Shared.target else {
            fail("Pick a Mirror Wall slot in the Mirror Wall Cast app first, then start sharing again.")
            return
        }
        let hello = CastHello(protocol: castProtocolVersion, name: Shared.phoneName, model: Shared.modelCode,
                              deviceID: Shared.deviceID, shareID: UUID().uuidString)
        Shared.log("Sharing to \(target.name) (\(target.hosts.joined(separator: ", "))\(target.hasRelay ? "; relay \(target.relay!)" : ""))", from: "broadcast")
        setStatus(sharing: true, "Connecting to \(target.name)…")

        let link = CastLink(target: target, hello: hello)
        link.onEvent = { [weak self] event in self?.handle(event, target: target) }
        encoder.onAccessUnit = { [weak link] micros, annexB, keyframe in
            link?.send(.video(captureMicros: micros, accessUnit: annexB), isVideo: true, keyframe: keyframe)
        }
        self.link = link
        link.start()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, welcomed, let link else { return }
        let now = Self.turns(of: sampleBuffer)
        if now != turns {
            turns = now
            link.send(.orientation(now))
            encoder.requestKeyframe()
        }
        if link.needsKeyframe { encoder.requestKeyframe() }
        encoder.encode(sampleBuffer, turns: now)
    }

    override func broadcastPaused() {
        link?.send(.paused)
        Shared.log("Paused", from: "broadcast")
    }

    override func broadcastResumed() {
        link?.send(.resumed)
        encoder.requestKeyframe()
        Shared.log("Resumed", from: "broadcast")
    }

    override func broadcastFinished() {
        Shared.log("Stopped sharing", from: "broadcast")
        link?.finish()
        encoder.stop()
        setStatus(sharing: false, "Stopped sharing.")
    }

    // MARK: Events

    private func handle(_ event: CastLink.Event, target: Shared.Target) {
        switch event {
        case .connecting(let text):
            welcomed = false
            setStatus(sharing: true, text)
        case .welcomed(let welcome):
            encoder.maxFrameRate = min(60, max(15, welcome.maxFrameRate))
            encoder.requestKeyframe()
            turns = -1
            welcomed = true
            Shared.log("Welcomed by \(welcome.slot), up to \(welcome.maxFrameRate) fps", from: "broadcast")
            setStatus(sharing: true, "Sharing to \(welcome.slot)")
        case .refused(let reason):
            fail(reason)
        case .stoppedByPresenter:
            fail("The presenter stopped sharing from the Mac.")
        case .lost(let why):
            fail("Lost \(target.name): \(why)")
        }
    }

    /// Ends the broadcast with a reason iOS shows the person.
    private func fail(_ reason: String) {
        Shared.log("Ending: \(reason)", from: "broadcast")
        setStatus(sharing: false, reason)
        encoder.stop()
        finishBroadcastWithError(NSError(domain: "MirrorWallCast", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]))
    }

    private func setStatus(sharing: Bool, _ text: String) {
        Shared.status = Shared.Status(sharing: sharing, text: text, at: Date())
    }

    /// ReplayKit's orientation attachment as Mirror Wall Cast's quarter turns left from upright
    /// (Android's display rotation: 1 is sideways with the phone's top on the left).
    static func turns(of sampleBuffer: CMSampleBuffer) -> Int {
        guard let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value) else { return 0 }
        switch orientation {
        case .left, .leftMirrored: return 3
        case .right, .rightMirrored: return 1
        case .down, .downMirrored: return 2
        default: return 0
        }
    }
}
