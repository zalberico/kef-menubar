import Foundation

/// Controls one KEF W2-platform speaker (LSX II, LS50 Wireless II, LS60...).
///
/// No I/O happens until the first call; the scheme (HTTPS with signing, or HTTP)
/// is then chosen by the transport.
public struct KEFClient: Sendable {
    public let transport: KEFTransport

    public init(host: String, mode: TransportMode = .auto) {
        transport = KEFTransport(host: host, mode: mode)
    }

    public init(transport: KEFTransport) {
        self.transport = transport
    }

    public var host: String { transport.host }

    // MARK: Low level

    /// Raw `getData`: the typed value at `path`.
    public func getData(_ path: String, roles: String = "value") async throws -> JSON {
        let answer = try await transport.request(.getData(path, roles: roles))
        switch answer {
        case .array(let values)?:
            guard let first = values.first else { throw KEFError.invalidResponse("empty getData answer for \(path)") }
            return first
        case .object(let object)?:  // tolerate firmwares answering with the bare object
            return .object(object)
        default:
            throw KEFError.invalidResponse("unexpected getData answer for \(path)")
        }
    }

    /// Read `path` and unwrap its typed value.
    public func getValue(_ path: String) async throws -> JSON {
        try await getData(path).unwrapped
    }

    /// Raw `setData` with an already typed `value`. Blocked paths throw ``KEFError/blocked(_:)``.
    @discardableResult
    public func setData(_ path: String, _ value: JSON, role: String = "value") async throws -> JSON? {
        try KEFSafety.check(path)
        return try await transport.request(.setData(path, value, role: role))
    }

    /// Write `value` to `path` as a typed value of `type`.
    public func setValue(_ path: String, type: String, _ value: JSON) async throws {
        try await setData(path, .typed(type, value))
    }

    /// Trigger an action node (`role: activate`).
    @discardableResult
    public func activate(_ path: String, _ value: JSON? = nil) async throws -> JSON? {
        try await setData(path, value ?? .object(JSONObject()), role: "activate")
    }

    public func getRows(_ path: String, from: Int = 0, to: Int = 19) async throws -> JSON {
        guard let answer = try await transport.request(.getRows(path, from: from, to: to)), answer.object != nil else {
            throw KEFError.invalidResponse("unexpected getRows answer for \(path)")
        }
        return answer
    }

    private func value<T>(_ path: String, _ extract: (JSON) -> T?) async throws -> T {
        let value = try await getValue(path)
        guard let result = extract(value) else {
            throw KEFError.invalidResponse("unexpected value at \(path): \(value.compactString.prefix(120))")
        }
        return result
    }

    // MARK: Device

    public func deviceName() async throws -> String { try await value(KEFPath.deviceName) { $0.string } }
    public func modelName() async throws -> String { try await value(KEFPath.modelName) { $0.string } }
    public func firmwareVersion() async throws -> String { try await value(KEFPath.firmware) { $0.string } }

    // MARK: Power & source

    public func status() async throws -> SpeakerStatus {
        try await value(KEFPath.speakerStatus) { $0.string.map(SpeakerStatus.init(rawValue:)) }
    }

    public func source() async throws -> Source {
        try await value(KEFPath.physicalSource) { $0.string.flatMap(Source.init(rawValue:)) }
    }

    /// Select a source; selecting a real source wakes the speaker up, `standby` turns it off.
    public func setSource(_ source: Source) async throws {
        try await setValue(KEFPath.physicalSource, type: ValueType.physicalSource, .string(source.rawValue))
    }

    // MARK: Volume

    public func volume() async throws -> Int { try await value(KEFPath.volume) { $0.int } }

    public func setVolume(_ volume: Int) async throws {
        try await setValue(KEFPath.volume, type: ValueType.i32, .int(Int64(min(100, max(0, volume)))))
    }

    public func isMuted() async throws -> Bool { try await value(KEFPath.mute) { $0.bool } }

    public func setMuted(_ muted: Bool) async throws {
        try await setValue(KEFPath.mute, type: ValueType.bool, .bool(muted))
    }

