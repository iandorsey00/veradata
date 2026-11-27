import Foundation

/// Stores the checked value's fingerprint without retaining the original text.
public struct FieldVerification: Codable, Equatable, Sendable {
    public let fingerprint: String
    public let checkedAt: Date

    public init?(value: JSONValue, original: String, checkedAt: Date = Date()) throws {
        guard let text = Self.comparisonText(value), Self.normalize(text) == Self.normalize(original) else { return nil }
        fingerprint = EvidenceDigest.hash(try value.data())
        self.checkedAt = checkedAt
    }

    public static func comparisonText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let text: String
        if let scalar = value.scalarText {
            text = scalar
        } else if let list = value.array, list.allSatisfy({ $0.string != nil }) {
            text = list.compactMap(\.string).joined(separator: "\n")
        } else {
            return nil
        }
        return normalize(text).isEmpty ? nil : text
    }

    public func matches(_ value: JSONValue?) -> Bool {
        guard let value, let bytes = try? value.data() else { return false }
        return EvidenceDigest.hash(bytes) == fingerprint
    }

    var isValid: Bool {
        EvidenceDigest.isValid(fingerprint) && checkedAt.timeIntervalSinceReferenceDate.isFinite
    }

    // VeraFlow defaults preserve case and punctuation, normalize to NFC, and collapse ECMAScript whitespace.
    private static let whitespace = CharacterSet(charactersIn:
        "\t\n\u{000B}\u{000C}\r \u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
    )

    private static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.components(separatedBy: whitespace)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
