import SwiftUI

/// Work from dispatch and the driver's own notes, filed by work day.
struct TasksView: View {
    @EnvironmentObject private var model: AppModel

    @State private var tasks: [DriverTask] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var addingNote = false
    @State private var showDone = false
    @State private var startingPickup = false

    private var visible: [DriverTask] { showDone ? tasks : tasks.filter(\.isOpen) }

    private var days: [(day: String, tasks: [DriverTask])] {
        let grouped = Dictionary(grouping: visible) { $0.workDate ?? "" }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    PageHeader("Tasks") {
                        Button {
                            showDone.toggle()
                        } label: {
                            Image(systemName: showDone ? "eye.slash" : "eye")
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel(showDone ? "Hide finished tasks" : "Show finished tasks")

                        Button {
                            addingNote = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Add a note")
                    }

                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    if !loading && visible.isEmpty && errorMessage == nil {
                        EmptyNote(
                            title: showDone ? "No tasks" : "Nothing open",
                            detail: "Work that dispatch assigns shows up here. Tap + to add a note of your own."
                        )
                    }

                    ForEach(days, id: \.day) { group in
                        SectionTitle(text: Format.day(iso: group.day))
                        ForEach(group.tasks) { task in
                            TaskCardView(
                                task: task,
                                onSaved: replace,
                                onError: { errorMessage = $0 },
                                onStartPickup: { startingPickup = true }
                            )
                        }
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .overlay { if loading && tasks.isEmpty { ProgressView() } }
            .brandScreen()
            .sheet(isPresented: $addingNote) {
                AddNoteView { task in
                    addingNote = false
                    tasks.insert(task, at: 0)
                }
            }
            .fullScreenCover(isPresented: $startingPickup) {
                PickupWizardView(mode: .new, model: model) {
                    Task { await load() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func replace(_ task: DriverTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list: TaskList = try await api.get("/api/tasks")
            tasks = list.tasks
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }
}

private struct TaskCardView: View {
    @EnvironmentObject private var model: AppModel
    let task: DriverTask
    let onSaved: (DriverTask) -> Void
    let onError: (String) -> Void
    let onStartPickup: () -> Void

    @State private var saving = false
    @State private var editingSteps = false

    /// Dispatch work that begins with collecting equipment and has no trip yet.
    private var canStartPickup: Bool {
        task.isOpen && task.tripId == nil && ["PICKUP", "LOAD", "EMPTY"].contains(task.kind ?? "")
    }

    private var steps: [TaskStep] { task.steps ?? [] }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title?.isEmpty == false ? task.title! : Words.taskKind(task.kind))
                    .font(.headline)
                    .foregroundColor(Brand.navy)
                Spacer()
                StatusPill(text: statusLabel, color: statusColor)
            }
            Text("\(task.sourceLabel) · \(Words.taskKind(task.kind))")
                .font(.caption)
                .foregroundColor(Brand.muted)

            if let card = task.card {
                InfoRow(label: "At", value: card.locationName)
                InfoRow(label: "To", value: card.destinationLocationName)
                InfoRow(label: "Container", value: card.containerNumber)
                if card.containerPending == true {
                    Text("Not in the yard yet")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                }
                InfoRow(label: "Notes", value: card.notes)
            }

            ForEach(steps) { step in
                Button {
                    Task { await toggle(step) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(step.done ? Brand.ok : Brand.muted)
                            .padding(.top, 1)
                        Text(step.text)
                            .font(.subheadline)
                            .foregroundColor(Brand.navy)
                            .strikethrough(step.done, color: Brand.muted)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 36)
                }
                .buttonStyle(.plain)
                .disabled(saving || !task.isOpen)
                .accessibilityLabel("\(step.text), \(step.done ? "done" : "not done")")
            }

            if task.isOpen && !steps.isEmpty {
                Button("Edit Steps") { editingSteps = true }
                    .font(.caption.weight(.bold))
                    .foregroundColor(Brand.linkBlue)
                    .frame(minHeight: 32)
            }

            if canStartPickup {
                Button("Start Pickup", action: onStartPickup)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving)
            }

            if task.isOpen {
                HStack(spacing: 12) {
                    Button("Mark Done") { Task { await setStatus("DONE") } }
                        .buttonStyle(SecondaryButtonStyle())
                    if !(task.assigned ?? false) {
                        Button("Remove", role: .destructive) { Task { await setStatus("DISMISSED") } }
                            .frame(minHeight: 52)
                            .padding(.horizontal, 8)
                    }
                }
                .disabled(saving)
            }
        }
        .sheet(isPresented: $editingSteps) { stepsSheet() }
    }

    private func stepsSheet() -> some View {
        TaskStepsView(task: task, onSaved: onSaved)
    }

    private var statusLabel: String {
        switch task.status {
        case "OPEN": return "Open"
        case "IN_PROGRESS": return "In progress"
        case "DONE": return "Done"
        case "DISMISSED": return "Dismissed"
        default: return task.status.capitalized
        }
    }

    private var statusColor: Color {
        switch task.status {
        case "DONE": return Brand.ok
        case "IN_PROGRESS": return Brand.linkBlue
        case "OPEN": return Color.orange
        default: return Brand.muted
        }
    }

    private struct StepsBody: Encodable { let steps: [TaskStep] }
    private struct StatusBody: Encodable { let status: String }

    private func toggle(_ step: TaskStep) async {
        var next = steps
        guard let index = next.firstIndex(where: { $0.id == step.id }) else { return }
        next[index].done.toggle()
        await save { api in try await api.patch("/api/tasks/\(task.id)", body: StepsBody(steps: next)) }
    }

    private func setStatus(_ status: String) async {
        await save { api in try await api.patch("/api/tasks/\(task.id)", body: StatusBody(status: status)) }
    }

    private func save(_ request: (APIClient) async throws -> TaskEnvelope) async {
        guard let api = model.api else { return }
        saving = true
        defer { saving = false }
        do {
            onSaved(try await request(api).task)
        } catch {
            onError(model.handle(error))
        }
    }
}

/// Paste or type work as a note. It files under today.
private struct AddNoteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onAdded: (DriverTask) -> Void

    @State private var text = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage { ErrorBanner(message: errorMessage) }
                Text("Files under today. Dispatch cards cannot be rewritten from here.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                TextEditor(text: $text)
                    .focused($focused)
                    .frame(minHeight: 180)
                    .padding(8)
                    .background(Brand.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Brand.line))
                Button(saving ? "Saving…" : "Add Note") { Task { await add() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(16)
            .screenBackground()
            .navigationTitle("Add a Note")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { focused = true }
        }
    }

    private struct NoteBody: Encodable { let text: String }

    private func add() async {
        guard let api = model.api else { return }
        saving = true
        defer { saving = false }
        do {
            let saved: TaskEnvelope = try await api.post("/api/tasks", body: NoteBody(text: text))
            onAdded(saved.task)
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
