import Foundation
import CryptoKit

public extension Data {
    var base64url: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64url: String, count: Int) {
        guard base64url.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - base64url.count % 4) % 4)),
              data.count == count, data.base64url == base64url else { return nil }
        self = data
    }
}

public enum PairingInvitationError: Error, Equatable, CustomStringConvertible {
    case expired, differentReceiver, invalidCode
    public var description: String {
        switch self {
        case .expired: return "This pairing code has expired — make a new one on the Mac"
        case .differentReceiver: return "This code is for a different Mac"
        case .invalidCode: return "Not a pairing code"
        }
    }
}

public struct PairingInvitation: Equatable {
    public let rid: UUID, tokenID: Data, secret: Data, expires: Date, name: String
    public init(rid: UUID, name: String, now: Date = Date()) throws {
        self.rid = rid; self.name = String(name.prefix(60)); tokenID = try PairCrypto.random(8)
        secret = try PairCrypto.random(32); expires = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 120)
    }
    public init(payload: String, expectedReceiverID: UUID? = nil, now: Date = Date()) throws {
        guard payload.utf8.count <= 2048, let url = URLComponents(string: payload), url.scheme == "mwiospoc", url.host == "pair",
              url.path.isEmpty, url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
              let items = url.queryItems, items.count == 6, Set(items.map(\.name)) == Set(["v", "rid", "tid", "sec", "exp", "name"]) else {
            throw PairingInvitationError.invalidCode
        }
        try self.init(fields: items, now: now)
        if let expectedReceiverID, rid != expectedReceiverID { throw PairingInvitationError.differentReceiver }
    }
    private init(fields: [URLQueryItem], now: Date) throws {
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
        guard values["v"] == "1" else { throw PairingInvitationError.invalidCode }
        guard let rid = values["rid"].flatMap(UUID.init(uuidString:)),
              let tokenID = Data(base64url: values["tid"] ?? "", count: 8),
              let secret = Data(base64url: values["sec"] ?? "", count: 32),
              let exp = Double(values["exp"] ?? ""), exp.isFinite, exp.rounded() == exp,
              let name = values["name"], !name.isEmpty, name.utf8.count <= 256 else {
            throw PairingInvitationError.invalidCode
        }
        guard exp >= now.timeIntervalSince1970 - 30 else { throw PairingInvitationError.expired }
        guard exp <= now.timeIntervalSince1970 + 150 else { throw PairingInvitationError.invalidCode }
        self.rid = rid; self.tokenID = tokenID; self.secret = secret; expires = Date(timeIntervalSince1970: exp); self.name = name
    }
    public var payload: String {
        var url = URLComponents(); url.scheme = "mwiospoc"; url.host = "pair"
        url.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "rid", value: rid.uuidString),
            URLQueryItem(name: "tid", value: tokenID.base64url), URLQueryItem(name: "sec", value: secret.base64url),
            URLQueryItem(name: "exp", value: String(Int64(expires.timeIntervalSince1970))), URLQueryItem(name: "name", value: name)]
        return url.string!
    }
    public var identity: String { "pair:\(tokenID.base64url)" }
    public var key: Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("mwiospoc-pair-v1".utf8),
            info: Data(rid.uuidString.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
}
