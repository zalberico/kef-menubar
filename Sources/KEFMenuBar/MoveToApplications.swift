// The GitHub (Developer ID) build only: the Mac App Store installs into Applications itself.
#if !APPSTORE
import AppKit
import os

/// Offers to move a freshly downloaded copy into the Applications folder.
///
/// Safari unzips the download into Downloads, and an app opened from there is easy to leave
/// behind. macOS also runs a downloaded app that wasn't moved from a hidden, read-only copy
/// (App Translocation), where Sparkle can't replace it, so it would never update. So on launch,
/// a copy that came from the internet (it carries the quarantine attribute, or macOS
/// translocated it) and isn't in an Applications folder asks once whether to move. Copies
/// built locally, or already moved, never ask.
///
/// Moving copies the app to /Applications (or ~/Applications when /Applications isn't
/// writable), clears the quarantine attribute on the copy, as Finder's own move would let it
/// run in place, moves the downloaded copy to the Trash, and relaunches from the new place.
///
/// Debug builds only, for testing without clicking: `-MoveToApplicationsAnswer move` (or
/// `stay`) asks and answers the question whether or not the copy is quarantined, and `-MoveToApplicationsFolder <path>` moves there instead
/// of an Applications folder.
@MainActor
enum MoveToApplications {
    private static let log = Logger(subsystem: "KEFMenuBar", category: "move")
    private static let suppressKey = "MoveToApplicationsSuppressed"

    /// Returns true when the app is moving and about to relaunch; the caller should start
    /// nothing else.
    static func offerIfNeeded() -> Bool {
        let running = Bundle.main.bundleURL
        let translocated = isTranslocated(running)
        let original = translocated ? (originalURL(ofTranslocated: running) ?? running) : running
        #if DEBUG
        let testAnswer = UserDefaults.standard.string(forKey: "MoveToApplicationsAnswer")
        #else
        let testAnswer: String? = nil
        #endif
        // A test answer stands in for the quarantine attribute too: launching a quarantined
        // debug build from a shell would only get it stopped by Gatekeeper.
        guard !UserDefaults.standard.bool(forKey: suppressKey),
              !isInApplicationsFolder(original),
              translocated || isQuarantined(running) || testAnswer != nil
        else { return false }

        let response: NSApplication.ModalResponse
        let suppress: Bool
        if let testAnswer {
            response = testAnswer == "move" ? .alertFirstButtonReturn : .alertSecondButtonReturn
            suppress = false
        } else {
            (response, suppress) = ask()
        }
        guard response == .alertFirstButtonReturn else {
            if suppress { UserDefaults.standard.set(true, forKey: suppressKey) }
            log.info("Not moving: the person chose to stay at \(original.path, privacy: .public)")
            return false
        }

        do {
            let destination = try move(running: running, original: original)
            relaunch(at: destination)
            return true
        } catch {
            log.error("Move failed: \(error.localizedDescription, privacy: .public)")
            let failure = NSAlert(error: error)
            failure.messageText = "Speakeasy couldn't move itself to Applications"
            failure.informativeText = "\(error.localizedDescription)\n\nYou can drag Speakeasy into your Applications folder in Finder instead."
            failure.runModal()
            return false
        }
    }

    /// The question, and whether "Don't ask again" was ticked.
    private static func ask() -> (NSApplication.ModalResponse, Bool) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Speakeasy to your Applications folder?"
        alert.informativeText = "Speakeasy is running from where it was downloaded. Moved to Applications, it stays put and can keep itself up to date."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let response = alert.runModal()
        return (response, alert.suppressionButton?.state == .on)
    }

    // MARK: Moving

    private struct MoveError: LocalizedError {
        let errorDescription: String?
    }

    /// Copies the app into Applications and trashes the downloaded copy. Returns the new URL.
    private static func move(running: URL, original: URL) throws -> URL {
        let manager = FileManager.default
        let folder = try destinationFolder()
        let name = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Speakeasy") + ".app"
        let destination = folder.appendingPathComponent(name, isDirectory: true)

        if manager.fileExists(atPath: destination.path) {
            let path = destination.standardizedFileURL.resolvingSymlinksInPath().path
            if NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == path
            }) {
                throw MoveError(errorDescription: "Another copy of Speakeasy is open from \(folder.path). Quit it, then open this one again.")
            }
            // The copy already there goes to the Trash, so it can be put back.
            try manager.trashItem(at: destination, resultingItemURL: nil)
            log.info("Moved the existing \(destination.path, privacy: .public) to the Trash")
        }

        try manager.copyItem(at: running, to: destination)
        clearQuarantine(destination)
        log.info("Copied to \(destination.path, privacy: .public)")

        // The downloaded copy goes to the Trash. Failing here (a read-only disk image, say)
        // leaves it where it was, which is harmless.
        if original.standardizedFileURL != destination.standardizedFileURL {
            do {
                try manager.trashItem(at: original, resultingItemURL: nil)
            } catch {
                log.info("Left the downloaded copy in place: \(error.localizedDescription, privacy: .public)")
            }
        }
        return destination
    }

    /// /Applications when this account can write to it, otherwise ~/Applications.
    private static func destinationFolder() throws -> URL {
        let manager = FileManager.default
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "MoveToApplicationsFolder") {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        #endif
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if manager.isWritableFile(atPath: system.path) { return system }
        let user = manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try manager.createDirectory(at: user, withIntermediateDirectories: true)
        return user
    }

    /// Waits for this process to exit, then opens the moved copy, so the two never run at once
    /// (only one can hold the volume hot keys).
    private static func relaunch(at destination: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"",
                          "sh", String(pid), destination.path]
        do {
            try task.run()
        } catch {
            log.error("Couldn't schedule the relaunch: \(error.localizedDescription, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    // MARK: Where the app is

    private static func isInApplicationsFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return ["/Applications", "/System/Applications", home].contains { path.hasPrefix($0 + "/") }
    }

    private static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// Removes the quarantine attribute from every file in the copied bundle.
    private static func clearQuarantine(_ bundle: URL) {
        let manager = FileManager.default
        var paths = [bundle.path]
        if let items = manager.enumerator(at: bundle, includingPropertiesForKeys: nil) {
            for case let item as URL in items { paths.append(item.path) }
        }
        for path in paths { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    // App Translocation has no public API; these Security.framework functions are what
    // macOS offers for it (and what other apps' move prompts use), looked up at run time.
    private typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    private static func isTranslocated(_ url: URL) -> Bool {
        guard let symbol = dlsym(security, "SecTranslocateIsTranslocatedURL") else {
            return url.path.contains("/AppTranslocation/")
        }
        let function = unsafeBitCast(symbol, to: IsTranslocated.self)
        var translocated = false
        return function(url as CFURL, &translocated, nil) && translocated
    }

    private static func originalURL(ofTranslocated url: URL) -> URL? {
        guard let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let function = unsafeBitCast(symbol, to: OriginalPath.self)
        return function(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
#endif
