import Foundation
import Network

enum BackendTransportKind: String, CaseIterable {
    case unixDomainSocket = "unix_domain_socket"
    case loopbackTcp = "loopback_tcp"

    var displayName: String {
        switch self {
        case .unixDomainSocket:
            return "Unix Domain Socket"
        case .loopbackTcp:
            return "Loopback TCP"
        }
    }
}

enum SidecarEndpoint: Equatable {
    case unix(path: String)
    case loopbackTcp(host: String, port: UInt16)

    var transportKind: BackendTransportKind {
        switch self {
        case .unix:
            return .unixDomainSocket
        case .loopbackTcp:
            return .loopbackTcp
        }
    }

    var endpointValue: String {
        switch self {
        case .unix(let path):
            return path
        case .loopbackTcp(_, let port):
            return String(port)
        }
    }

    var logDescription: String {
        switch self {
        case .unix(let path):
            return "unix://\(path)"
        case .loopbackTcp(let host, let port):
            return "tcp://\(host):\(port)"
        }
    }
}

final class FramedSidecarTransport {
    private enum FrameType {
        static let json: UInt8 = 1
        static let audio: UInt8 = 2
    }

    private let endpoint: SidecarEndpoint
    private let queue = DispatchQueue(label: "speakboard.sidecar.transport")

    private var connection: NWConnection?
    private var pendingConnectCompletion: ((Error?) -> Void)?
    private var receiveBuffer = Data()
    private var didBecomeReady = false
    private var didNotifyDisconnect = false

    var onText: ((String) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    init(endpoint: SidecarEndpoint) {
        self.endpoint = endpoint
    }

    var endpointDescription: String {
        endpoint.logDescription
    }

    func connect(completion: @escaping (Error?) -> Void) {
        queue.async {
            self.pendingConnectCompletion = completion
            self.receiveBuffer.removeAll(keepingCapacity: true)
            self.didBecomeReady = false
            self.didNotifyDisconnect = false

            let connection = self.makeConnection()
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleStateUpdate(state)
            }
            connection.start(queue: self.queue)
        }
    }

    func close() {
        queue.async {
            self.pendingConnectCompletion = nil
            self.receiveBuffer.removeAll(keepingCapacity: false)
            self.didBecomeReady = false
            self.connection?.cancel()
            self.connection = nil
        }
    }

    func sendJSONText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        sendFrame(type: FrameType.json, payload: data)
    }

    func sendAudioChunk(_ data: Data) {
        sendFrame(type: FrameType.audio, payload: data)
    }

    private func makeConnection() -> NWConnection {
        switch endpoint {
        case .unix(let path):
            return NWConnection(to: .unix(path: path), using: .tcp)
        case .loopbackTcp(let host, let port):
            return NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
        }
    }

    private func handleStateUpdate(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !didBecomeReady else { return }
            didBecomeReady = true
            let completion = pendingConnectCompletion
            pendingConnectCompletion = nil
            DispatchQueue.main.async { completion?(nil) }
            receiveNextChunk()

        case .failed(let error):
            let completion = pendingConnectCompletion
            pendingConnectCompletion = nil
            DispatchQueue.main.async { completion?(error) }
            handleDisconnect(error)

        case .cancelled:
            let completion = pendingConnectCompletion
            pendingConnectCompletion = nil
            DispatchQueue.main.async { completion?(nil) }
            handleDisconnect(nil)

        default:
            break
        }
    }

    private func receiveNextChunk() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainFrames()
            }
            if let error {
                self.handleDisconnect(error)
                return
            }
            if isComplete {
                self.handleDisconnect(nil)
                return
            }
            self.receiveNextChunk()
        }
    }

    private func drainFrames() {
        while receiveBuffer.count >= 5 {
            let payloadLength =
                (UInt32(receiveBuffer[1]) << 24) |
                (UInt32(receiveBuffer[2]) << 16) |
                (UInt32(receiveBuffer[3]) << 8) |
                UInt32(receiveBuffer[4])
            let frameLength = 5 + Int(payloadLength)
            guard receiveBuffer.count >= frameLength else { return }

            let frameType = receiveBuffer[0]
            let payload = receiveBuffer.subdata(in: 5..<frameLength)
            receiveBuffer.removeSubrange(0..<frameLength)

            guard frameType == FrameType.json,
                  let text = String(data: payload, encoding: .utf8) else {
                continue
            }
            DispatchQueue.main.async { self.onText?(text) }
        }
    }

    private func sendFrame(type: UInt8, payload: Data) {
        queue.async {
            guard let connection = self.connection else { return }

            var frame = Data([type])
            var length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: &length) { rawBuffer in
                frame.append(contentsOf: rawBuffer)
            }
            frame.append(payload)

            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { error in
                    if let error {
                        self.handleDisconnect(error)
                    }
                }
            )
        }
    }

    private func handleDisconnect(_ error: Error?) {
        guard !didNotifyDisconnect else { return }
        didNotifyDisconnect = true
        didBecomeReady = false
        pendingConnectCompletion = nil
        receiveBuffer.removeAll(keepingCapacity: false)
        connection = nil
        DispatchQueue.main.async { self.onDisconnect?(error) }
    }
}
