import AppIntents
import WidgetKit

/// The check box on the Tasks widget. The widget shows the change at once; if
/// the server cannot be reached the change waits and goes out later.
struct ToggleTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Check or uncheck a task"

    @Parameter(title: "Task")
    var taskId: String

    @Parameter(title: "Done")
    var done: Bool

    init() {}

    init(taskId: String, done: Bool) {
        self.taskId = taskId
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        var snapshot = SharedStore.loadSnapshot()
        if let index = snapshot.tasks.firstIndex(where: { $0.id == taskId }) {
            snapshot.tasks[index].done = done
            snapshot.tasks = snapshot.tasks.filter { !$0.done } + snapshot.tasks.filter { $0.done }
            SharedStore.save(snapshot)
        }

        do {
            guard let client = WidgetClient() else { throw WidgetClient.Failure(signedOut: true) }
            try await client.setTask(taskId, done: done)
        } catch {
            SharedStore.queue(PendingTaskChange(taskId: taskId, done: done))
        }

        WidgetCenter.shared.reloadTimelines(ofKind: TasksWidget.kind)
        return .result()
    }
}
