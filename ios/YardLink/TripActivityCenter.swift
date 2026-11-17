import ActivityKit
import Foundation

/// Keeps one Live Activity in step with the driver's live trip, so the Lock
/// Screen and Dynamic Island always show where the trip stands and what is next.
enum TripActivityCenter {
    /// Follow the trip Home is showing: start, update or end the activity.
    static func sync(home: HomePayload) {
        guard #available(iOS 16.2, *) else { return }
        Task { @MainActor in await Follower.shared.follow(home) }
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

        func follow(_ home: HomePayload) async {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            guard let active = home.active, active.trip.isLive else {
                await stop(finished: home.recentCompleted)
                return
            }
            let state = TripActivityAttributes.ContentState(
                status: active.trip.status,
                equipment: [active.container?.number, active.chassis?.number]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " on "),
                destination: active.destination?.name,
                next: active.primaryAction?.label
            )
            let content = ActivityContent(state: state, staleDate: nil)
            let running = Activity<TripActivityAttributes>.activities
            if let same = running.first(where: { $0.attributes.tripId == active.trip.id }) {
                await same.update(content)
                for other in running where other.id != same.id {
                    await other.end(nil, dismissalPolicy: .immediate)
                }
                return
            }
            for old in running { await old.end(nil, dismissalPolicy: .immediate) }
            _ = try? Activity.request(
                attributes: TripActivityAttributes(tripId: active.trip.id),
                content: content,
                pushType: nil
            )
        }

        /// Close the activity. A trip that just finished is shown as done for a few minutes first.
        func stop(finished: HomePayload.Active? = nil) async {
            for activity in Activity<TripActivityAttributes>.activities {
                if let finished, finished.trip.id == activity.attributes.tripId {
                    var state = activity.content.state
                    state.status = finished.trip.status
                    state.next = nil
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
