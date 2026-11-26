import Foundation
import KEFKit

/// Value formatting shared by the Mac and iPhone apps.
public enum Fmt {
    public static func signedDB(_ v: Double) -> String {
        let number = v.rounded() == v ? String(Int(v)) : String(format: "%g", v)
        return v > 0 ? "+\(number) dB" : (v == 0 ? "0 dB" : "\(number.replacingOccurrences(of: "-", with: "−")) dB")
    }

    public static func hertz(_ v: Double) -> String {
        v.rounded() == v ? "\(Int(v)) Hz" : String(format: "%.1f Hz", v)
    }

    public static func balance(_ v: Double) -> String {
        let steps = Int(v)
        return steps == 0 ? "Center" : (steps < 0 ? "L \(-steps)" : "R \(steps)")
    }
}

extension Source {
    /// SF Symbol for the input.
    public var symbol: String {
        switch self {
        case .usb: Self.usbSymbol
        case .wifi: "airplay.audio"
        case .tv: "tv"
        case .optical: "rays"
        case .analog: "waveform.path"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .coaxial: "cable.coaxial"
        case .standby: "power"
        }
    }

    #if os(macOS)
    private static let usbSymbol = "macmini.fill"
    #else
    private static let usbSymbol = "cable.connector"
    #endif

    public var shortName: String { self == .wifi ? "Wi-Fi" : displayName }
}

/// Product names for the codes in `settings:/kef/host/modelName`.
public enum SpeakerProduct {
    public static func displayName(forCode code: String) -> String {
        ["SP4041": "LSX II", "SP4077": "LSX II LT", "SP4025": "LS50 Wireless II", "SP4033": "LS60 Wireless"][code] ?? code
    }
}

extension StandbyMode {
    /// The auto-standby choices to offer: like KEF Connect, ECO only with the default wake
    /// source (the current mode always stays listed).
    public static func options(current: StandbyMode, wakeRaw: String?) -> [StandbyMode] {
        allCases.filter { $0 == current || $0.isAllowed(wakeRaw: wakeRaw) }
    }
}

extension WakeSource {
    /// The wake sources for these inputs, plus the current one if it isn't among them.
    public static func options(for inputs: [Source], current: WakeSource) -> [WakeSource] {
        let options = options(for: inputs)
        return options.contains(current) ? options : options + [current]
    }

    /// The note under the wake source picker.
    public static func caption(standbyMode: StandbyMode?) -> String {
        standbyMode == .eco
            ? "Wi-Fi and AirPlay always wake the speaker. ECO standby needs the default wake source, so choosing another input switches auto standby to 30 minutes."
            : "Wi-Fi and AirPlay always wake the speaker. ECO standby is only available with the default wake source."
    }
}

/// Makes sure the speaker at an address is the chosen one (DHCP can hand its old IP to
/// another KEF speaker). Speaker IDs are MAC addresses.
public enum SpeakerIdentity {
    public static func normalizedMAC(_ text: String) -> String {
        text.lowercased().filter(\.isHexDigit)
    }

    /// `true` only when, in automatic mode with a chosen speaker, the speaker at `client`
    /// reports another MAC address. A speaker that doesn't report one is given the benefit
    /// of the doubt, like the app has always done.
    public static func isDifferentSpeaker(_ client: KEFClient, hostMode: Preferences.HostMode, preferredID: String) async -> Bool {
        let preferred = normalizedMAC(preferredID)
        guard hostMode == .automatic, preferred.count == 12,
              let mac = try? await client.getValue(KEFPath.macAddress).string
        else { return false }
        return normalizedMAC(mac) != preferred
    }
}
