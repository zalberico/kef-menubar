import Foundation
import KEFKit
import Testing
@testable import KEFAppCore

@Suite(.serialized)
struct SpeakerCommandTests {
    /// A synthetic MAC (all one byte), never a real device's.
    static func mac(_ byte: String) -> String { Array(repeating: byte, count: 6).joined(separator: ":") }

    func command(_ speaker: FakeSpeaker, _ config: SharedSpeakerConfig = SharedSpeakerConfig(),
                 timeout: Duration = SpeakerCommand.defaultTimeout) throws -> SpeakerCommand {
        var config = config
        if config.host == nil { config.hostMode = .manual; config.manualHost = speaker.host }
        return try SpeakerCommand.connect(config, timeout: timeout) { _, _ in speaker.client() }
    }

    // MARK: Volume

    @Test func setVolumeIsClampedToTheLimit() async throws {
        let speaker = FakeSpeaker(last: 11)
        speaker.set(KEFPath.maximumVolume, int: 40)
        speaker.set(KEFPath.volumeLimit, bool: true)
        let outcome = try await command(speaker).setVolume(80)
        #expect(speaker.written(KEFPath.volume) == ["40"])
        #expect(outcome.applied == 40 && outcome.ceiling == 40 && outcome.clamped && outcome.limited)
        #expect(outcome.requested == 80 && outcome.previous == 20 && outcome.wrote)
        #expect(outcome.atCeiling)
        #expect(outcome.speakerName == "Test Speaker")
        #expect(speaker.written(KEFPath.mute).isEmpty)  // setting the volume never unmutes
    }

    @Test func withoutALimitTheVolumeGoesUpTo100() async throws {
        let speaker = FakeSpeaker(last: 12)
        speaker.set(KEFPath.maximumVolume, int: 40)  // ignored while the limit is off
        let command = try command(speaker)
        let full = try await command.setVolume(100)
        #expect(full.applied == 100 && !full.clamped && full.ceiling == 100)
        let over = try await command.setVolume(150)
        #expect(over.applied == 100 && over.clamped && !over.wrote)  // already at 100
        let negative = try await command.setVolume(-4)
        #expect(negative.applied == 0 && negative.clamped)
        #expect(speaker.written(KEFPath.volume) == ["100", "0"])
    }

    @Test func stepUpWhileMutedUnmutesThenSteps() async throws {
        let speaker = FakeSpeaker(last: 13)
        speaker.set(KEFPath.mute, bool: true)
        let outcome = try await command(speaker, SharedSpeakerConfig(volumeStep: 3)).step(.up)
        #expect(speaker.writes.map(\.path) == [KEFPath.mute, KEFPath.volume])
        #expect(speaker.written(KEFPath.mute) == ["false"])
        #expect(speaker.written(KEFPath.volume) == ["23"])
        #expect(outcome.unmuted && !outcome.muted && outcome.applied == 23 && outcome.requested == 23)
    }

    @Test func stepDownWhileMutedStaysMuted() async throws {
        let speaker = FakeSpeaker(last: 14)
        speaker.set(KEFPath.mute, bool: true)
        let outcome = try await command(speaker).step(.down)
        #expect(speaker.written(KEFPath.mute).isEmpty)
        #expect(speaker.written(KEFPath.volume) == ["18"])
        #expect(outcome.muted && !outcome.unmuted)
    }

    @Test func stepAtTheCeilingWritesNothing() async throws {
        let speaker = FakeSpeaker(last: 15)
        speaker.set(KEFPath.maximumVolume, int: 40)
        speaker.set(KEFPath.volumeLimit, bool: true)
        speaker.set(KEFPath.volume, int: 40)
        let outcome = try await command(speaker).step(.up)
        #expect(speaker.writes.isEmpty)
        #expect(!outcome.wrote && outcome.atCeiling && outcome.clamped && outcome.applied == 40)
    }

