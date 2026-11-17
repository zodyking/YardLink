import ActivityKit
import Foundation

/// What the Lock Screen and Dynamic Island show while a trip is live.
/// Shared by the app, which starts and updates it, and the widget extension,
/// which draws it.
@available(iOS 16.2, *)
struct TripActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The trip's status as the server names it (IN_TRANSIT, ...).
        var status: String
        var equipment: String
        var destination: String?
        /// What the driver does next, in the app's words.
        var next: String?
        /// Road distance left to the drop-off, estimated from the phone's position.
        var distanceMeters: Double?
        /// Distance when the trip began being tracked, for the progress bar.
        var startMeters: Double?
        /// When the phone expects to be there; the Lock Screen counts down to it.
        var arriveBy: Date?
    }

    /// The trip this activity follows, so a new trip starts a fresh one.
    var tripId: String
}

@available(iOS 16.2, *)
extension TripActivityAttributes.ContentState {
    /// How far along the trip is: 0 pickup, 1 on the road, 2 dropping off, 3 done.
    var stage: Int {
        switch status {
        case "PICKUP_IN_PROGRESS": return 0
        case "IN_TRANSIT": return 1
        case "DROPOFF_IN_PROGRESS": return 2
        default: return 3
        }
    }

    var statusText: String {
        switch stage {
        case 0: return "Picking up"
        case 1: return "In transit"
        case 2: return "Dropping off"
        default: return "Dropped off"
        }
    }
}

@available(iOS 16.2, *)
extension TripActivityAttributes.ContentState {
    /// 0 at the start of the drive, 1 at the drop-off. Nil until the phone has a position.
    var progress: Double? {
        guard let distanceMeters, let startMeters, startMeters > 0 else { return nil }
        return min(1, max(0, 1 - distanceMeters / startMeters))
    }

    /// "3.2 mi", "850 ft" — or kilometres and metres where the phone is set to metric.
    var distanceText: String? {
        guard let meters = distanceMeters else { return nil }
        if Locale.current.measurementSystem == .metric {
            if meters < 1_000 { return "\(Int((meters / 50).rounded()) * 50) m" }
            return String(format: meters < 10_000 ? "%.1f km" : "%.0f km", meters / 1_000)
        }
        let miles = meters / 1_609.344
        if miles < 0.1 { return "\(max(50, Int((meters * 3.28084 / 50).rounded()) * 50)) ft" }
        return String(format: miles < 10 ? "%.1f mi" : "%.0f mi", miles)
    }
}
