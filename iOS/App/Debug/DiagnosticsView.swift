#if DEBUG || PROBE
import KEFAppCore
import SwiftUI

/// Debug only: the probe log the app and the widget extension share, plus what the
/// extension can see in the App Group. Never shows an address or speaker identifier.
struct DiagnosticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var lines: [String] = []
    @State private var isRunning = false
    @State private var snapshotDate: Date?
    @State private var config = SharedSpeakerConfig()
    @State private var hasContainer = false

    var body: some View {
        List {
            Section("App Group") {
                LabeledContent("Container", value: hasContainer ? "Available" : "Missing")
                LabeledContent("Mode", value: config.hostMode.rawValue)
                LabeledContent("Saved address", value: config.host == nil ? "None" : "Yes")
                LabeledContent("Widget snapshot") {
                    if let snapshotDate {
                        Text(snapshotDate, format: .dateTime.hour().minute().second())
                    } else {
                        Text("None")
                    }
                }
            }

            Section {
                Button("Run Probe in App") {
                    Task {
                        isRunning = true
                        await SpeakerProbe.run()
                        reload()
                        isRunning = false
                    }
                }
                .disabled(isRunning)
                Button("Clear Log", role: .destructive) {
                    ProbeLog.clear()
                    reload()
                }
            } footer: {
                Text("The Speaker Probe control and the Shortcuts action add lines here too. Pull to refresh.")
            }

            Section("Probe Log, Newest First") {
                if lines.isEmpty {
                    Text("No entries yet")
                        .foregroundStyle(.secondary)
                }
                ForEach(lines.reversed(), id: \.self) { line in
                    Text(verbatim: line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .refreshable { reload() }
        .task { reload() }
        // Pick up lines the control or Shortcuts added while the app was in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    private func reload() {
        lines = ProbeLog.lines()
        snapshotDate = AppGroup.snapshotStore?.read()?.updatedAt
        config = AppGroup.speakerConfig()
        hasContainer = AppGroup.containerURL != nil
    }
}
#endif
