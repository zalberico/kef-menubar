import Foundation
import KEFKit
import Testing
@testable import KEFAppCore

struct SpeakerDialogTests {
    let dialog = SpeakerDialog(appName: "Speakeasy", speakerName: "Living Room")

    func volume(requested: Int, previous: Int, applied: Int, ceiling: Int = 100, limited: Bool = false,
                muted: Bool = false, unmuted: Bool = false) -> VolumeOutcome {
        VolumeOutcome(speakerName: "Living Room", requested: requested, previous: previous, applied: applied,
                      ceiling: ceiling, limited: limited, clamped: requested != applied, muted: muted,
                      unmuted: unmuted, wrote: applied != previous)
    }

    // MARK: Set volume

    @Test func setVolumeNamesTheSpeaker() {
        #expect(dialog.setVolume(volume(requested: 30, previous: 20, applied: 30)) == "Living Room is at 30.")
    }

    @Test func setVolumeAboveTheLimitSaysSo() {
        let outcome = volume(requested: 80, previous: 20, applied: 40, ceiling: 40, limited: true)
        #expect(dialog.setVolume(outcome) == "Living Room is at 40, its volume limit.")
        let exactly = volume(requested: 40, previous: 20, applied: 40, ceiling: 40, limited: true)
        #expect(dialog.setVolume(exactly) == "Living Room is at 40, its volume limit.")
    }

    @Test func setVolumeTo100WithoutALimitIsPlain() {
        #expect(dialog.setVolume(volume(requested: 150, previous: 20, applied: 100)) == "Living Room is at 100.")
    }

    @Test func setVolumeWhileMutedMentionsIt() {
        let outcome = volume(requested: 30, previous: 20, applied: 30, muted: true)
        #expect(dialog.setVolume(outcome) == "Living Room is at 30. It's muted.")
    }

    // MARK: Steps

    @Test func stepsSayTheNewVolume() {
        #expect(dialog.step(volume(requested: 26, previous: 24, applied: 26), direction: .up) == "Volume 26.")
        #expect(dialog.step(volume(requested: 22, previous: 24, applied: 22), direction: .down) == "Volume 22.")
    }

    @Test func stepUpWhileMutedSaysItUnmuted() {
        let outcome = volume(requested: 26, previous: 24, applied: 26, unmuted: true)
        #expect(dialog.step(outcome, direction: .up) == "Unmuted. Volume 26.")
    }

    @Test func stepUpAtTheLimit() {
        let outcome = volume(requested: 42, previous: 40, applied: 40, ceiling: 40, limited: true)
        #expect(dialog.step(outcome, direction: .up) == "Already at the volume limit, 40.")
        let reaching = volume(requested: 41, previous: 39, applied: 40, ceiling: 40, limited: true)
        #expect(dialog.step(reaching, direction: .up) == "Volume 40, the volume limit.")
        let unmutedAtLimit = volume(requested: 42, previous: 40, applied: 40, ceiling: 40, limited: true, unmuted: true)
        #expect(dialog.step(unmutedAtLimit, direction: .up) == "Unmuted. Already at the volume limit, 40.")
    }

    @Test func stepUpAt100WithoutALimit() {
        let outcome = volume(requested: 102, previous: 100, applied: 100)
        #expect(dialog.step(outcome, direction: .up) == "Already at the maximum, 100.")
    }

    @Test func stepDownAtZero() {
        #expect(dialog.step(volume(requested: -2, previous: 0, applied: 0), direction: .down) == "Already at 0.")
    }

    @Test func stepDownWhileMutedStaysMuted() {
        let outcome = volume(requested: 22, previous: 24, applied: 22, muted: true)
        #expect(dialog.step(outcome, direction: .down) == "Volume 22. Still muted.")
    }

    // MARK: Mute, power, inputs, playback

    @Test func mute() {
        #expect(dialog.mute(MuteOutcome(speakerName: "Living Room", muted: true, wrote: true)) == "Living Room is muted.")
        #expect(dialog.mute(MuteOutcome(speakerName: "Living Room", muted: false, wrote: false)) == "Living Room is unmuted.")
    }

