import Foundation
import KEFKit
import Testing
@testable import KEFAppCore

/// What the iPhone app's haptics follow: a mute, power or input change counts as confirmed
/// only once the speaker reports it, and a refused one counts as a failure.
@Suite(.serialized) @MainActor
struct SpeakerModelFeedbackTests {
    func makeModel(_ speaker: FakeSpeaker) -> (SpeakerModel, String) {
        let suite = "KEFAppCoreTests.\(UUID().uuidString)"
        let preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.lastHost = speaker.host
        let model = SpeakerModel(
            preferences: preferences, logSubsystem: "KEFAppCoreTests",
            makeClient: { host in FakeSpeaker.speaker(at: host)!.client() },
            discover: { [] })
        return (model, suite)
    }

    func online(_ speaker: FakeSpeaker) async -> (SpeakerModel, String) {
        let (model, suite) = makeModel(speaker)
        model.start()
        #expect(await eventually { model.isOnline })
        return (model, suite)
    }

    func cleanUp(_ model: SpeakerModel, _ suite: String) async {
        await model.suspend()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func muteIsConfirmedOnceTheSpeakerReportsIt() async {
        let speaker = FakeSpeaker(last: 70)
        let (model, suite) = await online(speaker)
        model.setMuted(true)
        #expect(model.confirmedChanges.total == 0)  // not on the tap itself
        #expect(await eventually { model.confirmedChanges.mute == 1 })
        #expect(model.failedCommands == 0)
        #expect(speaker.reads.contains { $0.path == KEFPath.mute })
        await cleanUp(model, suite)
    }

    @Test func powerAndInputAreToldApart() async {
        let speaker = FakeSpeaker(last: 71)
        let (model, suite) = await online(speaker)
        model.select(.wifi)
        #expect(await eventually { model.confirmedChanges.input == 1 })
        model.togglePower()  // to standby
        #expect(await eventually { model.confirmedChanges.power == 1 })
        model.togglePower()  // back on, to the last input
        #expect(await eventually { model.confirmedChanges.power == 2 })
        #expect(model.confirmedChanges.input == 1 && model.confirmedChanges.mute == 0)
        await cleanUp(model, suite)
    }

    @Test func aRefusedChangeCountsAFailureAndNoConfirmation() async {
        let speaker = FakeSpeaker(last: 72)
        let (model, suite) = await online(speaker)
        speaker.refuseWrites(to: KEFPath.mute)
        model.setMuted(true)
        #expect(await eventually { model.failedCommands == 1 })
        #expect(await eventually { !model.muted })  // the speaker's value is back
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.confirmedChanges.total == 0)
        await cleanUp(model, suite)
    }

    @Test func aChangeTheSpeakerNeverReportsIsNotConfirmed() async {
        let speaker = FakeSpeaker(last: 73)
        let (model, suite) = await online(speaker)
        speaker.ignoreWrites(to: KEFPath.physicalSource)
        model.select(.tv)
        // Read back for about 3 s, then given up on without a failure.
        try? await Task.sleep(for: .seconds(4))
        #expect(model.confirmedChanges.total == 0)
        #expect(model.failedCommands == 0)
        await cleanUp(model, suite)
    }

    @Test func onlyTheLatestOfQuickChangesIsConfirmed() async {
        let speaker = FakeSpeaker(last: 74)
        speaker.delay(0.3, for: "POST \(KEFPath.mute)")
        let (model, suite) = await online(speaker)
        model.setMuted(true)
        // The second write reaches the speaker after the first (they aren't serialized), and
        // starts before the first is answered.
        try? await Task.sleep(for: .milliseconds(50))
        model.setMuted(false)
        #expect(await eventually { model.confirmedChanges.mute == 1 })
        try? await Task.sleep(for: .milliseconds(800))
        #expect(model.confirmedChanges.mute == 1)
        #expect(!model.muted)
        await cleanUp(model, suite)
    }

    @Test func failuresCountAtMostOnceASecond() async {
        let speaker = FakeSpeaker(last: 75)
        let (model, suite) = await online(speaker)
        speaker.refuseWrites(to: KEFPath.mute)
        model.setMuted(true)
        #expect(await eventually { model.failedCommands == 1 })
        model.setMuted(true)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.failedCommands == 1)
        try? await Task.sleep(for: .seconds(1))
        model.setMuted(true)
        #expect(await eventually { model.failedCommands == 2 })
        await cleanUp(model, suite)
    }
}
