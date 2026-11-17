import CoreLocation
import Foundation
import MapKit

/// How far the drop-off is and how long it will take.
///
/// The real answer comes from Apple Maps, which is built into the phone: free,
/// no key, and it knows live traffic and the roads a truck would drive.
/// When Apple Maps cannot answer (no signal, too many requests) the phone works
/// it out itself: the straight line stretched by a road factor, and the
/// driver's own recent speed once they are moving.
enum TripEstimate {
    /// Roads run about a third longer than the crow flies.
    static let roadFactor = 1.3
    /// 30 mph, in metres per second, until the phone has seen the driver move.
    static let fallbackSpeed = 13.4
    /// Below this the driver is stopped or crawling and the reading says little.
    static let movingSpeed = 2.0
    private static let slowest = 6.0
    private static let fastest = 30.0

    struct Route {
        let meters: Double
        let seconds: TimeInterval
    }

    /// Ask Apple Maps for the driving distance and time, with today's traffic.
    static func route(fromLatitude lat: Double, longitude lon: Double, to site: ArrivalWatch.WatchedSite) async -> Route? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: site.latitude, longitude: site.longitude)
        ))
        request.transportType = .automobile
        request.departureDate = Date()
        guard let answer = try? await MKDirections(request: request).calculateETA() else { return nil }
        return Route(meters: answer.distance, seconds: answer.expectedTravelTime)
    }

    static func straightMeters(fromLatitude lat: Double, longitude lon: Double, to site: ArrivalWatch.WatchedSite) -> Double {
        CLLocation(latitude: lat, longitude: lon).distance(from: CLLocation(latitude: site.latitude, longitude: site.longitude))
    }

    /// Smooth the driver's speed so a red light does not double the time.
    static func smoothed(_ average: Double?, with reading: Double) -> Double? {
        guard reading >= movingSpeed else { return average }
        let clamped = min(fastest, max(slowest, reading))
        guard let average else { return clamped }
        return average * 0.8 + clamped * 0.2
    }

    static func seconds(forMeters meters: Double, speed: Double?) -> TimeInterval {
        max(60, meters / (speed ?? fallbackSpeed))
    }
}
