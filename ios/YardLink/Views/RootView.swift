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

/// The signed-in app. Drivers get the five working tabs, with Messages one
/// tap away on Home. Dispatchers get Messages and More here and run the desk
/// from the web console.
struct MainTabs: View {
    @EnvironmentObject private var model: AppModel
    let user: SessionUser

    var body: some View {
        TabView {
            if user.isDriver {
                HomeView(user: user)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .badge(model.unreadMessages)
                TripsView()
                    .tabItem { Label("Trips", systemImage: "arrow.triangle.swap") }
                TasksView()
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                LocationsView()
                    .tabItem { Label("Locations", systemImage: "mappin.and.ellipse") }
            } else {
                MessagesView(user: user)
                    .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right.fill") }
                    .badge(model.unreadMessages)
                LocationsView()
                    .tabItem { Label("Locations", systemImage: "mappin.and.ellipse") }
            }
            MoreView(user: user)
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
        }
        .tint(Brand.linkBlue)
        .task {
            // Keep the Messages badge current while the app is open.
            while !Task.isCancelled {
                await model.refreshUnread()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
}
