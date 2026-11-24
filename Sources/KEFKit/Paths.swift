/// API paths used by this app (names follow the reference client's `paths.py`).
public enum KEFPath {
    public static let deviceName = "settings:/deviceName"
    public static let modelName = "settings:/kef/host/modelName"
    public static let firmware = "settings:/version"
    public static let macAddress = "settings:/system/primaryMacAddress"

    public static let speakerStatus = "settings:/kef/host/speakerStatus"
    public static let physicalSource = "settings:/kef/play/physicalSource"

    public static let volume = "player:volume"
    public static let mute = "settings:/mediaPlayer/mute"
    public static let maximumVolume = "settings:/kef/host/maximumVolume"
    public static let volumeLimit = "settings:/kef/host/volumeLimit"
    public static let volumeStep = "settings:/kef/host/volumeStep"

    public static let playerData = "player:player/data"
    public static let playerControl = "player:player/control"

    /// Whole EQ / DSP profile (v2 format: physical values in dB / Hz).
    public static let eqProfileV2 = "kef:eqProfile/v2"
    /// Ranges and choices of each EQ setting (`getRows`).
    public static let eqDescriptors = "kef:dsp/editValue"

    /// Firmware update lifecycle (see `Firmware.swift`). The two actions are only reachable
    /// through `KEFClient.checkForFirmwareUpdate()` and `installFirmwareUpdate()`.
    public static let firmwareUpdateStatus = "firmwareupdate:updateStatus"
    public static let firmwareInstallInfo = "kef:fwupgrade/info"
    public static let firmwareCheckForUpdate = "firmwareupdate:checkForUpdate"
    public static let firmwareDownloadNewUpdate = "firmwareupdate:downloadNewUpdate"
}

public enum Endpoint {
    public static let getData = "/api/getData"
    public static let setData = "/api/setData"
    public static let getRows = "/api/getRows"
    public static let modifyQueue = "/api/event/modifyQueue"
    public static let pollQueue = "/api/event/pollQueue"
}

/// Paths this client refuses to write or activate.
///
/// Factory reset is excluded for good. Reboot, network setup, pairing wipes and DSP
/// restore are not exposed by this app either, so they are refused too rather than being
/// one typo away. Firmware paths are refused here as well: the two firmware actions the
/// app offers go through dedicated `KEFClient` methods that check the speaker's state first.
public enum KEFSafety {
    public static let blockedPrefixes: [String] = [
        "kef:speakerFactoryReset",
        "powermanager:goReboot",
        "networkwizard:",
        "network:",
        "kef:network/",
        "kef:speedTest/",
        "firmwareupdate:",
        "kef:fwupgrade/",
        "settings:/fwupdate",
        "kef:ble/",
        "bluetooth:clearAllDevices",
        "kef:restoreDspSettings",
        "kef:dedicatedEqProfiles/overwriteAllProfiles",
        "systemmanager:",
        "alerts:/alarm/remove",
        "grouping:",
        "hostlink:",
        "kefdsp:",
        "powermanager:",
    ]

    public static func isBlocked(_ path: String) -> Bool {
        blockedPrefixes.contains { path.hasPrefix($0) }
    }

    static func check(_ path: String) throws {
        if isBlocked(path) { throw KEFError.blocked(path) }
    }
}
