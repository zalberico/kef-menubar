import Testing
@testable import KEFAppCore

struct VolumePolicyTests {
    @Test(arguments: [
        (maximum: 40, limited: true, ceiling: 40),
        (maximum: 100, limited: true, ceiling: 100),
        (maximum: 0, limited: true, ceiling: 1),  // never 0: the slider needs a range
        (maximum: 40, limited: false, ceiling: 100),
        (maximum: 0, limited: false, ceiling: 100),
    ])
    func ceiling(maximum: Int, limited: Bool, ceiling: Int) {
        #expect(VolumePolicy.ceiling(maximum: maximum, limited: limited) == ceiling)
    }

    @Test(arguments: [
        (volume: -5, ceiling: 40, result: 0),
        (volume: 0, ceiling: 40, result: 0),
        (volume: 30, ceiling: 40, result: 30),
        (volume: 40, ceiling: 40, result: 40),
        (volume: 80, ceiling: 40, result: 40),
        (volume: 150, ceiling: 100, result: 100),
    ])
    func clamp(volume: Int, ceiling: Int, result: Int) {
        #expect(VolumePolicy.clamp(volume, ceiling: ceiling) == result)
    }

    @Test(arguments: [
        (from: 20, by: 2, ceiling: 100, result: 22),
        (from: 20, by: -2, ceiling: 100, result: 18),
        (from: 39, by: 2, ceiling: 40, result: 40),
        (from: 40, by: 2, ceiling: 40, result: 40),
        (from: 70, by: -2, ceiling: 40, result: 40),  // above a lowered limit: back to it
        (from: 70, by: 2, ceiling: 40, result: 40),
        (from: 1, by: -2, ceiling: 100, result: 0),
        (from: 20, by: 25, ceiling: 100, result: 30),  // step clamped to 10
        (from: 20, by: -25, ceiling: 100, result: 10),
        (from: 20, by: 0, ceiling: 100, result: 20),
    ])
    func step(from: Int, by: Int, ceiling: Int, result: Int) {
        #expect(VolumePolicy.step(from: from, by: by, ceiling: ceiling) == result)
    }
}
