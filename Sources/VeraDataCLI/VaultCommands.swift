import Foundation
import VeraDataCore

extension CLICommands {
    mutating func profiles(_ action: String, _ args: CLIArguments) throws {
        switch action {
        case "list":
            try args.validate(0...0)
            let vault = try load()
            let profiles = try vault.profiles.map { profile -> JSONValue in
                .object(["id": .string(profile.id), "name": .string(profile.name),
                         "recordCount": .number(try JSONNumber(String(profile.records.count)))])
            }
            try emit(.array(profiles))
        case "create":
            try args.validate(1...1, ["--id"])
            var vault = try store.load() ?? Vault(profiles: [])
            let name = args.positionals[0].trimmingCharacters(in: .whitespacesAndNewlines)
            try checkProfileName(name, in: vault)
            let profile = Profile(id: args.one("--id") ?? UUID().uuidString.lowercased(), name: name)
            vault.profiles.append(profile)
            try store.save(vault)
            try emit(.object(["id": .string(profile.id), "name": .string(profile.name)]))
        case "rename":
            try args.validate(2...2)
            var vault = try load()
            let index = try profileIndex(args.positionals[0], in: vault.profiles)
            let name = args.positionals[1].trimmingCharacters(in: .whitespacesAndNewlines)
            try checkProfileName(name, in: vault, excluding: vault.profiles[index].id)
            vault.profiles[index].name = name
            try store.save(vault)
        case "delete":
            try args.validate(1...1, ["--yes"])
            try args.requireConfirmation()
            var vault = try load()
            let index = try profileIndex(args.positionals[0], in: vault.profiles)
            vault.profiles.remove(at: index)
            try store.save(vault)
        default: throw DataIssue("Use profile list, create, rename or delete. See --help.")
        }
    }

