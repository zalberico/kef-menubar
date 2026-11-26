import SwiftUI
import WidgetKit

@main
struct RemoteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        PowerControl()
        MuteControl()
        InputControl()
        #if DEBUG || PROBE
        ProbeControl()
        #endif
    }
}
