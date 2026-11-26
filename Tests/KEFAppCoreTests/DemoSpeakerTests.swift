#if DEBUG
import Foundation
import KEFKit
import Testing
@testable import KEFAppCore

/// The screenshot demo (`-DemoSpeaker`) both apps use: read-only, since its state is shared.
struct DemoSpeakerTests {
    @Test func servesTheMadeUpSpeaker() async throws {
        let client = DemoSpeaker.makeClient()
        #expect(client.host == DemoSpeaker.host)
        #expect(try await client.deviceName() == "Living Room")
        #expect(try await client.volume() == 24)
        let player = try await client.playerState()
        #expect(player.track?.artist == "The Speakeasy Trio")
        #expect(player.track?.album == "Late Night Session")
    }

    @Test func drawsItsCovers() {
        for cover in [DemoCover.lateNightSession, DemoCover.earlyLight] {
            // A PNG, 600 px.
            #expect(cover.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
    }
}
#endif
