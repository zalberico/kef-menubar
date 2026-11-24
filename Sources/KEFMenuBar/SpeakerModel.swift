import AppKit
import KEFKit
import Observation
import os

/// Live state of the speaker, kept in sync through the event queue, and every command.
@MainActor @Observable
final class SpeakerModel {
    enum Connection: Equatable {
        case searching
        case connecting(String)
        case online
        case offline(String)
    }

    /// Paths followed on the event queue.
    static let watchedPaths = [
        KEFPath.speakerStatus, KEFPath.physicalSource, KEFPath.volume, KEFPath.mute,
        KEFPath.playerData, KEFPath.deviceName, KEFPath.maximumVolume, KEFPath.volumeLimit,
        KEFPath.eqProfileV2,
    ]

    let preferences: Preferences

    private(set) var connection: Connection = .searching
    private(set) var host: String?
    private(set) var isSecure: Bool?
    private(set) var name = "KEF Speaker"
    private(set) var modelName: String?
    private(set) var firmware: String?
    private(set) var status: SpeakerStatus?
    private(set) var source: Source?
    private(set) var lastSource: Source = .usb
    private(set) var volume = 0
    private(set) var muted = false
    private(set) var maximumVolume = 100
    private(set) var volumeLimited = false
    private(set) var player = PlayerState()
    private(set) var artwork: NSImage?
    private(set) var eq: EqProfile?
    private(set) var eqRanges = EqRange.defaults
    private(set) var discovered: [DiscoveredSpeaker] = []
    private(set) var isDiscovering = false
    private(set) var lastError: String?
    /// True for a moment after an input change, until the new input's own volume and EQ
    /// have been read back: the speaker keeps both per input, so writes based on the
    /// previous input's values would be wrong (or loud).
    private(set) var inputSettling = false

    // Firmware (see Firmware.swift in KEFKit).
    enum FirmwareActivity: Equatable { case idle, checking, updating }
    /// `nil` until read, or if the speaker doesn't report it.
    private(set) var firmwareStatus: FirmwareUpdateStatus?
    private(set) var firmwareInstall: FirmwareInstallInfo?
    private(set) var firmwareActivity: FirmwareActivity = .idle
    private(set) var firmwareCheckedAt: Date?
    /// Outcome of the last check or update, shown in Settings.
    private(set) var firmwareNotice: String?

    @ObservationIgnored private var client: KEFClient?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay: Duration = .seconds(1)
    @ObservationIgnored private var needsDiscovery: Bool
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?
    /// Bumped on every input change; writes and reads tagged with an older value are dropped.
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    // Coalesced writers: a drag sends at most one request at a time, always the latest value.
    @ObservationIgnored private var pendingVolume: (value: Int, generation: Int)?
    @ObservationIgnored private var volumeWriter: Task<Void, Never>?
    @ObservationIgnored private var volumeHoldUntil = ContinuousClock.now
    @ObservationIgnored private var pendingEQ: (profile: EqProfile, generation: Int)?
    @ObservationIgnored private var eqWriter: Task<Void, Never>?
    @ObservationIgnored private var eqHoldUntil = ContinuousClock.now
    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private var updateStartedFrom: String?
    @ObservationIgnored private var updateStartedAt: ContinuousClock.Instant?
    @ObservationIgnored private var updateSpeaker: String?

    private let log = Logger(subsystem: "KEFMenuBar", category: "speaker")

    init(preferences: Preferences) {
        self.preferences = preferences
        needsDiscovery = preferences.lastHost.isEmpty
        if !preferences.lastSpeakerName.isEmpty { name = preferences.lastSpeakerName }
        if let source = Source(rawValue: preferences.lastSource), source != .standby { lastSource = source }
    }

    // MARK: Derived state

