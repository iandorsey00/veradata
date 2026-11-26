import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case structured, veraFlowResume, flatRecord

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .structured: return VeraText.text("Structured JSON")
        case .veraFlowResume: return VeraText.text("Résumé data (JSON)")
        case .flatRecord: return VeraText.text("Single-record JSON")
        }
    }

    public var filename: String {
        switch self {
        case .structured: return "VeraData-selection.json"
        case .veraFlowResume: return "resume-data.json"
        case .flatRecord: return "VeraData-fields.json"
        }
    }

    public func includes(_ key: String, in record: Record) -> Bool {
        guard let value = record.fields[key] else { return false }
        switch self {
        case .structured: return true
        case .flatRecord: return value.isScalar
        case .veraFlowResume:
            guard record.kind == .custom || Self.resumeFields[record.kind, default: []].contains(key) else { return false }
            if let text = value.string { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return (record.kind == .custom || ["responsibilities", "achievements"].contains(key))
                && value.array?.contains(where: { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) == true
        }
    }

    private static let resumeFields: [RecordKind: Set<String>] = [
        .contact: ["name", "givenName", "familyName", "email", "phone", "summary", "headline", "website", "portfolio", "linkedin", "github", "GitHub"],
        .employment: ["employer", "title", "startDate", "endDate", "location", "responsibilities", "achievements"],
        .education: ["institution", "qualification", "fieldOfStudy", "startDate", "endDate", "location"],
    ]
}

public enum ExportFieldSelection: Equatable, Sendable {
    case whole
    case items(Set<Int>)
}

public enum ResumeSection: String, CaseIterable, Identifiable, Sendable {
    case skills, projects, languages, certifications

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .skills: return VeraText.text("Skills")
        case .projects: return VeraText.text("Selected Projects")
        case .languages: return VeraText.text("Languages")
        case .certifications: return VeraText.text("Certifications")
        }
    }

    private var recommendedKeys: Set<String> {
        switch self {
        case .skills: return ["skills", "technical skills", "office tools", "support and automation", "systems support",
                              "programming and web", "business and creative tools", "ai-assisted tools"]
        case .projects: return ["title", "type", "description", "details", "source", "live application", "website", "repository", "demo"]
        case .languages: return ["languages", "language", "proficiency"]
        case .certifications: return ["credential", "certification", "issuer", "year"]
        }
    }

    static func recommended(for record: Record) -> ResumeSection? {
        guard record.kind == .custom else { return nil }
        let keys = Set(record.fields.keys.map { $0.lowercased() })
        let label = record.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if keys.contains("credential") || keys.contains("certification") { return .certifications }
        if keys.contains("languages") || keys.contains("language") { return .languages }
        if record.fields.contains(where: {
            $0.key.lowercased() == "type" && $0.value.string?.lowercased().hasSuffix(" project") == true
        }) { return .projects }
        if keys.contains("skills") || ["skills", "core skills", "relevant skills", "技能", "核心技能", "相关技能"].contains(label) {
            return .skills
        }
        return nil
    }

    fileprivate func recommends(_ key: String) -> Bool { recommendedKeys.contains(key.lowercased()) }
}

public enum ResumeSelectionScope: Sendable {
    case standard, recommended, all
}

public struct ExportRecordSelection: Equatable, Identifiable, Sendable {
    public let id: Record.ID
    public var fields: [String: ExportFieldSelection]
    public var resumeSection: ResumeSection?

    public init(id: Record.ID, fields: [String: ExportFieldSelection], resumeSection: ResumeSection? = nil) {
        self.id = id
        self.fields = fields
        self.resumeSection = resumeSection
    }
}

public enum SelectiveExport {
    public static func allFields(in record: Record, format: ExportFormat) -> [String: ExportFieldSelection] {
        Dictionary(uniqueKeysWithValues: record.fields.keys
            .filter { format.includes($0, in: record) }
            .map { ($0, .whole) })
    }

    public static func standardResumeSelection(in profile: Profile, contactID: Record.ID?) -> [ExportRecordSelection] {
        resumeSelection(in: profile, contactID: contactID, scope: .standard)
    }

    public static func resumeSelection(
        in profile: Profile, contactID: Record.ID?, scope: ResumeSelectionScope
    ) -> [ExportRecordSelection] {
        profile.records.compactMap { record in
            var section: ResumeSection?
            switch record.kind {
            case .employment, .education: break
            case .contact where record.id == contactID: break
            case .custom where scope != .standard:
                section = ResumeSection.recommended(for: record)
                if scope == .recommended, section == nil { return nil }
            default: return nil
            }
            let fields = allFields(in: record, format: .veraFlowResume).filter { key, _ in
                scope != .recommended || section?.recommends(key) != false
            }
            return fields.isEmpty ? nil : ExportRecordSelection(id: record.id, fields: fields, resumeSection: section)
        }
    }

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
            return ProjectedRecord(kind: record.kind, fields: fields, resumeSection: chosen.resumeSection)
        }
    }
}

