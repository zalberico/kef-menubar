import CoreGraphics
import Foundation
import ImageIO
import KEFKit
import Observation
import os

/// Live state of the speaker, kept in sync through the event queue, and every command.
@MainActor @Observable
public final class SpeakerModel {
    public enum Connection: Equatable, Sendable {
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

    public let preferences: Preferences

    public private(set) var connection: Connection = .searching
    public private(set) var host: String?
    public private(set) var isSecure: Bool?
    public private(set) var name = "KEF Speaker"
    public private(set) var modelName: String?
    public private(set) var firmware: String?
    public private(set) var status: SpeakerStatus?
    public private(set) var source: Source?
    public private(set) var lastSource: Source = .usb
    public private(set) var volume = 0
    public private(set) var muted = false
    public private(set) var maximumVolume = 100
    public private(set) var volumeLimited = false
    public private(set) var player = PlayerState()
    /// The current track's artwork, downsampled to at most ``artworkMaxPixelSize``.
    public private(set) var artwork: CGImage?
    public private(set) var eq: EqProfile?
    public private(set) var eqRanges = EqRange.defaults
    public private(set) var discovered: [DiscoveredSpeaker] = []
    public private(set) var isDiscovering = false
    public private(set) var lastError: String?
    /// True for a moment after an input change, until the new input's own volume and EQ
    /// have been read back: the speaker keeps both per input, so writes based on the
    /// previous input's values would be wrong (or loud).
    public private(set) var inputSettling = false
    /// The values shown come from an earlier session with this speaker (they are kept while
    /// suspended and reconnecting, so the app can show them dimmed instead of nothing).
    public private(set) var hasCachedState = false
    /// ``suspend()`` was called and ``resume()`` hasn't been since.
    public private(set) var isSuspended = false

    /// The speaker's own settings (Settings › Speaker); `nil` until loaded.
    public private(set) var speakerSettings: SpeakerSettings?
    /// The last attempt to read them got nothing (offer a retry).
    public private(set) var speakerSettingsFailed = false
    @ObservationIgnored private var settingsWriter: Task<Void, Never>?
    @ObservationIgnored private var settingsWritesInFlight = 0

    // Firmware (see Firmware.swift in KEFKit).
    public enum FirmwareActivity: Equatable, Sendable { case idle, checking, updating }
    /// `nil` until read, or if the speaker doesn't report it.
    public private(set) var firmwareStatus: FirmwareUpdateStatus?
    public private(set) var firmwareInstall: FirmwareInstallInfo?
    public private(set) var firmwareActivity: FirmwareActivity = .idle
    public private(set) var firmwareCheckedAt: Date?
    /// Outcome of the last check or update, shown in Settings.
    public private(set) var firmwareNotice: String?

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
    /// Bumped by every ``start()`` and ``suspend()``: a suspend that sees another value after
    /// an await gives up, so a quick resume is never undone by the end of an older suspend.
    @ObservationIgnored private var lifecycleGeneration = 0
    /// Discoveries running at once (the Scan button and the connection loop can overlap).
    @ObservationIgnored private var discoveriesInFlight = 0

    @ObservationIgnored private let makeClient: @Sendable (String) -> KEFClient
    @ObservationIgnored private let discoverSpeakers: @Sendable () async -> [DiscoveredSpeaker]
    @ObservationIgnored private let log: Logger

    /// Artwork is decoded to at most this many pixels on its longest side.
    public static let artworkMaxPixelSize = 600

    /// - Parameters:
    ///   - logSubsystem: the unified-logging subsystem of the model's messages.
    ///   - makeClient: builds the client for an address (tests pass a stubbed transport).
    ///   - discover: finds the speakers on the network.
    public init(
        preferences: Preferences,
        logSubsystem: String = "KEFMenuBar",
        makeClient: @escaping @Sendable (String) -> KEFClient = { KEFClient(host: $0) },
        discover: @escaping @Sendable () async -> [DiscoveredSpeaker] = { await KEFDiscovery.discover() }
    ) {
        self.preferences = preferences
        self.makeClient = makeClient
        discoverSpeakers = discover
        log = Logger(subsystem: logSubsystem, category: "speaker")
        needsDiscovery = preferences.lastHost.isEmpty
        if !preferences.lastSpeakerName.isEmpty { name = preferences.lastSpeakerName }
        if let source = Source(rawValue: preferences.lastSource), source != .standby { lastSource = source }
    }

