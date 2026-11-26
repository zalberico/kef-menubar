import KEFAppCore
import KEFKit
import SwiftUI

/// One speaker to offer: found on the network now, connected to before, or both.
struct SpeakerChoice: Identifiable, Equatable {
    var id: String
    var name: String
    var host: String
    /// Product name, e.g. "LSX II".
    var product: String?
    var discovered: DiscoveredSpeaker?
    var saved: SavedSpeaker?

    /// Product and address ("LSX II · 192.0.2.10"), without repeating a name that is the
    /// product's.
    var detail: String {
        [product == name ? nil : product, host].compactMap { $0 }.joined(separator: " · ")
    }
}

extension SpeakerModel {
    /// Discovered speakers first (their addresses are fresh), then the others connected to
    /// before.
    var speakerChoices: [SpeakerChoice] {
        var choices = discovered.map { speaker in
            SpeakerChoice(id: speaker.id, name: speaker.name, host: speaker.host,
                          product: speaker.modelName ?? speaker.model.map { SpeakerProduct.displayName(forCode: $0) },
                          discovered: speaker)
        }
        for saved in preferences.knownSpeakers {
            if let index = choices.firstIndex(where: { $0.id == saved.id }) {
                choices[index].saved = saved
            } else {
                choices.append(SpeakerChoice(id: saved.id, name: saved.name, host: saved.host,
                                             product: saved.modelCode.map { SpeakerProduct.displayName(forCode: $0) },
                                             saved: saved))
            }
        }
        return choices
    }

    /// The speaker in use.
    func isCurrent(_ choice: SpeakerChoice) -> Bool {
        switch preferences.hostMode {
        case .manual:
            return choice.host == preferences.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
        case .automatic:
            let preferred = preferences.preferredSpeakerID
            return preferred.isEmpty ? choice.host == host : choice.id == preferred
        }
    }

    /// Switch to a speaker from the list.
    func choose(_ choice: SpeakerChoice) {
        guard !isCurrent(choice) else { return }
        if let speaker = choice.discovered {
            choose(speaker)
        } else if let saved = choice.saved, saved.id != saved.host {
            // Seen with Bonjour before (its id is its MAC address): the same as choosing it
            // from a scan, at its last address.
            preferences.preferredSpeakerID = saved.id
            preferences.lastHost = saved.host
            if preferences.hostMode != .automatic { preferences.hostMode = .automatic }
            reconnect(rediscover: false)
        } else {
            useManualHost(choice.host)
        }
    }
}

/// A row of the speaker list: the cabinet, name, product and address, a check on the one in use.
struct SpeakerRow: View {
    let choice: SpeakerChoice
    let isCurrent: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var cabinetHeight = 38

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 14) {
                let height = min(cabinetHeight, 64)
                CabinetArt()
                    .frame(width: height * CabinetArt.aspectRatio, height: height)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.name)
                        .foregroundStyle(.primary)
                    Text(choice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)  // the row is marked selected
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint(isCurrent ? "" : "Connects to this speaker")
    }
}

/// The manual address field and its Connect button.
struct ManualHostField: View {
    let connect: (String) -> Void

    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        let isBlank = ui.manualHostDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 10) {
            TextField("IP address", text: $ui.manualHostDraft)
                .keyboardType(.numbersAndPunctuation)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    if !isBlank { connect(ui.manualHostDraft) }
                }
            Button("Connect") {
                connect(ui.manualHostDraft)
            }
            .prominentGlassStyle()
            .disabled(isBlank)
        }
    }
}
