import SwiftUI

/// Rewrite a task's steps: edit the wording, add or remove a step, split one
/// that holds several lines, or join one to the step above. The same moves as
/// the web app's checklist; everything is saved together.
struct TaskStepsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let task: DriverTask
    let onSaved: (DriverTask) -> Void

    @State private var steps: [TaskStep]
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var focused: String?

    init(task: DriverTask, onSaved: @escaping (DriverTask) -> Void) {
        self.task = task
        self.onSaved = onSaved
        _steps = State(initialValue: task.steps ?? [])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage { ErrorBanner(message: errorMessage) }

                    Text("Ticks are kept as they are. A step left empty is dropped when you save.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)

                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(index: index, step: step)
                    }

                    Button {
                        add()
                    } label: {
                        Label("Add a Step", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .screenBackground()
            .navigationTitle("Edit Steps")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomBar {
                    Button(saving ? "Saving…" : "Save Steps") { Task { await save() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(saving)
                }
            }
        }
    }

    private func stepRow(index: Int, step: TaskStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    steps[index].done.toggle()
                } label: {
                    Image(systemName: steps[index].done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(steps[index].done ? Brand.ok : Brand.muted)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 32, minHeight: 32)
                .accessibilityLabel(steps[index].done ? "Tick off" : "Mark as done")

                TextField("What to do", text: Binding(
                    get: { index < steps.count ? steps[index].text : "" },
                    set: { if index < steps.count { steps[index].text = $0 } }
                ), axis: .vertical)
                    .font(.subheadline)
                    .foregroundColor(Brand.navy)
                    .lineLimit(1...6)
                    .focused($focused, equals: step.id)
            }

            HStack(spacing: 8) {
                if hasLines(index) {
                    Button("Split lines") { splitLines(index) }
                }
                if index > 0 {
                    Button("Join above") { mergeUp(index) }
                }
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    remove(index)
                } label: {
                    Image(systemName: "trash")
                }
                .frame(minWidth: 44, minHeight: 32)
                .accessibilityLabel("Remove this step")
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundColor(Brand.linkBlue)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func hasLines(_ index: Int) -> Bool {
        guard index < steps.count else { return false }
        return steps[index].text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count > 1
    }

    private func newStep(_ text: String) -> TaskStep {
        TaskStep(id: UUID().uuidString.lowercased(), text: text, done: false)
    }

    private func add() {
        let step = newStep("")
        steps.append(step)
        focused = step.id
    }

    private func remove(_ index: Int) {
        guard index < steps.count else { return }
        steps.remove(at: index)
    }

    /// One step holding several lines becomes one step per line.
    private func splitLines(_ index: Int) {
        guard index < steps.count else { return }
        let lines = steps[index].text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else { return }
        var replacement = [TaskStep(id: steps[index].id, text: lines[0], done: steps[index].done)]
        replacement += lines.dropFirst().map { newStep($0) }
        steps.replaceSubrange(index...index, with: replacement)
    }

    /// Joins a step onto the one above, as backspacing at the start does on
    /// the web. It counts as done only if both were.
    private func mergeUp(_ index: Int) {
        guard index > 0, index < steps.count else { return }
        let above = steps[index - 1]
        let current = steps[index]
        let joiner = above.text.isEmpty || current.text.isEmpty ? "" : " "
        let merged = TaskStep(
            id: above.id,
            text: "\(above.text)\(joiner)\(current.text)",
            done: above.done && current.done
        )
        steps.replaceSubrange((index - 1)...index, with: [merged])
        focused = merged.id
    }

    private struct Changes: Encodable {
        let steps: [TaskStep]
    }

    private func save() async {
        guard let api = model.api else { return }
        saving = true
        errorMessage = nil
        defer { saving = false }
        let kept = steps
            .map { TaskStep(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), done: $0.done) }
            .filter { !$0.text.isEmpty }
        do {
            let saved: TaskEnvelope = try await api.patch("/api/tasks/\(task.id)", body: Changes(steps: kept))
            onSaved(saved.task)
            dismiss()
        } catch {
            errorMessage = model.handle(error)
        }
    }
}
