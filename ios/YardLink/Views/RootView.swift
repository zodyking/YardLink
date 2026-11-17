import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.stage {
            case .launching:
                LaunchView()
            case .connect:
                ConnectView()
            case .signIn:
                SignInView()
            case .ready(let user):
                MainTabs(user: user)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.stage)
        .task { await model.start() }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Brand.paper.ignoresSafeArea()
            VStack(spacing: 24) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Yard Link")
                ProgressView()
            }
        }
    }
}

/// The signed-in app: the web app's five destinations with its own bottom
/// bar, Tasks raised in the middle. A dispatcher signing in on a phone gets
/// Messages in place of Home and runs the desk from the web console.
struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var push = PushCenter.shared
    let user: SessionUser

    enum Screen: Hashable {
        case home, trips, tasks, containers, messages, more
    }

    @State private var selection: Screen

    init(user: SessionUser) {
        self.user = user
        _selection = State(initialValue: user.isDriver ? .home : .messages)
    }

    private var items: [DriverTabBar<Screen>.Item] {
        if user.isDriver {
            return [
                .init(screen: .home, label: "Home", glyph: .home),
                .init(screen: .trips, label: "Trips", glyph: .trips),
                .init(screen: .tasks, label: "Tasks", glyph: .tasks, raised: true),
                .init(screen: .containers, label: "Containers", glyph: .containers),
                .init(screen: .more, label: "More", glyph: .more),
            ]
        }
        return [
            .init(screen: .messages, label: "Messages", glyph: .tasks, badge: model.unreadMessages),
            .init(screen: .containers, label: "Containers", glyph: .containers),
            .init(screen: .more, label: "More", glyph: .more),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            // The system tab bar is hidden and replaced below, so each tab
            // keeps its own navigation while the bar stays still.
            TabView(selection: $selection) {
                if user.isDriver {
                    HomeView(user: user, openTasks: { selection = .tasks })
                        .toolbar(.hidden, for: .tabBar)
                        .tag(Screen.home)
                    TripsView()
                        .toolbar(.hidden, for: .tabBar)
                        .tag(Screen.trips)
                    TasksView()
                        .toolbar(.hidden, for: .tabBar)
                        .tag(Screen.tasks)
                } else {
                    MessagesView(user: user)
                        .toolbar(.hidden, for: .tabBar)
                        .tag(Screen.messages)
                }
                LocationsView()
                    .toolbar(.hidden, for: .tabBar)
                    .tag(Screen.containers)
                MoreView(user: user)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(Screen.more)
            }

            DriverTabBar(items: items, selection: $selection)
        }
        .background(Brand.mist)
        .task {
            // The question arrives with Yard Link on screen, not at launch.
            await PushCenter.shared.askAndRegister()
            PushCenter.shared.refresh()
            PushCenter.shared.clearBadge()
        }
        .onChange(of: push.openScreen) { screen in
            // A driver reads messages over Home, which clears this itself; a
            // dispatcher has a Messages tab.
            guard let screen else { return }
            if screen == "messages", user.isDriver {
                selection = .home
                return
            }
            if screen == "messages" { selection = .messages }
            else if screen == "tasks", user.isDriver { selection = .tasks }
            push.openScreen = nil
        }
        .task {
            // Keep the Messages badge current while the app is open.
            while !Task.isCancelled {
                await model.refreshUnread()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .task(id: scenePhase) {
            // While a driver has the app open, the phone's position fills in
            // today's time card. A declined permission just means no pings.
            guard user.isDriver, scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.sendTimeCardPing()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }
}
