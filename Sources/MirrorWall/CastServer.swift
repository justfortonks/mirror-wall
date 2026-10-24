import Foundation
import MirrorCore
import Network

/// Listens on a slot's cast port for Android phones running the Mirror Wall Cast app, and
/// advertises the slot on the network (`_mirrorwall._tcp`) under its name so the app can list it.
///
/// Everything here runs on the server's own queue; callbacks arrive there too.
final class CastServer {
    static let serviceType = "_mirrorwall._tcp"

    let port: UInt16
    private let name: String
    let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [CastConnection] = []
    private let onConnection: (CastConnection) -> Void
    private var advertised = true

    /// Whether the slot is listed on the network. A listing withdrawn while a phone is connected
    /// doesn't affect that phone, which already has the address. Safe from any queue.
    func setAdvertised(_ on: Bool) {
        queue.async { [self] in
            guard on != advertised else { return }
            advertised = on
            listener?.service = on ? service : nil
        }
    }

    private var service: NWListener.Service { NWListener.Service(name: name, type: Self.serviceType) }

    init(port: UInt16, name: String, onConnection: @escaping (CastConnection) -> Void) {
        self.port = port
        self.name = name
        self.onConnection = onConnection
        queue = DispatchQueue(label: "Mirror Wall cast \(port)", qos: .userInteractive)
    }

    func start(onReady: (() -> Void)? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            options.noDelay = true
        }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.stateUpdateHandler = { state in
            if case .ready = state { onReady?() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        queue.sync {
            listener.service = advertised ? service : nil
            self.listener = listener
        }
        listener.start(queue: queue)
    }

    /// Stops listening and drops any phone that's connected.
    /// Run off the main queue. An intentional stop gets a chance to reach the companion.
    func stop(endingSharing: Bool = false) {
        let sent = DispatchGroup()
        queue.sync {
            listener?.cancel()
            listener = nil
            if endingSharing {
                for connection in connections where connection.isAccepted {
                    sent.enter()
                    connection.finishSharing { sent.leave() }
                }
            }
        }
        if endingSharing { _ = sent.wait(timeout: .now() + 1) }
        queue.sync {
            for connection in connections { connection.close() }
            connections = []
        }
    }

    var listeningPort: UInt16? { queue.sync { listener?.port?.rawValue } }

    private func accept(_ nwConnection: NWConnection) {
        guard connections.count < 8 else { nwConnection.cancel(); return }
        let connection = CastConnection(nwConnection, queue: queue)
        connections.append(connection)
        connection.onEnded = { [weak self, weak connection] in
            self?.connections.removeAll { $0 === connection }
        }
        onConnection(connection)
        connection.start()
    }
}

/// One phone's connection. Set the callbacks before it starts; they run on the server's queue.
final class CastConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let reader = CastReader()
    private var ended = false

    /// Each message from the phone.
    var onMessage: ((CastMessage) -> Void)?
    /// Once, when the connection ends for any reason.
    var onClose: (() -> Void)?
    /// Once, after onClose, for whoever keeps this connection alive (the server or the relay client).
    var onEnded: (() -> Void)?

    /// The phone's address, for the log; a relayed phone is "relay <host>".
    var remoteDescription: String { via ?? "\(connection.endpoint)" }
    private let via: String?
    /// Bytes that arrived with the relay's handshake, ahead of the Cast stream.
    private var initialData: Data

    /// Set (on the queue) once the slot has taken this phone; its video is ignored until then.
    private(set) var isAccepted = false

    /// `initialData` and `via` are for a connection the relay handed over, already started.
    init(_ connection: NWConnection, queue: DispatchQueue, initialData: Data = Data(), via: String? = nil) {
        self.connection = connection
        self.queue = queue
        self.initialData = initialData
        self.via = via
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.end()
            default: break
            }
        }
        if connection.state == .setup { connection.start(queue: queue) }
        if !initialData.isEmpty {
            let data = initialData
            initialData = Data()
            do {
                for message in try reader.push(Array(data)) { onMessage?(message) }
            } catch {
                close()
                return
            }
        }
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.isAccepted else { return }
            self.close()
        }
        receive()
    }

    /// Tells the phone it has the slot. Safe from any queue.
    func accept(_ welcome: CastWelcome) {
        queue.async { [self] in
            guard !ended else { return }
            isAccepted = true
            transmit(.welcome(welcome))
        }
    }

    /// Turns the phone away with a reason it shows, then hangs up. Safe from any queue.
    func refuse(_ reason: String) {
        queue.async { [self] in
            guard !ended else { return }
            connection.send(content: Data(CastMessage.busy(CastBusy(reason: reason)).encoded()), completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }
    }

    /// Call on the connection queue. Completion means the message was processed by the socket.
    func finishSharing(completion: @escaping () -> Void) {
        guard !ended else { completion(); return }
        connection.send(content: Data(CastMessage.stopSharing.encoded()), completion: .contentProcessed { _ in completion() })
    }

    /// Hangs up. Call on the queue.
    func close() {
        connection.cancel()
        end()
    }

    /// Sends a message to the phone. Safe from any queue.
    func send(_ message: CastMessage) {
        queue.async { [self] in
            guard !ended else { return }
            transmit(message)
        }
    }

    private func transmit(_ message: CastMessage) {
        connection.send(content: Data(message.encoded()), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.reader.push(Array(data)) {
                        self.onMessage?(message)
                    }
                } catch {
                    self.close()
                    return
                }
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        onClose?()
        onEnded?()
        onMessage = nil
        onClose = nil
    }
}
