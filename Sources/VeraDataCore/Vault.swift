import Foundation

public enum RecordKind: String, CaseIterable, Identifiable, Sendable {
    case contact, address, employment, education, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .contact: return "Contact"
        case .address: return "Address"
        case .employment: return "Employment"
        case .education: return "Education"
        case .custom: return "Custom record"
        }
    }

    public var localizedTitle: String { VeraText.text(title) }

    public var section: String {
        switch self {
        case .contact: return "Contacts"
        case .address: return "Addresses"
        case .employment: return "Employment"
        case .education: return "Education"
        case .custom: return "Other records"
        }
    }

    public var fields: [FieldDefinition] {
        switch self {
        case .contact:
            return [
                .init("name", "Full name", aliases: ["legal name", "姓名"]),
                .init("givenName", "First name", aliases: ["given name", "名字"]),
                .init("familyName", "Last name", aliases: ["family name", "surname", "姓"]),
                .init("email", "Email address", aliases: ["mail", "电子邮件", "邮箱"]),
                .init("phone", "Phone number", style: .phone, aliases: ["telephone", "mobile", "cell", "电话", "手机号"]),
            ]
        case .address:
            return [
                .init("use", "Address use", style: .choice(["Residential", "Mailing", "Billing", "Shipping", "Other"])),
                .init("line1", "Street address", aliases: ["address line 1", "street", "地址"]),
                .init("line2", "Unit or apartment", aliases: ["address line 2", "suite", "apt"]),
                .init("city", "City", aliases: ["locality", "城市"]),
                .init("region", "State or region", aliases: ["province", "state", "省"]),
                .init("postalCode", "Postal code", aliases: ["zip code", "postcode", "邮编"]),
                .init("country", "Country", aliases: ["国家"]),
                .init("formatted", "Mailing lines", style: .multiline, aliases: ["full address"]),
                .init("startDate", "From", style: .date),
                .init("endDate", "Through", style: .date),
            ]
        case .employment:
            return [
                .init("employer", "Employer name", aliases: ["company", "organization", "雇主", "公司"]),
                .init("legalName", "Legal organization name"),
                .init("title", "Job title", aliases: ["occupation", "position", "role", "职位"]),
                .init("startDate", "Start date", style: .date, aliases: ["from", "started", "入职日期"]),
                .init("endDate", "End date", style: .date, aliases: ["to", "ended", "离职日期"]),
                .init("location", "Work location", aliases: ["work address", "工作地点"]),
                .init("employerAddress", "Employer address", style: .multiline),
                .init("employmentType", "Employment type"),
                .init("responsibilities", "Responsibilities", style: .list, aliases: ["job duties", "description", "职责"]),
                .init("achievements", "Accomplishments", style: .list),
                .init("supervisor", "Supervisor"),
                .init("reasonForLeaving", "Reason for leaving", style: .multiline),
                .init("verificationContact", "Verification contact"),
            ]
        case .education:
            return [
                .init("institution", "Institution", aliases: ["school", "university", "学校"]),
                .init("qualification", "Qualification", aliases: ["degree", "学历"]),
                .init("fieldOfStudy", "Field of study", aliases: ["major", "专业"]),
                .init("startDate", "Start date", style: .date),
                .init("endDate", "End date", style: .date, aliases: ["graduated"]),
                .init("location", "Location"),
            ]
        case .custom:
            return []
        }
    }
}

public struct FieldDefinition: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case text, phone, date, multiline, list, choice([String]) }
    public let key: String
    public let label: String
    public let style: Style
    public let aliases: [String]
    public let localizesLabel: Bool
    public var localizedLabel: String { localizesLabel ? VeraText.text(label) : label }

    public init(_ key: String, _ label: String, style: Style = .text, aliases: [String] = [], localizesLabel: Bool = true) {
        self.key = key
        self.label = label
        self.style = style
        self.aliases = aliases
        self.localizesLabel = localizesLabel
    }
}

