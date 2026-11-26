import CryptoKit
import Foundation

/// Stores selections and fingerprints, with no copies of field values.
public struct ExportPreset: Codable, Sendable {
    public let name: String
    public let profileID: Profile.ID
    private let version: Int
    private let formatID: String
    private var records: [SavedRecord]

    private struct SavedRecord: Codable, Equatable, Sendable {
        let id: Record.ID
        let fields: [String: SavedField]
        let section: String?
    }

    private struct SavedField: Codable, Equatable, Sendable {
        let items: [Int]?
        let fingerprint: String?
    }

    public init(name: String, profile: Profile, selection: [ExportRecordSelection], format: ExportFormat) throws {
        _ = try SelectiveExport.data(from: profile, selection: selection, format: format)
        self.name = try Self.normalizedName(name)
        profileID = profile.id
        version = 2
        formatID = format.rawValue
        let profileRecords = Dictionary(uniqueKeysWithValues: profile.records.map { ($0.id, $0) })
        records = try selection.map { record in
            guard let source = profileRecords[record.id] else { throw Self.stale }
            let fields = try record.fields.mapValuesWithKeys { key, choice in
                guard let value = source.fields[key] else { throw Self.stale }
                let items: [Int]?
                switch choice {
                case .whole: items = nil
                case .items(let indices): items = indices.sorted()
                }
                return SavedField(items: items, fingerprint: try items.flatMap { _ in try Self.digest(value) })
            }
            return SavedRecord(id: record.id, fields: fields, section: record.resumeSection?.rawValue)
        }
    }

    public func selection(in profile: Profile) throws -> (format: ExportFormat, records: [ExportRecordSelection]) {
        guard profile.id == profileID else { throw DataIssue("The export preset belongs to a different profile.") }
        let saved = try definition()
        let profileRecords = Dictionary(uniqueKeysWithValues: profile.records.map { ($0.id, $0) })
        for record in records {
            guard let source = profileRecords[record.id] else { throw Self.stale }
            for (key, field) in record.fields {
                guard let current = source.fields[key], saved.format.permitsStoredSelection(key, in: source) else { throw Self.stale }
                if let items = field.items {
                    guard let count = current.array?.count, !items.isEmpty,
                          items.allSatisfy({ $0 >= 0 && $0 < count }),
                          try Self.digest(current) == field.fingerprint else { throw Self.stale }
                }
            }
        }
        return saved
    }

    /// Read the recorded choices even when they need to be reviewed against newer vault data.
    public func definition() throws -> (format: ExportFormat, records: [ExportRecordSelection]) {
        guard (1...2).contains(version), let format = ExportFormat(rawValue: formatID) else {
            throw DataIssue("This export preset format is not supported.")
        }
        let selection = try records.map { record in
            let section = record.section.flatMap(ResumeSection.init(rawValue:))
            guard record.section == nil || section != nil else { throw Self.stale }
            let fields = record.fields.mapValues { field in
                field.items.map { ExportFieldSelection.items(Set($0)) } ?? .whole
            }
            return ExportRecordSelection(id: record.id, fields: fields, resumeSection: section)
        }
        return (format, selection)
    }

    public func data(from vault: Vault, as format: ExportFormat? = nil) throws -> Data {
        guard let profile = vault.profiles.first(where: { $0.id == profileID }) else { throw Self.stale }
        let selected = try selection(in: profile)
        return try SelectiveExport.data(from: profile, selection: selected.records, format: format ?? selected.format)
    }

    public func replacingSelection(_ selection: [ExportRecordSelection], in profile: Profile,
                                  refreshedFields: [Record.ID: Set<String>]) throws -> ExportPreset {
        guard profile.id == profileID else { throw Self.stale }
        let old = try definition()
        if old.records == selection && refreshedFields.isEmpty { return self }
        var updated = try ExportPreset(name: name, profile: profile, selection: selection, format: old.format)
        let fingerprints = Dictionary(records.map { ($0.id, $0.fields) }, uniquingKeysWith: { old, _ in old })
        updated.records = updated.records.map { record in
            let fields = record.fields.reduce(into: record.fields) { output, entry in
                guard entry.value.items != nil, refreshedFields[record.id]?.contains(entry.key) != true,
                      let oldField = fingerprints[record.id]?[entry.key], oldField.items == entry.value.items else { return }
                output[entry.key] = oldField
            }
            return SavedRecord(id: record.id, fields: fields, section: record.section)
        }
        if old.records == selection, updated.records.elementsEqual(records, by: { new, old in
            new.fields.allSatisfy { key, field in field.items == nil || old.fields[key] == field }
        }) { return self }
        return updated
    }

    public static func normalizedName(_ name: String) throws -> String {
        try validateName(name)
        return name.lowercased()
    }

    public static func validateName(_ name: String) throws {
        guard name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9_-]{0,63}/#) != nil else {
            throw DataIssue("Use up to 64 English letters, digits, hyphens or underscores. Start with a letter or digit.")
        }
    }

    private static let stale = DataIssue("A preset field, record, list or object has changed. Review the selection and save the preset again.")

    private static func digest(_ value: JSONValue) throws -> String? {
        guard !value.isScalar else { return nil }
        let data = try value.data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ExportPresetStore: Sendable {
    private let vaultURL: URL

    public init(vaultURL: URL) { self.vaultURL = vaultURL }

    public func load(_ name: String) throws -> ExportPreset {
        try VaultStateStore(vaultURL: vaultURL).snapshot().preset(name)
    }

    public func names(for profileID: Profile.ID? = nil) throws -> [String] {
        let state = try VaultStateStore(vaultURL: vaultURL).snapshot()
        return state.presets.keys.sorted().filter {
            guard let preset = try? state.preset($0) else { return false }
            return profileID == nil || profileID == preset.profileID
        }
    }

    @discardableResult
    public func save(_ preset: ExportPreset, replace: Bool = false, expected: String? = nil) throws -> String {
        var token = ""
        try VaultStateStore(vaultURL: vaultURL).commit(expected: expected, summary: "Save export preset") { state in
            if state.presets[preset.name] != nil {
                guard replace, try state.preset(preset.name).profileID == preset.profileID else {
                    throw DataIssue("That export preset name is already in use.")
                }
            }
            try state.setPreset(preset)
            token = state.token
        }
        return token
    }

    public func delete(_ name: String) throws {
        let name = try ExportPreset.normalizedName(name)
        try VaultStateStore(vaultURL: vaultURL).commit(summary: "Delete export preset") { state in
            guard state.presets.removeValue(forKey: name) != nil else { throw DataIssue("Export preset not found.") }
        }
    }

    public func snapshot() throws -> VaultState { try VaultStateStore(vaultURL: vaultURL).snapshot() }
}

private extension Dictionary {
    func mapValuesWithKeys<T>(_ transform: (Key, Value) throws -> T) rethrows -> [Key: T] {
        try Dictionary<Key, T>(uniqueKeysWithValues: map { (try ($0.key, transform($0.key, $0.value))) })
    }
}
