import ActivityKit
import CoreLocation
import Foundation

/// Keeps one Live Activity in step with the driver's live trip, so the Lock
/// Screen and Dynamic Island show how far the drop-off is, how long it will
/// take, and what is next.
enum TripActivityCenter {
    /// Off while the Lock Screen and Dynamic Island layout is reworked. Turn
    /// back on to start activities again; everything below is kept as is.
    static let isEnabled = false

    /// Follow the trip Home is showing: start, update or end the activity.
    static func sync(home: HomePayload) {
        guard #available(iOS 16.2, *) else { return }
        guard isEnabled else {
            // Clear any activity a build from before the switch left running.
            Task { @MainActor in await Follower.shared.stop() }
            return
        }
        Task { @MainActor in await Follower.shared.follow(home) }
    }

    /// The phone moved: work out what is left to the drop-off. `speed` is the GPS speed in metres per second.
    static func moved(latitude: Double, longitude: Double, speed: Double, site: ArrivalWatch.WatchedSite) {
        guard #available(iOS 16.2, *), isEnabled else { return }
        Task { @MainActor in
            await Follower.shared.moved(latitude: latitude, longitude: longitude, speed: speed, site: site)
        }
    }

    /// End everything, on sign-out, so a stranger's lock screen shows nothing.
    static func endAll() {
        guard #available(iOS 16.2, *) else { return }
        Task { @MainActor in await Follower.shared.stop() }
    }

    @available(iOS 16.2, *)
    @MainActor
    private final class Follower {
        static let shared = Follower()

        private var tripId: String?
        private var base: TripActivityAttributes.ContentState?
        private var meters: Double?
        private var startMeters: Double?
        private var speed: Double?
        private var seconds: TimeInterval?
        /// The last answer from Apple Maps, and where the phone was when it came.
        private var route: (answer: TripEstimate.Route, straight: Double, at: Date, latitude: Double, longitude: Double)?
        private var asking = false
        private var sent: (meters: Double, at: Date)?

        func follow(_ home: HomePayload) async {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            guard let active = home.active, active.trip.isLive else {
                reset(tripId: nil)
                await stop(finished: home.recentCompleted)
                return
            }
            if tripId != active.trip.id { reset(tripId: active.trip.id) }
            base = TripActivityAttributes.ContentState(
                status: active.trip.status,
                equipment: [active.container?.number, active.chassis?.number]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " on "),
                destination: active.destination?.name,
                next: active.primaryAction?.label
            )
            await push(forceStart: true)
        }

        func moved(latitude: Double, longitude: Double, speed reading: Double, site: ArrivalWatch.WatchedSite) async {
            guard tripId != nil else { return }
            speed = TripEstimate.smoothed(speed, with: reading)
            let straight = TripEstimate.straightMeters(fromLatitude: latitude, longitude: longitude, to: site)
            let arrivalRadius = max(80, site.radiusMeters)
            // Once the phone is near the circle a road-route answer from a
            // minute ago is more likely to be wrong than the straight line is:
            // yard roads are not in Apple Maps, and the drive is nearly over
            // anyway. Switch to the phone's own position and stop asking.
            let arriving = straight <= arrivalRadius * 1.5

            if arriving {
                route = nil
                meters = straight
                seconds = TripEstimate.seconds(forMeters: straight, speed: speed)
            } else {
                // Ask Apple Maps once a minute, or after a good stretch of
                // driving; in between, scale its last answer by how much
                // closer the phone is.
                if !asking, needsRoute(latitude: latitude, longitude: longitude) {
                    asking = true
                    let id = tripId
                    let answer = await TripEstimate.route(fromLatitude: latitude, longitude: longitude, to: site)
                    asking = false
                    if let answer, id == tripId {
                        route = (answer, max(straight, 1), Date(), latitude, longitude)
                    }
                }
                if let route {
                    let ratio = min(1, straight / route.straight)
                    meters = route.answer.meters * ratio
                    seconds = route.answer.seconds * ratio
                } else {
                    meters = straight * TripEstimate.roadFactor
                    seconds = TripEstimate.seconds(forMeters: meters ?? 0, speed: self.speed)
                }
            }
            if startMeters == nil { startMeters = meters }
            // Close to the drop-off every fix goes straight to the Lock
            // Screen — that is exactly where the number matters most and
            // where it used to go stale. Further out, a fix every 50 m or 20
            // seconds is plenty; the countdown ticks on its own in between.
            let closeRange = (meters ?? .greatestFiniteMagnitude) <= arrivalRadius * 2
            if !closeRange, let sent, let meters,
               abs(sent.meters - meters) < 50, Date().timeIntervalSince(sent.at) < 20 {
                return
            }
            await push(forceStart: false)
        }

