/// The volume rules shared by the live model and the one-shot commands (widgets, controls,
/// intents): the volume never goes above the speaker's own volume limit when it is on.
public enum VolumePolicy {
    /// The step range for relative changes.
    public static let stepRange = 1...10

    /// The highest volume allowed: the speaker's limit when it is on, else 100.
    public static func ceiling(maximum: Int, limited: Bool) -> Int {
        limited ? max(1, maximum) : 100
    }

    /// `volume` kept within `0...ceiling`.
    public static func clamp(_ volume: Int, ceiling: Int) -> Int {
        min(max(volume, 0), ceiling)
    }

    /// One step up (`by > 0`) or down (`by < 0`) from `volume`, the step size clamped to
    /// 1...10, the result to `0...ceiling`. `by == 0` changes nothing but the clamp.
    public static func step(from volume: Int, by delta: Int, ceiling: Int) -> Int {
        guard delta != 0 else { return clamp(volume, ceiling: ceiling) }
        let size = min(max(abs(delta), stepRange.lowerBound), stepRange.upperBound)
        return clamp(volume + (delta > 0 ? size : -size), ceiling: ceiling)
    }
}
