import SwiftUI
import WidgetKit

@main
struct RemoteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        #if DEBUG
        ProbeControl()
        #endif
    }
}
