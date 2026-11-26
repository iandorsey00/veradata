import Foundation

public struct RecordImport: Equatable, Sendable {
    public let profiles: [Profile]

    public static func read(_ url: URL) throws -> RecordImport {
        try RecordImport(data: VaultFile.readData(url), fallbackLabel: url.deletingPathExtension().lastPathComponent)
    }

    public init(data: Data, fallbackLabel: String = "Imported Record") throws {
        let root = try JSONValue.parse(data)
        guard let object = root.object, !object.isEmpty else {
            throw DataIssue("Choose a VeraData JSON file or a nonempty JSON object of fields.")
        }
        let groups: [Profile]
        switch object["format"]?.string {
        case "veradata-mobile":
            groups = try MobileTransfer(data: data).profiles
        case "veradata-selection", "veradata-import":
            guard Set(object.keys) == ["format", "version", "records"],
                  case .number(let version)? = object["version"], version.raw == "1",
                  let items = object["records"]?.array, !items.isEmpty else {
                throw DataIssue("This record import file has an unsupported version or structure.")
            }
            let records = try items.enumerated().map { index, item in
                try Self.decode(item, number: index + 1)
            }
            groups = [Profile(name: fallbackLabel, records: records)]
        case let format? where format.hasPrefix("veradata-"):
            throw DataIssue("This VeraData file format is not supported for record import.")
        default:
            if object["version"] != nil, object["profiles"] != nil, object["settings"] != nil {
                groups = try Vault(data: data).profiles
            } else {
                let record = Record(kind: .custom, label: fallbackLabel, fields: object)
                groups = [Profile(name: fallbackLabel, records: [record])]
            }
        }
        profiles = groups.filter { !$0.records.isEmpty }
        guard !profiles.isEmpty else { throw DataIssue("There are no records in this file.") }
        _ = try Vault(profiles: profiles).validated()
    }

    private static func decode(_ value: JSONValue, number: Int) throws -> Record {
        let path = VeraText.format("Import record %lld", number)
        guard var object = value.object,
              let kindValue = object["kind"]?.string, let kind = RecordKind(rawValue: kindValue),
              var fields = object["fields"]?.object, !fields.isEmpty else {
            throw DataIssue(VeraText.format("%@ needs a supported kind and a nonempty fields object.", path))
        }
        if kind == .employment, let end = fields["endDate"]?.string {
            fields["endDate"] = .string(Record.canonicalEmploymentEndDate(end))
            object["fields"] = .object(fields)
        }
        if object["id"] == nil { object["id"] = .string(UUID().uuidString.lowercased()) }
        if object["label"] == nil {
            let parts: [String]
            switch kind {
            case .contact: parts = ["name", "email", "phone"]
            case .address: parts = ["line1", "city", "formatted"]
            case .employment: parts = ["employer", "title"]
            case .education: parts = ["institution", "qualification"]
            case .custom: parts = ["name", "title"]
            }
            let names = parts.compactMap { fields[$0]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            object["label"] = .string(names.isEmpty ? VeraText.format("%@ %lld", kind.localizedTitle, number)
                                     : names.prefix(kind == .employment ? 2 : 1).joined(separator: " · "))
        }
        return try Vault.decodeRecord(.object(object), at: path)
    }
}

public struct RecordImportReview: Sendable {
    public enum Decision: Equatable, Sendable {
        case skip
        case add
        case update(Record.ID, fields: Set<String>)
    }

    public let source: Profile
    public let destination: Profile
    private let candidates: [Record.ID: [Record.ID]]

