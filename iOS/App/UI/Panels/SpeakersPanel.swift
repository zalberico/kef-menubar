import KEFAppCore
import KEFKit
import SwiftUI

/// The speakers found on the network and connected to before, and a manual address.
struct SpeakersPanel: View {
    @Environment(SpeakerModel.self) private var model
    @Environment(UIState.self) private var ui

    var body: some View {
        let choices = model.speakerChoices
        let isManual = model.preferences.hostMode == .manual
        List {
            Section {
                if choices.isEmpty {
                    HStack(spacing: 10) {
                        if model.isDiscovering { ProgressView() }
                        Text(model.isDiscovering ? "Searching…" : "No speakers found yet")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(choices) { choice in
                        SpeakerRow(choice: choice, isCurrent: model.isCurrent(choice)) {
                            ui.connectionChosen()
                            model.choose(choice)
                        }
                    }
                }
            } footer: {
                if model.isDiscovering, !choices.isEmpty { Text("Scanning…") }
            }

            if isManual {
                Section {
                    Button("Find Automatically") {
                        ui.connectionChosen()
                        model.useAutomatic()
                    }
                } footer: {
                    Text("Using the address \(model.preferences.manualHost). Find Automatically looks for the speaker on your Wi-Fi network instead.")
                }
            }

            Section {
                ManualHostField { text in
                    ui.connectionChosen()
                    model.useManualHost(text)
                }
            } header: {
                Text("Manual IP Address")
            } footer: {
                Text("Use this if your speaker doesn't show up above.")
            }

            Section("Status") {
                Text(summary)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            Section {
                NavigationLink("Diagnostics", value: UIState.Route.diagnostics)
            }
            #endif
        }
        .refreshable { await model.discover() }
        .navigationTitle("Speakers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.discover() }
                } label: {
                    Label(model.isDiscovering ? "Scanning…" : "Scan", systemImage: "arrow.clockwise")
                }
                .disabled(model.isDiscovering)
            }
        }
        .task {
            // Like the Mac's list: look once when there's nothing to show.
            if model.discovered.isEmpty, !model.isDiscovering { await model.discover() }
        }
    }

    /// The Mac's connection summary.
    private var summary: String {
        switch model.connection {
        case .online:
            let product = model.modelDisplayName ?? model.name
            var text = "\(product) at \(model.host ?? "") (\(model.isSecure == true ? "HTTPS" : "HTTP"))"
            if let firmware = model.firmware { text += "\nFirmware \(shortFirmwareVersion(firmware))" }
            return text
        case .connecting(let host): return "Connecting to \(host)…"
        case .searching: return "Searching…"
        case .offline(let reason): return reason
        }
    }
}
