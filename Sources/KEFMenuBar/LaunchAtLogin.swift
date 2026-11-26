import ServiceManagement

/// Launch at login through SMAppService (the app registers itself as a login item).
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else if status != .notRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
