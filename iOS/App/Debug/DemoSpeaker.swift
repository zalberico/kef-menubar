#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import KEFAppCore
import KEFKit

/// Debug only: the `-DemoSpeaker` launch argument shows a made-up speaker ("Living Room",
/// playing a placeholder track, one KC62 sub) for screenshots; add `-DemoVolumeLimit 40`
/// to turn its volume limit on, and `-DemoSource tv` (any input, or `standby`) to start on
/// another input; `-DemoKW1 YES` puts the sub on a KW1 wireless kit (no T2 defaults).
/// Its client talks to an in-process fake through a URLProtocol, discovery finds nothing,
/// and its preferences live in their own suite, so nothing touches the network, the App
/// Group or the real speaker's settings.
enum DemoSpeaker {
    static let argument = "-DemoSpeaker"
    static let host = ["192", "0", "2", "10"].joined(separator: ".")  // TEST-NET-1
    static let name = "Living Room"

    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    @MainActor static func makeModel() -> SpeakerModel {
        let suite = "\(AppLog.subsystem).demo"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = Preferences(defaults: defaults)
        preferences.lastHost = host
        preferences.lastSpeakerName = name
        preferences.lastSource = Source.wifi.rawValue
        return SpeakerModel(
            preferences: preferences,
            logSubsystem: AppLog.subsystem,
            makeClient: { host in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [DemoSpeakerProtocol.self]
                return KEFClient(transport: KEFTransport(host: host, mode: .http, configuration: configuration))
            },
            discover: { [] })
    }
}

/// The fake speaker's state and its answers to the KEF API.
final class DemoSpeakerState: @unchecked Sendable {
    static let shared = DemoSpeakerState()

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var playing = true
    let artwork: Data = DemoSpeakerState.makeArtwork()

    static let artworkPath = "/demo/artwork.png"

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
        set(KEFPath.eqProfileV2, typed: ValueType.eqProfileV2, Self.eqProfile)
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

    private var playerData: String {
        let source = values[KEFPath.physicalSource] ?? ""
        guard source.contains("wifi") else { return #"{"state":"stopped"}"# }
        let icon = "http://\(DemoSpeaker.host)\(Self.artworkPath)"
        return """
        {"state":"\(playing ? "playing" : "paused")","trackRoles":{"title":"Placeholder Track","icon":"\(icon)",\
        "mediaData":{"metaData":{"artist":"Demo Artist","album":"Sample Sessions","serviceID":"airplay"}}},\
        "controls":{"pause":true,"next_":true,"previous":true}}
        """
    }

    /// Answer one request: (status, body).
    func handle(url: URL, body: Data?) -> (Int, Data) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.queryItems?.first { $0.name == "path" }?.value
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return lock.withLock {
            switch components?.path ?? "" {
            case Self.artworkPath:
                return (200, artwork)
            case Endpoint.getData:
                if path == KEFPath.playerData { return (200, Data("[\(playerData)]".utf8)) }
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
            if control == "pause" { playing.toggle() }
            return
        }
        guard role == "value", let value,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        else { return }
        values[path] = String(decoding: data, as: UTF8.self)
    }

    /// A 600 px placeholder cover: deep teal to saffron, with a record's grooves.
    private static func makeArtwork() -> Data {
        let size = 600
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return Data() }
        let colors = [CGColor(srgbRed: 0.04, green: 0.29, blue: 0.31, alpha: 1),
                      CGColor(srgbRed: 0.92, green: 0.65, blue: 0.21, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        }
        let center = CGPoint(x: Double(size) * 0.62, y: Double(size) * 0.4)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
        for ring in stride(from: 40.0, through: 420.0, by: 26.0) {
            context.setLineWidth(ring.truncatingRemainder(dividingBy: 78) == 0 ? 5 : 2)
            context.strokeEllipse(in: CGRect(x: center.x - ring, y: center.y - ring, width: 2 * ring, height: 2 * ring))
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36))
        guard let image = context.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
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
        let (status, data) = DemoSpeakerState.shared.handle(url: url, body: body)
        // The event queue's long poll waits like a real speaker's with nothing to report.
        let delay: TimeInterval = url.path == Endpoint.pollQueue ? 20 : 0.05
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard lock.withLock({ !stopped }) else { return }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }
}
#endif
