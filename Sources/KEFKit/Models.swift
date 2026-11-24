import Foundation

/// Physical source (input). `standby` means the speaker is off.
public enum Source: String, Sendable, CaseIterable, Identifiable {
    case wifi, bluetooth, tv, optical, coaxial, analog, usb, standby

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .tv: "TV"
        case .optical: "Optical"
        case .coaxial: "Coaxial"
        case .analog: "Analog"
        case .usb: "USB"
        case .standby: "Standby"
        }
    }

    /// Inputs of the LSX II, in the order the app shows them.
    public static let lsxII: [Source] = [.usb, .wifi, .tv, .optical, .analog, .bluetooth]

    /// The inputs to offer for a product code (`settings:/kef/host/modelName`). Only the
    /// LSX II is tested; other models follow KEF's published specs, LSX II as the fallback.
    public static func inputs(forModel code: String?) -> [Source] {
        switch code {
        case "SP4025", "SP4033": [.wifi, .tv, .optical, .coaxial, .analog, .bluetooth]  // LS50 Wireless II, LS60
        case "SP4077": [.usb, .wifi, .tv, .optical, .bluetooth]  // LSX II LT
        default: lsxII
        }
    }
}

/// `settings:/kef/host/speakerStatus`.
public enum SpeakerStatus: Sendable, Equatable {
    case standby, powerOn, networkSetup, firmwareUpgrade
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "standby": self = .standby
        case "powerOn": self = .powerOn
        case "networkSetup": self = .networkSetup
        case "firmwareUpgrade": self = .firmwareUpgrade
        default: self = .other(rawValue)
        }
    }
}

/// What is currently playing (from `trackRoles`, falling back on `mediaRoles` like the app).
public struct Track: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artworkURL: URL?
    public var serviceID: String?
}

/// `player:player/data`: playback state, current track and allowed controls.
public struct PlayerState: Sendable, Equatable {
    public enum Playback: String, Sendable {
        case stopped, playing, paused, transitioning
    }

    public var playback: Playback = .stopped
    public var track: Track?
    public var canPause = false
    public var canNext = false
    public var canPrevious = false

    public init() {}

    public init(json: JSON) {
        guard let data = json.unwrapped.object else { return }
        let value = JSON.object(data)
        playback = value["state"]?.string.flatMap(Playback.init(rawValue:)) ?? .stopped

        let trackRoles = value["trackRoles"] ?? .null
        let mediaRoles = value["mediaRoles"] ?? .null
        if trackRoles.object != nil || mediaRoles.object != nil {
            let metaT = trackRoles["mediaData"]?["metaData"] ?? .null
            let metaM = mediaRoles["mediaData"]?["metaData"] ?? .null
            func first(_ values: JSON?...) -> String? {
                values.lazy.compactMap { $0?.string }.first { !$0.isEmpty }
            }
            track = Track(
                title: first(trackRoles["title"], mediaRoles["title"]),
                artist: first(metaT["artist"], metaM["artist"]),
                album: first(metaT["album"], metaM["album"]),
                artworkURL: first(trackRoles["icon"], mediaRoles["icon"]).flatMap(URL.init(string:)),
                serviceID: first(metaT["serviceID"], metaM["serviceID"]))
        }
        let controls = value["controls"] ?? .null
        canPause = controls["pause"]?.bool ?? false
        canNext = (controls["next_"] ?? controls["next"])?.bool ?? false
        canPrevious = controls["previous"]?.bool ?? false
    }

    public var isPlaying: Bool { playback == .playing }

    /// Whether the track carries real metadata (physical inputs report e.g. title "usb").
    public var hasMetadata: Bool {
        guard let track, let title = track.title, !title.isEmpty else { return false }
        let physical = Set(Source.allCases.map(\.rawValue))
        return !(physical.contains(title.lowercased()) || title.lowercased() == track.serviceID?.lowercased())
    }
}

/// Commands of `player:player/control`. `pause` toggles play / pause.
public enum PlayerCommand: String, Sendable {
    case pause, stop, next, previous
}

/// One event of the speaker's event queue.
public struct KEFEvent: Sendable, Equatable {
    public var path: String
    /// `update`, `remove`... (`itemType` or `rowsType`).
    public var type: String
    /// Decoded new value; `nil` when the event carried none.
    public var value: JSON?
    /// The typed value as sent (`itemValue`).
    public var rawValue: JSON?

    public init(json: JSON) {
        path = json["path"]?.string ?? ""
        type = json["itemType"]?.string ?? json["rowsType"]?.string ?? "update"
        rawValue = json["itemValue"]
        value = rawValue?.unwrapped
    }

    /// Parse a `pollQueue` answer (`nil` / `[]` = the long-poll timed out).
    public static func parse(_ data: JSON?) throws -> [KEFEvent] {
        guard let data, data != .null else { return [] }
        guard let items = data.array else {
            throw KEFError.invalidResponse("unexpected pollQueue answer: \(data.compactString.prefix(200))")
        }
        return items.filter { $0.object != nil }.map(KEFEvent.init(json:))
    }

    /// Keep only the last event of each path, ordered by last occurrence.
    public static func latestPerPath(_ events: [KEFEvent]) -> [KEFEvent] {
        var order: [String] = []
        var latest: [String: KEFEvent] = [:]
        for event in events {
            if latest.updateValue(event, forKey: event.path) != nil { order.removeAll { $0 == event.path } }
            order.append(event.path)
        }
        return order.map { latest[$0]! }
    }
}
