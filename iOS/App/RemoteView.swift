import KEFAppCore
import SwiftUI

/// Placeholder remote: enough to see the connection work. The real screen replaces it.
struct RemoteView: View {
    @Environment(SpeakerModel.self) private var model
    @State private var manualHost = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Speaker", value: model.name)
                    LabeledContent("Status", value: model.statusText)
                    LabeledContent("Volume") {
                        HStack(spacing: 16) {
                            Button("Volume Down", systemImage: "minus") { model.setVolume(model.volume - 1) }
                            Text(model.volume, format: .number)
                                .monospacedDigit()
                                .frame(minWidth: 32)
                            Button("Volume Up", systemImage: "plus") { model.setVolume(model.volume + 1) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(!model.isOnline)
                    }
                }

                Section("Speaker Address") {
                    TextField("IP address", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { model.useManualHost(manualHost) }
                    Button("Connect") { model.useManualHost(manualHost) }
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Find Automatically") { model.useAutomatic() }
                }

                #if DEBUG
                Section {
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                }
                #endif
            }
            .navigationTitle(Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""))
        }
    }
}
