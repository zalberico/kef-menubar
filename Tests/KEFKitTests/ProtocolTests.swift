import Foundation
import Testing
@testable import KEFKit

struct JSONTests {
    @Test func roundTripKeepsOrderAndNumberKinds() throws {
        let text = #"{"z":1,"a":-3,"m":47.5,"b":true,"n":null,"s":"x","l":[1,2.0,"y"],"o":{"k":[]}}"#
        let value = try JSON(parsing: text)
        #expect(value["z"] == .int(1))
        #expect(value["m"] == .double(47.5))
        #expect(value.object?.keys == ["z", "a", "m", "b", "n", "s", "l", "o"])
        // Python: json.dumps(json.loads(text), separators=(",", ":")) → 2.0 stays 2.0
        #expect(value.compactString == text)
    }

    @Test func escapingMatchesPython() {
        // json.dumps("q\"b\\s/\n\t\u0001é😀", ensure_ascii=False)
        let value: JSON = .string("q\"b\\s/\n\t\u{01}é😀")
        #expect(value.compactString == #""q\"b\\s/\n\t\u0001é😀""#)
    }

    @Test func doublesFormatLikePythonRepr() {
        #expect(JSON.double(-1).compactString == "-1.0")
        #expect(JSON.double(67.5).compactString == "67.5")
        #expect(JSON.double(0.1).compactString == "0.1")
        #expect(JSON.double(1e-5).compactString == "1e-05")
        #expect(JSON.double(1e16).compactString == "1e+16")
    }

    @Test func parsesEscapesAndSurrogatePairs() throws {
        let value = try JSON(parsing: #"["é😀\/\"", "plain é"]"#)
        #expect(value.array?[0] == .string("é😀/\""))
        #expect(value.array?[1] == .string("plain é"))
    }

    @Test func rejectsMalformedDocuments() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "\"abc", "1 2", "-"] {
            #expect(throws: JSONParseError.self, "\(bad)") { try JSON(parsing: bad) }
        }
    }

    @Test func numericAccessors() {
        #expect(JSON.double(-3).int == -3)
        #expect(JSON.double(2.5).int == nil)
        #expect(JSON.int(4).double == 4)
        #expect(JSON.bool(true).int == nil)
    }

    @Test func objectEqualityIgnoresOrder() throws {
        #expect(try JSON(parsing: #"{"a":1,"b":2}"#) == JSON(parsing: #"{"b":2,"a":1}"#))
        var object = JSONObject([("a", 1), ("b", 2)])
        object["a"] = nil
        object["c"] = 3
        #expect(object.keys == ["b", "c"])
    }
}

struct TypedValueTests {
    @Test func wrapAndUnwrap() throws {
        #expect(JSON.typed(ValueType.i32, 42).compactString == #"{"type":"i32_","i32_":42}"#)
        let source = try JSON(parsing: #"{"kefPhysicalSource":"usb","type":"kefPhysicalSource"}"#)
        #expect(source.unwrapped == .string("usb"))
        #expect(source.typeName == "kefPhysicalSource")
        #expect(JSON.string("bare").unwrapped == .string("bare"))
    }
}

struct RequestTests {
    @Test func queryEncodingMatchesUrlencode() {
        // urllib.parse.urlencode([("queueId", "{a b}"), ("timeout", "25")])
        #expect(KEFRequest.pollQueue("{a b}").target == "/api/event/pollQueue?queueId=%7Ba+b%7D&timeout=25")
        #expect(KEFRequest.quotePlus("a-_.~é") == "a-_.~%C3%A9")
        #expect(KEFRequest.pollQueue("q").timeout == 40)
    }

    @Test func modifyQueuePutsQueueIdFirst() throws {
        let request = KEFRequest.modifyQueue(subscribe: ["a"], unsubscribe: ["b"], queueID: "{q}")
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body == #"{"queueId":"{q}","subscribe":[{"path":"a","type":"itemWithValue"}],"unsubscribe":[{"path":"b","type":"itemWithValue"}]}"#)
    }

