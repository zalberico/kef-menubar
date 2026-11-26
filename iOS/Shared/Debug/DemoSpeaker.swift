#if DEBUG
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import KEFAppCore
import KEFKit

/// Debug only: the `-DemoSpeaker` launch argument shows a made-up speaker ("Living Room",
/// playing a made-up album by a made-up band, one KC62 sub) for screenshots; next and
/// previous step through its four tracks (two albums, each with a cover drawn in code); add `-DemoVolumeLimit 40`
/// to turn its volume limit on, and `-DemoSource tv` (any input, or `standby`) to start on
/// another input; `-DemoKW1 YES` puts the sub on a KW1 wireless kit (no T2 defaults), and
/// `-DemoNoEQ YES` makes the speaker fail every EQ profile read. It offers a firmware update
/// (3.2.10) that downloads, installs and restarts in about half a minute, all made up;
/// `-DemoFirmwareUpdate NO` starts it up to date, and `-DemoUnreachable 20` makes it
/// unreachable for the first 20 s (the offline screen and its pull to reconnect).
/// Its client talks to an in-process fake through a URLProtocol, discovery finds nothing,
/// and its preferences live in their own suite, so nothing touches the network, the App
/// Group or the real speaker's settings.
///
/// `-DemoIntents YES` (with `-DemoSpeaker`) also points the intents, controls and widgets
/// at a demo speaker until the app is next launched without it: the app sets a flag in the
/// App Group, and each process then serves its own fake whose state is kept in the App
/// Group (`demo-speaker.json`), so a change made from Control Center is still there for the
/// widget. They write the widgets' snapshot, which the real app rewrites once it runs again.
enum DemoSpeaker {
    static let argument = "-DemoSpeaker"
    static let host = ["192", "0", "2", "10"].joined(separator: ".")  // TEST-NET-1
    static let name = "Living Room"
    static let modelCode = "SP4041"

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    /// When `-DemoUnreachable` stops refusing connections (counted from the first request).
    private static let reachableFrom = Date.now.addingTimeInterval(UserDefaults.standard.double(forKey: "DemoUnreachable"))

    /// `-DemoUnreachable` is still refusing connections. (The end is read before the clock:
    /// the first read sets it.)
    static var isUnreachable: Bool {
        let end = reachableFrom
        return Date.now < end
    }

