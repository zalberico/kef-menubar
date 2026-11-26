import AppIntents
import KEFAppCore
import KEFKit

/// A speaker input for Shortcuts, Siri and the Input control: ``KEFKit/Source`` without
/// standby (Turn Off covers that). The raw values are the speaker's own names for its
/// inputs and are saved in people's shortcuts, so they never change; add cases at the end.
enum SpeakerInput: String, AppEnum {
    case wifi = "wifi"
    case bluetooth = "bluetooth"
    case tv = "tv"
    case optical = "optical"
    case coaxial = "coaxial"
    case analog = "analog"
    case usb = "usb"

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Input")

    // Symbols as the app's input chips show them (`Source.symbol`); literals, so the
    // titles are localizable.
    static let caseDisplayRepresentations: [SpeakerInput: DisplayRepresentation] = [
        .wifi: DisplayRepresentation(title: "Wi-Fi", image: .init(systemName: "airplay.audio")),
        .bluetooth: DisplayRepresentation(title: "Bluetooth", image: .init(systemName: "dot.radiowaves.left.and.right")),
        .tv: DisplayRepresentation(title: "TV", image: .init(systemName: "tv")),
        .optical: DisplayRepresentation(title: "Optical", image: .init(systemName: "rays")),
        .coaxial: DisplayRepresentation(title: "Coaxial", image: .init(systemName: "cable.coaxial")),
        .analog: DisplayRepresentation(title: "Analog", image: .init(systemName: "waveform.path")),
        .usb: DisplayRepresentation(title: "USB", image: .init(systemName: "cable.connector")),
    ]

    var source: Source {
        switch self {
        case .wifi: .wifi
        case .bluetooth: .bluetooth
        case .tv: .tv
        case .optical: .optical
        case .coaxial: .coaxial
        case .analog: .analog
        case .usb: .usb
        }
    }

    init?(_ source: Source) {
        self.init(rawValue: source.rawValue)
    }

    /// The input's SF Symbol, as the app's input chips show it.
    var systemImage: String { source.symbol }
}

/// The inputs of the speaker the app last connected to (an LSX II's when unknown).
struct SpeakerInputOptions: DynamicOptionsProvider {
    func results() async throws -> [SpeakerInput] {
        Source.inputs(forModel: SpeakerAccess.config().modelCode).compactMap(SpeakerInput.init)
    }
}
