import Foundation

/// Called on one session's RadioChannel queue. Implementations must bound async decode
/// work and suppress obsolete callbacks after reconfiguration/close. No global decoder.
public protocol RadioVideoConsumer: AnyObject {
    func configure(_ config: VideoConfig) throws
    func receive(_ frame: VideoAccessUnit, completion: @escaping (VideoDecodeStatus) -> Void)
    func discontinuity(_ reason: String)
    func tick()
    func close(_ reason: String)
}