    @Test func power() {
        #expect(dialog.power(PowerOutcome(speakerName: "Living Room", isOn: true, source: .wifi, wrote: true))
                == "Living Room is on, on Wi-Fi.")
        #expect(dialog.power(PowerOutcome(speakerName: "Living Room", isOn: true, source: nil, wrote: false))
                == "Living Room is on.")
        #expect(dialog.power(PowerOutcome(speakerName: "Living Room", isOn: false, source: nil, wrote: true))
                == "Living Room is in standby.")
    }

    @Test func input() {
        #expect(dialog.input(InputOutcome(speakerName: "Living Room", source: .tv, wasOn: true, wrote: true))
                == "Switched to TV.")
        #expect(dialog.input(InputOutcome(speakerName: "Living Room", source: .tv, wasOn: false, wrote: true))
                == "Living Room is on, on TV.")
        #expect(dialog.input(InputOutcome(speakerName: "Living Room", source: .usb, wasOn: true, wrote: false))
                == "Already on USB.")
    }

    @Test func playback() {
        func line(_ command: PlayerCommand, playing: Bool) -> String {
            dialog.playback(PlaybackOutcome(speakerName: "Living Room", command: command, wasPlaying: playing))
        }
        #expect(line(.pause, playing: true) == "Paused.")
        #expect(line(.pause, playing: false) == "Playing.")
        #expect(line(.next, playing: true) == "Skipped.")
        #expect(line(.previous, playing: true) == "Playing the previous track.")
        #expect(line(.stop, playing: true) == "Stopped.")
    }

    @Test func playOrPauseThatFoundTheSpeakerSoAlready() {
        func line(_ request: PlaybackRequest, _ previous: PlayerState.Playback) -> String {
            dialog.playback(PlaybackOutcome(speakerName: "Living Room", command: .pause, wasPlaying: previous == .playing,
                                            request: request, previous: previous, wrote: false))
        }
        #expect(line(.play, .playing) == "Already playing.")
        #expect(line(.play, .transitioning) == "Already playing.")
        #expect(line(.pause, .paused) == "Already paused.")
        #expect(line(.pause, .stopped) == "Nothing is playing.")
        #expect(line(.pause, .transitioning) == "Nothing is playing yet.")
        // Sent: as for the toggle.
        #expect(dialog.playback(PlaybackOutcome(speakerName: "Living Room", command: .pause, wasPlaying: false,
                                                request: .play, previous: .paused)) == "Playing.")
        #expect(dialog.playback(PlaybackOutcome(speakerName: "Living Room", command: .pause, wasPlaying: true,
                                                request: .pause, previous: .playing)) == "Paused.")
    }

    @Test func outcomeNameWinsOverTheStoredOne() {
        let renamed = MuteOutcome(speakerName: "Kitchen", muted: true, wrote: true)
        #expect(dialog.mute(renamed) == "Kitchen is muted.")
        let unnamed = MuteOutcome(speakerName: "", muted: true, wrote: true)
        #expect(dialog.mute(unnamed) == "Living Room is muted.")
    }

    // MARK: Failures

    @Test func noSpeaker() {
        #expect(dialog.failure(SpeakerCommandError.noSpeaker) == "Choose a speaker in Speakeasy first.")
    }

    @Test func unreachableAndLocalNetwork() {
        let unreachable = "I couldn't reach Living Room. Check it's on and on the same Wi-Fi."
        #expect(dialog.failure(SpeakerCommandError.unreachable) == unreachable)
        #expect(dialog.failure(SpeakerCommandError.timedOut(writeSent: false)) == unreachable)
        let denied = "Speakeasy needs Local Network access. Open Speakeasy to allow it."
        #expect(dialog.failure(SpeakerCommandError.unreachable, localNetworkDenied: true) == denied)
        #expect(dialog.failure(SpeakerCommandError.timedOut(writeSent: false), localNetworkDenied: true) == denied)
        // A raw connection error reads the same as `unreachable`.
        #expect(dialog.failure(KEFError.connection("lost")) == unreachable)
    }

    @Test func timedOutAfterAWriteMayHaveApplied() {
        #expect(dialog.failure(SpeakerCommandError.timedOut(writeSent: true))
                == "Living Room didn't confirm in time; it may have changed.")
        // Local Network can't explain a write that went out.
        #expect(dialog.failure(SpeakerCommandError.timedOut(writeSent: true), localNetworkDenied: true)
                == "Living Room didn't confirm in time; it may have changed.")
    }

    @Test func differentSpeaker() {
        #expect(dialog.failure(SpeakerCommandError.differentSpeaker)
                == "A different speaker answered instead of Living Room. Open Speakeasy to find it again.")
    }

    @Test func unsupportedInputs() {
        #expect(dialog.failure(SpeakerCommandError.unsupportedInput(.coaxial)) == "Living Room doesn't have a coaxial input.")
        #expect(dialog.failure(SpeakerCommandError.unsupportedInput(.optical)) == "Living Room doesn't have an optical input.")
        #expect(dialog.failure(SpeakerCommandError.unsupportedInput(.analog)) == "Living Room doesn't have an analog input.")
        #expect(dialog.failure(SpeakerCommandError.unsupportedInput(.usb)) == "Living Room doesn't have a USB input.")
        #expect(dialog.failure(SpeakerCommandError.unsupportedInput(.standby))
                == "To put Living Room in standby, turn it off instead.")
    }

    @Test func unavailableControls() {
        #expect(dialog.failure(SpeakerCommandError.controlUnavailable(.next)) == "Living Room can't skip on this input.")
        #expect(dialog.failure(SpeakerCommandError.controlUnavailable(.previous)) == "Living Room can't go back on this input.")
        #expect(dialog.failure(SpeakerCommandError.controlUnavailable(.pause)) == "Living Room can't play or pause on this input.")
        #expect(dialog.failure(SpeakerCommandError.controlUnavailable(.stop)) == "Living Room can't stop on this input.")
    }

    @Test func otherFailuresNeverRepeatTheErrorText() {
        let address = ["198", "51", "100", "7"].joined(separator: ".")  // TEST-NET-2
        let refused = dialog.failure(SpeakerCommandError.failed("\(address) rejected our credentials"))
        #expect(refused == "Living Room couldn't do that. Try again in Speakeasy.")
        let auth = dialog.failure(KEFError.auth("\(address) rejected our credentials"))
        #expect(auth == "Living Room couldn't do that. Try again in Speakeasy.")
        let other = dialog.failure(CocoaError(.fileReadUnknown))
        #expect(other == "Something went wrong with Living Room. Try again in Speakeasy.")
        #expect(other?.contains(address) == false)
    }

    @Test func cancellationHasNoReply() {
        #expect(dialog.failure(CancellationError()) == nil)
    }

    @Test func unknownNameFallsBack() {
        let unnamed = SpeakerDialog(appName: "Speakeasy", speakerName: "  ")
        #expect(unnamed.failure(SpeakerCommandError.unreachable)
                == "I couldn't reach your speaker. Check it's on and on the same Wi-Fi.")
        #expect(unnamed.failure(SpeakerCommandError.unsupportedInput(.coaxial)) == "Your speaker doesn't have a coaxial input.")
        #expect(unnamed.mute(MuteOutcome(speakerName: "", muted: true, wrote: true)) == "Your speaker is muted.")
    }
}
