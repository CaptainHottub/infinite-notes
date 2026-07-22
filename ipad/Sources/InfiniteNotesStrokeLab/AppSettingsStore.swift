import Combine
import Foundation

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var configuration: NativeAppConfiguration {
        didSet { persist() }
    }

    private let defaultsKey = "native.appConfiguration.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(NativeAppConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }
    }

    func resetToDefaults() {
        configuration = .default
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
