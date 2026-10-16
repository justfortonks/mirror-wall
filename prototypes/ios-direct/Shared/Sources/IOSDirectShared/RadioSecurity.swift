import Foundation
import CryptoKit
import Security
import Network

public struct RadioCode {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    public let bytes: Data
    public init(bytes: Data) throws {
        guard bytes.count == 10 else { throw RadioError.protocolViolation("code must contain 80 bits") }
        self.bytes = bytes
    }
    public static func generate() throws -> RadioCode {
        var bytes = Data(count: 10)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 10, $0.baseAddress!) }
        guard status == errSecSuccess else { throw RadioError.protocolViolation("random generation failed: \(status)") }
        return try RadioCode(bytes: bytes)
    }
    public init(_ input: String) throws {
        let characters = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard characters.utf8.count == 16 else { throw RadioError.protocolViolation("Enter 16 Crockford-base32 characters") }
        var bytes = Data(), accumulator: UInt32 = 0, bits = 0
        for char in characters.utf8 {
            // Crockford input aliases; output is always canonical.
            let canonical: UInt8 = char == 79 ? 48 : (char == 73 || char == 76 ? 49 : char)
            guard let value = Self.alphabet.firstIndex(of: canonical) else { throw RadioError.protocolViolation("Invalid code character") }
            accumulator = (accumulator << 5) | UInt32(value); bits += 5
            if bits >= 8 { bits -= 8; bytes.append(UInt8(truncatingIfNeeded: accumulator >> bits)) }
        }
        try self.init(bytes: bytes)
    }
    public var formatted: String {
        var result = [UInt8](), accumulator: UInt32 = 0, bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte); bits += 8
            while bits >= 5 { bits -= 5; result.append(Self.alphabet[Int((accumulator >> bits) & 31)]) }
        }
        return stride(from: 0, to: 16, by: 4).map { String(decoding: result[$0..<$0 + 4], as: UTF8.self) }.joined(separator: "-")
    }
    public var psk: Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes),
            salt: Data("mwiospoc-g2-psk-v1".utf8), info: Data(), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

public enum RadioTLS {
    public static let service = "_mwiospoc._tcp"
    public static func parameters(code: RadioCode) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let psk = code.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("mwiospoc-g2".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
    public static func browserParameters() -> NWParameters {
        // Discovery only. Every actual connection/listener uses parameters(code:).
        let parameters = NWParameters(); parameters.includePeerToPeer = true; return parameters
    }
}