    /// A client for the in-process fake (and only it).
    static func makeClient(host: String = host) -> KEFClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoSpeakerProtocol.self]
        return KEFClient(transport: KEFTransport(host: host, mode: .http, configuration: configuration))
    }

    // MARK: Intents, controls and widgets

    private static let intentsFlag = "DebugDemoIntents"

    /// The app was launched with `-DemoSpeaker -DemoIntents YES` last time.
    static var intentsUseDemo: Bool { AppGroup.defaults().bool(forKey: intentsFlag) }

    /// Called by the app at launch: turns the demo on for the extension, or off.
    static func setIntentsUseDemo(_ enabled: Bool) {
        if enabled {
            AppGroup.defaults().set(true, forKey: intentsFlag)
            // The extension starts from the app's demo (its launch arguments: volume limit,
            // input), not from a stale run.
            saveIntentState()
        } else {
            AppGroup.defaults().removeObject(forKey: intentsFlag)
            if let url = stateURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The configuration the intents use for the demo speaker.
    static var intentConfig: SharedSpeakerConfig {
        SharedSpeakerConfig(hostMode: .manual, manualHost: host, lastSpeakerName: name,
                            lastSource: Source.wifi.rawValue, lastModelCode: modelCode)
    }

    private static var stateURL: URL? {
        AppGroup.containerURL?.appendingPathComponent("demo-speaker.json")
    }

    /// Load the state the last intent left, before using the fake.
    static func loadIntentState() {
        guard let url = stateURL, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(DemoSpeakerState.Saved.self, from: data) else { return }
        DemoSpeakerState.shared.restore(saved)
    }

    /// Keep the fake's state for the next intent, control or widget.
    static func saveIntentState() {
        guard let url = stateURL, let data = try? JSONEncoder().encode(DemoSpeakerState.shared.saved) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The fake speaker's state and its answers to the KEF API.
final class DemoSpeakerState: @unchecked Sendable {
    static let shared = DemoSpeakerState()

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var playing = true
    /// Which of ``tracks`` is playing.
    private var track = 0
    /// Changes the event queue reports next, like a real speaker's: a path and its new
    /// typed value, or no value ("changed, fetch it": the app then reads everything again).
    private var changes: [(path: String, value: String?)] = []
    /// The made-up firmware update: offered until it's installed.
    private var offersUpdate = UserDefaults.standard.object(forKey: "DemoFirmwareUpdate") == nil
        || UserDefaults.standard.bool(forKey: "DemoFirmwareUpdate")
    private var checkStartedAt: Date?
    private var updateStartedAt: Date?

    static let updateVersion = "3.2.10.0x1a2b3c4"
    /// The update's timeline, in seconds from "Update": download, install, then a restart
    /// during which the speaker can't be reached.
    private static let downloadEnd = 8.0, installEnd = 16.0, restartEnd = 28.0
    /// The made-up albums: a title, its cover's path and the cover.
    struct Album: Sendable {
        let title: String
        let path: String
        let cover: @Sendable () -> Data
    }

    static let artist = "The Speakeasy Trio"
    static let lateNight = Album(title: "Late Night Session", path: "/demo/late-night-session.png",
                                 cover: { DemoCover.lateNightSession })
    static let earlyLight = Album(title: "Early Light", path: "/demo/early-light.png",
                                  cover: { DemoCover.earlyLight })
    static let tracks: [(title: String, album: Album)] = [
        ("Corner Booth", lateNight), ("Velvet Lamps", lateNight), ("Two A.M. Stroll", lateNight),
        ("Morning Rain", earlyLight),
    ]

    private init() {
        set(KEFPath.deviceName, typed: "string_", #""\#(DemoSpeaker.name)""#)
        set(KEFPath.modelName, typed: "string_", #""SP4041""#)
        set(KEFPath.firmware, typed: "string_", #""3.1.141""#)
        let source = UserDefaults.standard.string(forKey: "DemoSource").flatMap(Source.init(rawValue:)) ?? .wifi
        set(KEFPath.speakerStatus, typed: "kefSpeakerStatus", source == .standby ? #""standby""# : #""powerOn""#)
        set(KEFPath.physicalSource, typed: "kefPhysicalSource", #""\#(source.rawValue)""#)
        set(KEFPath.volume, typed: "i32_", "24")
        set(KEFPath.mute, typed: "bool_", "false")
        let limit = UserDefaults.standard.integer(forKey: "DemoVolumeLimit")
        set(KEFPath.maximumVolume, typed: "i32_", String((1...100).contains(limit) ? limit : 100))
        set(KEFPath.volumeLimit, typed: "bool_", (1...100).contains(limit) ? "true" : "false")
        if !UserDefaults.standard.bool(forKey: "DemoNoEQ") {
            set(KEFPath.eqProfileV2, typed: ValueType.eqProfileV2, Self.eqProfile)
        }
        // Speaker settings as an LSX II reports them: ECO standby with the default wake
        // source, startup volume on with one level for all inputs (TV's own level is above
        // a volume limit of 40), standby light and startup sound on, remote step 3.
        set(KEFPath.standbyMode, typed: "kefStandbyMode", #""\#(StandbyMode.eco.rawValue)""#)
        set(KEFPath.wakeUpSource, typed: "kefWakeUpSource", #""\#(WakeSource.automatic.rawValue)""#)
        set(KEFPath.autoSwitchToTV, typed: ValueType.bool, "true")
        set(KEFPath.startupVolumeEnabled, typed: ValueType.bool, "true")
        set(KEFPath.startupVolumePerInput, typed: ValueType.bool, "false")
        set(KEFPath.startupVolume, typed: ValueType.i32, "30")
        let levels: [Source: Int] = [.usb: 20, .wifi: 30, .tv: 45, .optical: 35, .analog: 30, .bluetooth: 25]
        for (input, level) in levels {
            if let path = SpeakerSettings.startupVolumePath(input) { set(path, typed: ValueType.i32, String(level)) }
        }
        set(KEFPath.disableStandbyLight, typed: ValueType.bool, "false")
        set(KEFPath.startupTone, typed: ValueType.bool, "true")
        set(KEFPath.remoteIR, typed: ValueType.bool, "true")
        set(KEFPath.volumeStep, typed: ValueType.i16, "3")
    }

    /// An LSX II profile with one KEF KC62 sub at its defaults, desk mode on: the shape a
    /// real speaker answers with, including keys the app doesn't show (kept on writes).
    private static var eqProfile: String {
        let kw1 = UserDefaults.standard.bool(forKey: "DemoKW1")
        return """
        {"profileName":"Living Room","profileId":"00000000-0000-4000-8000-000000000001","soundProfile":"default",\
        "isExpertMode":false,"isEqMode":false,"isKW1":\(kw1),"wirelessSub":"none","subEnableStereo":false,\
        "trebleAmount":0,"bassExtension":"standard","deskMode":true,"deskModeSetting":-3,"wallMode":false,\
        "wallModeSetting":0,"wallMounted":false,"balance":0,"phaseCorrection":true,"dialogueMode":false,\
        "audioPolarity":"normal","subwooferCount":1,"subwooferPreset":"kc62","subwooferGain":-1,\
        "subOutLPFreq":55,"highPassMode":true,"highPassModeFreq":67.5,"subwooferPolarity":"normal",\
        "subwooferOut":true}
        """
    }

    private func set(_ path: String, typed type: String, _ payload: String) {
        values[path] = #"{"type":"\#(type)","\#(type)":\#(payload)}"#
    }

    /// What intents keep between runs: the values and whether it is playing.
    struct Saved: Codable {
        var values: [String: String]
        var playing: Bool
        var track: Int?
    }

    var saved: Saved { lock.withLock { Saved(values: values, playing: playing, track: track) } }

    func restore(_ saved: Saved) {
        lock.withLock {
            values = saved.values
            playing = saved.playing
            track = saved.track.map { min(max($0, 0), Self.tracks.count - 1) } ?? 0
        }
    }

    private var playerData: String {
        let source = values[KEFPath.physicalSource] ?? ""
        guard source.contains("wifi") else { return #"{"state":"stopped"}"# }
        let (title, album) = Self.tracks[track]
        let icon = "http://\(DemoSpeaker.host)\(album.path)"
        return """
        {"state":"\(playing ? "playing" : "paused")","trackRoles":{"title":"\(title)","icon":"\(icon)",\
        "mediaData":{"metaData":{"artist":"\(Self.artist)","album":"\(album.title)","serviceID":"airplay"}}},\
        "controls":{"pause":true,"next_":true,"previous":true}}
        """
    }

    /// The changes since the last poll as queue events, or `nil` when nothing changed.
    func takeEvents() -> Data? {
        lock.withLock {
            guard !changes.isEmpty else { return nil }
            let events = changes.map { change in
                change.value.map { #"{"path":"\#(change.path)","itemType":"update","itemValue":\#($0)}"# }
                    ?? #"{"path":"\#(change.path)","itemType":"update"}"#
            }
            changes = []
            return Data("[\(events.joined(separator: ","))]".utf8)
        }
    }

    /// Queue an event for `path` (the latest change of a path replaces an older one).
    private func changed(_ path: String, value: String?) {
        changes.removeAll { $0.path == path }
        changes.append((path, value))
    }

    // MARK: Firmware

    /// Seconds into the update, `nil` when none is running. Finishes it once the speaker
    /// is "back" with the new version. Call with the lock held.
    private func updateElapsed(now: Date = .now) -> TimeInterval? {
        guard let started = updateStartedAt else { return nil }
        let elapsed = now.timeIntervalSince(started)
        if elapsed >= Self.restartEnd {
            updateStartedAt = nil
            offersUpdate = false
            set(KEFPath.firmware, typed: "string_", #""\#(shortFirmwareVersion(Self.updateVersion))""#)
            return nil
        }
        return elapsed
    }

    /// The speaker is restarting after the update: every request fails.
    var isRestarting: Bool {
        lock.withLock { updateElapsed().map { $0 >= Self.installEnd } ?? false }
    }

    /// How long the event queue's long poll waits: 20 s, or until the restart begins.
    var pollDelay: TimeInterval {
        lock.withLock {
            guard let elapsed = updateElapsed(), elapsed < Self.installEnd else { return 20 }
            return min(20, max(0.05, Self.installEnd - elapsed))
        }
    }

    private var firmwareStatus: String {
        let image = #""imageDescription":{"version":"\#(Self.updateVersion)","forcedUpdate":false}"#
        if let elapsed = updateElapsed() {
            if elapsed < Self.downloadEnd {
                let progress = Int(elapsed / Self.downloadEnd * 100)
                return #"{"state":"downloading","downloadProgress":\#(progress),\#(image)}"#
            }
            return #"{"state":"downloaded",\#(image)}"#
        }
        if let checked = checkStartedAt, Date.now.timeIntervalSince(checked) < 3 {
            return #"{"state":"checkingForUpdate"}"#
        }
        return offersUpdate ? #"{"state":"newUpdateAvailable",\#(image)}"# : #"{"state":"idle"}"#
    }

    private var firmwareInstallInfo: String {
        if let elapsed = updateElapsed(), elapsed >= Self.downloadEnd {
            let progress = min(100, Int((elapsed - Self.downloadEnd) / (Self.installEnd - Self.downloadEnd) * 100))
            return #"{"firmwareUpgradeStatus":"installing","firmwareUpgradeProgress":{"systemMCU":\#(progress),"slaveMCU":\#(max(0, progress - 4))},"firmwareUpgradeError":"noError"}"#
        }
        return #"{"firmwareUpgradeStatus":"finish","firmwareUpgradeProgress":{},"firmwareUpgradeError":"noError"}"#
    }

    /// Answer one request: (status, body).
    func handle(url: URL, body: Data?) -> (Int, Data) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.queryItems?.first { $0.name == "path" }?.value
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return lock.withLock {
            switch components?.path ?? "" {
            case Self.lateNight.path:
                return (200, Self.lateNight.cover())
            case Self.earlyLight.path:
                return (200, Self.earlyLight.cover())
            case Endpoint.getData:
                if path == KEFPath.playerData { return (200, Data("[\(playerData)]".utf8)) }
                if path == KEFPath.firmwareUpdateStatus { return (200, Data("[\(firmwareStatus)]".utf8)) }
                if path == KEFPath.firmwareInstallInfo { return (200, Data("[\(firmwareInstallInfo)]".utf8)) }
                guard let path, let value = values[path] else { return (500, Data(#"{"error":{"message":"no such path"}}"#.utf8)) }
                return (200, Data("[\(value)]".utf8))
            case Endpoint.setData:
                write(path: json["path"] as? String, role: json["role"] as? String, value: json["value"])
                return (200, Data("{}".utf8))
            case Endpoint.getRows:
                return (200, Data(#"{"rows":[]}"#.utf8))
            case Endpoint.modifyQueue:
                return (200, Data(#""{demo-queue}""#.utf8))
            case Endpoint.pollQueue:
                return (200, Data("[]".utf8))
            default:
                return (404, Data())
            }
        }
    }

    private func write(path: String?, role: String?, value: Any?) {
        guard let path else { return }
        if path == KEFPath.playerControl, let control = (value as? [String: Any])?["control"] as? String {
            switch control {
            case "pause": playing.toggle()
            case "next": track = (track + 1) % Self.tracks.count
            case "previous": track = (track + Self.tracks.count - 1) % Self.tracks.count
            default: return
            }
            changed(KEFPath.playerData, value: nil)
            return
        }
        if role == "activate" {
            switch path {
            case KEFPath.firmwareCheckForUpdate:
                if updateStartedAt == nil { checkStartedAt = .now }
            case KEFPath.firmwareDownloadNewUpdate:
                if offersUpdate, updateStartedAt == nil { updateStartedAt = .now }
            case KEFPath.startupVolumeSet:
                // {"type":"kefDefaultVolumeSettings","kefDefaultVolumeSettings":{...}}
                let settings = (value as? [String: Any])?["kefDefaultVolumeSettings"] as? [String: Any]
                if let input = (settings?["kefPhysicalSource"] as? String).flatMap(Source.init(rawValue:)),
                   let level = settings?["defaultVolume"] as? Int,
                   let levelPath = SpeakerSettings.startupVolumePath(input) {
                    set(levelPath, typed: ValueType.i32, String(level))
                }
            default:
                break
            }
            return
        }
        guard role == "value", let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        else { return }
        let written = String(decoding: data, as: UTF8.self)
        values[path] = written
        changed(path, value: written)
        // The track goes with the input (only Wi-Fi plays one here).
        if path == KEFPath.physicalSource { changed(KEFPath.playerData, value: nil) }
    }

}

/// The demo's album covers, drawn in code (600 px PNGs): made-up records by a made-up band,
/// no real artwork, names or logos.
enum DemoCover {
    static let size = 600

    /// Warm and late: a plum night, an amber spotlight, three rings for the trio.
    static let lateNightSession: Data = draw { context, size in
        let s = CGFloat(size)
        fill(context, s, top: rgb(0.16, 0.06, 0.10), bottom: rgb(0.05, 0.03, 0.05))
        // The spotlight, upper right, with a wide soft glow.
        let light = CGPoint(x: s * 0.66, y: s * 0.64)
        glow(context, at: light, radius: s * 0.62, rgb(0.98, 0.58, 0.24, 0.55), rgb(0.55, 0.12, 0.10, 0))
        disc(context, at: light, radius: s * 0.2, inner: rgb(1, 0.86, 0.56), outer: rgb(0.96, 0.55, 0.22))
        // Three rings, overlapping along a diagonal.
        context.setLineWidth(s * 0.006)
        for (index, alpha) in [0.75, 0.5, 0.3].enumerated() {
            let center = CGPoint(x: s * (0.27 + 0.085 * CGFloat(index)), y: s * (0.42 - 0.05 * CGFloat(index)))
            context.setStrokeColor(rgb(0.99, 0.9, 0.76, alpha))
            context.strokeEllipse(in: CGRect(x: center.x - s * 0.13, y: center.y - s * 0.13, width: s * 0.26, height: s * 0.26))
        }
        // A thin stage line.
        context.setFillColor(rgb(0.99, 0.82, 0.55, 0.5))
        context.fill(CGRect(x: s * 0.08, y: s * 0.235, width: s * 0.84, height: s * 0.003))
        grain(context, s, light: true)
        let cream = rgb(0.99, 0.92, 0.8)
        text(context, "THE SPEAKEASY TRIO", font: "AvenirNext-DemiBold", size: s * 0.032, kern: s * 0.008,
             color: cream, at: CGPoint(x: s * 0.08, y: s * 0.88))
        text(context, "Late Night", font: "Didot-Italic", size: s * 0.1, kern: 0,
             color: cream, at: CGPoint(x: s * 0.075, y: s * 0.12))
        text(context, "Session", font: "Didot-Italic", size: s * 0.1, kern: 0,
             color: rgb(0.98, 0.7, 0.38), at: CGPoint(x: s * 0.075, y: s * 0.035))
    }

    /// The other album: a pale dawn, a coral sun on the water.
    static let earlyLight: Data = draw { context, size in
        let s = CGFloat(size)
        fill(context, s, top: rgb(0.74, 0.84, 0.9), bottom: rgb(0.99, 0.86, 0.74))
        let horizon = s * 0.4
        disc(context, at: CGPoint(x: s * 0.5, y: horizon), radius: s * 0.19,
             inner: rgb(0.99, 0.62, 0.45), outer: rgb(0.93, 0.4, 0.33))
        // Water below the horizon, with the sun's broken reflection.
        context.setFillColor(rgb(0.62, 0.75, 0.84))
        context.fill(CGRect(x: 0, y: 0, width: s, height: horizon))
        context.setFillColor(rgb(0.97, 0.55, 0.42, 0.75))
        for row in 0..<7 {
            let width = s * (0.3 - 0.035 * CGFloat(row))
            let y = horizon - s * (0.03 + 0.04 * CGFloat(row))
            context.fill(CGRect(x: s * 0.5 - width / 2, y: y, width: width, height: s * 0.012))
        }
        grain(context, s, light: false)
        let ink = rgb(0.13, 0.2, 0.3)
        text(context, "THE SPEAKEASY TRIO", font: "AvenirNext-DemiBold", size: s * 0.032, kern: s * 0.008,
             color: ink, at: CGPoint(x: s * 0.08, y: s * 0.88))
        text(context, "Early Light", font: "Didot-Italic", size: s * 0.1, kern: 0,
             color: ink, at: CGPoint(x: s * 0.075, y: s * 0.74))
    }

    // MARK: Drawing

    private static func draw(_ body: (CGContext, Int) -> Void) -> Data {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        body(context, size)
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func gradient(_ colors: [CGColor]) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)
    }

    /// The whole square, `top` to `bottom` (Core Graphics' origin is the bottom left).
    private static func fill(_ context: CGContext, _ s: CGFloat, top: CGColor, bottom: CGColor) {
        guard let gradient = gradient([bottom, top]) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: s), options: [])
    }

    private static func glow(_ context: CGContext, at center: CGPoint, radius: CGFloat, _ inner: CGColor, _ outer: CGColor) {
        guard let gradient = gradient([inner, outer]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                                   options: [])
    }

    private static func disc(_ context: CGContext, at center: CGPoint, radius: CGFloat, inner: CGColor, outer: CGColor) {
        guard let gradient = gradient([inner, outer]) else { return }
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        context.clip()
        let offset = CGPoint(x: center.x - radius * 0.3, y: center.y + radius * 0.3)
        context.drawRadialGradient(gradient, startCenter: offset, startRadius: 0, endCenter: center,
                                   endRadius: radius * 1.1, options: [.drawsAfterEndLocation])
        context.restoreGState()
    }

    /// A fine print grain, the same every time.
    private static func grain(_ context: CGContext, _ s: CGFloat, light: Bool) {
        var seed: UInt64 = 0x5EED
        func next() -> CGFloat {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31)
        }
        context.setFillColor(light ? rgb(1, 0.95, 0.85, 0.07) : rgb(0.2, 0.15, 0.1, 0.06))
        for _ in 0..<9000 {
            context.fill(CGRect(x: next() * s, y: next() * s, width: 1.2, height: 1.2))
        }
    }

    private static func text(_ context: CGContext, _ string: String, font name: String, size: CGFloat,
                             kern: CGFloat, color: CGColor, at origin: CGPoint) {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = origin
        CTLineDraw(line, context)
    }
}

/// Serves ``DemoSpeakerState`` to the demo client's session (and only that session).
final class DemoSpeakerProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        let state = DemoSpeakerState.shared
        if state.isRestarting || DemoSpeaker.isUnreachable {
            fail(after: 0.3)
            return
        }
        let (status, data) = state.handle(url: url, body: body)
        if url.path == Endpoint.pollQueue {
            poll(url: url, until: Date.now + state.pollDelay)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            answer(url: url, status: status, data: data)
        }
    }

    /// The event queue's long poll: it waits like a real speaker's, answering early with a
    /// change made meanwhile (another track), and is cut off when a made-up firmware update
    /// restarts the speaker.
    private func poll(url: URL, until deadline: Date) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
            // A cancelled poll ends here, leaving the changes to the next one.
            guard lock.withLock({ !stopped }) else { return }
            let state = DemoSpeakerState.shared
            if state.isRestarting {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else if let events = state.takeEvents() {
                answer(url: url, status: 200, data: events)
            } else if Date.now >= deadline {
                answer(url: url, status: 200, data: Data("[]".utf8))
            } else {
                poll(url: url, until: deadline)
            }
        }
    }

    private func answer(url: URL, status: Int, data: Data) {
        guard lock.withLock({ !stopped }) else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The speaker is "restarting": the connection is refused, like a real one mid-reboot.
    private func fail(after delay: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard lock.withLock({ !stopped }) else { return }
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }
}
#endif
