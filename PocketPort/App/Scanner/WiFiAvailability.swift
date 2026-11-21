import Combine
import Foundation
import Network

@MainActor
final class WiFiAvailability: ObservableObject {
    @Published private(set) var isAvailable: Bool?
    private let monitor: NWPathMonitor?

    init(testOverride: Bool? = nil) {
        isAvailable = testOverride
        guard testOverride == nil else {
            monitor = nil
            return
        }

        // Observe the Wi-Fi path even when another interface is the default.
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isAvailable = available
            }
        }
        monitor.start(queue: DispatchQueue(label: "PocketPort.WiFiAvailability"))
    }

    deinit {
        monitor?.cancel()
    }
}
