import CryptoKit
import Foundation

public struct ChangeReview {
    public let token: String
    public let difference: StateDifference
    public let changed: Bool
}

/// A versioned, deterministic patch of one profile and its export presets.
public struct ChangeSet {
    private let profileID: String
    private let operations: [[String: JSONValue]]
    private let payload: Data

    public init(data: Data) throws {
        let value = try JSONValue.parse(data)
        guard let object = value.object, Set(object.keys) == ["version", "profile", "operations"],
              case let .number(version)? = object["version"], version.raw == "1",
              let id = object["profile"]?.string, !id.isEmpty,
              let operations = object["operations"]?.array, !operations.isEmpty else {
            throw DataIssue("A change set needs version 1, a profile ID and a nonempty operations list.")
        }
        self.profileID = id
        self.operations = try operations.enumerated().map { offset, entry in
            guard let object = entry.object else { throw DataIssue("Operation \(offset + 1) must be an object.") }
            return object
        }
        self.payload = try value.data()
    }

    public func preview(in state: VaultState, expected: String? = nil) throws -> ChangeReview {
        let token = token(for: state)
        if let expected, expected != token { throw VaultStateConflict.stale }
        let after = try applying(to: state)
        return ChangeReview(token: token, difference: StateDifference(before: state, after: after), changed: state != after)
    }

    public func commit(to store: VaultStateStore, expected: String) throws -> VaultCommit {
        try store.commit(summary: "Apply change set") { state in
            guard token(for: state) == expected else { throw VaultStateConflict.stale }
            state = try applying(to: state)
        }
    }

    private func token(for state: VaultState) -> String {
        var hash = SHA256()
        hash.update(data: Data(state.token.utf8))
        hash.update(data: payload)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func applying(to before: VaultState) throws -> VaultState {
        var state = before
        guard var vault = try state.vault(), let index = vault.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw DataIssue("Profile ID not found. Use veradata profiles to list IDs.")
        }
        let originalVault = vault
        for (indexInSet, op) in operations.enumerated() {
            do {
                guard let type = op["operation"]?.string,
                      let recordID = op["record"]?.string, !recordID.isEmpty else {
                    throw DataIssue("Each operation needs an operation name and record ID.")
                }
                switch type {
                case "record.update":
                    try updateRecord(recordID, operation: op, profile: &vault.profiles[index])
                case "preset.update":
                    try updatePreset(recordID, operation: op, profile: vault.profiles[index], state: &state)
                default: throw DataIssue("Unsupported operation. Use record.update or preset.update.")
                }
            } catch {
                throw DataIssue("Operation \(indexInSet + 1): \(error.localizedDescription)")
            }
        }
        if vault != originalVault { state.vaultData = try vault.data() }
        return state
    }

    private func updateRecord(_ id: String, operation: [String: JSONValue], profile: inout Profile) throws {
        guard Set(operation.keys).isSubset(of: ["operation", "record", "fields", "unset", "label"]) else {
            throw DataIssue("record.update contains an unsupported property.")
        }
        guard let index = profile.records.firstIndex(where: { $0.id == id }) else {
            throw DataIssue("Record ID not found in the change set’s profile.")
        }
        let fields = try object(operation["fields"])
        let removals: [String]
        if let value = operation["unset"] {
            guard let list = value.array, list.allSatisfy({ $0.string != nil }) else {
                throw DataIssue("unset must be an array of field names.")
            }
            removals = list.compactMap(\.string)
        } else { removals = [] }
        guard Set(removals).isDisjoint(with: fields.keys) else {
            throw DataIssue("A field cannot be set and removed together.")
        }
        var record = profile.records[index]
        if let value = operation["label"] {
            guard let text = value.string else { throw DataIssue("label must be text.") }
            record.label = text
        }
        for field in removals { record.fields.removeValue(forKey: field) }
        record.aliases = record.aliases.filter { !removals.contains($0.value) }
        record.fields.merge(fields) { _, new in new }
        if record.kind == .employment, let end = record.fields["endDate"]?.string {
            record.fields["endDate"] = .string(Record.canonicalEmploymentEndDate(end))
        }
        try record.validate()
        profile.records[index] = record
    }

    private func updatePreset(_ id: String, operation: [String: JSONValue], profile: Profile,
                              state: inout VaultState) throws {
        guard Set(operation.keys).isSubset(of: ["operation", "preset", "record", "fields", "section", "position", "excludeRecord"]),
              let name = operation["preset"]?.string else {
            throw DataIssue("preset.update needs a preset name and supported properties.")
        }
        let preset = try state.preset(name)
        guard preset.profileID == profile.id else { throw DataIssue("The preset belongs to a different profile.") }
        let saved = try preset.definition()
        var selection = saved.records
        let existing = selection.firstIndex { $0.id == id }
        let fields = try object(operation["fields"])
        var refreshed: Set<String> = []

        if operation["excludeRecord"] == .bool(true) {
            guard fields.isEmpty, operation["section"] == nil, operation["position"] == nil else {
                throw DataIssue("excludeRecord cannot be combined with other changes to the same record.")
            }
            if let existing { selection.remove(at: existing) }
        } else {
            guard operation["excludeRecord"] == nil || operation["excludeRecord"] == .bool(false) else {
                throw DataIssue("excludeRecord must be true or false.")
            }
            guard let record = profile.records.first(where: { $0.id == id }) else {
                throw DataIssue("Record ID not found in the change set’s profile.")
            }
            var selected = existing.map { selection[$0] } ?? ExportRecordSelection(id: id, fields: [:])
            for (key, value) in fields {
                switch value {
                case .bool(false): selected.fields.removeValue(forKey: key)
                case .bool(true): selected.fields[key] = .whole
                case .array(let list):
                    let indices = try list.map(position)
                    let distinct = Set(indices)
                    guard !distinct.isEmpty, distinct.count == indices.count else {
                        throw DataIssue("Select a nonempty list of unique item indices.")
                    }
                    selected.fields[key] = .items(distinct)
                    refreshed.insert(key)
                default: throw DataIssue("Preset fields must be true, false or an array of item indices.")
                }
            }
            if let value = operation["section"] {
                guard record.kind == .custom, saved.format == .veraFlowResume else {
                    throw DataIssue("Résumé sections apply to custom records in résumé presets.")
                }
                if value == .null { selected.resumeSection = nil }
                else {
                    guard let raw = value.string, let section = ResumeSection(rawValue: raw) else {
                        throw DataIssue("Invalid résumé section.")
                    }
                    selected.resumeSection = section
                }
            }
            if let existing { selection.remove(at: existing) }
            if !selected.fields.isEmpty {
                let insertion = try operation["position"].map(position) ?? existing ?? selection.count
                guard insertion <= selection.count else { throw DataIssue("The record position is outside the preset.") }
                selection.insert(selected, at: insertion)
            } else if operation["position"] != nil || operation["section"] != nil || existing == nil {
                throw DataIssue("Select at least one field for this preset record.")
            }
        }
        let updated = try preset.replacingSelection(selection, in: profile, refreshedFields: refreshed.isEmpty ? [:] : [id: refreshed])
        try state.setPreset(updated)
    }

    private func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard let value else { return [:] }
        guard let fields = value.object else { throw DataIssue("fields must be a JSON object.") }
        return fields
    }

    private func position(_ value: JSONValue) throws -> Int {
        guard case let .number(raw) = value, let number = Int(raw.raw), number >= 0 else {
            throw DataIssue("Positions and list item indices must be nonnegative integers.")
        }
        return number
    }
}
