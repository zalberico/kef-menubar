/// Typed values of the KEF (StreamUnlimited) API.
///
/// The speaker wraps every value in an object carrying its type name, with the
/// payload under a key equal to that name:
///
///     {"type":"i32_","i32_":42}
///     {"type":"kefPhysicalSource","kefPhysicalSource":"usb"}
public enum ValueType {
    public static let bool = "bool_"
    public static let i16 = "i16_"
    public static let i32 = "i32_"
    public static let i64 = "i64_"
    public static let double = "double_"
    public static let string = "string_"
    public static let physicalSource = "kefPhysicalSource"
    public static let speakerStatus = "kefSpeakerStatus"
    public static let eqProfileV2 = "kefEqProfileV2"
}

public extension JSON {
    /// Wrap `payload` in a typed value: `typed("i32_", 42)` → `{"type":"i32_","i32_":42}`.
    static func typed(_ type: String, _ payload: JSON) -> JSON {
        .object(JSONObject([("type", .string(type)), (type, payload)]))
    }

    /// The `type` discriminator of a typed value, if any.
    var typeName: String? { self["type"]?.string }

    /// The payload of a typed value; anything else is returned unchanged.
    var unwrapped: JSON {
        if let type = typeName, let payload = self[type] { return payload }
        return self
    }
}
