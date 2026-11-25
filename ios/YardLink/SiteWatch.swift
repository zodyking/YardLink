import CoreLocation
import Foundation
import UIKit

/// Real in and out times for the time card.
///
/// The phone watches a circle around each of the company's pinned sites and
/// tells the server the moment it crosses into or out of one, stamped with
/// when it crossed rather than when anyone tapped. Region monitoring wakes the
/// app even when it is closed, so the times are caught with the phone in a
/// pocket. Only company sites are watched; nothing is sent between them.
@MainActor
final class SiteWatch: NSObject {
    static let shared = SiteWatch()

    struct Site: Codable, Equatable {
        let id: String
        let name: String
        let latitude: Double
        let longitude: Double
        let radiusM: Int?
    }

    private struct SitesPayload: Decodable { let sites: [Site] }

    /// A crossing waiting to reach the server. Kept on disk so one made with
    /// no signal is sent later instead of lost.
    private struct Crossing: Codable {
        let latitude: Double
        let longitude: Double
        let accuracyMeters: Double?
        let at: String
        let event: String
        let siteId: String
    }

    private let manager = CLLocationManager()
    private let defaults = UserDefaults.standard
    private let prefix = "yardlink.site."
    private let enabledKey = "site-watch-enabled"
    private let sitesKey = "site-watch-sites"
    private let pendingKey = "site-watch-pending"
    /// iOS watches at most 20 circles per app; one is the trip arrival watch.
    private let maxWatched = 18
    private var sites: [Site] = []
    private var sending = false

    private override init() {
        super.init()
        manager.delegate = self
        if let data = defaults.data(forKey: sitesKey), let saved = try? JSONDecoder().decode([Site].self, from: data) {
            sites = saved
        }
    }

    /// Called at launch, including a launch iOS makes in the background to
    /// deliver a crossing: having the manager and its delegate in place is
    /// what lets that crossing arrive.
    func resume() {
        guard defaults.bool(forKey: enabledKey) else { return }
        Task { await flush() }
    }

    /// Start for a signed-in driver: fetch the sites and watch the nearest.
    func start() async {
        defaults.set(true, forKey: enabledKey)
        ArrivalWatch.shared.requestAlwaysIfNeeded()
        await refreshSites()
        rearm()
        await flush()
    }

    /// Stop on sign-out, so nothing is watched or sent for the next person.
    func stop() {
        defaults.set(false, forKey: enabledKey)
        defaults.removeObject(forKey: sitesKey)
        defaults.removeObject(forKey: pendingKey)
        sites = []
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) {
            manager.stopMonitoring(for: region)
        }
        manager.stopMonitoringSignificantLocationChanges()
    }

    private var api: APIClient? {
        if let api = AppModel.current?.api { return api }
        return SharedStore.serverURL.map { APIClient(baseURL: $0) }
    }

    private func refreshSites() async {
        guard let api, let payload: SitesPayload = try? await api.get("/api/time-cards/sites") else { return }
        sites = payload.sites
        if let data = try? JSONEncoder().encode(sites) { defaults.set(data, forKey: sitesKey) }
    }

    /// Watch the sites closest to the phone. With more sites than iOS will
    /// watch at once, a big move picks the closest set again.
    private func rearm() {
        guard defaults.bool(forKey: enabledKey),
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let here = manager.location
        let nearest = sites
            .sorted { a, b in
                guard let here else { return a.id < b.id }
                return distance(here, a) < distance(here, b)
            }
            .prefix(maxWatched)
        let wanted = Set(nearest.map { prefix + $0.id })
        for region in manager.monitoredRegions where region.identifier.hasPrefix(prefix) && !wanted.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        let watched = Set(manager.monitoredRegions.map(\.identifier))
        for site in nearest where !watched.contains(prefix + site.id) {
            let region = CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: site.latitude, longitude: site.longitude),
                // Under about 100 m iOS crossings get unreliable.
                radius: max(100, min(Double(site.radiusM ?? 180), 1_000)),
                identifier: prefix + site.id
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
        }
        if sites.count > maxWatched {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    private func distance(_ here: CLLocation, _ site: Site) -> CLLocationDistance {
        here.distance(from: CLLocation(latitude: site.latitude, longitude: site.longitude))
    }

    fileprivate func crossed(_ identifier: String, entering: Bool, at moment: Date) {
        guard defaults.bool(forKey: enabledKey), identifier.hasPrefix(prefix) else { return }
        let siteId = String(identifier.dropFirst(prefix.count))
        guard let site = sites.first(where: { $0.id == siteId }) else { return }
        let fix = manager.location.flatMap { $0.horizontalAccuracy >= 0 ? $0 : nil }
        let crossing = Crossing(
            latitude: fix?.coordinate.latitude ?? site.latitude,
            longitude: fix?.coordinate.longitude ?? site.longitude,
            accuracyMeters: fix?.horizontalAccuracy,
            at: ISO8601DateFormatter().string(from: moment),
            event: entering ? "ENTER" : "EXIT",
            siteId: siteId
        )
        var pending = loadPending()
        pending.append(crossing)
        savePending(pending)
        Task { await flush() }
    }

    fileprivate func movedFar() {
        rearm()
    }

    private func loadPending() -> [Crossing] {
        guard let data = defaults.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([Crossing].self, from: data)) ?? []
    }

    private func savePending(_ pending: [Crossing]) {
        // A day's worth is plenty; older crossings stop mattering to the card.
        let kept = Array(pending.suffix(100))
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: pendingKey) }
    }

    /// Send waiting crossings in order. iOS gives a woken app only a few
    /// seconds, so the send asks for a little background time.
    private func flush() async {
        guard !sending, let api else { return }
        sending = true
        let task = UIApplication.shared.beginBackgroundTask(withName: "time-card-crossing")
        defer {
            sending = false
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
        var pending = loadPending()
        while let next = pending.first {
            do {
                let _: OkResult = try await api.post("/api/time-cards/ping", body: next)
            } catch let error as APIError where error.isSignedOut {
                stop()
                return
            } catch {
                return
            }
            pending.removeFirst()
            savePending(pending)
        }
    }
}

extension SiteWatch: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let identifier = region.identifier
        let now = Date()
        Task { @MainActor in SiteWatch.shared.crossed(identifier, entering: true, at: now) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        let now = Date()
        Task { @MainActor in SiteWatch.shared.crossed(identifier, entering: false, at: now) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in SiteWatch.shared.movedFar() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in SiteWatch.shared.rearm() }
    }
}