    // MARK: Derived state

    public var isOnline: Bool { connection == .online }
    /// On/standby follows the physical source, like pykefcontrol's `is_on()`.
    /// `speakerStatus` is not reliable for this: after a wake it can stay "standby"
    /// while the speaker plays (seen on LSX II 3.1.141, with powermanager "online").
    public var isOn: Bool { isOnline && source != nil && source != .standby }
    /// The inputs this model has.
    public var inputs: [Source] { Source.inputs(forModel: modelName) }
    public var volumeCeiling: Int { VolumePolicy.ceiling(maximum: maximumVolume, limited: volumeLimited) }
    /// The speaker is installing firmware (it restarts at the end).
    public var firmwareInstalling: Bool { status == .firmwareUpgrade || firmwareInstall?.isInstalling == true }
    public var firmwareUpdateAvailable: Bool {
        isOnline && firmwareActivity == .idle && !firmwareInstalling && firmwareStatus?.isUpdateAvailable == true
    }

    /// The inputs to offer: the model's, plus whatever input the speaker reports if it isn't one of them.
    public var pickerInputs: [Source] {
        var sources = Source.inputs(forModel: modelName)
        if isOn, let current = source, !sources.contains(current) { sources.append(current) }
        return sources
    }

    /// The product name (e.g. "LSX II"), `nil` until the speaker reported its model.
    public var modelDisplayName: String? { modelName.map { SpeakerProduct.displayName(forCode: $0) } }

    public var showsNowPlaying: Bool { isOn && (source == .wifi || source == .bluetooth) && player.hasMetadata }

    public var statusText: String {
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

    public func start() {
        guard runTask == nil else { return }
        lifecycleGeneration += 1
        runTask = Task { await run() }
    }

    /// Drop the connection and start again (after the speaker settings changed).
    public func reconnect(rediscover: Bool = true) {
        runTask?.cancel()
        runTask = nil
        if let client { Task { await client.transport.close() } }
        client = nil
        needsDiscovery = rediscover || preferences.lastHost.isEmpty
        retryDelay = .seconds(1)
        connection = .searching
        start()
    }

    /// Stop talking to the speaker (the iPhone app going to the background), keeping every
    /// value shown, the address and what discovery found. Volume, EQ and settings writes
    /// already made get a moment to go out first. ``resume()`` connects again.
    public func suspend() async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        isSuspended = true
        runTask?.cancel()  // also ends the long poll
        runTask = nil
        settleTask?.cancel()
        if let host { connection = .connecting(host) }
        let deadline = ContinuousClock.now + .seconds(2)
        while volumeWriter != nil || eqWriter != nil || settingsWritesInFlight > 0, ContinuousClock.now < deadline {
            // A cancelled caller stops waiting (a cancelled sleep returns at once and would spin).
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            guard generation == lifecycleGeneration else { return }
        }
        guard generation == lifecycleGeneration, let client else { return }
        self.client = nil
        await client.transport.close()
    }

    /// Connect again after ``suspend()``. With a known address this goes straight back to it
    /// (no Bonjour scan) unless the last attempt had already asked for one.
    public func resume() {
        isSuspended = false
        guard runTask == nil else { return }
        needsDiscovery = needsDiscovery || preferences.lastHost.isEmpty
        retryDelay = .seconds(1)
        start()
    }

    /// Retry now (the offline view): in automatic mode, look for the speaker again too.
    public func retry() {
        reconnect(rediscover: preferences.hostMode == .automatic)
    }

    /// Switch between finding the speaker automatically and a manual address. Switching to
    /// manual with no address yet keeps the speaker connected to; that address is returned
    /// so a text field can show it.
    @discardableResult
    public func setHostMode(_ mode: Preferences.HostMode) -> String? {
        var filled: String?
        if mode == .manual, preferences.manualHost.isEmpty, let host {
            preferences.manualHost = host
            filled = host
        }
        preferences.hostMode = mode
        reconnect()
        return filled
    }

    /// Find the speaker automatically (Bonjour).
    public func useAutomatic() {
        setHostMode(.automatic)
    }

    /// Connect to a typed address (blank text is ignored).
    public func useManualHost(_ text: String) {
        let host = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        preferences.manualHost = host
        if preferences.hostMode != .manual { preferences.hostMode = .manual }
        reconnect(rediscover: false)
    }

