import ActivityKit
import Foundation

/// Keeps one Live Activity in step with the driver's live trip, so the Lock
/// Screen and Dynamic Island show how far the drop-off is, how long it will
/// take, and what is next.
enum TripActivityCenter {
    /// Follow the trip Home is showing: start, update or end the activity.
    static func sync(home: HomePayload) {
        guard #available(iOS 16.2, *) else { return }
        Task { @MainActor in await Follower.shared.follow(home) }
    }

    /// The phone moved: `meters` is the road distance left, `speed` the GPS speed in metres per second.
    static func moved(meters: Double, speed: Double) {
        guard #available(iOS 16.2, *) else { return }
        Task { @MainActor in await Follower.shared.moved(meters: meters, speed: speed) }
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

        func moved(meters: Double, speed reading: Double) async {
            guard tripId != nil else { return }
            speed = TripEstimate.smoothed(speed, with: reading)
            self.meters = meters
            if startMeters == nil { startMeters = meters }
            // A fix every hundred metres is plenty; the countdown ticks on its own.
            if let sent, abs(sent.meters - meters) < 100, Date().timeIntervalSince(sent.at) < 60 { return }
            await push(forceStart: false)
        }

        private func reset(tripId: String?) {
            self.tripId = tripId
            base = nil
            meters = nil
            startMeters = nil
            speed = nil
            sent = nil
        }

        private func current() -> TripActivityAttributes.ContentState? {
            guard var state = base else { return nil }
            if let meters {
                state.distanceMeters = meters
                state.startMeters = max(startMeters ?? meters, meters)
                state.arriveBy = Date().addingTimeInterval(TripEstimate.seconds(forMeters: meters, speed: speed))
            }
            return state
        }

        private func push(forceStart: Bool) async {
            guard let tripId, let state = current() else { return }
            let content = ActivityContent(state: state, staleDate: nil)
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

        /// Close the activity. A trip that just finished is shown as done for a few minutes first.
        func stop(finished: HomePayload.Active? = nil) async {
            for activity in Activity<TripActivityAttributes>.activities {
                if let finished, finished.trip.id == activity.attributes.tripId {
                    var state = activity.content.state
                    state.status = finished.trip.status
                    state.next = nil
                    state.distanceMeters = nil
                    state.arriveBy = nil
                    await activity.end(
                        ActivityContent(state: state, staleDate: nil),
                        dismissalPolicy: .after(Date().addingTimeInterval(5 * 60))
                    )
                } else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}