    public func maximumVolume() async throws -> Int { try await value(KEFPath.maximumVolume) { $0.int } }

    public func setMaximumVolume(_ volume: Int) async throws {
        try await setValue(KEFPath.maximumVolume, type: ValueType.i32, .int(Int64(min(100, max(0, volume)))))
    }

    public func isVolumeLimited() async throws -> Bool { try await value(KEFPath.volumeLimit) { $0.bool } }

    public func setVolumeLimited(_ enabled: Bool) async throws {
        try await setValue(KEFPath.volumeLimit, type: ValueType.bool, .bool(enabled))
    }

    // MARK: Playback

    public func playerState() async throws -> PlayerState {
        PlayerState(json: try await getData(KEFPath.playerData))
    }

    public func control(_ command: PlayerCommand) async throws {
        try await activate(KEFPath.playerControl, ["control": .string(command.rawValue)])
    }

    // MARK: EQ / DSP

    public func eqProfile() async throws -> EqProfile {
        try EqProfile(json: try await getData(KEFPath.eqProfileV2))
    }

    /// Write a whole profile (the speaker applies it asynchronously, ~100 ms).
    ///
    /// Values are validated against `ranges` first (pass ``eqRanges()`` for the
    /// speaker's own limits), like the reference client does by default.
    public func setEqProfile(_ profile: EqProfile, validatingAgainst ranges: [EqKey: EqRange] = EqRange.defaults) async throws {
        try profile.validate(against: ranges)
        try await setData(KEFPath.eqProfileV2, profile.apiValue)
    }

    /// Ranges advertised by the speaker, completed with the app's defaults.
    public func eqRanges() async -> [EqKey: EqRange] {
        var ranges = EqRange.defaults
        if let rows = try? await getRows(KEFPath.eqDescriptors, from: 0, to: 100) {
            ranges.merge(EqRange.fromDescriptors(rows)) { $1 }
        }
        return ranges
    }

    // MARK: Events

    /// A new, private event queue on this speaker (no I/O until subscribed).
    public func makeEventQueue() -> KEFEventQueue { KEFEventQueue(transport: transport) }
}

/// An event queue on the speaker: subscribe to paths, then long-poll for changes.
///
/// The speaker does not replay current values: read the state after subscribing.
public actor KEFEventQueue {
    private let transport: KEFTransport
    public private(set) var queueID: String?
    public private(set) var subscriptions: [String] = []

    init(transport: KEFTransport) {
        self.transport = transport
    }

    /// Forget the queue (the next ``subscribe(_:)`` creates a new one).
    public func reset() {
        queueID = nil
        subscriptions = []
    }

    /// Add paths, creating the queue if needed. Returns `true` if a new queue was
    /// created (events may have been missed: re-read the state).
    @discardableResult
    public func subscribe(_ paths: [String]) async throws -> Bool {
        let answer = try await transport.request(.modifyQueue(subscribe: paths, queueID: queueID))
        guard let newID = answer?.string, !newID.isEmpty else {
            throw KEFError.invalidResponse("unexpected modifyQueue answer: \(answer?.compactString.prefix(200) ?? "empty")")
        }
        let created = newID != queueID
        if created && queueID != nil {
            // The speaker replaced the queue: send every subscription again.
            let all = subscriptions + paths.filter { !subscriptions.contains($0) }
            reset()
            try await subscribe(all)
            return true
        }
        queueID = newID
        for path in paths where !subscriptions.contains(path) { subscriptions.append(path) }
        return created
    }

    /// Wait up to `timeout` seconds for events (`[]` on timeout), in arrival order.
    /// Throws ``KEFError/api(status:message:path:)`` when the speaker forgot the queue.
    public func poll(timeout: Int = 25) async throws -> [KEFEvent] {
        guard let queueID else { throw KEFError.invalidResponse("not subscribed") }
        do {
            return try KEFEvent.parse(try await transport.request(.pollQueue(queueID, timeout: timeout)))
        } catch let error as KEFError {
            if case .api = error { self.queueID = nil }
            if error.isConnection { self.queueID = nil }
            throw error
        }
    }
}
