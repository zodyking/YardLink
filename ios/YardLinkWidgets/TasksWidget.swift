import AppIntents
import SwiftUI
import WidgetKit

struct TasksEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TasksProvider: TimelineProvider {
    func placeholder(in context: Context) -> TasksEntry {
        var sample = WidgetSnapshot()
        sample.signedIn = true
        sample.tasks = [
            WidgetTask(id: "1", title: "Pick up MSCU 123456", done: false),
            WidgetTask(id: "2", title: "Drop empty at APM", done: false),
            WidgetTask(id: "3", title: "Fuel stop", done: true),
        ]
        return TasksEntry(date: Date(), snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (TasksEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : TasksEntry(date: Date(), snapshot: SharedStore.loadSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TasksEntry>) -> Void) {
        Task {
            let snapshot = await WidgetData.refresh()
            let next = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [TasksEntry(date: Date(), snapshot: snapshot)], policy: .after(next)))
        }
    }
}

struct TasksWidget: Widget {
    static let kind = "YardLinkTasks"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TasksProvider()) { entry in
            TasksWidgetView(entry: entry)
        }
        .configurationDisplayName("Tasks")
        .description("Today's work. Check a task off right from the Home Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct TasksWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TasksEntry

    private var tasks: [WidgetTask] { entry.snapshot.tasks }
    private var open: [WidgetTask] { tasks.filter { !$0.done } }

    private var rowLimit: Int {
        switch family {
        case .systemSmall: return 2
        case .systemMedium: return 3
        default: return 7
        }
    }

    var body: some View {
        content
            .widgetURL(URL(string: "yardlink://open/tasks"))
            .containerBackground(for: .widget) { WidgetBrand.mist }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(tasks.count - open.count), in: 0...Double(max(tasks.count, 1))) {
                Text("Tasks")
            } currentValueLabel: {
                Text("\(open.count)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(open.isEmpty ? "Tasks: all done" : "Tasks: \(open.count) open")
                    .font(.headline)
                    .widgetAccentable()
                if let next = open.first {
                    Text(next.title).font(.caption).lineLimit(2)
                }
            }
        case .accessoryInline:
            Text(open.isEmpty ? "No open tasks" : "\(open.count) open tasks")
        default:
            board
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tasks")
                    .font(.headline)
                    .foregroundStyle(WidgetBrand.navy)
                Spacer()
                if entry.snapshot.signedIn, !open.isEmpty {
                    Text("\(open.count) open")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetBrand.linkBlue)
                }
            }

            if !entry.snapshot.signedIn {
                Text("Open Yard Link and sign in to see your tasks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if tasks.isEmpty {
                Text("Nothing assigned. Dispatch work and your own notes show up here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(tasks.prefix(rowLimit))) { task in
                    row(task)
                }
                if tasks.count > rowLimit {
                    Text("+\(tasks.count - rowLimit) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ task: WidgetTask) -> some View {
        HStack(spacing: 8) {
            Button(intent: ToggleTaskIntent(taskId: task.id, done: !task.done)) {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.done ? WidgetBrand.ok : WidgetBrand.linkBlue)
            }
            .buttonStyle(.plain)
            Text(task.title)
                .font(.footnote.weight(.medium))
                .strikethrough(task.done)
                .foregroundStyle(task.done ? Color.secondary : WidgetBrand.navy)
                .lineLimit(family == .systemSmall ? 2 : 1)
            Spacer(minLength: 0)
        }
    }
}