    @Test func stepSizeIsKeptWithinOneToTen() async throws {
        let speaker = FakeSpeaker(last: 16)
        let command = try command(speaker)
        _ = try await command.step(.up, by: 25)
        _ = try await command.step(.down, by: 0)
        #expect(speaker.written(KEFPath.volume) == ["30", "29"])
    }

    @Test func muteWritesOnlyAChange() async throws {
        let speaker = FakeSpeaker(last: 17)
        let command = try command(speaker)
        #expect(try await command.setMuted(true).wrote)
        #expect(try await command.setMuted(true).wrote == false)
        #expect(speaker.written(KEFPath.mute) == ["true"])
    }

    // MARK: Identity

    @Test func anotherSpeakerAtTheAddressIsNeverWritten() async throws {
        let speaker = FakeSpeaker(last: 18)
        speaker.set(KEFPath.macAddress, string: Self.mac("0b"))
        let config = SharedSpeakerConfig(hostMode: .automatic, lastHost: speaker.host,
                                         preferredSpeakerID: Self.mac("0a"), lastSource: "wifi")
        let command = try command(speaker, config)
        await #expect(throws: SpeakerCommandError.differentSpeaker) { try await command.setVolume(10) }
        await #expect(throws: SpeakerCommandError.differentSpeaker) { try await command.step(.up) }
        await #expect(throws: SpeakerCommandError.differentSpeaker) { try await command.setMuted(true) }
        await #expect(throws: SpeakerCommandError.differentSpeaker) { try await command.setPower(false) }
        await #expect(throws: SpeakerCommandError.differentSpeaker) { try await command.select(.tv) }
        await #expect(throws: SpeakerCommandError.differentSpeaker) { try await command.playPause() }
        #expect(speaker.writes.isEmpty)
        // The only thing read is the MAC address.
        #expect(Set(speaker.reads.compactMap(\.path)) == [KEFPath.macAddress])
    }

    @Test func theChosenSpeakerIsWritten() async throws {
        let speaker = FakeSpeaker(last: 19)
        speaker.set(KEFPath.macAddress, string: Self.mac("0A").uppercased())
        let config = SharedSpeakerConfig(hostMode: .automatic, lastHost: speaker.host, preferredSpeakerID: Self.mac("0a"))
        _ = try await command(speaker, config).setVolume(25)
        #expect(speaker.written(KEFPath.volume) == ["25"])
        #expect(speaker.reads.first?.path == KEFPath.macAddress)  // checked before anything else
    }

    @Test func manualModeDoesNotCheckIdentity() async throws {
        let speaker = FakeSpeaker(last: 20)
        speaker.set(KEFPath.macAddress, string: Self.mac("0b"))
        let config = SharedSpeakerConfig(hostMode: .manual, manualHost: speaker.host, preferredSpeakerID: Self.mac("0a"))
        _ = try await command(speaker, config).setVolume(25)
        #expect(speaker.written(KEFPath.volume) == ["25"])
    }

