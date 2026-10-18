import Foundation

/// Channel queues classify the cause before closing. Diagnostic strings are never
/// used as revocation authority or as the reconnect decision.
public enum RadioCloseCause: Equatable {
    case linkLoss
    case authentication
    case admissionDeadline(tlsReady: Bool, preparing: Bool = true)
    case rejected(String)
    case revoked // Only from a bye revoked received inside verified TLS.
    case peerEnded, localStop, protocolFailure
}
public enum PairingRejection: String, Codable {
    case notAccepted, revoked
    public var message: String {
        switch self {
        case .notAccepted: return "This Mac didn't accept this phone. It may have been forgotten on the Mac."
        case .revoked: return "This Mac forgot this phone. Pair again to reconnect."
        }
    }
    public func apply(to store: PairingKeyStore, rid: UUID, deviceID: UUID? = nil) throws {
        // An ambiguous TLS failure retains the credential. Only authenticated
        // revocation authorizes its automatic deletion.
        if self == .revoked {
            if let deviceID, try store.credential(rid: rid)?.deviceID != deviceID { return }
            try store.delete(account: rid.uuidString)
        }
    }
}
public enum ClientSessionAction: Equatable {
    case retry, stop, unreachable
    case pairingRejected(PairingRejection)
}
public struct ClientSessionPolicy {
    public static let unreachableMessage = "Can't reach this Mac. If it was forgotten on the Mac, pair again."
    public private(set) var everWelcomed = false
    public private(set) var welcomedThisAttempt = false
    public private(set) var consecutiveStalls = 0
    private var recovering = false
    public init() {}
    public mutating func beginAttempt() { welcomedThisAttempt = false }
    public mutating func welcomed() {
        everWelcomed = true; welcomedThisAttempt = true; consecutiveStalls = 0; recovering = false
    }
    public mutating func receiverUnavailable() { consecutiveStalls = 0 }
    public mutating func action(for cause: RadioCloseCause, receiverDiscovered: Bool) -> ClientSessionAction {
        switch cause {
        case .authentication: return .pairingRejected(.notAccepted)
        case .revoked: return .pairingRejected(.revoked)
        case .admissionDeadline:
            // Neither discovery nor a silent TLS timeout proves that the peer
            // rejected a credential. Count only consecutive discovered stalls.
            consecutiveStalls = receiverDiscovered ? consecutiveStalls + 1 : 0
            recovering = true
            return consecutiveStalls >= 3 ? .unreachable : .retry
        case .rejected(let reason):
            if reason.lowercased() == "unpaired" {
                return .pairingRejected(.notAccepted)
            }
            return .stop
        case .linkLoss:
            consecutiveStalls = 0
            return everWelcomed || recovering ? .retry : .stop
        case .peerEnded, .localStop, .protocolFailure: return .stop
        }
    }
}

/// Backoff and browse epochs are shared by both network modes. A result from an
/// earlier browser (even the same service name/rid) can never satisfy a retry.
public struct ReconnectBackoff {
    private var delay = 0.5
    public init() {}
    public mutating func next() -> Double { defer { delay = min(4, delay * 2) }; return delay }
}
public struct FreshReceiverResults<Endpoint> {
    public private(set) var generation = UUID()
    private var results: [UUID: Endpoint] = [:]
    public init() {}
    @discardableResult public mutating func restart() -> UUID {
        generation = UUID(); results.removeAll(); return generation
    }
    @discardableResult public mutating func update(_ results: [UUID: Endpoint], generation: UUID) -> Bool {
        guard generation == self.generation else { return false }
        self.results = results; return true
    }
    public func endpoint(for rid: UUID) -> Endpoint? { results[rid] }
}

/// UI state shared by Radio and Stream; never confers authentication. Kept apart
/// from the credential so an ambiguous failure can be marked without deleting it.
public struct ReceiverPairingStatus: Codable {
    private var failures: [UUID: PairingRejection] = [:]
    public init() {}
    public subscript(_ rid: UUID) -> PairingRejection? { failures[rid] }
    public mutating func reject(_ rid: UUID, reason: PairingRejection) { failures[rid] = reason }
    public mutating func clear(_ rid: UUID) { failures.removeValue(forKey: rid) }
    /// One-time migration: old builds persisted preparing timeouts as rejection.
    /// This clears UI hints only; a connection still requires TLS and HMAC.
    public mutating func clearLegacyReachabilityRejections() { failures = failures.filter { $0.value != .notAccepted } }
    public func label(rid: UUID, hasCredential: Bool) -> String {
        if let failure = failures[rid] { return failure == .notAccepted ? "Pairing rejected" : "Not paired" }
        return hasCredential ? "Paired" : "Not paired"
    }
}

/// One window per verified device. Rebinding invalidates old session callbacks;
/// disconnect retains the mapping/window, while a manual close removes it.
public struct VideoWindowSessions {
    private var sessions: [UUID: UUID] = [:] // Verified deviceID -> current sessionID.
    public init() {}
    @discardableResult public mutating func bind(device: UUID, session: UUID) -> Bool {
        let reusesWindow = sessions[device] != nil
        sessions[device] = session; return reusesWindow
    }
    public var count: Int { sessions.count }
    public func device(for session: UUID) -> UUID? { sessions.first { $0.value == session }?.key }
    public mutating func close(device: UUID) { sessions.removeValue(forKey: device) }
}
