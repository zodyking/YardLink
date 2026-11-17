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
