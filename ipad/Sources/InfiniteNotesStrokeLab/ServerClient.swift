import Foundation

final class ServerClient: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .failed(let message): return message
            }
        }
    }

    var onStatus: (@MainActor (Status) -> Void)?
    var onTextMessage: (@MainActor (String) -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let sendQueue = DispatchQueue(label: "InfiniteNotesNative.WebSocketSend")
    private var explicitlyDisconnected = false

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func connect(baseURL: URL, clientID: String) {
        disconnect(notify: false)
        explicitlyDisconnected = false

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            notifyStatus(.failed("Invalid server address"))
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "role", value: "ipad"),
            URLQueryItem(name: "clientId", value: clientID),
        ]
        guard let socketURL = components.url else {
            notifyStatus(.failed("Invalid WebSocket address"))
            return
        }

        notifyStatus(.connecting)
        let task = session.webSocketTask(with: socketURL)
        // Defensive compatibility with older servers that still send a full
        // notebook snapshot through one WebSocket message. New servers use HTTP
        // for full-state transfers, but this prevents an immediate reconnect loop.
        task.maximumMessageSize = 64 * 1024 * 1024
        self.task = task
        task.resume()
        receiveNext(from: task)
    }

    func disconnect() {
        disconnect(notify: true)
    }

    private func disconnect(notify: Bool) {
        explicitlyDisconnected = true
        let oldTask = task
        task = nil
        oldTask?.cancel(with: .goingAway, reason: nil)
        if notify {
            notifyStatus(.disconnected)
        }
    }

    func sendJSONObject(_ object: [String: Any]) {
        sendQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: object, options: [])
                guard let text = String(data: data, encoding: .utf8) else { return }
                self.task?.send(.string(text)) { [weak self] error in
                    if let error {
                        self?.notifyStatus(.failed(error.localizedDescription))
                    }
                }
            } catch {
                self.notifyStatus(.failed("Could not encode message"))
            }
        }
    }

    func ping() {
        let milliseconds = Date().timeIntervalSince1970 * 1000
        sendJSONObject(["type": "ping", "clientTime": milliseconds])
    }

    private func receiveNext(from task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task, task === self.task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    Task { @MainActor in
                        self.onTextMessage?(text)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        Task { @MainActor in
                            self.onTextMessage?(text)
                        }
                    }
                @unknown default:
                    break
                }
                self.receiveNext(from: task)
            case .failure(let error):
                if !self.explicitlyDisconnected {
                    self.notifyStatus(.failed(error.localizedDescription))
                }
            }
        }
    }

    private func notifyStatus(_ status: Status) {
        Task { @MainActor [weak self] in
            self?.onStatus?(status)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        notifyStatus(.connected)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === task else { return }
        task = nil
        if !explicitlyDisconnected {
            notifyStatus(.disconnected)
        }
    }
}
