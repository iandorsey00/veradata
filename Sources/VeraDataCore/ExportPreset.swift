import CryptoKit
import Foundation
import Darwin

/// Stores selections and fingerprints, with no copies of field values.
public struct ExportPreset: Codable, Sendable {
    public let name: String
    public let profileID: Profile.ID
    private let version: Int
    private let formatID: String
    private let records: [SavedRecord]

    private struct SavedRecord: Codable, Sendable {
        let id: Record.ID
        let fields: [String: SavedField]
        let section: String?
    }

    private struct SavedField: Codable, Sendable {
        let items: [Int]?
        let fingerprint: String?
    }

    public init(name: String, profile: Profile, selection: [ExportRecordSelection], format: ExportFormat) throws {
        try Self.validateName(name)
        _ = try SelectiveExport.data(from: profile, selection: selection, format: format)
        self.name = name
        profileID = profile.id
        version = 1
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
                return SavedField(items: items, fingerprint: try Self.digest(value))
            }
            return SavedRecord(id: record.id, fields: fields, section: record.resumeSection?.rawValue)
        }
    }

    public func selection(in profile: Profile) throws -> (format: ExportFormat, records: [ExportRecordSelection]) {
        guard profile.id == profileID else { throw DataIssue("The export preset belongs to a different profile.") }
        guard version == 1, let format = ExportFormat(rawValue: formatID) else {
            throw DataIssue("This export preset format is not supported.")
        }
        let profileRecords = Dictionary(uniqueKeysWithValues: profile.records.map { ($0.id, $0) })
        let selection = try records.map { record in
            guard let source = profileRecords[record.id] else { throw Self.stale }
            let fields = try record.fields.mapValuesWithKeys { key, saved -> ExportFieldSelection in
                guard let current = source.fields[key], format.includes(key, in: source),
                      try Self.digest(current) == saved.fingerprint else { throw Self.stale }
                return saved.items.map { .items(Set($0)) } ?? .whole
            }
            let section = record.section.flatMap(ResumeSection.init(rawValue:))
            guard record.section == nil || section != nil else { throw Self.stale }
            return ExportRecordSelection(id: record.id, fields: fields, resumeSection: section)
        }
        return (format, selection)
    }

    public func data(from vault: Vault) throws -> Data {
        guard let profile = vault.profiles.first(where: { $0.id == profileID }) else { throw Self.stale }
        let selected = try selection(in: profile)
        return try SelectiveExport.data(from: profile, selection: selected.records, format: selected.format)
    }

    public static func validateName(_ name: String) throws {
        guard name.wholeMatch(of: #/[a-z0-9][a-z0-9_-]{0,63}/#) != nil else {
            throw DataIssue("Use up to 64 lowercase letters, digits, hyphens or underscores. Start with a letter or digit.")
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
    private let directory: URL

    public init(vaultURL: URL) {
        directory = vaultURL.deletingLastPathComponent()
            .appendingPathComponent(vaultURL.lastPathComponent + ".export-presets", isDirectory: true)
    }

    public func load(_ name: String) throws -> ExportPreset {
        try ExportPreset.validateName(name)
        let data: Data
        do { data = try VaultFile.readData(path(name)) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            throw DataIssue("Export preset not found. Save it from VeraData’s export preview first.")
        }
        let preset = try JSONDecoder().decode(ExportPreset.self, from: data)
        guard preset.name == name else { throw DataIssue("The export preset filename does not match its contents.") }
        return preset
    }

    public func names(for profileID: Profile.ID? = nil) throws -> [String] {
        let files: [String]
        do { files = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return [] }
        return files.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }.sorted().filter { name in
                guard let preset = try? load(name) else { return false }
                return profileID == nil || profileID == preset.profileID
            }
    }

    public func save(_ preset: ExportPreset, replace: Bool = false) throws {
        try ExportPreset.validateName(preset.name)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw DataIssue("Could not open the export preset lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DataIssue("Another instance is saving an export preset. Try again.") }
        let destination = path(preset.name)
        if manager.fileExists(atPath: destination.path) {
            guard replace, try load(preset.name).profileID == preset.profileID else {
                throw DataIssue("That export preset name is already in use.")
            }
        }

        let data = try JSONEncoder().encode(preset)
        let pending = directory.appendingPathComponent(".preset-\(UUID().uuidString)")
        guard manager.createFile(atPath: pending.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DataIssue("Could not write the export preset.")
        }
        defer { try? manager.removeItem(at: pending) }
        guard rename(pending.path, destination.path) == 0 else { throw DataIssue("Could not save the export preset.") }
    }

    private func path(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }
}

private extension Dictionary {
    func mapValuesWithKeys<T>(_ transform: (Key, Value) throws -> T) rethrows -> [Key: T] {
        try Dictionary<Key, T>(uniqueKeysWithValues: map { (try ($0.key, transform($0.key, $0.value))) })
    }
}
