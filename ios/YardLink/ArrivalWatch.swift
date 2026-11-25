import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Arrivals that answer themselves.
///
/// While a trip is live the phone watches a circle around where the trip is
/// headed. Crossing in tells the server, which asks the driver whether they
/// have arrived and records it anyway after ten minutes — stamped at the
/// crossing, not at the answer. Region monitoring wakes the app even when it
/// has been closed, so the crossing is reported either way.
@MainActor
final class ArrivalWatch: NSObject, ObservableObject {
    static let shared = ArrivalWatch()

    /// The question waiting on the driver, shown as a banner in the app.
    @Published var question: ArrivalQuestion?

    private let manager = CLLocationManager()
    private var watching: WatchedSite?
    private var reporting = false
    /// Sites found from their address because nobody pinned them, kept so the
    /// phone asks the geocoder once per site and not once per fix.
    private var found: [String: WatchedSite] = [:]
    /// The site the phone has already told the server it is inside, so one
    /// arrival is reported once.
    private var reportedInside: String?

    struct WatchedSite: Equatable {
        let locationId: String
        let name: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
    }

    private var regionIdentifier: String { "yardlink.arrival" }

    /// Ask for the permission that lets a crossing wake the app. Called once
    /// the driver is on a trip, so the question has an obvious reason.
    func requestAlwaysIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Watch where the live trip is headed. A site the dispatcher pinned is
    /// used as it stands; one without a pin is looked up from its address, so
    /// the driver still gets the arrival question and the distance home.
    func watch(destination: NamedPlace?) {
        guard let destination else {
            watch(nil)
            return
        }
        if let pinned = destination.arrivalCircle {
            watch(pinned)
            return
        }
        guard let id = destination.id, let address = destination.postalAddress else {
            watch(nil)
            return
        }
        if let already = found[id] {
            watch(already)
            return
        }
        Task { [weak self] in
            guard let placemark = try? await CLGeocoder().geocodeAddressString(address).first,
                  let point = placemark.location?.coordinate else { return }
            let site = WatchedSite(
                locationId: id,
                name: destination.name ?? "this stop",
                latitude: point.latitude,
                longitude: point.longitude,
                radiusMeters: Double(destination.arrivalRadiusM ?? 180)
            )
            await MainActor.run {
                guard let self else { return }
                self.found[id] = site
                self.watch(site)
            }
        }
    }

