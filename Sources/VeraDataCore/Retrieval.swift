import Foundation

public struct Representation: Identifiable, Equatable, Sendable {
    public let label: String
    public let text: String
    public var localizedLabel: String { VeraText.text(label) }
    public var id: String { label }
}

public struct RecordValue: Identifiable, Equatable, Sendable {
    public let path: [String]
    public let label: String
    public let value: JSONValue
    public let representations: [Representation]
    public let aliases: [String]
    public var localizesLabel = false
    public var missingFields: [String] = []

    public var bulletItems: [String]? {
        guard representations.contains(where: { $0.label == "Bullet list" }) else { return nil }
        return value.array?.compactMap(\.string)
    }
    public var localizedLabel: String { localizesLabel ? VeraText.text(label) : label }

    public var id: String {
        if path.isEmpty { return "#" + label }
        return "/" + path.map {
            $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }.joined(separator: "/")
    }

    public var preferredRepresentation: Representation? {
        representations.first { $0.label == "Bullet list" } ?? representations.first
    }

    public var display: String {
        if value == .null { return VeraText.text("Unknown") }
        if preferredRepresentation?.text.isEmpty == true { return VeraText.text("Empty text") }
        return preferredRepresentation?.text ?? VeraText.text(value.array != nil ? "Empty list" : "Empty object")
    }
}

extension Record {
    public var renderedMailingLines: String? { mailingLines?.text }

    private var mailingLines: MailingLines? {
        guard kind == .address, let template = fields["formatted"]?.string else { return nil }
        return MailingLines.render(template, fields: fields)
    }

    public var values: [RecordValue] {
        var values = orderedKeys.flatMap { key -> [RecordValue] in
            let field = fieldDefinition(key)
            let shortcuts = aliases.filter { $0.value == key }.keys.sorted()
            if key == "formatted", let template = fields[key]?.string, let rendered = mailingLines {
                return [RecordValue(path: [key], label: field.label, value: .string(template),
                                    representations: [Representation(label: "Rendered address", text: rendered.text),
                                                      Representation(label: "As stored", text: template)],
                                    aliases: field.aliases + shortcuts + ["mailing address", "完整地址"], localizesLabel: true,
                                    missingFields: rendered.missingFields.map { fieldDefinition($0).localizedLabel })]
            }
            var results = Self.flatten(fields[key]!, path: [key], label: field.label, style: field.style,
                                aliases: field.aliases + shortcuts)
            if field.localizesLabel, results.count == 1 { results[0].localizesLabel = true }
            return results
        }
        if kind == .address, fields["formatted"]?.string?.isEmpty != false, let address = mailingAddress {
            let representation = Representation(label: "As stored", text: address)
            values.insert(RecordValue(path: [], label: "Full address", value: .string(address),
                                      representations: [representation], aliases: ["mailing address", "完整地址"], localizesLabel: true), at: 0)
        }
        if kind == .address, let coordinates = AddressCoordinates(fields: fields) {
            let text = coordinates.decimalDegrees
            values.insert(RecordValue(path: [], label: "Coordinates", value: .string(text),
                                      representations: [Representation(label: "Decimal degrees", text: text)],
                                      aliases: ["geo", "geocoords", "geo coordinates", "gps", "coordinate pair", "经纬度"], localizesLabel: true),
                          at: min(1, values.count))
        }
        return values
    }

    public var copyableSummary: String {
        ([label] + values.compactMap { field in
            guard let text = field.preferredRepresentation?.text, !text.isEmpty else { return nil }
            return "\(field.localizedLabel): \(text)"
        }).joined(separator: "\n")
    }

    public func projection(keys: Set<String>) -> JSONValue {
        .object(fields.filter { keys.contains($0.key) && $0.value.isScalar })
    }

