import Foundation
import VeraDataCore

extension CLICommands {
    mutating func lookup(_ command: String, _ args: CLIArguments) throws {
        switch command {
        case "search":
            try args.validate(1...1, ["--profile", "--record", "--limit", "--values"])
            let limit = try args.one("--limit").map { raw in
                guard let limit = Int(raw), limit > 0 else { throw DataIssue("--limit must be a positive integer.") }
                return limit
            } ?? 80
            let vault = try load()
            let profile = vault.profiles[try profileIndex(args.one("--profile"), in: vault.profiles)]
            let recordID = args.one("--record")
            if let recordID { _ = try recordIndex(recordID, in: profile) }
            let results = RetrievalIndex(records: profile.records).search(args.positionals[0], recordID: recordID, limit: limit)
            try emit(.array(results.map { result in
                var item: [String: JSONValue] = ["title": .string(result.title), "context": .string(result.subtitle)]
                if let id = result.record?.id { item["record"] = .string(id) }
                if let id = result.field?.id { item["field"] = .string(id) }
                if let current = result.currentValue { item["current"] = .string(current.rawValue) }
                if !result.representations.isEmpty {
                    item["representations"] = .array(result.representations.map { .string($0.label) })
                }
                if args.has("--values") {
                    if let chosen = result.preferredFormat ?? result.representations.first { item["value"] = .string(chosen.text) }
                    else if let field = result.field { item["value"] = field.value }
                }
                return .object(item)
            }))
        case "get":
            try args.validate(2...2, ["--profile", "--representation", "--copy"])
            let vault = try load()
            let profile = vault.profiles[try profileIndex(args.one("--profile"), in: vault.profiles)]
            let record = profile.records[try recordIndex(args.positionals[0], in: profile)]
            let fieldName = args.positionals[1]
            if let raw = record.fields[fieldName] ?? record.aliases[fieldName].flatMap({ record.fields[$0] }),
               args.one("--representation") == nil {
                if let text = raw.scalarText { try emit(text, copy: args.has("--copy")) }
                else if args.has("--copy") { try emit(raw.rendered(), copy: true) }
                else { try emit(raw) }
                return
            }
            let fields = record.values.filter { $0.id == fieldName || $0.path == [fieldName] || $0.aliases.contains(fieldName) }
            guard fields.count == 1, let field = fields.first else {
                throw DataIssue("Field not found or ambiguous. Use the exact field key or the field path from search.")
            }
            if field.representations.isEmpty, args.one("--representation") == nil {
                if args.has("--copy") { try emit(field.value.rendered(), copy: true) }
                else { try emit(field.value) }
            } else {
                try emitRepresentation(field.representations, args)
            }
        case "current":
            try args.validate(1...1, ["--representation", "--copy"], vault: false)
            guard let current = CurrentValue(rawValue: args.positionals[0]) else {
                throw DataIssue("Use current today or current timestamp.")
            }
            try emitRepresentation(current.representations(at: .now), args)
        default: throw DataIssue("Unknown lookup command. See --help.")
        }
    }

    private func emitRepresentation(_ values: [Representation], _ args: CLIArguments) throws {
        let result: Representation?
        if let label = args.one("--representation") {
            result = values.first { $0.label == label }
        } else {
            result = values.first
        }
        guard let result else { throw DataIssue("Representation not found. Use search to list available labels.") }
        try emit(result.text, copy: args.has("--copy"))
    }
}