    /// Watch the circle around where the live trip is headed, or stop watching.
    func watch(_ site: WatchedSite?) {
        if site == watching { return }
        for region in manager.monitoredRegions where region.identifier == regionIdentifier {
            manager.stopMonitoring(for: region)
        }
        watching = site
        reportedInside = nil
        guard let site else {
            stopTracking()
            return
        }
        requestAlwaysIfNeeded()
        startTracking()
        // Region monitoring is what wakes a closed app. Where the phone cannot
        // do it, the fixes below still catch the arrival while the app runs.
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: site.latitude, longitude: site.longitude),
            radius: max(80, min(site.radiusMeters, 2_000)),
            identifier: regionIdentifier
        )
        region.notifyOnEntry = true
        region.notifyOnExit = false
        manager.startMonitoring(for: region)
        // A driver already parked inside the circle never crosses it.
        manager.requestState(for: region)
    }

    /// Follow the phone along the drive, so the Lock Screen and Dynamic Island can
    /// show the distance left. A fix every 20 m — tight enough that the last
    /// stretch into a yard, where the distance left is smallest and matters
    /// most, still gets updates instead of going quiet.
    private func startTracking() {
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        // A paused feed never resumes on its own, which would freeze the
        // distance on the Lock Screen at whatever it last read.
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    private func stopTracking() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.pausesLocationUpdatesAutomatically = true
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    fileprivate func moved(latitude: Double, longitude: Double, speed: Double) {
        guard let site = watching else { return }
        TripActivityCenter.moved(latitude: latitude, longitude: longitude, speed: speed, site: site)

        // Pulling in counts even where region monitoring never fires: no
        // Always permission, a circle the phone declined to watch, or a driver
        // who was already parked inside it.
        let gap = CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: site.latitude, longitude: site.longitude))
        if gap <= max(80, site.radiusMeters) {
            guard reportedInside != site.locationId else { return }
            reportedInside = site.locationId
            Task { await reportCrossing(at: nil) }
        } else if gap > max(80, site.radiusMeters) * 1.5 {
            reportedInside = nil
        }
    }

    /// The driver answered the permission card: ask for the rest, and arm the
    /// watch that could not start without it.
    fileprivate func authorizationChanged() {
        requestAlwaysIfNeeded()
        guard let site = watching else { return }
        watching = nil
        watch(site)
    }

    /// Tell the server the phone is inside the circle.
    func reportCrossing(at fix: GpsFix?) async {
        guard !reporting, let api = AppModel.current?.api else { return }
        reporting = true
        defer { reporting = false }

        var position = fix
        if position == nil { position = await LocationFix.shared.current() }
        guard let position else { return }
        struct Crossing: Encodable {
            let latitude: Double
            let longitude: Double
            let accuracyMeters: Double?
            let at: String
        }
        let body = Crossing(
            latitude: position.latitude,
            longitude: position.longitude,
            accuracyMeters: position.accuracyMeters,
            at: ISO8601DateFormatter().string(from: Date())
        )
        guard let answer: ArrivalAnswer = try? await api.post("/api/arrivals", body: body) else { return }
        guard answer.asked, let arrival = answer.arrival else { return }
        question = arrival
        await raiseLocalQuestion(arrival)
    }

    /// Fetch whatever is still waiting — on launch, and when the app returns.
    func refresh() async {
        guard let api = AppModel.current?.api else { return }
        guard let open: OpenArrival = try? await api.get("/api/arrivals/open") else { return }
        question = open.arrival
    }

    /// Answer from the app or the lock screen.
    func answer(_ arrival: ArrivalQuestion, arrived: Bool) async {
        guard let api = AppModel.current?.api else { return }
        struct Answer: Encodable { let answer: String }
        let _: OkResult? = try? await api.post(
            "/api/arrivals/\(arrival.id)/answer",
            body: Answer(answer: arrived ? "yes" : "no")
        )
        if question?.id == arrival.id { question = nil }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [arrival.id])
    }

    /// The same question as a notification, for an employer with no push key.
    private func raiseLocalQuestion(_ arrival: ArrivalQuestion) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Arrived at \(arrival.locationName)?"
        content.body = "Yard Link will record the arrival in a few minutes unless you say otherwise."
        content.categoryIdentifier = ArrivalNotification.identifier
        content.sound = .default
        content.userInfo = ["screen": "arrival", "arrivalId": arrival.id]
        try? await center.add(UNNotificationRequest(identifier: arrival.id, content: content, trigger: nil))
    }
}

extension ArrivalWatch: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in ArrivalWatch.shared.authorizationChanged() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        // The time card's site circles belong to SiteWatch.
        guard region.identifier == "yardlink.arrival" else { return }
        Task { @MainActor in await ArrivalWatch.shared.reportCrossing(at: nil) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0 else { return }
        let latitude = last.coordinate.latitude
        let longitude = last.coordinate.longitude
        let speed = max(0, last.speed)
        Task { @MainActor in ArrivalWatch.shared.moved(latitude: latitude, longitude: longitude, speed: speed) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didDetermineState state: CLRegionState,
        for region: CLRegion
    ) {
        guard state == .inside, region.identifier == "yardlink.arrival" else { return }
        Task { @MainActor in await ArrivalWatch.shared.reportCrossing(at: nil) }
    }
}

/// The two answers Apple shows under the notification.
enum ArrivalNotification {
    static let identifier = "YARDLINK_ARRIVAL"
    static let arrived = "YARDLINK_ARRIVED"
    static let notYet = "YARDLINK_NOT_YET"

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: identifier,
            actions: [
                UNNotificationAction(identifier: arrived, title: "Yes, I'm here", options: []),
                UNNotificationAction(identifier: notYet, title: "Not yet", options: []),
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}

struct ArrivalQuestion: Decodable, Identifiable, Equatable {
    let id: String
    let locationName: String
    let enteredAt: String
    let autoAt: String
}

private struct ArrivalAnswer: Decodable {
    let asked: Bool
    let arrival: ArrivalQuestion?
}

private struct OpenArrival: Decodable {
    let arrival: ArrivalQuestion?
}
