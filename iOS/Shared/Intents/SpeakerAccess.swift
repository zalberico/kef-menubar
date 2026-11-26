import AppIntents
import Foundation
import KEFAppCore
import KEFKit
import WidgetKit

/// How intents, controls and widgets reach the speaker, from the app or the widget
/// extension: read the configuration the app saved, run one ``SpeakerCommand``, fold the
/// outcome into the widgets' snapshot and reload the widgets and controls.
enum SpeakerAccess {
    /// Long enough for the HTTPS handshake and a few requests; short enough for Siri.
    static let timeout: Duration = .seconds(8)
    /// How long the speaker takes to settle after switching input or power (it restores
    /// that input's volume about half a second later), before reading it again.
    static let settleDelay: Duration = .milliseconds(1500)
    /// A widget or control refresh: the stored snapshot stands in if this runs out.
    static let readTimeout: Duration = .seconds(4)

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Speakeasy"
    }

    /// The speaker configuration the app saved (the demo's in a debug demo run).
    static func config() -> SharedSpeakerConfig {
        #if DEBUG
        if DemoSpeaker.intentsUseDemo { return DemoSpeaker.intentConfig }
        #endif
        return AppGroup.speakerConfig()
    }

    static func connect(_ config: SharedSpeakerConfig, timeout: Duration) throws -> SpeakerCommand {
        #if DEBUG
        if DemoSpeaker.intentsUseDemo {
            DemoSpeaker.loadIntentState()
            return try SpeakerCommand.connect(config, timeout: timeout) { host, _ in DemoSpeaker.makeClient(host: host) }
        }
        #endif
        return try SpeakerCommand.connect(config, timeout: timeout)
    }

    private static func finished(_ command: SpeakerCommand) async {
        await command.close()
        #if DEBUG
        if DemoSpeaker.intentsUseDemo { DemoSpeaker.saveIntentState() }
        #endif
    }

    /// Run one operation for an intent and return its outcome and reply. Failures are
    /// thrown as ``SpeakerIntentError`` with a reply that says what went wrong.
    /// With `refresh`, the speaker is read again after the change (within what is left of
    /// the deadline), for changes that move more than the outcome says: switching input or
    /// power changes the track and can change the volume (the speaker keeps one per input).
    static func perform<Outcome: Sendable>(
        refresh: Bool = false,
        _ operation: @Sendable (SpeakerCommand) async throws -> Outcome,
        apply: (inout SpeakerSnapshot, Outcome) -> Void,
        reply: (SpeakerDialog, Outcome) -> String
    ) async throws -> (outcome: Outcome, reply: String) {
        let config = config()
        let dialog = SpeakerDialog(appName: appName, speakerName: config.lastSpeakerName)
        do {
            let command = try connect(config, timeout: timeout)
            let outcome: Outcome
            var fresh: SpeakerSnapshot?
            do {
                outcome = try await operation(command)
                if refresh {
                    // The speaker moves to that input's own volume a moment after switching.
                    try? await Task.sleep(for: settleDelay)
                    fresh = try? await command.snapshot()
                }
            } catch {
                await finished(command)
                throw error
            }
            await finished(command)
            if var fresh, let store = AppGroup.snapshotStore {
                // The outcome wins where they differ: the speaker can lag behind its own change.
                apply(&fresh, outcome)
                try? store.update(with: fresh)
            } else {
                AppGroup.snapshotStore?.apply { apply(&$0, outcome) }
            }
            reloadWidgetsAndControls()
            return (outcome, reply(dialog, outcome))
        } catch {
            if case SpeakerCommandError.timedOut(writeSent: true) = error {
                // It may have changed: let the widgets and controls read it again.
                reloadWidgetsAndControls()
            }
            let denied = Self.mayBeLocalNetwork(error) ? await LocalNetworkStatus.isDenied(host: config.host) : false
            guard let message = dialog.failure(error, localNetworkDenied: denied) else { throw error }
            throw SpeakerIntentError(message: message)
        }
    }

    private static func mayBeLocalNetwork(_ error: any Error) -> Bool {
        switch error {
        case SpeakerCommandError.unreachable, SpeakerCommandError.timedOut(writeSent: false): true
        default: false
        }
    }

    /// The current state for widgets and controls: one fresh read shared by everything
    /// that asks within a few seconds, else the last stored snapshot.
    static func currentSnapshot() async -> SnapshotReader.Reading {
        guard let reader = SharedReader.reader else { return SnapshotReader.Reading(snapshot: nil, isFresh: false) }
        return await reader.current {
            let command = try connect(config(), timeout: readTimeout)
            do {
                let snapshot = try await command.snapshot()
                await finished(command)
                return snapshot
            } catch {
                await finished(command)
                throw error
            }
        }
    }

    static func reloadWidgetsAndControls() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}

/// One reader per process, so overlapping value providers and timelines share a read.
private enum SharedReader {
    static let reader: SnapshotReader? = AppGroup.snapshotStore.map { SnapshotReader(store: $0) }
}

/// A failure an intent reports to Siri and Shortcuts in its own words.
struct SpeakerIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// One operation each, for the app's intents (Siri, Shortcuts) and the widget's and
/// controls' own intents: runs it with ``SpeakerAccess/perform(_:apply:reply:)`` and
/// returns the outcome and the reply.
enum SpeakerActions {
    static func setVolume(_ level: Int) async throws -> (outcome: VolumeOutcome, reply: String) {
        try await SpeakerAccess.perform({ try await $0.setVolume(level) }, apply: { $0.apply($1) }, reply: { $0.setVolume($1) })
    }

    static func step(_ direction: SpeakerCommand.Direction) async throws -> (outcome: VolumeOutcome, reply: String) {
        try await SpeakerAccess.perform(
            { try await $0.step(direction) }, apply: { $0.apply($1) }, reply: { $0.step($1, direction: direction) })
    }

    static func setMuted(_ muted: Bool) async throws -> (outcome: MuteOutcome, reply: String) {
        try await SpeakerAccess.perform({ try await $0.setMuted(muted) }, apply: { $0.apply($1) }, reply: { $0.mute($1) })
    }

    static func setPower(_ on: Bool) async throws -> (outcome: PowerOutcome, reply: String) {
        try await SpeakerAccess.perform(refresh: true, { try await $0.setPower(on) }, apply: { $0.apply($1) }, reply: { $0.power($1) })
    }

    /// `select` refuses an input this model doesn't have, before sending anything.
    static func select(_ input: SpeakerInput) async throws -> (outcome: InputOutcome, reply: String) {
        let source = input.source
        return try await SpeakerAccess.perform(refresh: true, { try await $0.select(source) }, apply: { $0.apply($1) }, reply: { $0.input($1) })
    }

    static func playPause(_ request: PlaybackRequest) async throws -> (outcome: PlaybackOutcome, reply: String) {
        try await SpeakerAccess.perform({ try await $0.playPause(request) }, apply: { $0.apply($1) }, reply: { $0.playback($1) })
    }

    static func next() async throws -> (outcome: PlaybackOutcome, reply: String) {
        try await SpeakerAccess.perform({ try await $0.next() }, apply: { $0.apply($1) }, reply: { $0.playback($1) })
    }

    static func previous() async throws -> (outcome: PlaybackOutcome, reply: String) {
        try await SpeakerAccess.perform({ try await $0.previous() }, apply: { $0.apply($1) }, reply: { $0.playback($1) })
    }
}
