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

/// The signed-in app. Drivers get the same five tabs as the web app, with
/// Messages one tap away on Home. Dispatchers get Messages, the equipment
/// lists and More here, and run the desk from the web console.
struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    let user: SessionUser

    private enum Screen: Hashable {
        case home, trips, tasks, containers, messages, more
    }

    @State private var selection: Screen

    init(user: SessionUser) {
        self.user = user
        _selection = State(initialValue: user.isDriver ? .home : .messages)
    }

    var body: some View {
        TabView(selection: $selection) {
            if user.isDriver {
                HomeView(user: user, openTasks: { selection = .tasks })
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .badge(model.unreadMessages)
                    .tag(Screen.home)
                TripsView()
                    .tabItem { Label("Trips", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                    .tag(Screen.trips)
                TasksView()
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                    .tag(Screen.tasks)
            } else {
                MessagesView(user: user)
                    .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
                    .badge(model.unreadMessages)
                    .tag(Screen.messages)
            }
            LocationsView()
                .tabItem { Label("Containers", systemImage: "shippingbox.fill") }
                .tag(Screen.containers)
            MoreView(user: user)
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(Screen.more)
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
