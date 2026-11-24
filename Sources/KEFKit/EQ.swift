import Foundation

/// Keys of the v2 EQ / DSP profile (`kef:eqProfile/v2`), in physical units.
public enum EqKey: String, Sendable, CaseIterable {
    case balance                // steps, -30…30
    case deskMode               // bool
    case deskModeSetting        // dB
    case wallMode               // bool
    case wallModeSetting        // dB
    case trebleAmount           // dB
    case phaseCorrection        // bool
    case bassExtension          // "less" | "standard" | "extra"
    case highPassMode           // bool
    case highPassModeFreq       // Hz
    case subOutLPFreq           // Hz
    case subwooferGain          // dB
    case subwooferPolarity      // "normal" | "inverted"
    case subwooferOut           // bool
    case subwooferPreset        // "custom", "kc62", ...
    case subwooferCount
    case isExpertMode
    case profileName
}

/// The speaker's EQ / DSP profile.
///
/// Like the official app (and the reference client), the whole profile is read,
/// modified and written back. Unknown keys are kept verbatim so fields added by
/// newer firmware are never dropped.
public struct EqProfile: Sendable, Equatable {
    public var raw: JSONObject

    public init(raw: JSONObject) { self.raw = raw }

    /// Parse a typed `kefEqProfileV2` value (or its bare object).
    public init(json: JSON) throws {
        let inner = json.unwrapped
        guard let object = inner.object, object["dspInfo"] == nil,
              json.typeName == nil || json.typeName == ValueType.eqProfileV2
        else { throw KEFError.invalidResponse("not a v2 EQ profile: \(json.compactString.prefix(200))") }
        raw = object
    }

    public subscript(key: EqKey) -> JSON? {
        get { raw[key.rawValue] }
        set { raw[key.rawValue] = newValue }
    }

    public func bool(_ key: EqKey) -> Bool? { self[key]?.bool }
    public func double(_ key: EqKey) -> Double? { self[key]?.double }
    public func string(_ key: EqKey) -> String? { self[key]?.string }

    public mutating func set(_ key: EqKey, _ value: Bool) { self[key] = .bool(value) }
    public mutating func set(_ key: EqKey, _ value: Double) { self[key] = .double(value) }
    public mutating func set(_ key: EqKey, _ value: String) { self[key] = .string(value) }

    public var hasSubwoofer: Bool { (self[.subwooferCount]?.int ?? 0) > 0 }

    /// The typed value to send with `setData`, with numbers typed like the reference
    /// client writes them (`balance` int, gains as floats, frequencies int when integral).
    public var apiValue: JSON {
        var body = JSONObject()
        if raw["subwooferOutHotfix"] == nil { body["subwooferOutHotfix"] = .null }
        if raw["isCalibrated"] == nil { body["isCalibrated"] = .null }
        for (key, value) in raw { body[key] = Self.normalize(key, value) }
        return .typed(ValueType.eqProfileV2, .object(body))
    }

    static func normalize(_ key: String, _ value: JSON) -> JSON {
        // Never trap: non-finite or absurd numbers are left as they are (validation rejects them).
        guard let v = value.double, v.isFinite, abs(v) < 1e15 else { return value }
        switch key {
        case "balance", "subwooferCount":
            return .int(Int64(v.rounded()))
        case "wallModeSetting", "trebleAmount", "subwooferGain", "deskModeSetting":
            return .double(v)
        case "highPassModeFreq", "subOutLPFreq":
            return v.rounded() == v ? .int(Int64(v)) : .double(v)
        default:
            return value
        }
    }

    /// Like the reference client's `validate_eq_profile`: every numeric setting must be
    /// finite, inside its range and on its step grid (frequencies may be off-grid,
    /// subwoofer presets use 47.5 Hz and the like).
    public func validate(against ranges: [EqKey: EqRange] = EqRange.defaults) throws {
        for (key, range) in ranges {
            guard let value = self[key], value != .null else { continue }
            guard let number = value.double, number.isFinite else {
                throw KEFError.invalidValue("\(key.rawValue) must be a finite number, not \(value.compactString)")
            }
            guard number >= range.min - 1e-9, number <= range.max + 1e-9 else {
                throw KEFError.invalidValue("\(key.rawValue)=\(number) is outside \(range.min)…\(range.max)")
            }
            if range.step > 0, key != .highPassModeFreq, key != .subOutLPFreq {
                let steps = (number - range.min) / range.step
                if abs(steps - steps.rounded()) > 1e-6 {
                    throw KEFError.invalidValue("\(key.rawValue)=\(number) is not a multiple of \(range.step) from \(range.min)")
                }
            }
        }
    }
}

/// Allowed range of a numeric EQ setting.
public struct EqRange: Sendable, Equatable {
    public var min: Double
    public var max: Double
    public var step: Double

    public init(_ min: Double, _ max: Double, step: Double) {
        self.min = min
        self.max = max
        self.step = step
    }

    public var closed: ClosedRange<Double> { min...max }

    /// Clamp `value` into the range and onto its step grid.
    public func snap(_ value: Double) -> Double {
        let clamped = Swift.min(Swift.max(value, min), max)
        guard step > 0 else { return clamped }
        return Swift.min(max, min + ((clamped - min) / step).rounded() * step)
    }

    /// App defaults, used when the speaker does not advertise its own ranges.
    public static let defaults: [EqKey: EqRange] = [
        .balance: EqRange(-30, 30, step: 1),
        .deskModeSetting: EqRange(-10, 0, step: 0.5),
        .wallModeSetting: EqRange(-10, 0, step: 0.5),
        .trebleAmount: EqRange(-3, 3, step: 0.25),
        .highPassModeFreq: EqRange(50, 120, step: 2.5),
        .subOutLPFreq: EqRange(40, 250, step: 2.5),
        .subwooferGain: EqRange(-10, 10, step: 1),
    ]

    /// Ranges advertised by the speaker in `kef:dsp/editValue` (`getRows` answer).
    public static func fromDescriptors(_ rows: JSON) -> [EqKey: EqRange] {
        var result: [EqKey: EqRange] = [:]
        for row in rows["rows"]?.array ?? [] {
            guard let name = row["name"]?.string, let key = EqKey(rawValue: name),
                  let range = row["descriptor"]?["range"],
                  let lo = range["min"]?.double, let hi = range["max"]?.double
            else { continue }
            result[key] = EqRange(lo, hi, step: range["step"]?.double ?? 1)
        }
        return result
    }
}
