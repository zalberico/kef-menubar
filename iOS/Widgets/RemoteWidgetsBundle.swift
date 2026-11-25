import SwiftUI
import WidgetKit

@main
struct RemoteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        #if DEBUG || PROBE
        ProbeControl()
        #endif
    }
}
