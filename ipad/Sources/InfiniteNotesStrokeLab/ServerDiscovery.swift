import Foundation
import Combine

/// Browsing and delegate callbacks run on the main run loop.
final class ServerDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Server: Identifiable {
        let id: String
        let name: String
        let address: String
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var message = "Looking for nearby servers…"
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]

    private func key(_ service: NetService) -> String {
        "\(service.name).\(service.type)\(service.domain)"
    }

    func start() {
        stop()
        message = "Looking for nearby servers…"
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: "_infinite-notes._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        for service in services.values {
            service.delegate = nil
            service.stop()
        }
        services.removeAll()
        servers.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let id = key(service)
        guard services[id] == nil else { return }
        services[id] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let id = key(service)
        let removed = services.removeValue(forKey: id)
        removed?.delegate = nil
        removed?.stop()
        servers.removeAll { $0.id == id }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let id = key(sender)
        guard services[id] === sender,
              let hostname = sender.hostName, !hostname.isEmpty,
              (1...65535).contains(sender.port) else { return }
        var components = URLComponents()
        components.scheme = "http"
        components.host = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        components.port = sender.port
        guard let address = components.url?.absoluteString else { return }
        servers.removeAll { $0.id == id }
        servers.append(Server(id: id, name: sender.name, address: address))
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services[key(sender)] === sender else { return }
        message = "A server could not be reached. Try Refresh or enter its address below."
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        message = "Discovery is unavailable. Check Local Network permission in iPad Settings, or enter an address below."
    }
}
