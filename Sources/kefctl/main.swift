import Foundation
import KEFKit

/// kefctl — exercise KEFKit against a real speaker.
///
///     kefctl discover
///     kefctl <host> state | get <path> | rows <path> | volume [n] | mute [on|off]
///                   source [name] | control pause|next|previous | eq | eq-set <key> <value>
///                   maxvol [n] | limit [on|off] | watch [seconds] | firmware [check]
let usage = """
    usage: kefctl discover
           kefctl <host> state | get <path> | rows <path> | volume [n] | mute [on|off]
                         source [usb|wifi|tv|optical|coaxial|analog|bluetooth|standby]
                         control pause|next|previous | eq | eq-set <key> <value>
                         maxvol [n] | limit [on|off] | watch [seconds] | firmware [check]
                         name [new name] | settings | startupvol [level [input]]
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func parseBool(_ text: String) -> Bool {
    switch text.lowercased() {
    case "on", "true", "1", "yes": return true
    case "off", "false", "0", "no": return false
    default: fail("expected on/off, got \(text)")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else { fail(usage) }

if first == "discover" {
    for speaker in await KEFDiscovery.discover() {
        print("\(speaker.name)\t\(speaker.host)\t\(speaker.modelName ?? speaker.model ?? "?")\t\(speaker.mac ?? "")\t\(speaker.firmware ?? "")")
    }
    exit(0)
}

guard args.count >= 2 else { fail(usage) }
let client = KEFClient(host: first)
let command = args[1]
let rest = Array(args.dropFirst(2))

do {
    switch command {
    case "state":
        async let name = client.deviceName()
        async let status = client.status()
        async let source = client.source()
        async let volume = client.volume()
        async let muted = client.isMuted()
        async let maxVolume = client.maximumVolume()
        async let limited = client.isVolumeLimited()
        async let player = client.playerState()
        print("name:      \(try await name)")
        print("status:    \(try await status)")
        print("source:    \(try await source.rawValue)")
        print("volume:    \(try await volume)  muted: \(try await muted)")
        print("max:       \(try await maxVolume)  limit enabled: \(try await limited)")
        let p = try await player
        print("player:    \(p.playback.rawValue)  \(p.track?.title ?? "-") — \(p.track?.artist ?? "-")  art: \(p.track?.artworkURL?.absoluteString ?? "-")")
        print("controls:  pause=\(p.canPause) next=\(p.canNext) previous=\(p.canPrevious)")
        print("secure:    \(await client.transport.isSecure.map(String.init(describing:)) ?? "?")")

    case "get":
        guard let path = rest.first else { fail(usage) }
        print(try await client.getData(path).compactString)

    case "rows":
        guard let path = rest.first else { fail(usage) }
        print(try await client.getRows(path, from: 0, to: 100).compactString)

    case "volume":
        if let text = rest.first {
            guard let volume = Int(text) else { fail("volume must be 0-100") }
            try await client.setVolume(volume)
        }
        print(try await client.volume())

    case "mute":
        if let text = rest.first { try await client.setMuted(parseBool(text)) }
        print(try await client.isMuted())

    case "source":
        if let text = rest.first {
            guard let source = Source(rawValue: text) else { fail("unknown source \(text)") }
            try await client.setSource(source)
        }
        print(try await client.source().rawValue)

    case "control":
        guard let text = rest.first, let command = PlayerCommand(rawValue: text) else { fail(usage) }
        try await client.control(command)
        print("ok")

    case "eq":
        let profile = try await client.eqProfile()
        print(JSON.object(profile.raw).compactString)
        for (key, range) in await client.eqRanges().sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("  \(key.rawValue): \(range.min)…\(range.max) step \(range.step)")
        }

    case "eq-set":
        guard rest.count == 2, let key = EqKey(rawValue: rest[0]) else { fail("eq-set <key> <value>") }
        var profile = try await client.eqProfile()
        let text = rest[1]
        if let number = Double(text) {
            guard number.isFinite else { fail("value must be a finite number") }
            profile.set(key, number)
        } else if ["on", "off", "true", "false"].contains(text) {
            profile.set(key, parseBool(text))
        } else {
            profile.set(key, text)
        }
        try await client.setEqProfile(profile, validatingAgainst: await client.eqRanges())
        try await Task.sleep(for: .milliseconds(300))
        print(try await client.eqProfile()[key]?.compactString ?? "nil")

    case "maxvol":
        if let text = rest.first {
            guard let volume = Int(text) else { fail("maxvol must be 0-100") }
            try await client.setMaximumVolume(volume)
        }
        print(try await client.maximumVolume())

    case "limit":
        if let text = rest.first { try await client.setVolumeLimited(parseBool(text)) }
        print(try await client.isVolumeLimited())

    case "watch":
        let seconds = rest.first.flatMap(Int.init) ?? 30
        let queue = client.makeEventQueue()
        try await queue.subscribe([
            KEFPath.speakerStatus, KEFPath.physicalSource, KEFPath.volume, KEFPath.mute,
            KEFPath.playerData, KEFPath.deviceName, KEFPath.maximumVolume, KEFPath.volumeLimit, KEFPath.eqProfileV2,
        ])
        print("queue \(await queue.queueID ?? "?"), watching for \(seconds)s")
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            let remaining = Int((deadline - ContinuousClock.now).components.seconds)
            for event in try await queue.poll(timeout: max(1, min(25, remaining))) {
                print("\(event.type) \(event.path) = \(event.value?.compactString.prefix(160) ?? "nil")")
            }
        }

    case "name":
        if !rest.isEmpty { try await client.setDeviceName(rest.joined(separator: " ")) }
        print(try await client.deviceName())

    case "settings":
        let model = try? await client.modelName()
        let s = await client.speakerSettings(inputs: Source.inputs(forModel: model))
        func show(_ value: Any?) -> String { value.map { "\($0)" } ?? "-" }
        print("auto standby:    \(show(s.standbyMode?.title))")
        print("wake source:     \(show(s.wakeSource?.title))")
        print("switch to TV:    \(show(s.autoSwitchToTV))")
        print("startup volume:  \(show(s.startupVolumeEnabled)) (per input: \(show(s.startupVolumePerInput)), all: \(show(s.startupVolume)))")
        let perInput = s.startupVolumes.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        if !perInput.isEmpty { print("  per input:     \(perInput.joined(separator: ", "))") }
        print("standby light:   \(show(s.standbyLight))")
        print("startup sound:   \(show(s.startupTone))")
        print("remote:          \(show(s.remoteEnabled)) (volume step \(show(s.remoteVolumeStep)))")

    case "startupvol":
        // startupvol [level [input]]: the level the speaker returns to after standby
        // (used only while "reset volume after standby" is on).
        if let text = rest.first {
            guard let level = Int(text) else { fail("startupvol <0-100> [input]") }
            let source = rest.count > 1 ? Source(rawValue: rest[1]) : nil
            if rest.count > 1, source == nil { fail("unknown input \(rest[1])") }
            try await client.setStartupVolume(level, for: source)
        }
        let s = await client.speakerSettings(inputs: Source.inputs(forModel: try? await client.modelName()))
        print("all inputs: \(s.startupVolume.map(String.init) ?? "-")  enabled: \(s.startupVolumeEnabled.map(String.init) ?? "-")")
        print(s.startupVolumes.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", "))

    case "firmware":
        // Status, or `firmware check` to ask the speaker to look for an update.
        // Installing is only offered in the app, behind a confirmation.
        if let sub = rest.first {
            guard sub == "check" else { fail("firmware [check]") }
            try await client.checkForFirmwareUpdate()
            for _ in 0..<20 {  // the speaker answers within seconds
                try await Task.sleep(for: .seconds(1))
                if try await !client.firmwareUpdateStatus().isBusy { break }
            }
        }
        let status = try await client.firmwareUpdateStatus()
        print("installed: \(try await client.firmwareVersion())")
        print("update:    \(status.rawState)\(status.availableVersion.map { " \($0)" } ?? "")\(status.downloadProgress.map { $0 > 0 ? " \($0)%" : "" } ?? "")")
        if let info = try? await client.firmwareInstallInfo() {
            let parts = info.progress.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)%" }.joined(separator: ", ")
            print("install:   \(info.status)\(parts.isEmpty ? "" : " (\(parts))")\(info.hasError ? " error: \(info.error ?? "")" : "")")
        }

    default:
        fail(usage)
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
