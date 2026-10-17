import Foundation
import Security

public protocol PairingKeyStore: AnyObject {
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

public final class MemoryPairingKeyStore: PairingKeyStore {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func write(_ data: Data, account: String) throws { lock.lock(); defer { lock.unlock() }; items[account] = data }
    public func delete(account: String) throws { lock.lock(); defer { lock.unlock() }; items.removeValue(forKey: account) }
}

public final class KeychainPairingKeyStore: PairingKeyStore {
    public static let service = "com.justfortonks.mirrorwall.iosdirectpoc"
    public init() {}
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func read(account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw storageError(status) }
        return data
    }
    public func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw storageError(added) }
        } else if status != errSecSuccess { throw storageError(status) }
    }
    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw storageError(status) }
    }
    private func storageError(_ status: OSStatus) -> RadioError { .protocolViolation("Keychain operation failed (\(status))") }
}

public extension PairingKeyStore {
    func credential(rid: UUID) throws -> DeviceCredential? {
        guard let data = try read(account: rid.uuidString) else { return nil }
        let value = try JSONDecoder().decode(DeviceCredential.self, from: data)
        guard value.rid == rid, value.deviceKey.count == 32 else { throw RadioError.protocolViolation("Invalid stored pairing") }
        return value
    }
    func save(_ credential: DeviceCredential) throws {
        guard credential.deviceKey.count == 32 else { throw RadioError.protocolViolation("Invalid device key") }
        try write(JSONEncoder().encode(credential), account: credential.rid.uuidString)
    }
}

public struct ReceiverIdentity: Codable, Equatable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = String(name.prefix(60)) }
    public static func load(at url: URL, name: String) throws -> ReceiverIdentity {
        if FileManager.default.fileExists(atPath: url.path) { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        let identity = Self(name: name)
        try JSONEncoder().encode(identity).write(to: url, options: .atomic); return identity
    }
}
public struct PairedDevice: Codable, Identifiable, Equatable {
    public let id: UUID
    public let installID: UUID
    public let label: String, model: String
    public let created: Date
    public var lastSeen: Date?
    public init(id: UUID, installID: UUID, label: String, model: String, created: Date = Date()) {
        self.id = id; self.installID = installID; self.label = label; self.model = model; self.created = created
    }
}

/// Receiver queue owns metadata; secrets are only persisted through the key store.
public final class ReceiverPairingStore {
    public let identity: ReceiverIdentity
    public let keys: PairingKeyStore
    public private(set) var devices: [PairedDevice]
    private let metadataURL: URL?
    public init(identity: ReceiverIdentity, keys: PairingKeyStore, metadataURL: URL? = nil) throws {
        self.identity = identity; self.keys = keys; self.metadataURL = metadataURL
        if let url = metadataURL, FileManager.default.fileExists(atPath: url.path) {
            devices = try JSONDecoder().decode([PairedDevice].self, from: Data(contentsOf: url))
        } else { devices = [] }
    }
    func identities() throws -> [(String, Data)] {
        try devices.compactMap { device in
            guard let key = try key(device.id) else { return nil }; return ("dev:\(device.id.uuidString)", key)
        }
    }
    func key(_ id: UUID) throws -> Data? {
        guard devices.contains(where: { $0.id == id }), let data = try keys.read(account: id.uuidString), data.count == 32 else { return nil }
        return data
    }
    public func add(_ device: PairedDevice, key: Data) throws {
        guard key.count == 32 else { throw RadioError.protocolViolation("Invalid device key") }
        try keys.write(key, account: device.id.uuidString)
        let old = devices; devices.removeAll { $0.id == device.id }; devices.append(device)
        do { try persist() } catch { devices = old; try? keys.delete(account: device.id.uuidString); throw error }
    }
    public func forget(_ id: UUID) throws {
        // Delete first: even a metadata write failure must not restore access.
        try keys.delete(account: id.uuidString); devices.removeAll { $0.id == id }; try persist()
    }
    func seen(_ id: UUID) throws {
        if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].lastSeen = Date(); try persist() }
    }
    private func persist() throws {
        if let url = metadataURL { try JSONEncoder().encode(devices).write(to: url, options: .atomic) }
    }
}
