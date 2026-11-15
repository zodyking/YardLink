import SwiftUI

@main
struct YardLinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(Brand.linkBlue)
                .onOpenURL { url in
                    // A tapped yardlink://connect link does the same as scanning the code.
                    model.handleConnectText(url.absoluteString)
                }
        }
    }
}