    /// Use one of the discovered speakers.
    public func choose(_ speaker: DiscoveredSpeaker) {
        preferences.preferredSpeakerID = speaker.id
        preferences.lastHost = speaker.host
        if preferences.hostMode != .automatic { preferences.hostMode = .automatic }
        reconnect(rediscover: false)
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
                // A run cancelled meanwhile (reconnect, suspend) must not replace the client
                // of the run that took over.
                if Task.isCancelled { return }
                client = makeClient(host)
                if self.host != host {  // another address: forget what the old one reported
                    hasCachedState = false
                    modelName = nil
                    firmware = nil
                    speakerSettings = nil
                    speakerSettingsFailed = false
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

    public func discover() async {
        discoveriesInFlight += 1
        isDiscovering = true
        let found = await discoverSpeakers()
        discovered = found
        discoveriesInFlight -= 1
        // Overlapping scans: "Scanning…" lasts until the last one is done.
        if discoveriesInFlight == 0 { isDiscovering = false }
    }

    /// One connected session: subscribe, read everything, then follow events until an error.
    private func session(_ client: KEFClient) async throws {
        try await verifyIdentity(client)
        let queue = client.makeEventQueue()
        try await queue.subscribe(Self.watchedPaths)
        try await refreshAll(client)
        try Task.checkCancellation()
        connection = .online
        hasCachedState = true
        retryDelay = .seconds(1)
        isSecure = await client.transport.isSecure
        rememberSpeaker(client)
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
        if await SpeakerIdentity.isDifferentSpeaker(client, hostMode: preferences.hostMode,
                                                    preferredID: preferences.preferredSpeakerID) {
            needsDiscovery = true
            throw KEFError.connection("A different speaker answered at \(client.host)")
        }
    }

    /// Keep what the other targets (widgets, intents) and the speaker list need. Never logged.
    private func rememberSpeaker(_ client: KEFClient) {
        preferences.lastIsSecure = isSecure
        if let modelName { preferences.lastModelCode = modelName }
        let id = preferences.hostMode == .automatic && !preferences.preferredSpeakerID.isEmpty
            ? preferences.preferredSpeakerID : client.host
        preferences.remember(SavedSpeaker(id: id, name: name, host: client.host, modelCode: modelName))
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
                if let v = value.string { name = v; preferences.lastSpeakerName = v }
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
            let image = await Self.loadArtwork(url, client: client, maxPixelSize: Self.artworkMaxPixelSize)
            if artworkURL == url { artwork = image }
        }
    }

    /// A stable key for the current artwork (a hash of its URL), `nil` without artwork.
    public var artworkKey: String? {
        guard artwork != nil, let artworkURL else { return nil }
        return Self.artworkKey(for: artworkURL)
    }

    /// FNV-1a of the URL: stable across launches, and the URL itself is never stored.
    public nonisolated static func artworkKey(for url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Artwork comes from the speaker or from the streaming service. Use the speaker's
    /// session (KEF CA for the speaker, system trust for anything else); recent firmware
    /// no longer serves port 80, so speaker http URLs are retried on HTTPS 4430.
    private nonisolated static func loadArtwork(_ url: URL, client: KEFClient, maxPixelSize: Int) async -> CGImage? {
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
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = decodeImage(data, maxPixelSize: maxPixelSize)
            {
                return image
            }
        }
        return nil
    }

    /// Decode and downsample in one go, applying the EXIF orientation like `NSImage` did.
    public nonisolated static func decodeImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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

    public func setVolume(_ value: Int) {
        guard !inputSettling else { return }
        let value = VolumePolicy.clamp(value, ceiling: volumeCeiling)
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

    public func stepVolume(by delta: Int) {
        guard !inputSettling else { return }
        if muted && delta > 0 { setMuted(false) }
        setVolume(volume + delta)
    }

    public func setMuted(_ value: Bool) {
        muted = value
        send { try await $0.setMuted(value) }
    }

    public func toggleMute() { setMuted(!muted) }

    public func select(_ newSource: Source) {
        setSource(newSource)
        let generation = sourceGeneration
        Task {
            await perform { try await $0.setSource(newSource) }
            // The speaker loads the input's own volume and EQ as it switches.
            if generation == sourceGeneration { settle(after: .milliseconds(1500)) }
        }
    }

    public func togglePower() {
        select(isOn ? .standby : lastSource)
    }

    public func control(_ command: PlayerCommand) {
        if command == .pause { player.playback = player.isPlaying ? .paused : .playing }
        send { try await $0.control(command) }
    }

    public func setMaximumVolume(_ value: Int) {
        maximumVolume = value
        send { try await $0.setMaximumVolume(value) }
    }

    public func setVolumeLimited(_ value: Bool) {
        volumeLimited = value
        send { try await $0.setVolumeLimited(value) }
    }

    /// Change the current input's EQ profile (whole-profile write, coalesced).
    public func updateEQ(_ change: (inout EqProfile) -> Void) {
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

    public func range(_ key: EqKey) -> EqRange { eqRanges[key] ?? EqRange.defaults[key] ?? EqRange(0, 1, step: 1) }
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

    /// The firmware status line in Settings.
    public var firmwareStatusText: String {
        let version = firmwareStatus?.availableVersion.map { shortFirmwareVersion($0) }
        let versionSuffix = version.map { " \($0)" } ?? ""
        if !isOnline {
            return firmwareActivity == .updating ? "Restarting after the update…" : "Speaker offline"
        }
        if firmwareActivity == .updating || firmwareInstalling {
            if firmwareStatus?.state == .downloading { return "Downloading\(versionSuffix)…" }
            if firmwareInstalling { return "Installing… the speaker restarts when done" }
            return "Starting the update…"
        }
        if firmwareActivity == .checking { return "Checking…" }
        guard let status = firmwareStatus else { return "Not reported by this speaker" }
        switch status.state {
        case .idle:
            guard let checked = firmwareCheckedAt else { return "Up to date" }
            return "Up to date · checked \(checked.formatted(date: .omitted, time: .shortened))"
        case .checking: return "Checking…"
        case .available: return "Update available\(versionSuffix)"
        case .downloading: return "Downloading\(versionSuffix)…"
        case .downloaded: return "Update downloaded\(versionSuffix)"
        case .other(let raw): return raw
        }
    }

    /// Download or install progress (0–100), when the speaker reports one.
    public var firmwareProgress: Int? {
        guard isOnline else { return nil }
        if firmwareStatus?.state == .downloading { return firmwareStatus?.downloadProgress }
        if let install = firmwareInstall, install.isInstalling { return install.overallProgress }
        return nil
    }

    /// An update is being installed or followed (the banner in the popover).
    public var showsFirmwareUpdating: Bool {
        firmwareActivity == .updating || (isOnline && firmwareInstalling)
    }

    /// Title of the confirmation shown before ``installFirmwareUpdate()``.
    public var firmwareUpdateAlertTitle: String {
        let version = firmwareStatus?.availableVersion.map { shortFirmwareVersion($0) }
        return "Update \(name)\(version.map { " to \($0)" } ?? "")?"
    }

    /// Message of that confirmation.
    public static let firmwareUpdateAlertMessage = "The speaker downloads and installs the update, then restarts. Playback stops and the speaker can't be reached for a few minutes. Keep it plugged in until it's back."

    /// Who an update belongs to: the chosen speaker's MAC in automatic mode, else its address.
    private func speakerIdentity(host: String) -> String {
        let mac = SpeakerIdentity.normalizedMAC(preferences.preferredSpeakerID)
        return preferences.hostMode == .automatic && mac.count == 12 ? mac : host
    }

    /// Ask the speaker to look for new firmware (it stays in standby if it was).
    public func checkForFirmwareUpdate() {
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
    public func installFirmwareUpdate() {
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

    // MARK: Speaker settings

    /// (Re)load the speaker's settings, e.g. when Settings opens.
    public func loadSpeakerSettings() {
        guard let client, isOnline else { return }
        speakerSettingsFailed = false
        Task { await reloadSpeakerSettings(client) }
    }

    /// Keeps the previous settings if nothing could be read.
    private func reloadSpeakerSettings(_ client: KEFClient) async {
        let settings = await client.speakerSettings(inputs: inputs)
        guard self.client?.host == client.host else { return }
        if settings.isEmpty {
            speakerSettingsFailed = true
        } else {
            speakerSettings = settings
            speakerSettingsFailed = false
        }
    }

    /// Apply a change locally, write it, and re-read the settings if the write fails.
    /// Writes go out one at a time in the order they were made, so the last choice wins.
    private func changeSettings(_ change: (inout SpeakerSettings) -> Void,
                                write: @escaping @Sendable (KEFClient) async throws -> Void) {
        guard isOnline, let client, var settings = speakerSettings else { return }
        change(&settings)
        speakerSettings = settings
        let previous = settingsWriter
        settingsWritesInFlight += 1
        settingsWriter = Task {
            defer { settingsWritesInFlight -= 1 }
            await previous?.value
            guard self.client?.host == client.host else { return }
            do {
                try await write(client)
            } catch {
                report(error)
                await reloadSpeakerSettings(client)
            }
        }
    }

    /// Whether `newName` can be sent: trimmed, not empty, different, at most 64 characters.
    public func canRename(_ newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return isOnline && !trimmed.isEmpty && trimmed != name && trimmed.count <= 64
    }

    public func rename(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isOnline, !trimmed.isEmpty, trimmed != name else { return }
        let previous = name
        name = trimmed
        Task {
            guard let client else { return }
            do {
                try await client.setDeviceName(trimmed)
                preferences.lastSpeakerName = trimmed
            } catch {
                report(error)
                if name == trimmed { name = previous }
            }
        }
    }

    /// ECO standby only works with the default wake source, like in KEF Connect.
    public func setStandbyMode(_ mode: StandbyMode) {
        let needsDefaultWake = !mode.isAllowed(wakeRaw: speakerSettings?.wakeSourceRaw)
        changeSettings({
            $0.standbyMode = mode
            if needsDefaultWake { $0.wakeSourceRaw = WakeSource.automatic.rawValue }
        }, write: { client in
            if needsDefaultWake { try await client.setWakeSource(.automatic) }
            try await client.setStandbyMode(mode)
        })
    }

    public func setWakeSource(_ source: WakeSource) {
        let leavesEco = speakerSettings?.standbyMode == .eco && !StandbyMode.eco.isAllowed(wakeRaw: source.rawValue)
        changeSettings({
            $0.wakeSourceRaw = source.rawValue
            if leavesEco { $0.standbyMode = .thirtyMinutes }
        }, write: { client in
            if leavesEco { try await client.setStandbyMode(.thirtyMinutes) }
            try await client.setWakeSource(source)
        })
    }

    public func setAutoSwitchToTV(_ on: Bool) {
        changeSettings({ $0.autoSwitchToTV = on }, write: { try await $0.setAutoSwitchToTV(on) })
    }

    public func setStartupVolumeEnabled(_ on: Bool) {
        changeSettings({ $0.startupVolumeEnabled = on }, write: { try await $0.setStartupVolumeEnabled(on) })
    }

    public func setStartupVolumePerInput(_ on: Bool) {
        changeSettings({ $0.startupVolumePerInput = on }, write: { try await $0.setStartupVolumePerInput(on) })
    }

    /// Startup volume for all inputs (`source == nil`) or one input, never above the volume limit.
    public func setStartupVolume(_ level: Int, for source: Source? = nil) {
        let level = VolumePolicy.clamp(level, ceiling: volumeCeiling)
        changeSettings({
            if let source { $0.startupVolumes[source] = level } else { $0.startupVolume = level }
        }, write: { try await $0.setStartupVolume(level, for: source) })
    }

    public func setStandbyLight(_ on: Bool) {
        changeSettings({ $0.standbyLight = on }, write: { try await $0.setStandbyLight(on) })
    }

    public func setStartupTone(_ on: Bool) {
        changeSettings({ $0.startupTone = on }, write: { try await $0.setStartupTone(on) })
    }

    public func setRemoteEnabled(_ on: Bool) {
        changeSettings({ $0.remoteEnabled = on }, write: { try await $0.setRemoteEnabled(on) })
    }

    public func setRemoteVolumeStep(_ step: Int) {
        let step = min(max(step, 1), 10)
        changeSettings({ $0.remoteVolumeStep = step }, write: { try await $0.setRemoteVolumeStep(step) })
    }

    // MARK: Subwoofer preset

    /// Sub model presets are offered where KEF Connect's tables are known to apply.
    public var offersSubwooferPresets: Bool {
        SubwooferPreset.supportedModels.contains(modelName ?? "") && eq?.hasSubwoofer == true
    }

    /// Choose a sub model and apply its gain, crossover and high-pass (current input's profile).
    /// Returns whether anything changed (`false` while the input settles, without a profile,
    /// when the preset doesn't apply, or when the profile already has its values).
    @discardableResult
    public func applySubwooferPreset(_ preset: SubwooferPreset) -> Bool {
        guard !inputSettling, let profile = eq, let applied = profile.applying(preset), applied != profile else { return false }
        updateEQ { $0 = applied }
        return true
    }
}