        private func needsRoute(latitude: Double, longitude: Double) -> Bool {
            guard let route else { return true }
            if Date().timeIntervalSince(route.at) > 60 { return true }
            return CLLocation(latitude: latitude, longitude: longitude)
                .distance(from: CLLocation(latitude: route.latitude, longitude: route.longitude)) > 500
        }

        private func reset(tripId: String?) {
            self.tripId = tripId
            base = nil
            meters = nil
            startMeters = nil
            speed = nil
            seconds = nil
            route = nil
            sent = nil
        }

        private func current() -> TripActivityAttributes.ContentState? {
            guard var state = base else { return nil }
            if let meters {
                state.distanceMeters = meters
                state.startMeters = max(startMeters ?? meters, meters)
                state.arriveBy = Date().addingTimeInterval(seconds ?? TripEstimate.seconds(forMeters: meters, speed: speed))
            }
            return state
        }

        private func push(forceStart: Bool) async {
            guard let tripId, let state = current() else { return }
            // If nothing pushes a fresher number within three minutes — the
            // app got killed and region monitoring cannot wake it, the phone
            // lost signal, whatever the reason — iOS dims the Dynamic Island
            // and Lock Screen on its own rather than let them sit there
            // looking current when they are not. That is the one part of
            // this that cannot be done from inside the app: nothing Yard
            // Link runs gets a chance to act at the instant the app is
            // swiped away, by design, on every iPhone.
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(180))
            let running = Activity<TripActivityAttributes>.activities
            if let same = running.first(where: { $0.attributes.tripId == tripId }) {
                await same.update(content)
                for other in running where other.id != same.id {
                    await other.end(nil, dismissalPolicy: .immediate)
                }
            } else if forceStart {
                for old in running { await old.end(nil, dismissalPolicy: .immediate) }
                _ = try? Activity.request(
                    attributes: TripActivityAttributes(tripId: tripId),
                    content: content,
                    pushType: nil
                )
            }
            if let meters { sent = (meters, Date()) }
        }

        /// A trip that just finished is shown as done for a few minutes
        /// first — but only genuinely just now. Home keeps `recentCompleted`
        /// around for 12 hours so the screen can still reference it, and
        /// without this check every reopen of the app in that window would
        /// re-arm another 5 minutes of "done" on the Dynamic Island, long
        /// after the driver has moved on.
        private static let justFinishedWindow: TimeInterval = 5 * 60

        private func isJustFinished(_ finished: HomePayload.Active) -> Bool {
            guard let at = [finished.trip.droppedOffAt, finished.trip.completedAt].compactMap({ $0 }).max() else { return false }
            return Date().timeIntervalSince(at) < Self.justFinishedWindow
        }

        /// Close the activity. A trip that just finished is shown as done for a few minutes first.
        func stop(finished: HomePayload.Active? = nil) async {
            for activity in Activity<TripActivityAttributes>.activities {
                if let finished, finished.trip.id == activity.attributes.tripId, isJustFinished(finished) {
                    var state = activity.content.state
                    state.status = finished.trip.status
                    state.next = nil
                    state.distanceMeters = nil
                    state.arriveBy = nil
                    await activity.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .after(Date().addingTimeInterval(Self.justFinishedWindow))
                    )
                } else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}