    var isOnline: Bool { connection == .online }
    /// On/standby follows the physical source, like pykefcontrol's `is_on()`.
    /// `speakerStatus` is not reliable for this: after a wake it can stay "standby"
    /// while the speaker plays (seen on LSX II 3.1.141, with powermanager "online").
    var isOn: Bool { isOnline && source != nil && source != .standby }
    var volumeCeiling: Int { volumeLimited ? max(1, maximumVolume) : 100 }
    /// The speaker is installing firmware (it restarts at the end).
    var firmwareInstalling: Bool { status == .firmwareUpgrade || firmwareInstall?.isInstalling == true }
    var firmwareUpdateAvailable: Bool {
        isOnline && firmwareActivity == .idle && !firmwareInstalling && firmwareStatus?.isUpdateAvailable == true
    }

    var showsNowPlaying: Bool { isOn && (source == .wifi || source == .bluetooth) && player.hasMetadata }

    var statusText: String {
        switch connection {
        case .searching: return "Looking for speaker…"
        case .connecting(let host): return "Connecting to \(host)…"
        case .offline: return firmwareActivity == .updating ? "Restarting after update…" : "Offline — retrying"
        case .online:
            if status == .networkSetup { return "Network setup" }
            if status == .firmwareUpgrade || firmwareActivity == .updating { return "Updating firmware" }
            guard let source, source != .standby else { return "Standby" }
            let input = source == .wifi ? "Wi-Fi / AirPlay" : source.displayName
            return muted ? "\(input) · Muted" : input
        }
    }

    // MARK: Connection lifecycle

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    /// Drop the connection and start again (after the speaker settings changed).
    func reconnect(rediscover: Bool = true) {
        runTask?.cancel()
        runTask = nil
        if let client { Task { await client.transport.close() } }
        client = nil
        needsDiscovery = rediscover || preferences.lastHost.isEmpty
        retryDelay = .seconds(1)
        connection = .searching
        start()
    }

    private func run() async {
        while !Task.isCancelled {
            let resolved = await resolveHost()
            if Task.isCancelled { return }
            guard let host = resolved else {
                connection = .offline("No speaker found")
                await backoff()
                continue
            }
            if client?.host != host {
                if let client { await client.transport.close() }
                client = KEFClient(host: host)
                if self.host != host {  // another address: forget what the old one reported
                    modelName = nil
                    firmware = nil
                    firmwareStatus = nil
                    firmwareInstall = nil
                    firmwareCheckedAt = nil
                }
                // Keep following an update across reconnects (Retry, a new DHCP address after
                // the restart) as long as it's the same speaker; drop it for another speaker.
                if firmwareActivity == .updating, updateSpeaker != speakerIdentity(host: host) {
                    finishUpdate(nil)
                }
            }
            guard let client else { return }
            self.host = host
            if connection != .online { connection = .connecting(host) }
            do {
                try await session(client)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                log.info("connection lost: \(error.localizedDescription, privacy: .public)")
                connection = .offline(error.localizedDescription)
                if preferences.hostMode == .automatic { needsDiscovery = true }  // the IP may have changed
                await backoff()
            }
        }
    }

    private func backoff() async {
        if firmwareActivity == .updating, let started = updateStartedAt, ContinuousClock.now - started > .seconds(30 * 60) {
            finishUpdate("The speaker hasn't come back after the update. Check that it's plugged in and on the network.")
        }
        try? await Task.sleep(for: retryDelay)
        retryDelay = min(retryDelay * 2, .seconds(30))
    }

    private func resolveHost() async -> String? {
        switch preferences.hostMode {
        case .manual:
            let host = preferences.manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
            return host.isEmpty ? nil : host
        case .automatic:
            if !needsDiscovery, !preferences.lastHost.isEmpty { return preferences.lastHost }
            await discover()
            if Task.isCancelled { return nil }
            // Stick to the chosen speaker: never fall back to another KEF speaker on the
            // network just because ours is missing from one scan.
            let preferred = preferences.preferredSpeakerID
            let pick = preferred.isEmpty ? discovered.first : discovered.first { $0.id == preferred }
            if let pick {
                needsDiscovery = false
                preferences.lastHost = pick.host
                if preferred.isEmpty { preferences.preferredSpeakerID = pick.id }
                return pick.host
            }
            // Ours wasn't seen: keep trying its last address, unless another speaker has it now.
            if !preferred.isEmpty, discovered.contains(where: { $0.host == preferences.lastHost && $0.id != preferred }) {
                return nil
            }
            return preferences.lastHost.isEmpty ? nil : preferences.lastHost
        }
    }