    @Test func activateSendsEmptyObject() async throws {
        let request = KEFRequest.setData(KEFPath.playerControl, ["control": "pause"], role: "activate")
        let body = String(decoding: try #require(request.body), as: UTF8.self)
        #expect(body == #"{"path":"player:player/control","role":"activate","value":{"control":"pause"}}"#)
    }

    @Test func errorMessages() {
        let body = Data(#"{"error":{"name":"CMAbstractWorker::invalidPath","message":"Node at path 'x' does not exist"}}"#.utf8)
        #expect(errorMessage(body) == "Node at path 'x' does not exist (CMAbstractWorker::invalidPath)")
        #expect(errorMessage(Data("Unknown queue id!".utf8)) == "Unknown queue id!")
    }
}

struct SafetyTests {
    @Test(arguments: [
        "kef:speakerFactoryReset", "powermanager:goReboot", "networkwizard:wireless/key",
        "network:setNetworkProfile", "firmwareupdate:downloadNewUpdate", "bluetooth:clearAllDevices",
        "kef:restoreDspSettings/v2", "kef:ble/updateNow", "settings:/fwupdate/firmwareUpdateServerUrl",
    ])
    func destructivePathsAreRefused(_ path: String) async {
        #expect(KEFSafety.isBlocked(path))
        let client = KEFClient(host: "192.0.2.1")  // TEST-NET: must fail before any I/O
        await #expect(throws: KEFError.blocked(path)) { try await client.activate(path) }
    }

    @Test(arguments: [KEFPath.volume, KEFPath.mute, KEFPath.physicalSource, KEFPath.eqProfileV2,
                      KEFPath.playerControl, KEFPath.maximumVolume, KEFPath.volumeLimit])
    func everydayPathsAreAllowed(_ path: String) {
        #expect(!KEFSafety.isBlocked(path))
    }
}

struct ModelTests {
    /// Captured from the LSX II on USB.
    static let usbPlayer = #"{"trackRoles":{"mediaData":{"metaData":{"playLogicPath":"kef:/playlogic","serviceID":"usb"}},"title":"usb","audioType":"audioBroadcast","type":"audio","path":"kef:/playlogic/usb"},"controls":{"pause":false,"next_":false,"previous":false},"mediaRoles":{"mediaData":{"metaData":{"serviceID":"usb"}},"title":"usb"},"state":"playing","error":""}"#

    @Test func physicalInputHasNoMetadata() throws {
        let player = PlayerState(json: try JSON(parsing: Self.usbPlayer))
        #expect(player.playback == .playing)
        #expect(player.track?.title == "usb")
        #expect(!player.hasMetadata)
        #expect(!player.canPause && !player.canNext)
    }

    @Test func streamingTrack() throws {
        let json = try JSON(parsing: #"""
            {"type":"x","x":{"state":"paused","trackRoles":{"title":"Song","icon":"https://img/a.jpg",
             "mediaData":{"metaData":{"artist":"Band","album":"LP","serviceID":"airplay"}}},
             "controls":{"pause":true,"next_":true,"previous":true}}}
            """#)
        let player = PlayerState(json: json)
        #expect(player.playback == .paused)
        #expect(player.track == Track(title: "Song", artist: "Band", album: "LP",
                                      artworkURL: URL(string: "https://img/a.jpg"), serviceID: "airplay"))
        #expect(player.hasMetadata && player.canPause && player.canNext && player.canPrevious)
    }

    @Test func events() throws {
        let json = try JSON(parsing: #"""
            [{"path":"player:volume","itemType":"update","itemValue":{"type":"i32_","i32_":30}},
             {"path":"settings:/mediaPlayer/mute","itemType":"update","itemValue":{"type":"bool_","bool_":true}},
             {"path":"player:volume","itemType":"update","itemValue":{"type":"i32_","i32_":31}},
             {"path":"player:player/data","itemType":"update"}, 7]
            """#)
        let events = try KEFEvent.parse(json)
        #expect(events.count == 4)
        #expect(events[3].value == nil)
        let latest = KEFEvent.latestPerPath(events)
        #expect(latest.map(\.path) == [KEFPath.mute, KEFPath.volume, KEFPath.playerData])
        #expect(latest[1].value == .int(31))
        #expect(try KEFEvent.parse(nil).isEmpty)
        #expect(try KEFEvent.parse(.array([])).isEmpty)
    }
}

struct EqTests {
    /// Captured from the LSX II (KC62 preset).
    static let profile = #"{"type":"kefEqProfileV2","kefEqProfileV2":{"highPassMode":true,"wallMounted":false,"subwooferCount":1,"phaseCorrection":true,"wallModeSetting":0,"trebleAmount":0,"isEqMode":false,"wirelessSub":"none","wallMode":false,"isExpertMode":false,"subEnableStereo":false,"highPassModeFreq":67.5,"dialogueMode":false,"profileName":"Subwoofer","subwooferPreset":"kc62","bassExtension":"less","deskModeSetting":-3,"balance":0,"audioPolarity":"normal","subwooferOut":true,"subwooferGain":-1,"soundProfile":"default","isKW1":false,"profileId":"762A880D-259D-4A84-9119-34C7F8D7B8C8","subwooferPolarity":"normal","deskMode":true,"subOutLPFreq":47.5}}"#

    @Test func parseAndModify() throws {
        var eq = try EqProfile(json: JSON(parsing: Self.profile))
        #expect(eq.double(.subwooferGain) == -1)
        #expect(eq.string(.bassExtension) == "less")
        #expect(eq.bool(.deskMode) == true)
        #expect(eq.hasSubwoofer)
        eq.set(.subwooferGain, 2)
        #expect(eq.double(.subwooferGain) == 2)
    }

    /// Mirrors pykefcontrol's `_to_v2`: unknown keys kept, app nulls added, numbers typed.
    @Test func apiValueKeepsUnknownKeysAndTypesNumbers() throws {
        let eq = try EqProfile(json: JSON(parsing: Self.profile))
        let api = eq.apiValue
        #expect(api.typeName == ValueType.eqProfileV2)
        let body = try #require(api.unwrapped.object)
        #expect(body.keys.prefix(2) == ["subwooferOutHotfix", "isCalibrated"])
        #expect(body["subwooferOutHotfix"] == .null)
        #expect(body["wirelessSub"] == .string("none"))
        #expect(body["isEqMode"] == .bool(false))
        #expect(body["subwooferGain"] == .double(-1))
        #expect(body["wallModeSetting"] == .double(0))
        #expect(body["deskModeSetting"] == .double(-3))
        #expect(body["balance"] == .int(0))
        #expect(body["subOutLPFreq"] == .double(47.5))
        #expect(body["highPassModeFreq"] == .double(67.5))
        #expect(body.count == eq.raw.count + 2)
        #expect(api.compactString.contains(#""subwooferGain":-1.0"#))
    }

    /// Mirrors pykefcontrol's `validate_eq_profile` (out of range, off grid, NaN refused).
    @Test func validation() throws {
        let eq = try EqProfile(json: JSON(parsing: Self.profile))
        try eq.validate()  // the real profile (47.5 / 67.5 Hz preset values) is valid
        for (key, value) in [(EqKey.trebleAmount, 30.0), (.trebleAmount, 0.3), (.subwooferGain, .nan),
                             (.balance, .infinity), (.subOutLPFreq, 300)] {
            var bad = eq
            bad.set(key, value)
            #expect(throws: KEFError.self, "\(key)=\(value)") { try bad.validate() }
        }
        var offGridFrequency = eq
        offGridFrequency.set(.subOutLPFreq, 47.4)
        try offGridFrequency.validate()
    }

    @Test func normalizeNeverTraps() throws {
        var eq = try EqProfile(json: JSON(parsing: Self.profile))
        eq.set(.balance, .infinity)
        eq.set(.highPassModeFreq, .nan)
        eq.set(.subwooferCount, 1e300)
        _ = eq.apiValue  // must not crash
    }

    @Test func invalidProfileIsRefusedBeforeAnyRequest() async throws {
        var eq = try EqProfile(json: JSON(parsing: Self.profile))
        eq.set(.subwooferGain, 60)
        let client = KEFClient(host: "192.0.2.1")  // TEST-NET: would time out if contacted
        await #expect(throws: KEFError.self) { try await client.setEqProfile(eq) }
    }

    @Test func rejectsV1Profiles() {
        #expect(throws: KEFError.self) {
            try EqProfile(json: JSON(parsing: #"{"type":"kefEqProfile","kefEqProfile":{"dspInfo":{}}}"#))
        }
    }

    @Test func rangesFromDescriptors() throws {
        let rows = try JSON(parsing: #"{"rows":[{"name":"highPassModeFreq","descriptor":{"range":{"step":2.5,"min":50,"max":120},"format":"range"}},{"name":"deskMode","descriptor":{"format":"boolean"}},{"name":"bogus","descriptor":{"range":{"min":0,"max":1}}}]}"#)
        let ranges = EqRange.fromDescriptors(rows)
        #expect(ranges == [.highPassModeFreq: EqRange(50, 120, step: 2.5)])
    }

    @Test func snapping() {
        let range = EqRange(-3, 3, step: 0.25)
        #expect(range.snap(0.3) == 0.25)
        #expect(range.snap(9) == 3)
        #expect(range.snap(-9) == -3)
        #expect(EqRange(40, 250, step: 2.5).snap(47.4) == 47.5)
    }
}

struct TrustTests {
    @Test func embeddedRootCAParses() {
        let summary = SecCertificateCopySubjectSummary(KEFTrust.rootCA) as String?
        #expect(summary == "KEF-CA")
    }

    @Test func ipDetection() {
        #expect(KEFTrust.isIPAddress("192.168.1.78"))
        #expect(KEFTrust.isIPAddress("[fe80::1%en0]"))
        #expect(!KEFTrust.isIPAddress("lsxii.local"))
    }
}
