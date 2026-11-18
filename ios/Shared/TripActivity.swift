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

    /// "3.2 mi", "850 ft" — the distance as one piece of text.
    var distanceText: String? {
        guard let parts = distanceParts else { return nil }
        return "\(parts.value) \(parts.unit)"
    }
}

@available(iOS 16.2, *)
extension TripActivityAttributes.ContentState {
    /// The distance split so the number can be set large and the unit small.
    var distanceParts: (value: String, unit: String)? {
        guard let meters = distanceMeters else { return nil }
        if Locale.current.measurementSystem == .metric {
            if meters < 1_000 { return ("\(Int((meters / 50).rounded()) * 50)", "m") }
            return (String(format: meters < 10_000 ? "%.1f" : "%.0f", meters / 1_000), "km")
        }
        let miles = meters / 1_609.344
        if miles < 0.1 { return ("\(max(50, Int((meters * 3.28084 / 50).rounded()) * 50))", "ft") }
        return (String(format: miles < 10 ? "%.1f" : "%.0f", miles), "mi")
    }

    var distanceValue: String? { distanceParts?.value }
    var distanceUnit: String? { distanceParts?.unit }

    private var arrivalParts: (clock: String, suffix: String)? {
        guard let arriveBy else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        let whole = formatter.string(from: arriveBy)
        for marker in [formatter.amSymbol, formatter.pmSymbol] where !marker.isEmpty && whole.hasSuffix(marker) {
            return (whole.dropLast(marker.count).trimmingCharacters(in: .whitespaces), marker)
        }
        return (whole, "")
    }

    /// "4:32" — the clock time the phone expects the driver to pull in.
    var arrivalClock: String? { arrivalParts?.clock }
    /// "PM", or nothing where the phone shows a 24-hour clock.
    var arrivalSuffix: String? { arrivalParts?.suffix }
}