private struct ProjectedRecord {
    let kind: RecordKind
    let fields: [String: JSONValue]
    let resumeSection: ResumeSection?

    func text(_ key: String) -> String? {
        guard let value = fields[key]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func key(named name: String) -> String? {
        fields.keys.sorted().first { $0.lowercased() == name }
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
            for key in ["email", "phone", "summary", "headline"] {
                if let value = contact.text(key) { result[key] = .string(inline(value)) }
            }
            let links = try ["website", "portfolio", "linkedin", "github"].compactMap { key -> String? in
                guard let field = contact.key(named: key), let text = contact.text(field) else { return nil }
                guard let link = visibleLink(text) else {
                    throw DataIssue("Résumé links need a complete HTTP or HTTPS address.")
                }
                return link
            }
            if !links.isEmpty { result["links_markdown"] = .string(links.joined(separator: " · ")) }
        }
        for (kind, key) in [(RecordKind.employment, "experience_markdown"), (.education, "education_markdown")] {
            let blocks = records.filter { $0.kind == kind }.compactMap(block)
            if !blocks.isEmpty { result[key] = .string(blocks.joined(separator: "\n\n")) }
        }
        let custom = records.filter { $0.kind == .custom }
        guard custom.allSatisfy({ $0.resumeSection != nil }) else {
            throw DataIssue("Choose a résumé section for each selected custom record.")
        }
        let skills = sectionBody(.skills, records: custom)
        // Existing VeraFlow forms can render these subsections through their Skills field.
        let extraSkills = [ResumeSection.languages, .certifications].compactMap { section in
            sectionBody(section, records: custom).map { "### \(section.title)\n\n\($0)" }
        }
        if let body = nonempty(([skills].compactMap { $0 } + extraSkills).joined(separator: "\n\n")) {
            result["skills_markdown"] = .string(body)
        }
        if let body = sectionBody(.projects, records: custom) { result["projects_markdown"] = .string(body) }
        guard !result.isEmpty else { throw DataIssue("Select at least one nonempty résumé field.") }
        guard !result.values.contains(where: { $0.string?.contains("\0") == true }) else {
            throw DataIssue("Remove null characters from your résumé fields before exporting.")
        }
        return .object(result)
    }

    static func sectionBody(_ section: ResumeSection, records: [ProjectedRecord]) -> String? {
        nonempty(records.filter { $0.resumeSection == section }
            .compactMap { customBlock($0, section: section) }.joined(separator: "\n\n"))
    }

    static func customBlock(_ record: ProjectedRecord, section: ResumeSection) -> String? {
        var lines: [String] = []
        var presented: Set<String> = []
        if section == .projects {
            if let key = record.key(named: "title"), let title = record.text(key) {
                lines.append("### " + inline(title))
                presented.insert(key)
            }
            if let key = record.key(named: "type"), let type = record.text(key) {
                lines.append(inline(type))
                presented.insert(key)
            }
            let links = ["source", "live application", "website", "repository", "demo"].compactMap { name -> String? in
                guard let key = record.key(named: name), let text = record.text(key),
                      let rendered = visibleLink(text) else { return nil }
                presented.insert(key)
                return rendered
            }
            if !links.isEmpty { lines.append(links.joined(separator: " · ")) }
        }
        let credential = record.key(named: "credential") ?? record.key(named: "certification")
        if section == .certifications, let key = credential, record.text(key) != nil {
            let details = [key, record.key(named: "issuer"), record.key(named: "year")].compactMap { $0 }
            let values = details.compactMap(record.text).map(inline)
            lines.append("- " + values.joined(separator: " · "))
            presented.formUnion(details)
        }
        // A record's display name never enters the export.
        let bullets = record.fields.keys.sorted().filter { !presented.contains($0) }.flatMap { key -> [String] in
            guard let value = record.fields[key] else { return [] }
            let texts = value.string.map { [$0] } ?? (value.array ?? []).compactMap(\.string)
            return texts.compactMap { nonempty(inline($0)) }.map { "- " + $0 }
        }
        if !bullets.isEmpty { lines.append(bullets.joined(separator: "\n")) }
        return nonempty(lines.joined(separator: "\n\n"))
    }

    static func visibleLink(_ text: String) -> String? {
        guard !text.contains(where: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\\" }),
              let url = URLComponents(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return "<\(text)>"
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
