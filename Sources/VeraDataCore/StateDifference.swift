import Foundation

/// Describes changed keys without retaining or exposing their values in the summary.
public struct StateDifference: Sendable {
    public struct Entry: Sendable {
        public let target: String
        public let action: String
        public let fields: [String]
        public let before: JSONValue?
        public let after: JSONValue?

        public func json(reveal: Bool) -> JSONValue {
            var output: [String: JSONValue] = [
                "target": .string(target), "action": .string(action), "fields": .array(fields.map(JSONValue.string)),
            ]
            if reveal {
                output["before"] = before ?? .null
                output["after"] = after ?? .null
            }
            return .object(output)
        }
    }

    public let entries: [Entry]
    public let records: [String]
    public let presets: [String]

    public init(before: VaultState, after: VaultState) {
        let lhs = (try? before.vault()) ?? nil
        let rhs = (try? after.vault()) ?? nil
        var entries: [Entry] = []
        var records: [String] = []
        let oldProfiles = Dictionary(uniqueKeysWithValues: (lhs?.profiles ?? []).map { ($0.id, $0) })
        let newProfiles = Dictionary(uniqueKeysWithValues: (rhs?.profiles ?? []).map { ($0.id, $0) })
        for profile in Set(oldProfiles.keys).union(newProfiles.keys).sorted() {
            let old = oldProfiles[profile]
            let new = newProfiles[profile]
            if old?.name != new?.name {
                entries.append(Self.entry("profile/" + profile, old?.name.mapValue, new?.name.mapValue, ["name"]))
            }
            let oldRecords = Dictionary(uniqueKeysWithValues: (old?.records ?? []).map { ($0.id, $0) })
            let newRecords = Dictionary(uniqueKeysWithValues: (new?.records ?? []).map { ($0.id, $0) })
            for id in Set(oldRecords.keys).union(newRecords.keys).sorted() {
                let left = oldRecords[id]
                let right = newRecords[id]
                guard left != right else { continue }
                let a = left?.fields ?? [:]
                let b = right?.fields ?? [:]
                var fields = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
                if left?.label != right?.label { fields.insert("@label") }
                if left?.aliases != right?.aliases { fields.insert("@aliases") }
                if left?.kind != right?.kind { fields.insert("@kind") }
                if (left?.evidence ?? []) != (right?.evidence ?? []) { fields.insert("@evidence") }
                let key = profile + "/" + id
                records.append(key)
                entries.append(Self.entry("record/" + key, Self.recordValues(left, fields), Self.recordValues(right, fields), fields.sorted()))
            }
        }
        if lhs?.shortcut != rhs?.shortcut {
            entries.append(Self.entry("settings", lhs?.shortcut.rawValue.mapValue, rhs?.shortcut.rawValue.mapValue, ["searchShortcut"]))
        }
        let presets = Set(before.presets.keys).union(after.presets.keys).filter { before.presets[$0] != after.presets[$0] }.sorted()
        for name in presets {
            let a = before.presets[name].flatMap { try? JSONValue.parse($0) }
            let b = after.presets[name].flatMap { try? JSONValue.parse($0) }
            entries.append(Self.entry("preset/" + name, a, b, Self.presetFields(a, b)))
        }
        self.entries = entries
        self.records = records
        self.presets = presets
    }

    private static func recordValues(_ record: Record?, _ fields: Set<String>) -> JSONValue? {
        guard let record else { return nil }
        var values = record.fields.filter { fields.contains($0.key) }
        if fields.contains("@label") { values["@label"] = .string(record.label) }
        if fields.contains("@aliases") { values["@aliases"] = .object(record.aliases.mapValues(JSONValue.string)) }
        if fields.contains("@kind") { values["@kind"] = .string(record.kind.rawValue) }
        if fields.contains("@evidence") { values["@evidence"] = .string(String(record.evidence.count)) }
        return .object(values)
    }

    private static func presetFields(_ before: JSONValue?, _ after: JSONValue?) -> [String] {
        func keys(_ preset: JSONValue?) -> [String: JSONValue] {
            var keys: [String: JSONValue] = [:]
            for entry in preset?.object?["records"]?.array ?? [] {
                guard let record = entry.object, let id = record["id"]?.string else { continue }
                for (field, value) in record["fields"]?.object ?? [:] { keys[id + "/" + field] = value }
                keys[id + "/@section"] = record["section"]
            }
            return keys
        }
        let a = keys(before)
        let b = keys(after)
        var fields = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
        if before?.object?["records"]?.array?.compactMap({ $0.object?["id"] }) != after?.object?["records"]?.array?.compactMap({ $0.object?["id"] }) {
            fields.insert("@order")
        }
        return fields.sorted()
    }

    private static func entry(_ target: String, _ before: JSONValue?, _ after: JSONValue?, _ fields: [String]) -> Entry {
        Entry(target: target, action: before == nil ? "add" : after == nil ? "remove" : "update",
              fields: fields, before: before, after: after)
    }
}

private extension String {
    var mapValue: JSONValue { .string(self) }
}
