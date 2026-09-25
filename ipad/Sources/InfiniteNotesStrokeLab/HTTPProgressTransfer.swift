import Foundation

/// Collects an HTTP response while reporting the bytes delivered to the decoder.
/// URLSession transparently decompresses gzip responses; callers can use an
/// uncompressed-size response header for an accurate JSON progress denominator.
final class HTTPProgressTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias ProgressHandler = (Int64, HTTPURLResponse) -> Void
    typealias CompletionHandler = (Data?, URLResponse?, Error?) -> Void

    private let onProgress: ProgressHandler
    private let onCompletion: CompletionHandler
    private var session: URLSession?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var lastProgressTime = 0.0

    init(onProgress: @escaping ProgressHandler, onCompletion: @escaping CompletionHandler) {
        self.onProgress = onProgress
        self.onCompletion = onCompletion
    }

    func start(_ request: URLRequest) -> URLSessionDataTask {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        task.resume()
        return task
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if let http = self.response { onProgress(0, http) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgressTime >= 0.2, let response {
            lastProgressTime = now
            onProgress(Int64(body.count), response)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let response { onProgress(Int64(body.count), response) }
        onCompletion(error == nil ? body : nil, response, error)
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }
}