    func discover() async {
        isDiscovering = true
        discovered = await KEFDiscovery.discover()
        isDiscovering = false
    }

    /// One connected session: subscribe, read everything, then follow events until an error.
    private func session(_ client: KEFClient) async throws {
        try await verifyIdentity(client)
        let queue = client.makeEventQueue()
        try await queue.subscribe(Self.watchedPaths)
        try await refreshAll(client)
        try Task.checkCancellation()
        connection = .online
        retryDelay = .seconds(1)
        isSecure = await client.transport.isSecure
        eqRanges = await client.eqRanges()
        let firmwareWatch = Task { await watchFirmware(client) }
        defer { firmwareWatch.cancel() }
        log.info("online: \(self.name, privacy: .public) at \(client.host, privacy: .public), secure=\(self.isSecure == true), source=\(self.source?.rawValue ?? "?", privacy: .public), volume=\(self.volume)")
        var queueResets = 0
        while true {
            try Task.checkCancellation()
            let started = ContinuousClock.now
            let events: [KEFEvent]
            do {
                events = try await queue.poll()
                queueResets = 0
            } catch KEFError.api {
                // The speaker forgot the queue: recreate it and resync, quietly. If it keeps
                // happening (another client evicting ours), back off through run() instead.
                queueResets += 1
                if queueResets > 3 { throw KEFError.connection("the speaker keeps dropping the event queue") }
                try await Task.sleep(for: .seconds(1))
                await queue.reset()
                try await queue.subscribe(Self.watchedPaths)
                try await refreshAll(client)
                continue
            }
            if events.isEmpty {
                if ContinuousClock.now - started < .seconds(1) { try await Task.sleep(for: .seconds(1)) }
                continue
            }
            try await apply(KEFEvent.latestPerPath(events), client)
        }
    }

    /// In automatic mode, make sure the speaker at this address is still the chosen one
    /// (DHCP can hand its old IP to another KEF speaker). Speaker IDs are MAC addresses.
    private func verifyIdentity(_ client: KEFClient) async throws {
        let preferred = Self.normalizedMAC(preferences.preferredSpeakerID)
        guard preferences.hostMode == .automatic, preferred.count == 12,
              let mac = try? await client.getValue(KEFPath.macAddress).string
        else { return }
        if Self.normalizedMAC(mac) != preferred {
            needsDiscovery = true
            throw KEFError.connection("A different speaker answered at \(client.host)")
        }
    }

    private static func normalizedMAC(_ text: String) -> String {
        text.lowercased().filter(\.isHexDigit)
    }

    private func refreshAll(_ client: KEFClient) async throws {
        async let name = client.deviceName()
        async let status = client.status()
        async let source = try? client.source()  // tolerate inputs newer firmware may add
        async let volume = client.volume()
        async let muted = client.isMuted()
        async let maximum = client.maximumVolume()
        async let limited = client.isVolumeLimited()
        async let player = client.playerState()
        async let eq = try? client.eqProfile()
        self.name = try await name
        preferences.lastSpeakerName = self.name
        self.status = try await status
        // A full read is a consistent snapshot of the current input: no settling needed.
        if let source = await source { self.source = source; remember(source) }
        sourceGeneration += 1
        settleTask?.cancel()
        inputSettling = false
        if ContinuousClock.now >= volumeHoldUntil { self.volume = try await volume }
        self.muted = try await muted
        self.maximumVolume = try await maximum
        self.volumeLimited = try await limited
        setPlayer(try await player)
        if let profile = await eq, ContinuousClock.now >= eqHoldUntil { self.eq = profile }
        if modelName == nil || firmwareActivity == .updating {
            modelName = try? await client.getValue(KEFPath.modelName).string
            firmware = try? await client.firmwareVersion()
        }
    }

