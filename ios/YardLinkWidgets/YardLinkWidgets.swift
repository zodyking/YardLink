import SwiftUI
import WidgetKit

@main
struct YardLinkWidgets: WidgetBundle {
    var body: some Widget {
        TasksWidget()
        TripWidget()
        QuickActionsWidget()
        TripLiveActivity()
    }
}
