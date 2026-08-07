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
    private let heartbeatQueue = DispatchQueue(label: "InfiniteNotesNative.WebSocketHeartbeat")
    private let stateLock = NSLock()
    private var heartbeatTimer: DispatchSourceTimer?
    private var explicitlyDisconnected = false
    private static let heartbeatInterval: TimeInterval = 8

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func connect(baseURL: URL, clientID: String) {
        disconnect(notify: false)
        withConnectionState { explicitlyDisconnected = false }

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
        task.maximumMessageSize = 256 * 1024 * 1024
        withConnectionState { self.task = task }
        task.resume()
        receiveNext(from: task)
    }

    func disconnect() {
        disconnect(notify: true)
    }

    private func disconnect(notify: Bool) {
        let oldTask = withConnectionState { () -> URLSessionWebSocketTask? in
            explicitlyDisconnected = true
            defer { task = nil }
            return task
        }
        stopHeartbeat()
        oldTask?.cancel(with: .goingAway, reason: nil)
        if notify {
            notifyStatus(.disconnected)
        }
    }

    func sendJSONObject(_ object: [String: Any]) {
        // Capture the socket that owned this message. Previously queued work read
        // self.task only when it eventually executed, allowing packets from a dead
        // connection to spill into a newly opened socket and trigger another close.
        guard let targetTask = withConnectionState({ task }) else { return }
        sendQueue.async { [weak self, weak targetTask] in
            guard let self, let targetTask,
                  self.withConnectionState({ self.task === targetTask }) else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: object, options: [])
                guard let text = String(data: data, encoding: .utf8) else { return }
                targetTask.send(.string(text)) { [weak self, weak targetTask] error in
                    guard let self, let targetTask, let error else { return }
                    self.failCurrentConnection(targetTask, message: error.localizedDescription)
                }
            } catch {
                self.failCurrentConnection(targetTask, message: "Could not encode message")
            }
        }
    }

    func ping() {
        let milliseconds = Date().timeIntervalSince1970 * 1000
        sendJSONObject(["type": "ping", "clientTime": milliseconds])
    }

    private func startHeartbeat(for targetTask: URLSessionWebSocketTask) {
        heartbeatQueue.async { [weak self, weak targetTask] in
            guard let self, let targetTask else { return }
            self.heartbeatTimer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: self.heartbeatQueue)
            timer.schedule(
                deadline: .now() + Self.heartbeatInterval,
                repeating: Self.heartbeatInterval,
                leeway: .milliseconds(500)
            )
            timer.setEventHandler { [weak self, weak targetTask] in
                guard let self, let targetTask,
                      self.withConnectionState({ self.task === targetTask }) else { return }
                // A real WebSocket ping keeps enterprise Wi-Fi/NAT mappings alive
                // without triggering a notebook sync or application message.
                targetTask.sendPing { [weak self, weak targetTask] error in
                    guard let self, let targetTask, let error else { return }
                    self.failCurrentConnection(
                        targetTask,
                        message: "Heartbeat failed: \(error.localizedDescription)"
                    )
                }
            }
            self.heartbeatTimer = timer
            timer.resume()
        }
    }

    private func stopHeartbeat() {
        heartbeatQueue.async { [weak self] in
            guard let self else { return }
            self.heartbeatTimer?.cancel()
            self.heartbeatTimer = nil
        }
    }

    private func receiveNext(from task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task,
                  self.withConnectionState({ self.task === task }) else { return }
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
                self.failCurrentConnection(task, message: error.localizedDescription)
            }
        }
    }

    private func withConnectionState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func failCurrentConnection(_ failedTask: URLSessionWebSocketTask, message: String) {
        let shouldNotify = withConnectionState { () -> Bool in
            guard task === failedTask else { return false }
            task = nil
            return !explicitlyDisconnected
        }
        guard shouldNotify else { return }
        stopHeartbeat()
        failedTask.cancel(with: .goingAway, reason: nil)
        notifyStatus(.failed(message))
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
        guard withConnectionState({ task === webSocketTask }) else { return }
        startHeartbeat(for: webSocketTask)
        notifyStatus(.connected)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let shouldNotify = withConnectionState { () -> Bool in
            guard webSocketTask === task else { return false }
            task = nil
            return !explicitlyDisconnected
        }
        if shouldNotify {
            stopHeartbeat()
            let detail = reason.flatMap { String(data: $0, encoding: .utf8) }
            let suffix = detail.map { ": \($0)" } ?? ""
            notifyStatus(.failed("Connection closed (\(closeCode.rawValue))\(suffix)"))
        }
    }
}
