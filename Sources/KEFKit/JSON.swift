import Foundation

/// A JSON value that keeps object key order and the integer/double distinction.
///
/// Request bodies are serialized by ``compactData`` exactly like the reference
/// client's `json.dumps(obj, separators=(",", ":"), ensure_ascii=False)`, and the
/// bytes that get signed are the bytes that get sent.
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// An insertion-ordered JSON object. Equality ignores key order.
public struct JSONObject: Sendable, Hashable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var index = 0
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            let key = keys[index]
            return (key, storage[key]!)
        }
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
}

// MARK: - Literals

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
}

// MARK: - Accessors

public extension JSON {
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var object: JSONObject? { if case .object(let v) = self { v } else { nil } }
    var array: [JSON]? { if case .array(let v) = self { v } else { nil } }
    var isNull: Bool { self == .null }

    /// Integer value; integral doubles (`-3.0`) are accepted, booleans are not.
    var int: Int? {
        switch self {
        case .int(let v): return Int(exactly: v)
        case .double(let v) where v.rounded() == v && abs(v) < 1e15: return Int(v)
        default: return nil
        }
    }

    /// Numeric value as a double (integers included, booleans not).
    var double: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }

    subscript(key: String) -> JSON? { object?[key] }
}

// MARK: - Serialization

public extension JSON {
    /// Compact UTF-8 serialization (no whitespace, non-ASCII characters left as is).
    var compactData: Data { Data(compactString.utf8) }

    var compactString: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let v): out += v ? "true" : "false"
        case .int(let v): out += String(v)
        case .double(let v): out += JSON.format(v)
        case .string(let v): JSON.escape(v, into: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(to: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            var first = true
            for (key, value) in object {
                if !first { out += "," }
                first = false
                JSON.escape(key, into: &out)
                out += ":"
                value.write(to: &out)
            }
            out += "}"
        }
    }

    /// Same text as Python's `repr(float)`: shortest round-trip form, `-1.0`, `67.5`, `1e-05`.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value > 0 ? "Infinity" : "-Infinity") }
        return "\(value)"
    }

    private static func escape(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let offset: Int
    public var description: String { "Invalid JSON at byte \(offset): \(message)" }
}

public extension JSON {
    /// Parse a JSON document (keeps key order; integers stay integers).
    init(parsing data: Data) throws {
        var parser = Parser(bytes: [UInt8](data))
        self = try parser.parseDocument()
    }

    init(parsing string: String) throws {
        try self.init(parsing: Data(string.utf8))
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws -> JSON {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw error("trailing data") }
        return value
    }

    private func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard peek == byte else { throw error("expected '\(Character(Unicode.Scalar(byte)))'") }
        index += 1
    }

    private mutating func parseValue(depth: Int) throws -> JSON {
        guard depth < 256 else { throw error("nesting too deep") }
        guard let byte = peek else { throw error("unexpected end of data") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func literal(_ word: String) throws {
        for byte in word.utf8 { try expect(byte) }
    }

    private mutating func parseObject(depth: Int) throws -> JSON {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if peek == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard peek == UInt8(ascii: "\"") else { throw error("expected object key") }
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(object)
            default: throw error("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSON {
        index += 1
        var values: [JSON] = []
        skipWhitespace()
        if peek == UInt8(ascii: "]") { index += 1; return .array(values) }
        while true {
            skipWhitespace()
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(values)
            default: throw error("expected ',' or ']'")
            }
        }
    }

    private mutating func parseNumber() throws -> JSON {
        let start = index
        var isFloat = false
        if peek == UInt8(ascii: "-") { index += 1 }
        func digits() { while let b = peek, b >= 0x30 && b <= 0x39 { index += 1 } }
        digits()
        if peek == UInt8(ascii: ".") { isFloat = true; index += 1; digits() }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            isFloat = true
            index += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
            digits()
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard !text.isEmpty, text != "-" else { throw error("invalid value") }
        if !isFloat, let value = Int64(text) { return .int(value) }
        guard let value = Double(text) else { throw error("invalid number \(text)") }
        return .double(value)
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw error("invalid \\u escape") }
        index += 4
        return value
    }

    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        var buffer: [UInt8] = []
        while let byte = peek {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let escape = peek else { throw error("unterminated escape") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(escape)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
                    {
                        let save = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = save
                        }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    buffer.append(contentsOf: String(scalar).utf8)
                default:
                    throw error("invalid escape")
                }
            default:
                buffer.append(byte)
            }
        }
        throw error("unterminated string")
    }
}