public struct Record: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: RecordKind
    public var label: String
    public var fields: [String: JSONValue]
    public var aliases: [String: String]

    public init(id: String = UUID().uuidString.lowercased(), kind: RecordKind, label: String,
                fields: [String: JSONValue] = [:], aliases: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.label = label
        self.fields = fields
        self.aliases = aliases
    }

    public var orderedKeys: [String] {
        let known = kind.fields.map(\.key)
        return known.filter { fields[$0] != nil } + fields.keys.filter { !known.contains($0) }.sorted()
    }

    public static func canonicalEmploymentEndDate(_ text: String) -> String {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.caseInsensitiveCompare("Present") == .orderedSame || candidate == "至今" ? "Present" : text
    }

    public func fieldDefinition(_ key: String) -> FieldDefinition {
        kind.fields.first { $0.key == key } ?? FieldDefinition(key, key, localizesLabel: false)
    }

    public var subtitle: String {
        let parts: [String]
        switch kind {
        case .employment, .education:
            let name = fields[kind == .employment ? "title" : "qualification"]?.string ?? ""
            let start = fields["startDate"]?.string ?? ""
            let end = fields["endDate"]?.string ?? ""
            let displayEnd = kind == .employment && end == "Present" ? VeraText.text("Present") : end
            let period = [start, displayEnd].filter { !$0.isEmpty }.joined(separator: " – ")
            parts = [name, period]
        case .address:
            parts = [fields["use"]?.string.map { VeraText.text($0) } ?? "", VeraText.text(addressStatus)]
        case .contact, .custom:
            parts = [kind.localizedTitle]
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public var addressStatus: String {
        guard kind == .address else { return "" }
        if case .null? = fields["endDate"] { return "End date unknown" }
        return fields["endDate"]?.string?.isEmpty == false ? "Historical" : "Open-ended"
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "kind": .string(kind.rawValue), "label": .string(label),
            "fields": .object(fields),
        ]
        if !aliases.isEmpty { object["aliases"] = .object(aliases.mapValues(JSONValue.string)) }
        return .object(object)
    }

    public func validate() throws {
        try validateID(id, at: "Record ID")
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DataIssue("Enter a record name.")
        }
        guard fields.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DataIssue("Field names cannot be empty.")
        }
        for field in kind.fields {
            guard let value = fields[field.key], value != .null else { continue }
            if case .list = field.style {
                guard let items = value.array, items.allSatisfy({ $0.string != nil }) else {
                    throw DataIssue(VeraText.format("%@ must be a list of text items.", field.localizedLabel))
                }
                continue
            }
            guard let string = value.string else { throw DataIssue(VeraText.format("%@ must be text.", field.localizedLabel)) }
            if field.style == .date, !string.isEmpty, PartialDate(string) == nil {
                if kind == .employment, field.key == "endDate" {
                    if string == "Present" { continue }
                    throw DataIssue("Enter a valid employment end date or Present.")
                }
                throw DataIssue(VeraText.format("%@ must be a valid YYYY, YYYY-MM or YYYY-MM-DD date.", field.localizedLabel))
            }
            if case let .choice(options) = field.style, !string.isEmpty, !options.contains(string) {
                throw DataIssue(VeraText.format("Choose a supported value for %@.", field.localizedLabel))
            }
        }
        for (alias, field) in aliases {
            guard alias.wholeMatch(of: #/;[^\s;]+/#) != nil, fields[field] != nil else {
                throw DataIssue("Each shortcut must start with a semicolon, contain no spaces and point to a stored field.")
            }
        }
    }
}

public struct Profile: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var records: [Record]

    public init(id: String = UUID().uuidString.lowercased(), name: String, records: [Record] = []) {
        self.id = id
        self.name = name
        self.records = records
    }
}

public enum SearchShortcut: String, CaseIterable, Identifiable, Sendable {
    case space, j, k, off
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .space: return "⌃⌥ Space"
        case .j: return "⌃⌥ J"
        case .k: return "⌃⌥ K"
        case .off: return "Off"
        }
    }
}

public struct Vault: Equatable, Sendable {
    public static let version = 1
    public var profiles: [Profile]
    public var shortcut: SearchShortcut

    public init(profiles: [Profile] = [Profile(name: "Personal")], shortcut: SearchShortcut = .space) {
        self.profiles = profiles
        self.shortcut = shortcut
    }

