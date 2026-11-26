import Foundation
import VeraDataCore

extension CLICommands {
    private var stateStore: VaultStateStore { VaultStateStore(vaultURL: store.url) }
    private static let reviewFlags: Set<String> = ["--apply", "--commit", "--expect", "--human", "--show-values"]

    func applyChanges(_ args: CLIArguments) throws {
        try args.validate(1...1, Self.reviewFlags)
        try runChangeSet(ChangeSet(data: input(args.positionals[0])), args)
    }

    func updatePreset(_ args: CLIArguments) throws {
        try args.validate(1...1, Self.reviewFlags.union([
            "--record", "--include", "--exclude", "--items", "--section", "--position", "--remove-record",
        ]))
        guard args.many("--record").count == 1, let record = args.one("--record") else {
            throw DataIssue("Choose one record with --record ID.")
        }
        let name = args.positionals[0]
        let preset = try presetStore.load(name)
        var operation: [String: JSONValue] = [
            "operation": .string("preset.update"), "preset": .string(name), "record": .string(record),
        ]
        var fields: [String: JSONValue] = [:]
        func add(_ key: String, _ value: JSONValue) throws {
            guard !key.isEmpty, fields[key] == nil else { throw DataIssue("Choose each field at most once.") }
            fields[key] = value
        }
        for key in args.many("--include") { try add(key, .bool(true)) }
        for key in args.many("--exclude") { try add(key, .bool(false)) }
        for item in args.many("--items") {
            guard let equals = item.firstIndex(of: "=") else { throw DataIssue("Use --items FIELD=0,2.") }
            let values = try item[item.index(after: equals)...].split(separator: ",", omittingEmptySubsequences: false)
                .map { JSONValue.number(try JSONNumber(String($0))) }
            try add(String(item[..<equals]), .array(values))
        }
        if !fields.isEmpty { operation["fields"] = .object(fields) }
        if let section = args.one("--section") { operation["section"] = section == "none" ? .null : .string(section) }
        if let position = args.one("--position") { operation["position"] = .number(try JSONNumber(position)) }
        if args.has("--remove-record") { operation["excludeRecord"] = .bool(true) }
        guard operation.count > 3 else { throw DataIssue("Supply at least one preset change.") }
        let payload = try JSONValue.object([
            "version": .number(JSONNumber("1")), "profile": .string(preset.profileID), "operations": .array([.object(operation)]),
        ]).data()
        try runChangeSet(ChangeSet(data: payload), args)
    }

    private func runChangeSet(_ changes: ChangeSet, _ args: CLIArguments) throws {
        let expected = try commitToken(args)
        let review = try changes.preview(in: stateStore.snapshot(), expected: expected)
        if let expected {
            let result = try changes.commit(to: stateStore, expected: expected)
            try emitReview(review.difference, changed: result.changed, committed: true,
                           revision: result.revision?.id, args)
        } else {
            try emitReview(review.difference, changed: review.changed, token: review.token, args)
        }
    }

    func history(_ command: String, _ args: CLIArguments) throws {
        switch command {
        case "list":
            try args.validate(0...0)
            try emit(.array(try stateStore.history().map(revisionJSON)))
        case "show", "restore":
            try args.validate(1...1, command == "show" ? ["--against", "--human", "--show-values"] : Self.reviewFlags)
            let saved = try stateStore.revision(args.positionals[0])
            let current = try args.one("--against").map { try stateStore.revision($0).state } ?? stateStore.snapshot()
            if command == "show" {
                let difference = StateDifference(before: saved.state, after: current)
                if args.has("--human") {
                    try emitReview(difference, changed: saved.state != current, revision: saved.revision.id, args)
                } else {
                    try emit(.object(["revision": revisionJSON(saved.revision),
                                      "changes": .array(difference.entries.map { $0.json(reveal: args.has("--show-values")) })]))
                }
                return
            }
            guard saved.revision.recoverable else { throw DataIssue("This revision has no readable vault to restore.") }
            let difference = StateDifference(before: current, after: saved.state)
            let token = saved.revision.id + "." + current.token
            if let expected = try commitToken(args) {
                guard expected == token else { throw VaultStateConflict.stale }
                let result = try stateStore.restore(saved.revision.id, expected: current.token)
                try emitReview(difference, changed: result.changed, committed: true, revision: result.revision?.id, args)
            } else {
                try emitReview(difference, changed: current != saved.state, token: token, revision: saved.revision.id, args)
            }
        case "prune", "retention":
            try args.validate(0...0, ["--keep", "--apply"])
            if let raw = args.one("--keep") {
                guard let keep = Int(raw), (1...500).contains(keep) else { throw DataIssue("Keep between 1 and 500 revisions.") }
                let candidates = try stateStore.pruningCandidates(keeping: keep)
                if args.has("--apply") { try stateStore.prune(keeping: keep, configure: command == "retention") }
                try emit(.object(["keep": .number(JSONNumber(String(keep))), "applied": .bool(args.has("--apply")),
                                  "pruningCandidates": .array(candidates.map(JSONValue.string)),
                                  "revisions": .number(JSONNumber(String(stateStore.history().count)))]))
            } else {
                guard command == "retention", !args.has("--apply") else { throw DataIssue("Supply --keep COUNT.") }
                try emit(.object(["keep": .number(JSONNumber(String(stateStore.retention())))]))
            }
        default: throw DataIssue("Use history list, show, restore, prune or retention.")
        }
    }

    private func commitToken(_ args: CLIArguments) throws -> String? {
        let apply = args.has("--apply")
        let commit = args.has("--commit")
        guard !(apply && commit), (apply || commit) == (args.one("--expect") != nil) else {
            throw DataIssue("Preview first, then use --apply --expect TOKEN with the preview token.")
        }
        return args.one("--expect")
    }

    private func revisionJSON(_ revision: VaultRevision) -> JSONValue {
        .object([
            "id": .string(revision.id), "date": .string(ISO8601DateFormatter().string(from: revision.date)),
            "summary": .string(revision.summary), "records": .array(revision.records.map(JSONValue.string)),
            "presets": .array(revision.presets.map(JSONValue.string)), "recoverable": .bool(revision.recoverable),
        ])
    }

    private func emitReview(_ difference: StateDifference, changed: Bool, committed: Bool = false,
                            token: String? = nil, revision: String? = nil, _ args: CLIArguments) throws {
        let reveal = args.has("--show-values")
        if args.has("--human") {
            for entry in difference.entries {
                print("\(entry.action) \(entry.target)  \(entry.fields.joined(separator: ", "))")
                if reveal {
                    if let before = entry.before { print("  before \(try before.rendered())") }
                    if let after = entry.after { print("  after  \(try after.rendered())") }
                }
            }
            if let token { print("Preview token  \(token)") }
            if let revision { print("Revision  \(revision)") }
            print(changed ? (committed ? "Changes committed." : "No changes committed.") : "No changes.")
        } else {
            var result: [String: JSONValue] = ["changed": .bool(changed), "committed": .bool(committed),
                                                "changes": .array(difference.entries.map { $0.json(reveal: reveal) })]
            if let token { result["token"] = .string(token) }
            if let revision { result["revision"] = .string(revision) }
            try emit(.object(result))
        }
    }
}
