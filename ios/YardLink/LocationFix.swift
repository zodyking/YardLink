import CoreLocation

/// Where the phone is, sent along with a pickup or an arrival so the time
/// card can place the stop.
struct GpsFix: Encodable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
}

/// One-shot position. The work never waits on it: a declined permission or a
/// slow fix answers nil and the pickup goes ahead without a position.
@MainActor
final class LocationFix: NSObject, CLLocationManagerDelegate {
    static let shared = LocationFix()

    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<GpsFix?, Never>] = []
    private var timeout: Task<Void, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func current(timeoutSeconds: Double = 6) async -> GpsFix? {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            return nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            manager.requestLocation()
        }

        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    private func finish(_ fix: GpsFix?) {
        timeout?.cancel()
        timeout = nil
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume(returning: fix) }
    }

    private func authorizationChanged() {
        guard !waiting.isEmpty else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last.map { location in
            GpsFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracyMeters: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
            )
        }
        Task { @MainActor in self.finish(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
