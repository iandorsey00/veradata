import Foundation

public struct DataIssue: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { VeraText.text(message) }
}

// Keep JSON number lexemes intact. Foundation's generic JSON decoding uses
// fixed-precision number types, which can silently round imported values.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(JSONNumber)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var object: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var array: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var scalarText: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.raw
        case .bool(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    public var isScalar: Bool { array == nil && object == nil }

    public static func parse(_ data: Data) throws -> Self {
        try parse(data, maxBytes: maxBytes)
    }

    static func parse(_ data: Data, maxBytes: Int) throws -> Self {
        guard data.count <= maxBytes else { throw DataIssue(maxBytes == Self.maxBytes ? "JSON exceeds the 16 MiB limit." : "JSON exceeds the size limit.") }
        guard let source = String(data: data, encoding: .utf8) else {
            throw DataIssue("Open a UTF-8 JSON file.")
        }
        var reader = JSONReader(bytes: Array(source.utf8))
        let value = try reader.readValue(depth: 0)
        reader.skipWhitespace()
        guard reader.atEnd else { throw reader.issue("Unexpected content after the JSON value") }
        return value
    }

    public static let maxBytes = 16 * 1024 * 1024
    public static let maxDepth = 64

    public func data() throws -> Data {
        try data(maxBytes: Self.maxBytes)
    }

    func data(maxBytes: Int) throws -> Data {
        let data = Data((try rendered() + "\n").utf8)
        guard data.count <= maxBytes else { throw DataIssue(maxBytes == Self.maxBytes ? "JSON exceeds the 16 MiB limit." : "JSON exceeds the size limit.") }
        return data
    }

    public func rendered() throws -> String { try render(depth: 0) }

    private func render(depth: Int) throws -> String {
        guard depth <= Self.maxDepth else { throw DataIssue("JSON is nested too deeply.") }
        let childDepth = depth + 1
        let indent = String(repeating: "  ", count: depth)
        let childIndent = indent + "  "
        switch self {
        case .string(let value): return try Self.quote(value)
        case .number(let value): return value.raw
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let values):
            guard !values.isEmpty else { return "[]" }
            let lines = try values.map { try childIndent + $0.render(depth: childDepth) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let values):
            guard !values.isEmpty else { return "{}" }
            let lines = try values.sorted { $0.key < $1.key }.map {
                try childIndent + Self.quote($0.key) + ": " + $0.value.render(depth: childDepth)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    private static func quote(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Encoding a Swift String always produces a UTF-8 JSON fragment.
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public struct JSONNumber: Equatable, Sendable {
    public let raw: String
    public init(_ raw: String) throws {
        guard raw.wholeMatch(of: Self.syntax) != nil else { throw DataIssue("Invalid JSON number.") }
        self.raw = raw
    }

    fileprivate init(validated raw: String) { self.raw = raw }

    fileprivate static let syntax = #/-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/#
}

private struct JSONReader {
    let bytes: [UInt8]
    var index = 0
    var atEnd: Bool { index == bytes.count }
    private var next: UInt8? { atEnd ? nil : bytes[index] }

    func issue(_ text: String) -> DataIssue {
        let prefix = bytes.prefix(index)
        let line = prefix.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let column = index - (prefix.lastIndex(of: 10) ?? -1)
        return DataIssue(VeraText.format("%@ at line %lld, byte %lld.", VeraText.text(text), line, column))
    }

    mutating func skipWhitespace() {
        while let byte = next, [9, 10, 13, 32].contains(byte) { index += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard next == byte else { return false }
        index += 1
        return true
    }

    mutating func readValue(depth: Int) throws -> JSONValue {
        guard depth <= JSONValue.maxDepth else { throw issue("JSON is nested too deeply") }
        skipWhitespace()
        guard let next else { throw issue("Expected a JSON value") }
        switch next {
        case 34: return .string(try readString())
        case 123: return .object(try readObject(depth: depth + 1))
        case 91: return .array(try readArray(depth: depth + 1))
        case 116: try expect("true"); return .bool(true)
        case 102: try expect("false"); return .bool(false)
        case 110: try expect("null"); return .null
        case 45, 48...57: return .number(try readNumber())
        default: throw issue("Expected a JSON value")
        }
    }

    private mutating func expect(_ literal: String) throws {
        guard bytes[index...].starts(with: literal.utf8) else { throw issue("Invalid JSON literal") }
        index += literal.utf8.count
    }

    private mutating func readString() throws -> String {
        let start = index
        guard take(34) else { throw issue("Expected a quoted string") }
        while let byte = next {
            index += 1
            if byte == 34 {
                do {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                } catch {
                    throw issue("Invalid JSON string")
                }
            }
            if byte == 92, !atEnd { index += 1 }
        }
        throw issue("Unterminated string")
    }

    private mutating func readNumber() throws -> JSONNumber {
        let start = index
        while let byte = next, (48...57).contains(byte) || [43, 45, 46, 69, 101].contains(byte) {
            index += 1
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        guard token.wholeMatch(of: JSONNumber.syntax) != nil else { throw issue("Invalid JSON number") }
        return JSONNumber(validated: token)
    }

    private mutating func readObject(depth: Int) throws -> [String: JSONValue] {
        index += 1
        skipWhitespace()
        var values: [String: JSONValue] = [:]
        if take(125) { return values }
        while true {
            skipWhitespace()
            let key = try readString()
            guard values[key] == nil else { throw issue("Duplicate object key") }
            skipWhitespace()
            guard take(58) else { throw issue("Expected a colon after the object key") }
            values[key] = try readValue(depth: depth)
            skipWhitespace()
            if take(125) { return values }
            guard take(44) else { throw issue("Expected a comma or closing brace") }
        }
    }

    private mutating func readArray(depth: Int) throws -> [JSONValue] {
        index += 1
        skipWhitespace()
        var values: [JSONValue] = []
        if take(93) { return values }
        while true {
            values.append(try readValue(depth: depth))
            skipWhitespace()
            if take(93) { return values }
            guard take(44) else { throw issue("Expected a comma or closing bracket") }
        }
    }
}
