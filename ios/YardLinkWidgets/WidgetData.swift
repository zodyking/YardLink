import Foundation
import WidgetKit

/// Fetch what the widgets show, falling back on the last thing the app or a
/// widget saved so a lost signal never blanks the screen.
enum WidgetData {
    static func refresh() async -> WidgetSnapshot {
        var snapshot = SharedStore.loadSnapshot()
        guard let client = WidgetClient() else {
            snapshot.signedIn = false
            return snapshot
        }

        // Send any check made on a widget while the phone was offline.
        var waiting = SharedStore.pendingChanges()
        for change in waiting {
            if (try? await client.setTask(change.taskId, done: change.done)) != nil {
                waiting.removeAll { $0 == change }
            }
        }
        SharedStore.savePending(waiting)

        do {
            var tasks = try await client.tasks()
            for change in waiting {
                if let index = tasks.firstIndex(where: { $0.id == change.taskId }) { tasks[index].done = change.done }
            }
            snapshot.tasks = tasks.filter { !$0.done } + tasks.filter { $0.done }
            snapshot.trip = (try? await client.trip()) ?? snapshot.trip
            snapshot.signedIn = true
            snapshot.updatedAt = Date()
            SharedStore.save(snapshot)
        } catch let failure as WidgetClient.Failure where failure.signedOut {
            snapshot.signedIn = false
        } catch {
            // Offline: keep showing what was last saved.
        }
        return snapshot
    }
}
