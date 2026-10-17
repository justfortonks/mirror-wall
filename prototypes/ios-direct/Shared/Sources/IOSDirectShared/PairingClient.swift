import Foundation
import Network

/// Pairing cannot send media. Success waits for the Mac's pairDone acknowledgement.
public final class PairingClient {
    private let channel: RadioChannel
    private var challenged = false, receivedGrant = false, complete = false
    public var onState: ((String) -> Void)?
    public var onProgress: ((PairingProgress) -> Void)?
    public var onPaired: ((DeviceCredential) -> Void)?
    private var credential: DeviceCredential?
    public init(endpoint: NWEndpoint, invitation: PairingInvitation, install: UUID, label: String, model: String,
                store: PairingKeyStore, log: RadioLog? = nil) {
        channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(identities: [(invitation.identity, invitation.key)])), log: log)
        channel.onReady = { [weak self] in self?.progress(.awaitingApproval) }
        channel.onMessage = { [weak self] message in
            guard let self else { return }
            switch message {
            case .authChallenge(let nonce):
                guard !self.challenged else { throw RadioError.protocolViolation("duplicate challenge") }
                self.challenged = true
                self.channel.send(.authResponse(invitation.identity, PairCrypto.proof(key: invitation.key, nonce: nonce,
                    rid: invitation.rid, identity: invitation.identity)))
                self.channel.send(.pairRequest(install: install, label: String(label.prefix(60)), model: String(model.prefix(60))))
            case .pairGrant(let credential):
                guard self.challenged, !self.receivedGrant, credential.rid == invitation.rid else { throw RadioError.protocolViolation("invalid grant") }
                do { try store.save(credential) }
                catch { self.channel.close("Pairing failed: this phone could not save its credential"); return }
                self.receivedGrant = true; self.credential = credential
                self.progress(.finishing)
                self.channel.send(.pairDone)
                self.channel.queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, !self.complete, !self.channel.closed else { return }
                    self.channel.close("Pairing failed: Mac did not confirm the saved pairing within 4 seconds")
                }
            case .pairDenied: self.channel.close(Date() >= invitation.expires ? PairingInvitationError.expired.description : "Denied on Mac or pairing invitation ended")
            case .bye("paired"):
                guard self.receivedGrant, let credential = self.credential else { throw RadioError.protocolViolation("grant required") }
                self.complete = true; self.onPaired?(credential); self.channel.close("paired")
            default: throw RadioError.protocolViolation("unexpected pairing message")
            }
        }
        channel.onClosed = { [weak self] reason in
            guard let self else { return }
            if !self.complete, let credential = self.credential,
               (try? store.credential(rid: invitation.rid))?.deviceID == credential.deviceID { try? store.delete(account: invitation.rid.uuidString) }
            let failure: String
            if reason.hasPrefix("Denied") || reason.hasPrefix("This pairing code has expired") || reason.hasPrefix("Pairing ") { failure = reason }
            else { failure = "Pairing failed: wrong code, handshake failed, or Mac disconnected" }
            self.progress(self.complete ? .paired : .failed(failure))
        }
        channel.onTick = { [weak self] in
            if Date() > invitation.expires.addingTimeInterval(30) { self?.channel.close(PairingInvitationError.expired.description) }
        }
    }
    public func start() {
        progress(.connecting); channel.start()
        channel.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.challenged else { return }; self.channel.close("pairing handshake timeout")
        }
    }
    private func progress(_ progress: PairingProgress) { onState?(progress.message); onProgress?(progress) }
    /// Completion runs after closure and provisional-key cleanup on the channel queue.
    public func cancel(completion: (() -> Void)? = nil) {
        channel.queue.async { self.channel.close("Pairing cancelled"); completion?() }
    }
    deinit { channel.connection.cancel() }
}