    private var mailingAddress: String? {
        func field(_ key: String) -> String? {
            guard let text = fields[key]?.string, !text.isEmpty else { return nil }
            return text
        }
        let cityRegion = [field("city"), field("region")].compactMap { $0 }.joined(separator: ", ")
        let locality = [cityRegion.isEmpty ? nil : cityRegion, field("postalCode")]
            .compactMap { $0 }.joined(separator: " ")
        let lines = [field("line1"), field("line2"), locality.isEmpty ? nil : locality, field("country")]
            .compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func flatten(
        _ value: JSONValue, path: [String], label: String, style: FieldDefinition.Style, aliases: [String]
    ) -> [RecordValue] {
        if let object = value.object, !object.isEmpty {
            return object.keys.sorted().flatMap { key in
                flatten(object[key]!, path: path + [key], label: "\(label) › \(key)", style: .text, aliases: aliases)
            }
        }
        if let array = value.array, !array.isEmpty, !array.allSatisfy({ $0.string != nil }) {
            return array.enumerated().flatMap { index, child in
                flatten(child, path: path + [String(index)], label: "\(label) › \(index + 1)", style: .text, aliases: aliases)
            }
        }
        return [RecordValue(path: path, label: label, value: value,
                            representations: formats(value, style: style), aliases: aliases)]
    }

    private static func formats(_ value: JSONValue, style: FieldDefinition.Style) -> [Representation] {
        if let list = value.array, !list.isEmpty {
            let items = list.compactMap(\.string)
            return [
                Representation(label: "Plain text", text: items.joined(separator: "\n")),
                Representation(label: "Bullet list", text: items.map { "• " + $0 }.joined(separator: "\n")),
            ]
        }
        guard let text = value.scalarText else { return [] }
        var formats = [Representation(label: "As stored", text: text)]
        if style == .date, let date = PartialDate(text) {
            formats.append(Representation(label: "Year", text: date.year))
            if let month = date.month { formats.append(Representation(label: "Month", text: month)) }
            if let yearMonth = date.yearMonth {
                formats.append(Representation(label: "Year and month", text: yearMonth))
            }
        }
        if style == .phone, text.wholeMatch(of: #/\+?[0-9(). -]+/#) != nil {
            let digits = text.filter { $0.isASCII && $0.isNumber }
            if !digits.isEmpty { formats.append(Representation(label: "Digits only", text: digits)) }
            if text.hasPrefix("+"), (2...15).contains(digits.count), digits.first != "0" {
                formats.append(Representation(label: "International", text: "+" + digits))
            }
        }
        return formats
    }
}

public struct SearchResult: Identifiable, Equatable, Sendable {
    public let record: Record?
    public let field: RecordValue?
    public let preferredFormat: Representation?
    public let currentValue: CurrentValue?
    public let representations: [Representation]

    public var id: String {
        if let currentValue { return "#current/" + currentValue.rawValue }
        return (record?.id ?? "") + (field?.id ?? "#record")
    }
    public var title: String { currentValue.map { VeraText.text($0.title) } ?? field?.localizedLabel ?? record?.label ?? "" }
    public var subtitle: String {
        if currentValue != nil { return VeraText.text("Device clock") }
        return (field == nil ? record?.subtitle : record?.label) ?? ""
    }

    init(record: Record, field: RecordValue?, preferredFormat: Representation?) {
        self.record = record
        self.field = field
        self.preferredFormat = preferredFormat
        currentValue = nil
        representations = field?.representations ?? []
    }

    init(currentValue: CurrentValue, representations: [Representation]) {
        self.currentValue = currentValue
        record = nil
        field = nil
        preferredFormat = representations.first
        self.representations = representations
    }
}

public struct RetrievalIndex: Sendable {
    private struct Entry: Sendable {
        let record: Record
        let value: RecordValue?
        let title: String
        let context: String
        let aliases: [String]
        let content: String
        let formatTerms: [[String]]

    }

    private let entries: [Entry]