    @Test func noAddressMeansNoSpeaker() {
        #expect(throws: SpeakerCommandError.noSpeaker) { try SpeakerCommand.connect(SharedSpeakerConfig()) }
        #expect(throws: SpeakerCommandError.noSpeaker) {
            try SpeakerCommand.connect(SharedSpeakerConfig(hostMode: .manual, manualHost: "  "))
        }
    }

    // MARK: Inputs and power

    @Test func anInputTheModelLacksIsRefused() async throws {
        let speaker = FakeSpeaker(last: 21)
        speaker.set(KEFPath.modelName, string: "SP4025")  // LS50 Wireless II: no USB
        // Model code known from the app: refused before any request.
        let known = try command(speaker, SharedSpeakerConfig(hostMode: .manual, manualHost: speaker.host, lastModelCode: "SP4025"))
        await #expect(throws: SpeakerCommandError.unsupportedInput(.usb)) { try await known.select(.usb) }
        #expect(speaker.log.isEmpty)
        // Unknown: the model is read from the speaker.
        let unknown = try command(speaker)
        await #expect(throws: SpeakerCommandError.unsupportedInput(.usb)) { try await unknown.select(.usb) }
        await #expect(throws: SpeakerCommandError.unsupportedInput(.standby)) { try await unknown.select(.standby) }
        #expect(speaker.reads.compactMap(\.path).contains(KEFPath.modelName))
        #expect(speaker.writes.isEmpty)
        let coaxial = try await unknown.select(.coaxial)
        #expect(coaxial.wrote && coaxial.wasOn && coaxial.source == .coaxial)
        #expect(speaker.written(KEFPath.physicalSource) == [#""coaxial""#])
    }

    @Test func selectingTheCurrentInputWritesNothing() async throws {
        let speaker = FakeSpeaker(last: 22)
        let outcome = try await command(speaker).select(.usb)
        #expect(!outcome.wrote && speaker.writes.isEmpty)
    }

    @Test func powerOnUsesTheLastInputTheModelHas() async throws {
        let speaker = FakeSpeaker(last: 23)
        speaker.set(KEFPath.physicalSource, source: .standby)
        let config = SharedSpeakerConfig(hostMode: .manual, manualHost: speaker.host, lastSource: "tv", lastModelCode: "SP4041")
        let outcome = try await command(speaker, config).setPower(true)
        #expect(outcome.isOn && outcome.wrote && outcome.source == .tv)
        #expect(speaker.written(KEFPath.physicalSource) == [#""tv""#])
    }

    @Test func powerOnNeverPicksAnInputTheModelLacks() async throws {
        let speaker = FakeSpeaker(last: 24)
        speaker.set(KEFPath.physicalSource, source: .standby)
        speaker.set(KEFPath.modelName, string: "SP4033")  // LS60: no USB, first input Wi-Fi
        let config = SharedSpeakerConfig(hostMode: .manual, manualHost: speaker.host, lastSource: "usb")
        let outcome = try await command(speaker, config).setPower(true)
        #expect(outcome.source == .wifi)
        #expect(speaker.written(KEFPath.physicalSource) == [#""wifi""#])
        // No last input at all: the model's first input too.
        speaker.set(KEFPath.physicalSource, source: .standby)
        _ = try await command(speaker).setPower(true)
        #expect(speaker.written(KEFPath.physicalSource) == [#""wifi""#, #""wifi""#])
    }

    @Test func powerWritesOnlyAChange() async throws {
        let speaker = FakeSpeaker(last: 25)
        let command = try command(speaker)
        #expect(try await command.setPower(true).wrote == false)  // already on (USB)
        let off = try await command.setPower(false)
        #expect(off.wrote && !off.isOn && off.source == nil)
        #expect(try await command.setPower(false).wrote == false)
        #expect(speaker.written(KEFPath.physicalSource) == [#""standby""#])
    }

    // MARK: Playback

    @Test func playbackControlsOnlyWhenOffered() async throws {
        let speaker = FakeSpeaker(last: 26)
        let command = try command(speaker)
        await #expect(throws: SpeakerCommandError.controlUnavailable(.pause)) { try await command.playPause() }
        await #expect(throws: SpeakerCommandError.controlUnavailable(.next)) { try await command.next() }
        #expect(speaker.writes.isEmpty)
        speaker.set(KEFPath.playerData, raw: #"{"state":"playing","controls":{"pause":true,"next_":true,"previous":false}}"#)
        #expect(try await command.playPause().wasPlaying)
        _ = try await command.next()
        await #expect(throws: SpeakerCommandError.controlUnavailable(.previous)) { try await command.previous() }
        let controls = speaker.writes.filter { $0.path == KEFPath.playerControl }.map(\.value)
        #expect(controls == [#"{"control":"pause"}"#, #"{"control":"next"}"#])
    }

    // MARK: Safety

    @Test func neverTouchesABlockedPathAndOnlyPlaybackSendsControl() async throws {
        let speaker = FakeSpeaker(last: 27)
        let command = try command(speaker, SharedSpeakerConfig(hostMode: .manual, manualHost: speaker.host, lastSource: "tv"))
        _ = try await command.setVolume(30)
        _ = try await command.step(.up)
        _ = try await command.step(.down)
        _ = try await command.setMuted(true)
        _ = try await command.setMuted(false)
        _ = try await command.select(.tv)
        _ = try await command.setPower(false)
        _ = try await command.setPower(true)
        _ = try await command.snapshot()
        #expect(!speaker.log.isEmpty)
        #expect(!speaker.log.contains { $0.path.map(KEFSafety.isBlocked) ?? false })
        #expect(!speaker.log.contains { $0.path == KEFPath.playerControl })
        #expect(Set(speaker.writes.compactMap(\.path)) == [KEFPath.volume, KEFPath.mute, KEFPath.physicalSource])
        // Only the explicit playback operations send player:control.
        speaker.set(KEFPath.playerData, raw: #"{"state":"paused","controls":{"pause":true}}"#)
        _ = try await command.playPause()
        #expect(speaker.writes.filter { $0.path == KEFPath.playerControl }.count == 1)
        #expect(!speaker.log.contains { $0.path.map(KEFSafety.isBlocked) ?? false })
    }

    @Test func readsAreSerial() async throws {
        let speaker = FakeSpeaker(last: 28)
        speaker.delay(0.02)
        let command = try command(speaker)
        _ = try await command.snapshot()
        _ = try await command.setVolume(30)
        _ = try await command.step(.up)
        _ = try await command.setPower(false)
        #expect(speaker.log.count > 15)
        #expect(speaker.highestConcurrency == 1)
    }

    @Test func snapshotReadsTheState() async throws {
        let speaker = FakeSpeaker(last: 29)
        speaker.set(KEFPath.volume, int: 33)
        speaker.set(KEFPath.maximumVolume, int: 50)
        speaker.set(KEFPath.volumeLimit, bool: true)
        speaker.set(KEFPath.physicalSource, source: .wifi)
        let art = "http://" + speaker.host + "/art.jpg"
        speaker.set(KEFPath.playerData, raw: #"{"state":"playing","trackRoles":{"title":"Song","icon":"\#(art)","mediaData":{"metaData":{"artist":"Band"}}}}"#)
        let snapshot = try await command(speaker).snapshot()
        #expect(snapshot.name == "Test Speaker" && snapshot.isOn && snapshot.input == .wifi)
        #expect(snapshot.volume == 33 && snapshot.ceiling == 50 && !snapshot.muted)
        #expect(snapshot.title == "Song" && snapshot.artist == "Band" && snapshot.isPlaying)
        #expect(snapshot.artworkKey == SpeakerModel.artworkKey(for: URL(string: art)!))
        #expect(speaker.writes.isEmpty)
    }

    // MARK: Deadline

    @Test func aHungSpeakerTimesOutWithoutWriting() async throws {
        let speaker = FakeSpeaker(last: 30)
        speaker.delay(3, for: KEFPath.volume)
        let command = try command(speaker, timeout: .milliseconds(400))
        let started = ContinuousClock.now
        await #expect(throws: SpeakerCommandError.timedOut(writeSent: false)) { try await command.setVolume(30) }
        #expect(ContinuousClock.now - started < .seconds(2))
        try await Task.sleep(for: .milliseconds(300))
        #expect(speaker.writes.isEmpty)
        // The deadline is shared: later operations fail at once.
        await #expect(throws: SpeakerCommandError.timedOut(writeSent: false)) { try await command.setMuted(true) }
        #expect(speaker.writes.isEmpty)
    }

    @Test func aTimeOutAfterTheWriteSaysItMayNotHaveApplied() async throws {
        let speaker = FakeSpeaker(last: 31)
        speaker.delay(3, for: "POST " + KEFPath.volume)  // reads are quick, the write hangs
        let command = try command(speaker, timeout: .milliseconds(500))
        let started = ContinuousClock.now
        await #expect(throws: SpeakerCommandError.timedOut(writeSent: true)) { try await command.setVolume(30) }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(speaker.written(KEFPath.volume) == ["30"])
        #expect(SpeakerCommandError.timedOut(writeSent: true).errorDescription?.contains("may not have applied") == true)
    }
}