    private func apply(_ events: [KEFEvent], _ client: KEFClient) async throws {
        // An event without a value means "changed, fetch it": resync everything once.
        if events.contains(where: { $0.value == nil && Self.watchedPaths.contains($0.path) }) {
            try await refreshAll(client)
        }
        for event in events {
            guard let value = event.value else { continue }
            switch event.path {
            case KEFPath.volume:
                if let v = value.int, inputSettling || (ContinuousClock.now >= volumeHoldUntil && pendingVolume == nil) { volume = v }
            case KEFPath.mute:
                if let v = value.bool { muted = v }
            case KEFPath.physicalSource:
                if let v = value.string.flatMap(Source.init(rawValue:)), v != source {
                    setSource(v)
                    settle(after: .milliseconds(1500))  // the speaker already switched
                }
            case KEFPath.speakerStatus:
                if let v = value.string { status = SpeakerStatus(rawValue: v) }
            case KEFPath.deviceName:
                if let v = value.string { name = v }
            case KEFPath.maximumVolume:
                if let v = value.int { maximumVolume = v }
            case KEFPath.volumeLimit:
                if let v = value.bool { volumeLimited = v }
            case KEFPath.playerData:
                setPlayer(PlayerState(json: value))
            case KEFPath.eqProfileV2:
                guard let profile = try? EqProfile(json: value) else { break }
                // Profiles are per input: a different profile means the input changed,
                // so take it even mid-edit.
                let switched = profile.raw["profileId"] != eq?.raw["profileId"]
                    || profile.string(.profileName) != eq?.string(.profileName)
                if switched { pendingEQ = nil }
                if switched || inputSettling || (ContinuousClock.now >= eqHoldUntil && pendingEQ == nil) { eq = profile }
            default:
                break
            }
        }
    }

    /// An input change: volume and EQ are per input, so drop anything queued for the old
    /// input and refuse new volume / EQ writes until the new input's values are read back.
    private func setSource(_ newSource: Source) {
        let changed = source != nil && newSource != source
        source = newSource
        remember(newSource)
        guard changed else { return }
        sourceGeneration += 1
        settleTask?.cancel()
        pendingVolume = nil
        pendingEQ = nil
        volumeHoldUntil = .now
        eqHoldUntil = .now
        inputSettling = newSource != .standby
    }

    private func remember(_ source: Source) {
        guard source != .standby else { return }
        lastSource = source
        preferences.lastSource = source.rawValue
    }

    /// Read the (new) input's volume and EQ once the speaker has switched, then allow writes.
    private func settle(after delay: Duration) {
        guard inputSettling, let client else { return }
        let generation = sourceGeneration
        settleTask?.cancel()
        settleTask = Task {
            for attempt in 0..<3 {
                try? await Task.sleep(for: attempt == 0 ? delay : .seconds(1))
                guard !Task.isCancelled, generation == sourceGeneration else { return }
                async let volume = try? client.volume()
                async let eq = try? client.eqProfile()
                let (freshVolume, freshEQ) = await (volume, eq)
                guard !Task.isCancelled, generation == sourceGeneration else { return }
                guard let freshVolume else { continue }
                self.volume = freshVolume
                self.eq = freshEQ
                inputSettling = false
                log.info("input settled: \(self.source?.rawValue ?? "?", privacy: .public), volume=\(freshVolume)")
                return
            }
        }
    }

    private func setPlayer(_ newPlayer: PlayerState) {
        player = newPlayer
        let url = newPlayer.hasMetadata ? newPlayer.track?.artworkURL : nil
        guard url != artworkURL else { return }
        artworkURL = url
        artwork = nil
        guard let url, let client else { return }
        Task {
            let image = await Self.loadArtwork(url, client: client)
            if artworkURL == url { artwork = image }
        }
    }

    /// Artwork comes from the speaker or from the streaming service. Use the speaker's
    /// session (KEF CA for the speaker, system trust for anything else); recent firmware
    /// no longer serves port 80, so speaker http URLs are retried on HTTPS 4430.
    private static func loadArtwork(_ url: URL, client: KEFClient) async -> NSImage? {
        var candidates = [url]
        if url.scheme == "http", url.host == client.host, url.port == nil || url.port == 80,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        {
            components.scheme = "https"
            components.port = 4430
            if let secure = components.url { candidates.insert(secure, at: 0) }
        }
        for candidate in candidates {
            if let (data, response) = try? await client.transport.session.data(from: candidate),
               (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data)
            {
                return image
            }
        }
        return nil
    }

