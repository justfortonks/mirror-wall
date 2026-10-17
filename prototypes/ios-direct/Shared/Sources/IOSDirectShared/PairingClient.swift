import Foundation
import Network

/// Pairing cannot send media. Success waits for the Mac's pairDone acknowledgement.
public final class PairingClient {
    private let channel: RadioChannel
    private var challenged = false, receivedGrant = false, complete = false
    public var onState: ((String) -> Void)?
    public var onPaired: ((DeviceCredential) -> Void)?
    private var credential: DeviceCredential?
    public init(endpoint: NWEndpoint, invitation: PairingInvitation, install: UUID, label: String, model: String,
                store: PairingKeyStore, log: RadioLog? = nil) {
        channel = RadioChannel(NWConnection(to: endpoint, using: RadioTLS.parameters(identities: [(invitation.identity, invitation.key)])), log: log)
        channel.onReady = { [weak self] in self?.onState?("Waiting for approval on Mac") }
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
                try store.save(credential); self.receivedGrant = true; self.credential = credential
                self.channel.send(.pairDone)
            case .pairDenied: self.channel.close(Date() >= invitation.expires ? "Expired pairing code" : "Denied on Mac or pairing invitation ended")
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
            self.onState?(self.complete ? "Paired" : (reason.hasPrefix("Denied") || reason.hasPrefix("Expired")) ? reason : "Wrong code / handshake failed, or invitation expired")
        }
        channel.onTick = { [weak self] in
            if Date() > invitation.expires.addingTimeInterval(30) { self?.channel.close("Expired pairing code") }
        }
    }
    public func start() {
        channel.start()
        channel.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.challenged else { return }; self.channel.close("pairing handshake timeout")
        }
    }
    public func cancel() { channel.queue.async { self.channel.close("pairing cancelled") } }
    deinit { channel.connection.cancel() }
}
