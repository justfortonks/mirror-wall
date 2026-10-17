import Foundation

public enum PairingProgress: Equatable {
    case connecting, awaitingApproval, finishing
    case paired, failed(String)
    public var terminal: Bool {
        switch self { case .paired, .failed: return true; default: return false }
    }
    public var message: String {
        switch self {
        case .connecting: return "Connecting to the Mac…"
        case .awaitingApproval: return "Waiting for approval on Mac"
        case .finishing: return "Mac allowed this phone; saving pairing…"
        case .paired: return "Paired"
        case .failed(let reason): return reason
        }
    }
}

/// One attempt owns discovery and TLS. Terminal states release ownership, and
/// callbacks from a cancelled/replaced attempt cannot overwrite a newer result.
public struct PairingAttempt {
    public private(set) var id: UUID?
    public private(set) var message = ""
    public var busy: Bool { id != nil }
    public init() {}
    @discardableResult public mutating func begin() -> UUID? {
        guard id == nil else { message = "Pairing already in progress; finish or cancel it before scanning again"; return nil }
        let id = UUID(); self.id = id; message = "Finding the Mac from this code…"; return id
    }
    @discardableResult public mutating func update(_ progress: PairingProgress, attempt: UUID) -> Bool {
        guard id == attempt else { return false }
        message = progress.message
        if progress.terminal { id = nil }
        return true
    }
    public mutating func cancel() { id = nil; message = "Pairing cancelled" }
}

/// Non-secret UI cache. Authentication always reads the credential itself from
/// the store; refreshing this value only changes the Paired/Not paired label.
public struct PairingCredentialPresence {
    public private(set) var receivers = Set<UUID>()
    public init() {}
    public mutating func refresh(_ rid: UUID, store: PairingKeyStore) throws {
        if try store.credential(rid: rid) != nil { receivers.insert(rid) }
        else { receivers.remove(rid) }
    }
}
