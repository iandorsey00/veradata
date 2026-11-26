import Foundation
import VeraDataCore

extension CLICommands {
    mutating func exports(_ command: String, _ args: CLIArguments) throws {
        switch command {
        case "selection":
            try args.validate(0...0, ["--profile", "--resume", "--contact", "--exclude"])
            let vault = try load()
            let profile = vault.profiles[try profileIndex(args.one("--profile"), in: vault.profiles)]
            let scope: ResumeSelectionScope
            switch args.one("--resume") {
            case "standard": scope = .standard
            case "recommended": scope = .recommended
            case "all": scope = .all
            default: throw DataIssue("Supply --resume standard, recommended or all.")
            }
            let contacts = profile.records.filter { record in
                record.kind == .contact && !SelectiveExport.allFields(in: record, format: .veraFlowResume).isEmpty
            }
            if let id = args.one("--contact") {
                guard contacts.contains(where: { $0.id == id }) else {
                    throw DataIssue("Choose a contact record ID with résumé fields in the selected profile.")
                }
            } else if contacts.count > 1 {
                throw DataIssue("This profile has multiple contacts. Choose one with --contact RECORD.")
            }
            let excluded = Set(args.many("--exclude"))
            for id in excluded { _ = try recordIndex(id, in: profile) }
            let records = SelectiveExport.resumeSelection(
                in: profile, contactID: args.one("--contact") ?? contacts.first?.id, scope: scope
            ).filter { !excluded.contains($0.id) }
            try emit(SelectionPlan(profile: profile.id, format: .veraFlowResume, records: records).json)
        case "export":
            try args.validate(0...0, ["--preset", "--selection", "--format"])
            let override: ExportFormat?
            switch args.one("--format") {
            case nil: override = nil
            case "structured": override = .structured
            default: throw DataIssue("Use --format structured to override the saved format.")
            }
            let state = try VaultStateStore(vaultURL: store.url).snapshot()
            guard let vault = try state.vault() else { throw DataIssue("VeraData vault not found.") }
            switch (args.one("--preset"), args.one("--selection")) {
            case (let name?, nil):
                try emit(state.preset(name).data(from: vault, as: override))
            case (nil, let path?):
                let plan = try SelectionPlan(object(path))
                let profile = vault.profiles[try profileIndex(plan.profile, in: vault.profiles)]
                let native = try SelectiveExport.data(from: profile, selection: plan.records, format: plan.format)
                if let override, override != plan.format {
                    try emit(SelectiveExport.data(from: profile, selection: plan.records, format: override))
                } else {
                    try emit(native)
                }
            default: throw DataIssue("Choose one of --preset NAME or --selection FILE.")
            }
        case "export-phone":
            try args.validate(0...0, ["--profile", "--record", "--all", "--pick"])
            let vault = try load()
            var picks: [Profile.ID: Set<Record.ID>] = [:]
            if !args.many("--pick").isEmpty {
                guard !args.has("--all"), args.one("--profile") == nil, args.many("--record").isEmpty else {
                    throw DataIssue("Use --pick PROFILE_ID:RECORD_ID without --profile, --record or --all.")
                }
                for pick in args.many("--pick") {
                    let parts = pick.split(separator: ":", omittingEmptySubsequences: false)
                    guard parts.count == 2, let profile = vault.profiles.first(where: { $0.id == parts[0] }) else {
                        throw DataIssue("Use --pick PROFILE_ID:RECORD_ID. List IDs with profiles and records.")
                    }
                    let id = String(parts[1])
                    _ = try recordIndex(id, in: profile)
                    picks[profile.id, default: []].insert(id)
                }
            } else {
                let profile = vault.profiles[try profileIndex(args.one("--profile"), in: vault.profiles)]
                let ids = args.many("--record")
                guard args.has("--all") == ids.isEmpty else {
                    throw DataIssue("Choose --record RECORD for each record, or use --all for the selected profile.")
                }
                for id in ids { _ = try recordIndex(id, in: profile) }
                picks[profile.id] = Set(args.has("--all") ? profile.records.map(\.id) : ids)
            }
            try emit(MobileTransfer(vault: vault, selection: picks).data())
        default: throw DataIssue("Unknown export command. See --help.")
        }
    }

