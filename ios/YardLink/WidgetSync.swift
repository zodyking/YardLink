import Foundation
import WidgetKit

/// Keeps the Home Screen widgets in step with what the app has just loaded,
/// and sends the checks made on a widget while the phone was offline.
enum WidgetSync {
    static func update(tasks: [DriverTask]) {
        var snapshot = SharedStore.loadSnapshot()
        let rows = tasks
            .filter { $0.status != "DISMISSED" }
            .map { task -> WidgetTask in
                let name = [task.title, task.rawText].compactMap { $0 }.first { !$0.isEmpty } ?? Words.taskKind(task.kind)
                return WidgetTask(id: task.id, title: name, done: task.status == "DONE")
            }
        snapshot.tasks = rows.filter { !$0.done } + rows.filter { $0.done }
        remember(snapshot)
    }

    static func update(home: HomePayload) {
        var snapshot = SharedStore.loadSnapshot()
        if let shown = home.active ?? home.recentCompleted {
            snapshot.trip = WidgetTrip(
                container: shown.container?.number,
                chassis: shown.chassis?.number,
                destination: shown.destination?.name,
                status: shown.trip.status,
                next: shown.primaryAction?.label,
                live: home.active != nil
            )
        } else {
            snapshot.trip = nil
        }
        remember(snapshot)
    }

    private static func remember(_ snapshot: WidgetSnapshot) {
        var next = snapshot
        next.signedIn = true
        next.updatedAt = Date()
        SharedStore.save(next)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Forget everything on sign-out, so a widget never shows the last person's work.
    static func clear() {
        SharedStore.clearSnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private struct StatusBody: Encodable { let status: String }

    /// Send what was checked on a widget without a signal, now that the app has one.
    static func flushPending(api: APIClient) async {
        var waiting = SharedStore.pendingChanges()
        guard !waiting.isEmpty else { return }
        for change in waiting {
            let sent: TaskEnvelope? = try? await api.patch(
                "/api/tasks/\(change.taskId)",
                body: StatusBody(status: change.done ? "DONE" : "OPEN")
            )
            if sent != nil { waiting.removeAll { $0 == change } }
        }
        SharedStore.savePending(waiting)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
