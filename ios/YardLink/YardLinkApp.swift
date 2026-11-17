import SwiftUI
import UIKit

@main
struct YardLinkApp: App {
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    @StateObject private var model = AppModel()

    init() {
        // Back arrows and bar buttons are white on the navy bar.
        UINavigationBar.appearance().tintColor = .white
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in
                    // A widget opens yardlink://open/tasks and the like.
                    if url.host == "open" {
                        PushCenter.shared.openScreen = url.lastPathComponent
                        return
                    }
                    // A tapped yardlink://connect link does the same as scanning the code.
                    model.handleConnectText(url.absoluteString)
                }
        }
    }
}