    mutating func presets(_ action: String, _ args: CLIArguments) throws {
        switch action {
        case "list":
            try args.validate(0...0, ["--profile"])
            var profileID: String?
            if let selector = args.one("--profile") {
                let vault = try load()
                profileID = vault.profiles[try profileIndex(selector, in: vault.profiles)].id
            }
            for name in try presetStore.names(for: profileID) { print(name) }
        case "show":
            try args.validate(1...1)
            let preset = try presetStore.load(args.positionals[0])
            let saved = try preset.definition()
            try emit(SelectionPlan(profile: preset.profileID, format: saved.format, records: saved.records).json)
        case "save":
            try args.validate(1...1, ["--selection", "--replace"])
            guard let path = args.one("--selection") else { throw DataIssue("Supply --selection FILE.") }
            let plan = try SelectionPlan(object(path))
            let state = try VaultStateStore(vaultURL: store.url).snapshot()
            guard let vault = try state.vault() else { throw DataIssue("VeraData vault not found.") }
            let profile = vault.profiles[try profileIndex(plan.profile, in: vault.profiles)]
            let preset = try ExportPreset(name: args.positionals[0], profile: profile, selection: plan.records, format: plan.format)
            try presetStore.save(preset, replace: args.has("--replace"), expected: state.token)
            try emit(.object(["name": .string(preset.name), "profile": .string(preset.profileID)]))
        case "delete":
            try args.validate(1...1, ["--yes"])
            try args.requireConfirmation()
            try presetStore.delete(args.positionals[0])
        default: throw DataIssue("Use preset list, show, save or delete. See --help.")
        }
    }
}

/// A plain JSON selection. True chooses a whole field. An array chooses zero-based list indices.
private struct SelectionPlan {
    let profile: String
    let format: ExportFormat
    let records: [ExportRecordSelection]

    init(profile: String, format: ExportFormat, records: [ExportRecordSelection]) {
        self.profile = profile
        self.format = format
        self.records = records
    }

    init(_ object: [String: JSONValue]) throws {
        guard Set(object.keys) == ["profile", "format", "records"], let profile = object["profile"]?.string, !profile.isEmpty,
              let format = object["format"]?.string, let records = object["records"]?.array else {
            throw DataIssue("A selection needs profile, format and records. Use veradata selection for an example.")
        }
        self.profile = profile
        switch format {
        case "resume": self.format = .veraFlowResume
        case "structured": self.format = .structured
        case "flat": self.format = .flatRecord
        default: throw DataIssue("Selection format must be resume, structured or flat.")
        }
        self.records = try records.map { item in
            guard let entry = item.object, Set(entry.keys).isSubset(of: ["id", "fields", "section"]),
                  let id = entry["id"]?.string, let fields = entry["fields"]?.object else {
                throw DataIssue("Each selected record needs an ID and a fields object.")
            }
            let choices = try fields.mapValues { value -> ExportFieldSelection in
                if value == .bool(true) { return .whole }
                guard let indices = value.array, !indices.isEmpty else {
                    throw DataIssue("Set a selected field to true or a nonempty list of item indices.")
                }
                let positions = try indices.map { index in
                    guard case let .number(raw) = index, let value = Int(raw.raw), value >= 0 else {
                        throw DataIssue("List item indices must be nonnegative integers.")
                    }
                    return value
                }
                let unique = Set(positions)
                guard unique.count == positions.count else { throw DataIssue("List item indices must be unique.") }
                return .items(unique)
            }
            let section = entry["section"]?.string.flatMap(ResumeSection.init(rawValue:))
            guard entry["section"] == nil || section != nil else {
                throw DataIssue("Résumé section must be skills, projects, languages or certifications.")
            }
            return ExportRecordSelection(id: id, fields: choices, resumeSection: section)
        }
    }

    var json: JSONValue {
        get throws {
            let type: String
            switch format {
            case .veraFlowResume: type = "resume"
            case .structured: type = "structured"
            case .flatRecord: type = "flat"
            }
            let items: [JSONValue] = try records.map { record in
                let fields = try record.fields.mapValues { value -> JSONValue in
                    switch value {
                    case .whole: return .bool(true)
                    case .items(let positions):
                        return .array(try positions.sorted().map { .number(try JSONNumber(String($0))) })
                    }
                }
                var item: [String: JSONValue] = ["id": .string(record.id), "fields": .object(fields)]
                if let section = record.resumeSection { item["section"] = .string(section.rawValue) }
                return .object(item)
            }
            return .object(["profile": .string(profile), "format": .string(type), "records": .array(items)])
        }
    }
}