    // MARK: Commands

    private func perform(_ operation: @escaping @Sendable (KEFClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await operation(client)
        } catch {
            report(error)
            // Undo optimistic local changes with the speaker's real values.
            try? await refreshAll(client)
        }
    }

    private func send(_ operation: @escaping @Sendable (KEFClient) async throws -> Void) {
        Task { await perform(operation) }
    }

    private func report(_ error: Error) {
        log.error("command failed: \(error.localizedDescription, privacy: .public)")
        lastError = (error as? KEFError)?.errorDescription ?? error.localizedDescription
        errorClearTask?.cancel()
        errorClearTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { lastError = nil }
        }
    }

    func setVolume(_ value: Int) {
        guard !inputSettling else { return }
        let value = min(max(value, 0), volumeCeiling)
        volume = value
        volumeHoldUntil = .now + .milliseconds(800)
        pendingVolume = (value, sourceGeneration)
        guard volumeWriter == nil else { return }
        volumeWriter = Task {
            while let next = pendingVolume {
                pendingVolume = nil
                guard next.generation == sourceGeneration else { continue }  // input changed meanwhile
                await perform { try await $0.setVolume(next.value) }
            }
            volumeWriter = nil
            volumeHoldUntil = .now + .milliseconds(500)
        }
    }

    func stepVolume(by delta: Int) {
        guard !inputSettling else { return }
        if muted && delta > 0 { setMuted(false) }
        setVolume(volume + delta)
    }

    func setMuted(_ value: Bool) {
        muted = value
        send { try await $0.setMuted(value) }
    }

    func toggleMute() { setMuted(!muted) }

    func select(_ newSource: Source) {
        setSource(newSource)
        let generation = sourceGeneration
        Task {
            await perform { try await $0.setSource(newSource) }
            // The speaker loads the input's own volume and EQ as it switches.
            if generation == sourceGeneration { settle(after: .milliseconds(1500)) }
        }
    }

    func togglePower() {
        select(isOn ? .standby : lastSource)
    }

    func control(_ command: PlayerCommand) {
        if command == .pause { player.playback = player.isPlaying ? .paused : .playing }
        send { try await $0.control(command) }
    }

    func setMaximumVolume(_ value: Int) {
        maximumVolume = value
        send { try await $0.setMaximumVolume(value) }
    }

    func setVolumeLimited(_ value: Bool) {
        volumeLimited = value
        send { try await $0.setVolumeLimited(value) }
    }

    /// Change the current input's EQ profile (whole-profile write, coalesced).
    func updateEQ(_ change: (inout EqProfile) -> Void) {
        guard !inputSettling, var profile = eq else { return }
        change(&profile)
        guard profile != eq else { return }
        eq = profile
        eqHoldUntil = .now + .milliseconds(1500)
        pendingEQ = (profile, sourceGeneration)
        guard eqWriter == nil else { return }
        eqWriter = Task {
            while let next = pendingEQ {
                pendingEQ = nil
                guard next.generation == sourceGeneration else { continue }  // never onto another input
                let ranges = eqRanges
                await perform { try await $0.setEqProfile(next.profile, validatingAgainst: ranges) }
                try? await Task.sleep(for: .milliseconds(120))
            }
            eqWriter = nil
            eqHoldUntil = .now + .milliseconds(800)
        }
    }

    func range(_ key: EqKey) -> EqRange { eqRanges[key] ?? EqRange.defaults[key] ?? EqRange(0, 1, step: 1) }
    // MARK: Firmware

    /// Reads the firmware state at once, then every 15 minutes, or every 2 s while a
    /// check, download or install is going on.
    private func watchFirmware(_ client: KEFClient) async {
        var next = ContinuousClock.now
        while !Task.isCancelled {
            let active = firmwareActivity != .idle || firmwareStatus?.isBusy == true || firmwareInstalling
            if active || ContinuousClock.now >= next {
                await refreshFirmware(client)
                next = ContinuousClock.now + .seconds(15 * 60)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Returns whether the update status could be read.
    @discardableResult
    private func refreshFirmware(_ client: KEFClient) async -> Bool {
        async let status = try? client.firmwareUpdateStatus()
        async let install = try? client.firmwareInstallInfo()
        let newStatus = await status
        if let newStatus { firmwareStatus = newStatus }
        if let install = await install { firmwareInstall = install }
        if firmwareActivity == .updating { followUpdate() }
        return newStatus != nil
    }

    /// Who an update belongs to: the chosen speaker's MAC in automatic mode, else its address.
    private func speakerIdentity(host: String) -> String {
        let mac = Self.normalizedMAC(preferences.preferredSpeakerID)
        return preferences.hostMode == .automatic && mac.count == 12 ? mac : host
    }

    /// Ask the speaker to look for new firmware (it stays in standby if it was).
    func checkForFirmwareUpdate() {
        guard let client, isOnline, firmwareActivity == .idle, !firmwareInstalling else { return }
        firmwareActivity = .checking
        firmwareNotice = nil
        Task {
            var asked = true
            do {
                try await client.checkForFirmwareUpdate()
            } catch let error as KEFError where error.isConnection {
                // The request may still have arrived: read the status before deciding.
                log.info("firmware check: no answer (\(error.localizedDescription, privacy: .public)), reading status anyway")
            } catch {
                report(error)
                asked = false
            }
            var readStatus = false
            if asked {
                // At least ~5 s, so a check that starts a moment late is still seen.
                for second in 0..<20 {
                    try? await Task.sleep(for: .seconds(1))
                    if await refreshFirmware(client) { readStatus = true }
                    if second >= 4, firmwareStatus?.isBusy != true { break }
                }
            }
            if asked && readStatus {
                firmwareCheckedAt = Date()
            } else {
                firmwareNotice = "Couldn't check for updates. Try again in a moment."
            }
            firmwareActivity = .idle
            log.info("firmware check: \(self.firmwareStatus?.rawState ?? "no status", privacy: .public) \(self.firmwareStatus?.availableVersion ?? "", privacy: .public)")
        }
    }

    /// Have the speaker download and install the update it reported. Only call after the
    /// user confirmed: the speaker stops playing and restarts.
    func installFirmwareUpdate() {
        guard let client, firmwareUpdateAvailable else { return }
        firmwareActivity = .updating
        firmwareNotice = nil
        updateStartedFrom = firmware
        updateStartedAt = .now
        updateSpeaker = host.map { speakerIdentity(host: $0) }
        log.info("firmware update requested: \(self.firmware ?? "?", privacy: .public) -> \(self.firmwareStatus?.availableVersion ?? "?", privacy: .public)")
        Task {
            do {
                try await client.installFirmwareUpdate()
            } catch let error as KEFError where error.isConnection {
                // No answer: the speaker may already be busy. Follow the status as usual.
                log.info("firmware update: no answer (\(error.localizedDescription, privacy: .public))")
            } catch {
                report(error)
                finishUpdate("The update didn't start: \((error as? KEFError)?.errorDescription ?? error.localizedDescription)")
            }
        }
    }

    /// While updating: done once the speaker comes back with another version, or it reports an
    /// error, or nothing has happened for a long time.
    private func followUpdate() {
        guard let started = updateStartedAt else { return }
        if let firmware, let from = updateStartedFrom, firmware != from {
            finishUpdate("Updated to \(shortFirmwareVersion(firmware)).")
        } else if let install = firmwareInstall, install.hasError {
            finishUpdate("The speaker reported an update error (\(install.error ?? "unknown")).")
        } else if ContinuousClock.now - started > .seconds(30 * 60), !firmwareInstalling, firmwareStatus?.isBusy != true {
            finishUpdate("The update hasn't finished yet. The speaker may complete it on its own while idle.")
        }
    }

    /// Stop following the update; `nil` drops it silently (another speaker was chosen).
    private func finishUpdate(_ notice: String?) {
        log.info("firmware update: \(notice ?? "no longer followed", privacy: .public)")
        firmwareNotice = notice
        firmwareActivity = .idle
        updateStartedFrom = nil
        updateStartedAt = nil
        updateSpeaker = nil
    }
}
