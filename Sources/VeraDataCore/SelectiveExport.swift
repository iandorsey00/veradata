import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case structured, veraFlowResume, flatRecord

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .structured: return VeraText.text("Structured JSON")
        case .veraFlowResume: return VeraText.text("VeraFlow résumé")
        case .flatRecord: return VeraText.text("Single-record JSON")
        }
    }

    public var filename: String {
        switch self {
        case .structured: return "VeraData-selection.json"
        case .veraFlowResume: return "VeraFlow-resume.json"
        case .flatRecord: return "VeraData-fields.json"
        }
    }

    public func includes(_ key: String, in record: Record) -> Bool {
        guard let value = record.fields[key] else { return false }
        switch self {
        case .structured: return true
        case .flatRecord: return value.isScalar
        case .veraFlowResume:
            guard Self.resumeFields[record.kind, default: []].contains(key) else { return false }
            if let text = value.string { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return ["responsibilities", "achievements"].contains(key)
                && value.array?.contains(where: { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) == true
        }
    }

    private static let resumeFields: [RecordKind: Set<String>] = [
        .contact: ["name", "givenName", "familyName", "email", "phone", "summary"],
        .employment: ["employer", "title", "startDate", "endDate", "location", "responsibilities", "achievements"],
        .education: ["institution", "qualification", "fieldOfStudy", "startDate", "endDate", "location"],
    ]
}

public enum ExportFieldSelection: Equatable, Sendable {
    case whole
    case items(Set<Int>)
}

public struct ExportRecordSelection: Equatable, Identifiable, Sendable {
    public let id: Record.ID
    public var fields: [String: ExportFieldSelection]

    public init(id: Record.ID, fields: [String: ExportFieldSelection]) {
        self.id = id
        self.fields = fields
    }
}

public enum SelectiveExport {
    public static func data(from profile: Profile, selection: [ExportRecordSelection], format: ExportFormat) throws -> Data {
        let records = try project(profile: profile, selection: selection, format: format)
        let value: JSONValue
        switch format {
        case .structured:
            value = .object([
                "format": .string("veradata-selection"),
                "version": .number(try JSONNumber("1")),
                "records": .array(records.map { .object(["kind": .string($0.kind.rawValue), "fields": .object($0.fields)]) }),
            ])
        case .flatRecord:
            guard records.count == 1, let record = records.first else {
                throw DataIssue("Choose fields from one record for single-record JSON.")
            }
            value = .object(record.fields)
        case .veraFlowResume:
            value = try ResumeProjection.value(from: records)
        }
        let data = try value.data()
        if format == .veraFlowResume, data.count > 1024 * 1024 {
            throw DataIssue("VeraFlow résumé data must be 1 MiB or smaller.")
        }
        return data
    }

    private static func project(
        profile: Profile, selection: [ExportRecordSelection], format: ExportFormat
    ) throws -> [ProjectedRecord] {
        guard !selection.isEmpty, Set(selection.map(\.id)).count == selection.count else {
            throw DataIssue("Choose at least one record. Select each record only once.")
        }
        return try selection.map { chosen in
            guard let record = profile.records.first(where: { $0.id == chosen.id }), !chosen.fields.isEmpty else {
                throw DataIssue("A selected record is missing or has no fields selected.")
            }
            var fields: [String: JSONValue] = [:]
            for (key, selected) in chosen.fields {
                guard format.includes(key, in: record), let value = record.fields[key] else {
                    throw DataIssue("A selected field is missing or unavailable in this format.")
                }
                switch selected {
                case .whole:
                    fields[key] = value
                case .items(let indices):
                    guard let list = value.array, !indices.isEmpty, indices.allSatisfy(list.indices.contains) else {
                        throw DataIssue("A selected list item is no longer available.")
                    }
                    fields[key] = .array(indices.sorted().map { list[$0] })
                }
            }
            return ProjectedRecord(kind: record.kind, fields: fields)
        }
    }
}

private struct ProjectedRecord {
    let kind: RecordKind
    let fields: [String: JSONValue]

    func text(_ key: String) -> String? {
        guard let value = fields[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ResumeProjection {
    static func value(from records: [ProjectedRecord]) throws -> JSONValue {
        let contacts = records.filter { $0.kind == .contact }
        guard contacts.count <= 1 else { throw DataIssue("Choose fields from only one contact record for a résumé.") }
        var result: [String: JSONValue] = [:]
        if let contact = contacts.first {
            let fallback = [contact.text("givenName"), contact.text("familyName")].compactMap { $0 }.joined(separator: " ")
            if let name = contact.text("name") ?? nonempty(fallback) { result["name"] = .string(inline(name)) }
            for key in ["email", "phone", "summary"] {
                if let value = contact.text(key) { result[key] = .string(inline(value)) }
            }
        }
        for (kind, key) in [(RecordKind.employment, "experience_markdown"), (.education, "education_markdown")] {
            let blocks = records.filter { $0.kind == kind }.compactMap(block)
            if !blocks.isEmpty { result[key] = .string(blocks.joined(separator: "\n\n")) }
        }
        guard !result.isEmpty else { throw DataIssue("Select at least one nonempty résumé field.") }
        guard !result.values.contains(where: { $0.string?.contains("\0") == true }) else {
            throw DataIssue("Remove null characters from your résumé fields before exporting.")
        }
        return .object(result)
    }

    static func block(_ record: ProjectedRecord) -> String? {
        let isJob = record.kind == .employment
        let titleKeys = isJob ? ["title", "employer"] : ["qualification", "institution"]
        let title = titleKeys.compactMap(record.text).map(inline).joined(separator: " · ")
        let locations = (isJob ? ["location"] : ["fieldOfStudy", "location"]).compactMap(record.text).map(inline)
        let dates = ["startDate", "endDate"].compactMap(record.text).map(inline).joined(separator: " – ")
        let details = (locations + [dates]).filter { !$0.isEmpty }.joined(separator: " · ")
        let bullets = ["responsibilities", "achievements"].flatMap { key in
            (record.fields[key]?.array ?? []).compactMap(\.string).compactMap { nonempty(inline($0)) }.map { "- " + $0 }
        }
        let header = [title.isEmpty ? nil : "### " + title, nonempty(details)].compactMap { $0 }.joined(separator: "\n")
        return nonempty([header, bullets.joined(separator: "\n")].filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    static func nonempty(_ text: String) -> String? { text.isEmpty ? nil : text }

    static func inline(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let punctuation: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "&", "#", "|", "~", "!"]
        let escaped = line.map { punctuation.contains($0) ? "\\" + String($0) : String($0) }.joined()
        if escaped.hasPrefix("+ ") || escaped.hasPrefix("- ") || escaped.hasPrefix("---") || escaped.hasPrefix("===") {
            return "\\" + escaped
        }
        if let number = escaped.prefixMatch(of: #/[0-9]{1,9}(?=[.)](?: |$))/#) {
            return String(number.output) + "\\" + escaped.dropFirst(number.output.count)
        }
        return escaped
    }
}
