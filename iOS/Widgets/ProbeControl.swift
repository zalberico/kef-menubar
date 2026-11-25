#if DEBUG
import AppIntents
import SwiftUI
import WidgetKit

/// Debug only: a Control Center button that runs ``ProbeIntent`` from the widget extension.
struct ProbeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SpeakerProbe") {
            ControlWidgetButton(action: ProbeIntent()) {
                Label("Speaker Probe", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .displayName("Speaker Probe")
        .description("Debug: reads the speaker once and logs whether it could be reached.")
    }
}
#endif
