import CoreLocation
import Foundation

/// How far the drop-off is and how long it will take, worked out on the phone
/// from the driver's position and the drop-off address — no routing service.
///
/// Distance is the straight line between the two points stretched by a road
/// factor, because roads are never straight. Time uses the driver's own recent
/// speed once they are moving, and a steady town-driving speed before that.
enum TripEstimate {
    /// Roads run about a third longer than the crow flies.
    static let roadFactor = 1.3
    /// 30 mph, in metres per second, until the phone has seen the driver move.
    static let fallbackSpeed = 13.4
    /// Below this the driver is stopped or crawling and the reading says little.
    static let movingSpeed = 2.0
    private static let slowest = 6.0
    private static let fastest = 30.0

    static func roadMeters(fromLatitude lat: Double, longitude lon: Double, to site: ArrivalWatch.WatchedSite) -> Double {
        let here = CLLocation(latitude: lat, longitude: lon)
        let there = CLLocation(latitude: site.latitude, longitude: site.longitude)
        return here.distance(from: there) * roadFactor
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
