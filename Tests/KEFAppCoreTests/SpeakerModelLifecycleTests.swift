import Foundation
import KEFKit
import Testing
@testable import KEFAppCore

/// The model against a fake speaker, through the injected client factory and discovery.
@Suite(.serialized) @MainActor
struct SpeakerModelLifecycleTests {
    struct Harness {
        let speaker: FakeSpeaker
        let model: SpeakerModel
        let discoveries: Box<Int>
        let suite: String
    }

    /// A model in automatic mode that already knows the fake's address (no chosen MAC, so
    /// no identity check), with discovery counted instead of run.
    func makeHarness(last: Int) -> Harness {
        let speaker = FakeSpeaker(last: last)
        let suite = "KEFAppCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = Preferences(defaults: defaults)
        preferences.lastHost = speaker.host
        let discoveries = Box(0)
        let model = SpeakerModel(
            preferences: preferences, logSubsystem: "KEFAppCoreTests",
            makeClient: { host in FakeSpeaker.speaker(at: host)!.client() },
            discover: {
                discoveries.withLock { $0 += 1 }
                return []
            })
        return Harness(speaker: speaker, model: model, discoveries: discoveries, suite: suite)
    }

    func cleanUp(_ harness: Harness) async {
        await harness.model.suspend()
        UserDefaults(suiteName: harness.suite)?.removePersistentDomain(forName: harness.suite)
    }

    /// Wait (yielding the main actor) until `condition` holds.
    func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    func subscribes(_ speaker: FakeSpeaker) -> Int {
        speaker.log.filter { $0.endpoint == Endpoint.modifyQueue }.count
    }

    @Test func comesOnlineThroughTheInjectedClient() async {
        let h = makeHarness(last: 50)
        h.speaker.set(KEFPath.volume, int: 31)
        h.model.start()
        #expect(await eventually { h.model.isOnline })
        #expect(h.model.volume == 31 && h.model.name == "Test Speaker" && h.model.source == .usb)
        #expect(h.model.hasCachedState)
        #expect(h.discoveries.current == 0)
        #expect(h.model.preferences.lastModelCode == "SP4041")
        #expect(h.model.preferences.lastIsSecure == false)
        #expect(h.model.preferences.knownSpeakers.map(\.host) == [h.speaker.host])
        #expect(h.model.snapshot()?.volume == 31)
        await cleanUp(h)
    }

    @Test func suspendKeepsTheValuesAndStopsTalking() async {
        let h = makeHarness(last: 51)
        h.speaker.set(KEFPath.volume, int: 27)
        h.speaker.set(KEFPath.mute, bool: true)
        h.model.start()
        #expect(await eventually { h.model.isOnline })
        await h.model.suspend()
        #expect(h.model.isSuspended)
        #expect(h.model.connection == .connecting(h.speaker.host))
        #expect(h.model.hasCachedState)
        #expect(h.model.volume == 27 && h.model.muted && h.model.source == .usb)
        #expect(h.model.name == "Test Speaker" && h.model.host == h.speaker.host && h.model.modelName == "SP4041")
        // Nothing more goes to the speaker (the long poll was cancelled).
        try? await Task.sleep(for: .milliseconds(100))
        let count = h.speaker.log.count
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(h.speaker.log.count == count)
        await cleanUp(h)
    }

    @Test func resumeWithAKnownHostDoesNotRediscover() async {
        let h = makeHarness(last: 52)
        h.model.start()
        #expect(await eventually { h.model.isOnline })
        await h.model.suspend()
        h.speaker.set(KEFPath.volume, int: 44)  // changed while the app was away
        h.model.resume()
        #expect(!h.model.isSuspended)
        #expect(await eventually { h.model.isOnline })
        #expect(h.model.volume == 44)
        #expect(h.discoveries.current == 0)
        #expect(subscribes(h.speaker) == 2)
        await cleanUp(h)
    }

    @Test func resumeDuringTheSuspendDrainIsNotUndone() async {
        let h = makeHarness(last: 53)
        h.model.start()
        #expect(await eventually { h.model.isOnline })
        h.speaker.delay(0.6, for: "POST " + KEFPath.volume)  // a volume write still going out
        h.model.setVolume(25)
        let suspending = Task { await h.model.suspend() }
        try? await Task.sleep(for: .milliseconds(150))  // suspend is now waiting for the write
        h.model.resume()
        await suspending.value
        // The write was let through, and the resumed session survived the end of the suspend.
        #expect(await eventually { h.speaker.written(KEFPath.volume) == ["25"] })
        #expect(await eventually { h.model.isOnline })
        h.model.setMuted(true)
        #expect(await eventually(.seconds(1)) { h.speaker.written(KEFPath.mute) == ["true"] })
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(h.model.isOnline)
        #expect(subscribes(h.speaker) == 2)  // no reconnect after the old suspend finished
        #expect(h.discoveries.current == 0)
        await cleanUp(h)
    }

    @Test func overlappingDiscoveriesKeepScanningUntilTheLastEnds() async {
        let gate = Box(0)
        let suite = "KEFAppCoreTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        let model = SpeakerModel(preferences: preferences, logSubsystem: "KEFAppCoreTests",
                                 makeClient: { KEFClient(host: $0) },
                                 discover: {
                                     let n = gate.withLock { $0 += 1; return $0 }
                                     try? await Task.sleep(for: .milliseconds(n == 1 ? 200 : 600))
                                     return []
                                 })
        let first = Task { await model.discover() }
        try? await Task.sleep(for: .milliseconds(50))
        let second = Task { await model.discover() }
        await first.value
        #expect(model.isDiscovering)  // the second scan is still running
        await second.value
        #expect(!model.isDiscovering)
    }

    @Test func liftedHelpersKeepTheMacText() async {
        let h = makeHarness(last: 54)
        h.model.start()
        #expect(await eventually { h.model.isOnline })
        #expect(h.model.modelDisplayName == "LSX II")
        #expect(h.model.pickerInputs == Source.lsxII)
        #expect(h.model.canRename(" New name "))
        #expect(!h.model.canRename(" Test Speaker "))
        #expect(!h.model.canRename("   "))
        #expect(!h.model.canRename(String(repeating: "x", count: 65)))
        #expect(h.model.firmwareUpdateAlertTitle == "Update Test Speaker?")
        #expect(StandbyMode.options(current: .thirtyMinutes, wakeRaw: "usb") == [.thirtyMinutes, .sixtyMinutes, .never])
        #expect(StandbyMode.options(current: .eco, wakeRaw: WakeSource.automatic.rawValue) == StandbyMode.allCases)
        #expect(WakeSource.options(for: [.wifi, .tv], current: .usb) == [.automatic, .tv, .usb])
        #expect(!h.model.applySubwooferPreset(.kc62))  // no profile with a sub: nothing applied
        await cleanUp(h)
    }
}
