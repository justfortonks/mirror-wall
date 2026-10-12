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
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [CastConnection] = []
    private let onConnection: (CastConnection) -> Void

    init(port: UInt16, name: String, onConnection: @escaping (CastConnection) -> Void) {
        self.port = port
        self.name = name
        self.onConnection = onConnection
        queue = DispatchQueue(label: "Mirror Wall cast \(port)", qos: .userInteractive)
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let options = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            options.noDelay = true
        }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: name, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Stops listening and drops any phone that's connected.
    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections { connection.close() }
            connections = []
        }
    }

    private func accept(_ nwConnection: NWConnection) {
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
    fileprivate var onEnded: (() -> Void)?

    /// The phone's address, for the log.
    var remoteDescription: String { "\(connection.endpoint)" }

    /// Set (on the queue) once the slot has taken this phone; its video is ignored until then.
    private(set) var isAccepted = false

    fileprivate init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    fileprivate func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.end()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    /// Tells the phone it has the slot. Safe from any queue.
    func accept(_ welcome: CastWelcome) {
        queue.async { [self] in
            guard !ended else { return }
            isAccepted = true
            send(.welcome(welcome))
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

    /// Hangs up. Call on the queue.
    func close() {
        connection.cancel()
        end()
    }

    private func send(_ message: CastMessage) {
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