    public init(records: [Record]) {
        entries = records.flatMap { record -> [Entry] in
            let context = Self.normalized([record.label, record.kind.title, VeraText.text(record.kind.title, language: "zh-Hans"), record.subtitle,
                                           record.fields["employer"]?.string ?? "",
                                           record.fields["institution"]?.string ?? ""].joined(separator: " "))
            let header = Entry(record: record, value: nil, title: Self.normalized(record.label),
                               context: context, aliases: [], content: "", formatTerms: [])
            let fields = record.values.map { value in
                var aliases = value.aliases
                if value.localizesLabel { aliases.append(VeraText.text(value.label, language: "zh-Hans")) }
                let formatTerms = value.representations.dropFirst().map {
                    [Self.normalized($0.label), Self.normalized(VeraText.text($0.label, language: "zh-Hans"))]
                }
                return Entry(record: record, value: value, title: Self.normalized(value.label),
                             context: context, aliases: aliases.map(Self.normalized),
                             content: Self.normalized(String(value.display.prefix(2048))), formatTerms: formatTerms)
            }
            return [header] + fields
        }
    }

    public func search(
        _ query: String, recordID: String? = nil, limit: Int = 80, now: Date = .now,
        timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent
    ) -> [SearchResult] {
        let normalized = Self.normalized(query)
        let tokens = normalized.split(separator: " ").map(String.init)
        let aliasQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = entries.enumerated().compactMap { position, entry -> (Int, Int, SearchResult)? in
            guard recordID == nil || entry.record.id == recordID else { return nil }
            if normalized.isEmpty {
                guard recordID == nil ? entry.value == nil : entry.value != nil else { return nil }
                return (0, position, SearchResult(record: entry.record, field: entry.value, preferredFormat: nil))
            }
            if normalized.hasPrefix(";") {
                let exactAlias = entry.value?.aliases.contains { $0.caseInsensitiveCompare(aliasQuery) == .orderedSame }
                guard exactAlias == true else { return nil }
            }

            let formats = entry.value?.representations ?? []
            let matchedFormats = zip(formats.dropFirst(), entry.formatTerms).compactMap { format, labels -> Representation? in
                guard tokens.count > 1 else { return nil }
                let matches = labels.contains { label in
                    let words = label.split(separator: " ").map(String.init).filter { $0 != "and" }
                    return !words.isEmpty && words.allSatisfy(tokens.contains)
                }
                return matches ? format : nil
            }
            let format = matchedFormats.max { $0.label.count < $1.label.count }

            let score: Int
            if entry.aliases.contains(normalized) { score = 120 }
            else if entry.title == normalized { score = 110 }
            else if entry.title.hasPrefix(normalized) { score = 95 }
            else if entry.aliases.contains(where: { $0.hasPrefix(normalized) }) { score = 85 }
            else {
                let metadata = ([entry.title, entry.context] + entry.aliases
                    + entry.formatTerms.flatMap { $0 }).joined(separator: " ")
                guard tokens.allSatisfy({ metadata.contains($0) || entry.content.contains($0) }) else { return nil }
                score = tokens.reduce(0) { total, token in
                    total + (entry.title.contains(token) ? 10 : (metadata.contains(token) ? 5 : 1))
                } + (format == nil ? 0 : 5)
            }
            if entry.record.addressStatus == "Historical", recordID == nil, !normalized.hasPrefix(";") {
                return (score - 12, position, SearchResult(record: entry.record, field: entry.value, preferredFormat: format))
            }
            return (score, position, SearchResult(record: entry.record, field: entry.value, preferredFormat: format))
        }
        let current = CurrentValue.allCases.enumerated().compactMap { position, value -> (Int, Int, SearchResult)? in
            guard let score = value.match(normalized) else { return nil }
            let formats = value.representations(at: now, timeZone: timeZone, locale: locale)
            return (score, entries.count + position, SearchResult(currentValue: value, representations: formats))
        }
        let sorted = (matches + current).sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }
        return sorted.prefix(max(0, limit)).map { $0.2 }
    }

    private static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let separated = String(folded.map { $0.isLetter || $0.isNumber || $0 == ";" ? $0 : " " })
        return separated.split(separator: " ").joined(separator: " ")
    }
}