    public init(source: Profile, destination: Profile) {
        self.source = source
        self.destination = destination
        var index: [MatchKey: Set<Int>] = [:]
        for (position, record) in destination.records.enumerated() {
            for key in Self.keys(for: record) { index[key, default: []].insert(position) }
        }
        candidates = Dictionary(source.records.map { incoming in
            let positions = Self.keys(for: incoming).reduce(into: Set<Int>()) {
                $0.formUnion(index[$1, default: []])
            }
            let matches = positions.compactMap { position -> (Int, Int, Record.ID)? in
                let existing = destination.records[position]
                let score = Self.match(incoming, existing)
                return score > 0 ? (score, position, existing.id) : nil
            }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }
            return (incoming.id, matches.map { $0.2 })
        }, uniquingKeysWith: { first, _ in first })
    }

    public func possibleMatches(for record: Record) -> [Record.ID] { candidates[record.id, default: []] }

    public func initialDecision(for record: Record) -> Decision {
        possibleMatches(for: record).isEmpty ? .add : .skip
    }

    public func applying(_ decisions: [Record.ID: Decision]) throws -> Profile {
        var updated = destination
        var edited: Set<Record.ID> = []
        var ids = Set(destination.records.map(\.id))
        for record in source.records {
            switch decisions[record.id, default: .skip] {
            case .skip: continue
            case .add:
                if ids.insert(record.id).inserted {
                    updated.records.append(record)
                } else {
                    let copy = Record(kind: record.kind, label: record.label, fields: record.fields, aliases: record.aliases)
                    ids.insert(copy.id)
                    updated.records.append(copy)
                }
            case .update(let id, let keys):
                guard let index = destination.records.firstIndex(where: { $0.id == id && $0.kind == record.kind }),
                      edited.insert(id).inserted else {
                    throw DataIssue("Choose a different existing record for each update.")
                }
                guard !keys.isEmpty, keys.isSubset(of: Set(record.fields.keys)) else {
                    throw DataIssue("Choose at least one incoming field for each update.")
                }
                for key in keys { updated.records[index].fields[key] = record.fields[key] }
            }
        }
        _ = try Vault(profiles: [updated]).validated()
        return updated
    }

    private struct MatchKey: Hashable {
        let kind: RecordKind
        let field: String
        let value: String
    }

    private static func keys(for record: Record) -> [MatchKey] {
        let fields: [String]
        switch record.kind {
        case .employment: fields = ["employer"]
        case .contact: fields = ["email", "phone", "name"]
        case .address: fields = ["line1"]
        case .education: fields = ["institution"]
        case .custom: fields = []
        }
        let stored = fields.compactMap { field -> MatchKey? in
            guard let value = record.fields[field]?.scalarText, !normalize(value).isEmpty else { return nil }
            return MatchKey(kind: record.kind, field: field, value: normalize(value))
        }
        return stored + [
            MatchKey(kind: record.kind, field: "#id", value: record.id),
            MatchKey(kind: record.kind, field: "#label", value: normalize(record.label)),
        ]
    }

    private static func match(_ incoming: Record, _ existing: Record) -> Int {
        if incoming.id == existing.id { return 100 }
        func same(_ key: String) -> Bool {
            guard let a = incoming.fields[key]?.scalarText, let b = existing.fields[key]?.scalarText else { return false }
            let normalized = normalize(a)
            return !normalized.isEmpty && normalized == normalize(b)
        }
        let sameLabel = normalize(incoming.label) == normalize(existing.label)
        switch incoming.kind {
        case .employment:
            guard same("employer") else { return sameLabel ? 10 : 0 }
            let a = incoming.fields["startDate"]?.string ?? ""
            let b = existing.fields["startDate"]?.string ?? ""
            let relatedDates = !a.isEmpty && !b.isEmpty
                && (a == b || a.hasPrefix(b + "-") || b.hasPrefix(a + "-"))
            return 20 + (same("title") ? 15 : 0) + (relatedDates ? 10 : 0)
        case .contact:
            if same("email") || same("phone") { return 40 }
            if same("name") { return 20 }
        case .address:
            if same("line1"), same("postalCode") || same("city") { return 25 }
        case .education:
            if same("institution"), same("qualification") { return 25 }
        case .custom:
            break
        }
        return sameLabel ? 10 : 0
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
