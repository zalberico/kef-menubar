import Foundation

// Firmware updates, done the way KEF Connect does them:
//
//   1. `firmwareupdate:checkForUpdate` asks the speaker to look for new firmware.
//   2. `firmwareupdate:updateStatus` then reports `newUpdateAvailable` (with the version).
//   3. `firmwareupdate:downloadNewUpdate` has the speaker download and install it; it
//      restarts at the end. `kef:fwupgrade/info` shows the install progress.
//
// Those two actions are the only firmware paths this client ever triggers, and only through
// the dedicated methods below. `KEFSafety` keeps refusing everything under `firmwareupdate:`
// (including `installUpdate`, which KEF Connect does not use) for generic `setData` and
// `activate`. The speaker also updates itself while idle, so none of this is required.

/// `firmwareupdate:updateStatus`.
public struct FirmwareUpdateStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case checking
        case available
        case downloading
        case downloaded
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "idle": self = .idle
            case "checkingForUpdate", "checkingForUpdates": self = .checking
            case "newUpdateAvailable", "updateAvailable": self = .available
            case "downloading", "downloadInProgress", "downloadingUpdate": self = .downloading
            case "downloaded": self = .downloaded
            default: self = .other(rawValue)
            }
        }
    }

    public var state: State
    public var rawState: String
    /// Download progress, 0–100.
    public var downloadProgress: Int?
    /// Version of the update the speaker found, e.g. `3.2.10.0x1234567`.
    public var availableVersion: String?
    public var isForced: Bool?

    /// From the typed value (`{"type":"firmwareUpdateStatus",...}`) or its payload.
    public init?(json: JSON) {
        let payload = json.typeName == nil ? json : json.unwrapped
        guard let raw = payload["state"]?.string else { return nil }
        rawState = raw
        state = State(rawValue: raw)
        downloadProgress = payload["downloadProgress"]?.int
        let image = payload["imageDescription"]
        availableVersion = image?["version"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        isForced = image?["forcedUpdate"]?.bool
    }

    public init(state: State, rawState: String, downloadProgress: Int? = nil, availableVersion: String? = nil) {
        self.state = state
        self.rawState = rawState
        self.downloadProgress = downloadProgress
        self.availableVersion = availableVersion
    }

    /// The speaker has found (or already downloaded) newer firmware.
    public var isUpdateAvailable: Bool { state == .available || state == .downloaded }
    /// The speaker is busy checking or downloading.
    public var isBusy: Bool { state == .checking || state == .downloading }
}

/// `kef:fwupgrade/info`: install progress of the speaker's components.
public struct FirmwareInstallInfo: Sendable, Equatable {
    /// `finish` once nothing is being installed.
    public var status: String
    /// Progress per component (`systemMCU`, `slaveMCU`...), 0–100.
    public var progress: [String: Int]
    /// `noError` when fine.
    public var error: String?

    public init?(json: JSON) {
        let payload = json.typeName == nil ? json : json.unwrapped
        guard let status = payload["firmwareUpgradeStatus"]?.string else { return nil }
        self.status = status
        var progress: [String: Int] = [:]
        for (key, value) in payload["firmwareUpgradeProgress"]?.object ?? JSONObject() {
            if let percent = value.int { progress[key] = percent }
        }
        self.progress = progress
        error = payload["firmwareUpgradeError"]?.string
    }

    /// Something is being installed right now.
    public var isInstalling: Bool { !["finish", "finished", "idle", "none", ""].contains(status) }
    /// Lowest component progress while installing.
    public var overallProgress: Int? { progress.values.min() }
    public var hasError: Bool { error.map { !$0.isEmpty && $0 != "noError" } ?? false }
}

/// Short form of a firmware version: `3.1.141.0x0a4f556` → `3.1.141`.
public func shortFirmwareVersion(_ version: String) -> String {
    let parts = version.split(separator: ".")
    return parts.count > 3 ? parts.prefix(3).joined(separator: ".") : version
}

extension KEFClient {
    /// Where the speaker is in the update lifecycle.
    public func firmwareUpdateStatus() async throws -> FirmwareUpdateStatus {
        let value = try await getData(KEFPath.firmwareUpdateStatus)
        guard let status = FirmwareUpdateStatus(json: value) else {
            throw KEFError.invalidResponse("unexpected firmware status: \(value.compactString.prefix(120))")
        }
        return status
    }

    /// Install progress (meaningful while the speaker installs an update).
    public func firmwareInstallInfo() async throws -> FirmwareInstallInfo {
        let value = try await getData(KEFPath.firmwareInstallInfo)
        guard let info = FirmwareInstallInfo(json: value) else {
            throw KEFError.invalidResponse("unexpected firmware install info: \(value.compactString.prefix(120))")
        }
        return info
    }

    /// Ask the speaker to look for new firmware. It answers within seconds and stays in
    /// standby if it was; read ``firmwareUpdateStatus()`` afterwards.
    public func checkForFirmwareUpdate() async throws {
        try await activateFirmwareAction(KEFPath.firmwareCheckForUpdate)
    }

    /// Have the speaker download and install the update it found. It stops playing and
    /// restarts when done, unreachable for a few minutes.
    ///
    /// Refused unless the speaker itself reports an available update right now.
    public func installFirmwareUpdate() async throws {
        let status = try await firmwareUpdateStatus()
        guard status.isUpdateAvailable else {
            throw KEFError.invalidValue("the speaker reports no firmware update to install (\(status.rawState))")
        }
        try await activateFirmwareAction(KEFPath.firmwareDownloadNewUpdate)
    }

    /// The one way past ``KEFSafety`` for firmware: only the two actions KEF Connect uses.
    private func activateFirmwareAction(_ path: String) async throws {
        precondition(path == KEFPath.firmwareCheckForUpdate || path == KEFPath.firmwareDownloadNewUpdate)
        _ = try await transport.request(.setData(path, .object(JSONObject()), role: "activate"))
    }
}