    public func validated() throws -> Vault {
        guard !profiles.isEmpty else { throw DataIssue("A vault must contain at least one profile.") }
        var profileIDs: Set<String> = []
        for profile in profiles {
            try validateID(profile.id, at: "Profile ID")
            guard profileIDs.insert(profile.id).inserted else { throw DataIssue("Profile IDs must be unique.") }
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DataIssue("Profile names cannot be empty.")
            }
            var recordIDs: Set<String> = []
            for record in profile.records {
                guard recordIDs.insert(record.id).inserted else {
                    throw DataIssue("Record IDs must be unique within each profile.")
                }
                do { try record.validate() } catch let error as DataIssue {
                    throw DataIssue(VeraText.format("Profile %@, record %@: %@", profile.id, record.id, error.localizedDescription))
                }
            }
        }
        return self
    }

    public init(data: Data) throws {
        let root = try JSONValue.parse(data)
        let envelope = try requireObject(root, at: "Vault", keys: ["version", "profiles", "settings"])
        guard let version = envelope["version"], case .number(let number) = version else {
            throw DataIssue("Missing numeric VeraData schema version.")
        }
        guard number.raw == String(Self.version) else {
            throw DataIssue("Unsupported VeraData schema version. Open this backup with a compatible version of VeraData.")
        }
        let settings = try requireObject(envelope["settings"], at: "Settings", keys: ["searchShortcut"])
        guard let key = settings["searchShortcut"]?.string, let shortcut = SearchShortcut(rawValue: key) else {
            throw DataIssue("Invalid global search shortcut.")
        }
        guard let profiles = envelope["profiles"]?.array else { throw DataIssue("Profiles must be a list.") }
        self.shortcut = shortcut
        self.profiles = try Self.decodeProfiles(profiles)
        _ = try validated()
    }

    static func decodeProfiles(_ profiles: [JSONValue]) throws -> [Profile] {
        try profiles.enumerated().map { index, value in
            let path = VeraText.format("Profile %lld", index + 1)
            let object = try requireObject(value, at: path, keys: ["id", "name", "records"])
            guard let id = object["id"]?.string, let name = object["name"]?.string,
                  let records = object["records"]?.array else {
                throw DataIssue(VeraText.format("%@ needs a text ID, name and list of records.", path))
            }
            return Profile(id: id, name: name, records: try records.enumerated().map { position, item in
                try Self.decodeRecord(item, at: VeraText.format("%@, record %lld", path, position + 1))
            })
        }
    }

    static func decodeRecord(_ value: JSONValue, at path: String) throws -> Record {
        let object = try requireObject(value, at: path, keys: ["id", "kind", "label", "fields", "aliases"])
        guard let id = object["id"]?.string, let label = object["label"]?.string,
              let type = object["kind"]?.string, let kind = RecordKind(rawValue: type),
              let fields = object["fields"]?.object else {
            throw DataIssue(VeraText.format("%@ needs an ID, supported kind, label and fields object.", path))
        }
        let aliases = try requireObject(object["aliases"] ?? .object([:]), at: "\(path) shortcuts")
        guard aliases.values.allSatisfy({ $0.string != nil }) else {
            throw DataIssue(VeraText.format("%@ shortcuts must point to text field keys.", path))
        }
        return Record(id: id, kind: kind, label: label, fields: fields, aliases: aliases.compactMapValues(\.string))
    }

    public func data() throws -> Data {
        _ = try validated()
        return try JSONValue.object([
            "version": .number(JSONNumber(String(Self.version))),
            "settings": .object(["searchShortcut": .string(shortcut.rawValue)]),
            "profiles": Self.encodeProfiles(profiles),
        ]).data()
    }

    static func encodeProfiles(_ profiles: [Profile]) -> JSONValue {
        .array(profiles.map { profile in
            .object([
                "id": .string(profile.id), "name": .string(profile.name),
                "records": .array(profile.records.map(\.json)),
            ])
        })
    }
}

private func requireObject(
    _ value: JSONValue?, at path: String, keys: Set<String>? = nil
) throws -> [String: JSONValue] {
    guard let object = value?.object else { throw DataIssue(VeraText.format("%@ must be a JSON object.", path)) }
    if let keys, !Set(object.keys).isSubset(of: keys) {
        throw DataIssue(VeraText.format("%@ contains unsupported properties. Put custom properties inside fields.", path))
    }
    return object
}

private func validateID(_ value: String, at path: String) throws {
    guard value.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9_-]{0,127}/#) != nil else {
        throw DataIssue(VeraText.format("%@ must contain 1–128 ASCII letters, digits, underscores or hyphens and start with a letter or digit.", path))
    }
}

public struct PartialDate: Equatable, Sendable {
    public let year: String
    public let month: String?
    public let day: String?

    public init?(_ raw: String) {
        guard raw.wholeMatch(of: #/[0-9]{4}(?:-[0-9]{2}(?:-[0-9]{2})?)?/#) != nil else { return nil }
        let pieces = raw.split(separator: "-").map(String.init)
        guard let yearNumber = Int(pieces[0]), yearNumber > 0 else { return nil }
        year = pieces[0]
        month = pieces.count > 1 ? pieces[1] : nil
        day = pieces.count > 2 ? pieces[2] : nil
        if let month, let m = Int(month) {
            guard (1...12).contains(m) else { return nil }
            if let day, let d = Int(day) {
                let leap = yearNumber % 400 == 0 || (yearNumber % 4 == 0 && yearNumber % 100 != 0)
                let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
                guard (1...lengths[m - 1]).contains(d) else { return nil }
            }
        }
    }

    public var yearMonth: String? { month.map { year + "-" + $0 } }
}
