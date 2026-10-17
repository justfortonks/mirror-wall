import Foundation
import CryptoKit
import Security
import Network

public enum PairCrypto {
    public static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RadioError.protocolViolation("secure random unavailable") }
        return data
    }
    public static func proof(key: Data, nonce: Data, rid: UUID, identity: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: nonce + Data((rid.uuidString + identity + "mwiospoc-auth-v1").utf8), using: SymmetricKey(data: key)))
    }
    public static func verify(_ proof: Data, key: Data, nonce: Data, rid: UUID, identity: String) -> Bool {
        let expected = Self.proof(key: key, nonce: nonce, rid: rid, identity: identity)
        guard proof.count == expected.count else { return false }
        return zip(proof, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct DeviceCredential: Codable, Equatable {
    public let deviceID: UUID
    public let deviceKey: Data
    public let rid: UUID
    public let receiverName: String
    public init(deviceID: UUID, deviceKey: Data, rid: UUID, receiverName: String) {
        self.deviceID = deviceID; self.deviceKey = deviceKey; self.rid = rid; self.receiverName = receiverName
    }
    public var tlsIdentity: String { "dev:\(deviceID.uuidString)" }
    public func authenticate(_ message: RadioMessage, on channel: RadioChannel) throws -> Bool {
        guard case .authChallenge(let nonce) = message else { return false }
        guard !channel.active else { throw RadioError.protocolViolation("duplicate challenge") }
        channel.send(.authResponse(deviceID.uuidString, PairCrypto.proof(key: deviceKey, nonce: nonce, rid: rid, identity: deviceID.uuidString)))
        return true
    }
}

public enum RadioTLS {
    public static let service = "_mwiospoc._tcp"
    // Set only after the real loopback cipher probe. Both endpoints reject other suites at ready.
    public static let cipherSuite: UInt16 = 0xCCAC
    public static func parameters(identities: [(String, Data)], cipher: UInt16 = cipherSuite) -> NWParameters {
        let tls = NWProtocolTLS.Options(), tcp = NWProtocolTCP.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: cipher)!)
        // Resumption must not outlive revocation or a single-use invitation.
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        for (name, key) in identities {
            let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(name.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        }
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp); parameters.includePeerToPeer = true
        return parameters
    }
    public static func parameters(credential: DeviceCredential) -> NWParameters {
        parameters(identities: [(credential.tlsIdentity, credential.deviceKey)])
    }
    public static func browserParameters() -> NWParameters {
        let parameters = NWParameters(); parameters.includePeerToPeer = true; return parameters
    }
}