    private func checkProfileName(_ name: String, in vault: Vault, excluding id: String? = nil) throws {
        guard !vault.profiles.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw DataIssue("A profile with that name already exists.")
        }
    }

    mutating func records(_ action: String, _ args: CLIArguments) throws {
        switch action {
        case "list":
            try args.validate(0...0, ["--profile", "--kind"])
            let vault = try load()
            let profile = vault.profiles[try profileIndex(args.one("--profile"), in: vault.profiles)]
            let kind = try args.one("--kind").map(recordKind)
            try emit(.array(profile.records.filter { kind == nil || $0.kind == kind }.map { record in
                .object(["id": .string(record.id), "kind": .string(record.kind.rawValue), "label": .string(record.label)])
            }))
        case "show":
            try args.validate(1...1, ["--profile"])
            let vault = try load()
            let profile = vault.profiles[try profileIndex(args.one("--profile"), in: vault.profiles)]
            try emit(profile.records[recordIndex(args.positionals[0], in: profile)].json)
        case "add", "update":
            try saveRecord(action, args)
        case "delete":
            try args.validate(1...1, ["--profile", "--yes"])
            try args.requireConfirmation()
            var vault = try load()
            let profile = try profileIndex(args.one("--profile"), in: vault.profiles)
            let index = try recordIndex(args.positionals[0], in: vault.profiles[profile])
            vault.profiles[profile].records.remove(at: index)
            try store.save(vault)
        default: throw DataIssue("Use record list, show, add, update or delete. See --help.")
        }
    }

    private mutating func saveRecord(_ action: String, _ args: CLIArguments) throws {
        let isNew = action == "add"
        let count = isNew ? 0...0 : 1...1
        let common: Set<String> = ["--profile", "--label", "--fields", "--set", "--aliases"]
        try args.validate(count, common.union(isNew ? ["--id", "--kind"] : ["--unset"]))
        let fieldsPath = args.one("--fields")
        let aliasesPath = args.one("--aliases")
        try args.validateInputPaths([fieldsPath, aliasesPath])
        var fields = try fieldsPath.map(object) ?? [:]
        for assignment in args.many("--set") {
            guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
                throw DataIssue("Use --set KEY=TEXT. Use --fields for typed JSON values.")
            }
            let key = String(assignment[..<equals])
            guard fields.updateValue(.string(String(assignment[assignment.index(after: equals)...])), forKey: key) == nil else {
                throw DataIssue("Supply each field update only once.")
            }
        }
        let removed = Set(args.many("--unset"))
        guard removed.isDisjoint(with: fields.keys) else { throw DataIssue("A field cannot be set and unset together.") }
        let aliases = try aliasesPath.map { path in
            let values = try object(path)
            guard values.values.allSatisfy({ $0.string != nil }) else {
                throw DataIssue("Aliases must map shortcut strings to field names.")
            }
            return values.compactMapValues(\.string)
        }

        var vault = try load()
        let profile = try profileIndex(args.one("--profile"), in: vault.profiles)
        let index: Int?
        var record: Record
        if isNew {
            guard let kind = args.one("--kind"), let label = args.one("--label") else {
                throw DataIssue("Supply --kind and --label to add a record.")
            }
            index = nil
            record = Record(id: args.one("--id") ?? UUID().uuidString.lowercased(), kind: try recordKind(kind), label: label)
        } else {
            let existing = try recordIndex(args.positionals[0], in: vault.profiles[profile])
            index = existing
            record = vault.profiles[profile].records[existing]
            if let label = args.one("--label") { record.label = label }
        }

        for key in removed { record.fields.removeValue(forKey: key) }
        record.fields.merge(fields) { _, new in new }
        if let aliases { record.aliases = aliases }
        else { record.aliases = record.aliases.filter { !removed.contains($0.value) } }
        if record.kind == .employment, let end = record.fields["endDate"]?.string {
            record.fields["endDate"] = .string(Record.canonicalEmploymentEndDate(end))
        }
        if let index { vault.profiles[profile].records[index] = record }
        else { vault.profiles[profile].records.append(record) }
        try store.save(vault)
        try emit(.object(["id": .string(record.id)]))
    }

    private func recordKind(_ value: String) throws -> RecordKind {
        guard let kind = RecordKind(rawValue: value) else {
            throw DataIssue("Use a record kind of contact, address, employment, education or custom.")
        }
        return kind
    }

    mutating func importRecords(_ args: CLIArguments) throws {
        try args.validate(1...1, ["--profile", "--source-profile", "--on-match", "--apply"])
        let onMatch = args.one("--on-match") ?? "skip"
        guard ["skip", "update", "add"].contains(onMatch) else {
            throw DataIssue("--on-match must be skip, update or add.")
        }
        let path = args.positionals[0]
        let sourceFile = try RecordImport(
            data: input(path),
            fallbackLabel: path == "-" ? "Imported Record" : URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        )
        let sourceIndex = try profileIndex(args.one("--source-profile"), in: sourceFile.profiles, option: "--source-profile")
        let source = sourceFile.profiles[sourceIndex]
        var vault = try load()
        let destinationIndex = try profileIndex(args.one("--profile"), in: vault.profiles)
        let destination = vault.profiles[destinationIndex]
        let review = RecordImportReview(source: source, destination: destination)
        var decisions: [Record.ID: RecordImportReview.Decision] = [:]
        let plan: [JSONValue] = try source.records.map { record in
            let matches = review.possibleMatches(for: record)
            var line: [String: JSONValue] = ["id": .string(record.id), "label": .string(record.label),
                                             "matches": .array(matches.map(JSONValue.string))]
            var decision = review.initialDecision(for: record)
            if !matches.isEmpty && onMatch == "add" { decision = .add }
            if !matches.isEmpty && onMatch == "update" {
                let candidates = destination.records.filter { matches.contains($0.id) }
                guard let result = candidates.first(where: { $0.id == record.id }) ?? (candidates.count == 1 ? candidates.first : nil) else {
                    throw DataIssue("Ambiguous import match for record \(record.id). Use a matching record ID or update the record explicitly.")
                }
                let keys = Set(record.fields.keys.filter { record.fields[$0] != result.fields[$0] })
                if !keys.isEmpty { decision = .update(result.id, fields: keys) }
            }
            decisions[record.id] = decision
            switch decision {
            case .skip: line["action"] = .string("skip")
            case .add: line["action"] = .string("add")
            case let .update(id, fields):
                line["action"] = .string("update")
                line["target"] = .string(id)
                line["fields"] = .array(fields.sorted().map(JSONValue.string))
            }
            return .object(line)
        }
        let updated = try review.applying(decisions)
        if args.has("--apply"), updated != destination {
            vault.profiles[destinationIndex] = updated
            try store.save(vault)
        }
        try emit(.object(["applied": .bool(args.has("--apply")), "profile": .string(destination.id), "records": .array(plan)]))
    }

    mutating func maintenance(_ command: String, _ args: CLIArguments) throws {
        switch command {
        case "backup":
            try args.validate(0...0)
            let vault = try load()
            try emit(vault.data())
        case "restore":
            try args.validate(1...1, ["--yes"])
            try args.requireConfirmation()
            let backup = try Vault(data: input(args.positionals[0]))
            try store.restore(backup)
        case "shortcut":
            try args.validate(0...1)
            var vault = try load()
            if let key = args.positionals.first {
                guard let shortcut = SearchShortcut(rawValue: key) else {
                    throw DataIssue("Use space, j, k or off for the global search shortcut.")
                }
                vault.shortcut = shortcut
                try store.save(vault)
            }
            try emit(vault.shortcut.rawValue, copy: false)
        default: throw DataIssue("Unknown vault command. See --help.")
        }
    }
}
