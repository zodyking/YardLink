import SwiftUI
import UIKit

/// Conversations with dispatch and co-workers, on the employer's own server.
struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    let user: SessionUser

    @State private var threads: [ThreadSummary] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var pickingContact = false
    @State private var path: [ThreadSummary] = []
    @ObservedObject private var rootTap = TabRootTap.shared

    var body: some View {
        NavigationStack(path: $path) {
            List {
                PageHeader("Messages") {
                    Button {
                        pickingContact = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("New message")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                if !loading && threads.isEmpty && errorMessage == nil {
                    Text(user.isDriver ? "No messages yet. Tap the pencil to write to dispatch." : "No messages yet. Tap the pencil to write to a driver.")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                        .listRowBackground(Color.clear)
                }
                ForEach(threads) { thread in
                    NavigationLink(value: thread) {
                        ThreadRow(thread: thread)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if loading && threads.isEmpty { ProgressView() }
            }
            .brandScreen()
            .navigationDestination(for: ThreadSummary.self) { thread in
                ThreadView(thread: thread, user: user)
            }
            .refreshable { await load() }
            .task { await load() }
            .onChange(of: path) { newPath in
                // Coming back from a conversation: unread counts have changed.
                if newPath.isEmpty { Task { await load() } }
            }
            .sheet(isPresented: $pickingContact) {
                ContactPicker { contact in
                    pickingContact = false
                    Task { await start(with: contact) }
                }
            }
            .onChange(of: rootTap.event) { event in
                // Tapping Messages again while already there pops back to it.
                guard event?.screen == AnyHashable(MainTabs.Screen.messages) else { return }
                path = []
            }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let list: ThreadList = try await api.get("/api/messages")
            threads = list.threads
            model.unreadMessages = list.unread
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private func start(with contact: Contact) async {
        guard let api = model.api else { return }
        struct Body: Encodable { let userId: String }
        do {
            let ref: ThreadRef = try await api.post("/api/messages/threads", body: Body(userId: contact.userId))
            await load()
            if let thread = threads.first(where: { $0.id == ref.threadId }) {
                path = [thread]
            }
        } catch {
            errorMessage = model.handle(error)
        }
    }
}

private struct ThreadRow: View {
    let thread: ThreadSummary

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.navy)
                Text(String(thread.title.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title)
                        .font(.headline)
                        .foregroundColor(Brand.navy)
                        .lineLimit(1)
                    Spacer()
                    if let at = thread.lastMessageAt {
                        Text(at, format: Calendar.current.isDateInToday(at) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day())
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                    }
                }
                Text(thread.lastMessagePreview ?? thread.subtitle)
                    .font(.subheadline.weight(thread.unread > 0 ? .semibold : .regular))
                    .foregroundColor(thread.unread > 0 ? Brand.navy : Brand.muted)
                    .lineLimit(1)
            }
            if thread.unread > 0 {
                Text(thread.unread > 9 ? "9+" : "\(thread.unread)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundColor(Brand.navy)
                    .background(Brand.sky)
                    .clipShape(Capsule())
                    .accessibilityLabel("\(thread.unread) unread")
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThreadView: View {
    @EnvironmentObject private var model: AppModel
    let thread: ThreadSummary
    let user: SessionUser

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var loading = true
    @State private var sending = false
    @State private var errorMessage: String?
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if loading && messages.isEmpty {
                            ProgressView().padding(.top, 40)
                        } else if messages.isEmpty {
                            Text("Nothing here yet. Say hello.")
                                .font(.subheadline)
                                .foregroundColor(Brand.muted)
                                .padding(.top, 40)
                        }
                        ForEach(messages) { message in
                            Bubble(message: message, mine: message.senderUserId == user.userId)
                                .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage {
                ErrorBanner(message: errorMessage)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Write a message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($composing)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
            .padding(12)
            .background(Brand.paper)
        }
        .screenBackground()
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .lightBar()
        .task {
            await load()
            // Pick up replies while the conversation is open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                await loadNew()
            }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            let result: ThreadMessages = try await api.get("/api/messages/threads/\(thread.id)")
            messages = result.messages
            errorMessage = nil
        } catch {
            errorMessage = model.handle(error)
        }
        loading = false
    }

    private func loadNew() async {
        guard let api = model.api, let last = messages.last else {
            if messages.isEmpty { await load() }
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let result: ThreadMessages = try? await api.get(
            "/api/messages/threads/\(thread.id)",
            query: ["after": formatter.string(from: last.createdAt)]
        ) else { return }
        let known = Set(messages.map(\.id))
        let fresh = result.messages.filter { !known.contains($0.id) }
        if !fresh.isEmpty { messages.append(contentsOf: fresh) }
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = model.api, !body.isEmpty, !sending else { return }
        sending = true
        errorMessage = nil
        // The id is made here so a retry on a weak signal cannot send twice.
        struct Outgoing: Encodable { let id: String; let body: String }
        do {
            let sent: SentMessage = try await api.post(
                "/api/messages/threads/\(thread.id)",
                body: Outgoing(id: UUID().uuidString.lowercased(), body: body)
            )
            if !messages.contains(where: { $0.id == sent.message.id }) {
                messages.append(sent.message)
            }
            draft = ""
            // Tell iOS this conversation happened, so the person turns up in
            // the share sheet and their notices arrive with a face on them.
            await MessageIntents.donate(
                MessageIntents.incoming(from: thread.title, handle: nil, body: body, threadId: thread.id),
                incoming: false
            )
        } catch {
            errorMessage = model.handle(error)
        }
        sending = false
    }
}

private struct Bubble: View {
    let message: ChatMessage
    let mine: Bool

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(mine ? "You" : message.senderName)
                        .font(.caption.weight(.bold))
                        .foregroundColor(Brand.navy)
                    if let label = message.kindLabel {
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundColor(.white)
                            .background(Brand.navy)
                            .clipShape(Capsule())
                    }
                    Text(message.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption2)
                        .foregroundColor(Brand.muted)
                }
                if !message.body.isEmpty {
                    Text(message.body)
                        .font(.body)
                        .foregroundColor(Brand.navy)
                        .textSelection(.enabled)
                }
                if let files = message.documents, !files.isEmpty {
                    ForEach(files) { file in
                        ProtectedImage(documentId: file.id, fileName: file.fileName, isImage: (file.mimeType ?? "").hasPrefix("image/"))
                    }
                }
            }
            .padding(12)
            .background(mine ? Brand.sky.opacity(0.35) : (message.isSystem ? Brand.mist : Brand.paper))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(mine ? Color.clear : Brand.line, style: StrokeStyle(lineWidth: 1, dash: message.isSystem ? [4] : []))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// A photo that needs the signed-in session to download.
private struct ProtectedImage: View {
    @EnvironmentObject private var model: AppModel
    let documentId: String
    let fileName: String
    let isImage: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel(fileName)
            } else {
                Label(fileName, systemImage: isImage ? "photo" : "doc")
                    .font(.subheadline)
                    .foregroundColor(Brand.linkBlue)
            }
        }
        .task {
            guard isImage, image == nil, let api = model.api else { return }
            if let data = try? await api.data("/api/documents/\(documentId)/file"), let loaded = UIImage(data: data) {
                image = loaded
            }
        }
    }
}

private struct ContactPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (Contact) -> Void

    @State private var contacts: [Contact] = []
    @State private var search = ""
    @State private var loading = true

    private var shown: [Contact] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? contacts : contacts.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List(shown) { contact in
                Button {
                    onPick(contact)
                } label: {
                    VStack(alignment: .leading) {
                        Text(contact.name).font(.headline).foregroundColor(Brand.navy)
                        Text(contact.role == "ADMIN" ? "Dispatcher" : "Driver")
                            .font(.subheadline)
                            .foregroundColor(Brand.muted)
                    }
                }
            }
            .overlay {
                if loading { ProgressView() } else if shown.isEmpty {
                    Text("Nobody matches that search.").foregroundColor(Brand.muted)
                }
            }
            .searchable(text: $search, prompt: "Search people")
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .lightBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if let api = model.api, let list: ContactList = try? await api.get("/api/messages/contacts") {
                    contacts = list.contacts
                }
                loading = false
            }
        }
    }
}
