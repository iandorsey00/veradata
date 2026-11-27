import AppKit
import Foundation
import VeraDataCore
import Darwin

@main
struct VeraDataCLI {
    static let usage = """
        Usage: veradata COMMAND [OPTIONS]

        Vault and records:
          vault encrypt DESTINATION.veradata
          profiles
          profile create NAME [--id ID]
          profile rename PROFILE NAME
          profile delete PROFILE --yes
          records [--profile PROFILE] [--kind KIND]
          record show RECORD [--profile PROFILE]
          record add --kind KIND --label NAME [--id ID] [--fields FILE] [--set KEY=TEXT] [--aliases FILE]
          record update RECORD [--label NAME] [--fields FILE] [--set KEY=TEXT] [--unset KEY] [--aliases FILE]
          record delete RECORD --yes
          import FILE [--source-profile PROFILE] [--on-match skip|update|add] [--apply]
          backup
          restore FILE --yes
          shortcut [space|j|k|off]

        Lookup:
          search QUERY [--record RECORD] [--limit COUNT] [--values]
          get RECORD FIELD [--representation LABEL] [--copy]
          current today|timestamp [--representation LABEL] [--copy]

        Export and presets:
          selection --resume standard|recommended|all [--contact RECORD] [--exclude RECORD]
          export --preset NAME [--format structured]
          export --selection FILE [--format structured]
          export-phone --record RECORD ... | --all
          export-phone --pick PROFILE_ID:RECORD_ID ...
          presets
          preset show NAME
          preset save NAME --selection FILE [--replace]
          preset delete NAME --yes
          preset update NAME --record ID [--include FIELD] [--exclude FIELD]
            [--items FIELD=0,2] [--section SECTION] [--position N] [--remove-record]
            [--apply --expect TOKEN]

        Transactions and recovery:
          apply FILE [--apply --expect TOKEN] [--human] [--show-values]
          history
          history show REVISION [--against REVISION] [--human] [--show-values]
          history restore REVISION [--apply --expect TOKEN] [--show-values]
          history prune --keep COUNT [--apply]
          history retention [--keep COUNT --apply]

        Data commands accept --vault PATH. For an encrypted file, the password is prompted on the terminal.
        Profile-scoped commands accept --profile ID or NAME.
        With no --vault, commands use the desktop app's vault. With no --profile, use the first profile.
        FILE may be - for stdin. JSON and selected values go to stdout. Diagnostics go to stderr.
        Transaction previews redact values. --json-errors writes structured diagnostics to stderr.
        Import previews changes by default. An export selection is a JSON file produced by selection
        or preset show. Preview it with export before saving or replacing a preset.
        """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do { try run(arguments) }
        catch {
            let code: Int32 = error is VaultStateConflict ? 3 : 1
            let human = Data("veradata: \(error.localizedDescription)\n".utf8)
            let structured = arguments.prefix { $0 != "--" }.contains("--json-errors")
            let payload = structured ? try? JSONValue.object([
                "error": .string(code == 3 ? "conflict" : "failed"),
                "message": .string(error.localizedDescription),
            ]).data() : nil
            try? FileHandle.standardError.write(contentsOf: payload ?? human)
            exit(code)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first, !["--help", "-h", "help"].contains(command) else {
            print(usage)
            return
        }
        var remaining = Array(arguments.dropFirst())
        let action = ["profile", "record", "preset", "history", "vault"].contains(command) && remaining.first?.hasPrefix("-") == false
            ? remaining.removeFirst() : ""
        let args = try CLIArguments(remaining)
        if args.has("--help") || args.has("-h") {
            print(usage)
            return
        }
        let path = args.one("--vault").map { URL(fileURLWithPath: $0) } ?? VaultFile.defaultURL
        let encrypted: EncryptedVault? = if command != "current", EncryptedVault.isEncryptedURL(path) {
            try EncryptedVault.open(path, password: vaultPassword("Vault password: "))
        } else { nil }
        var cli = CLICommands(vaultURL: path, encrypted: encrypted)
        switch command {
        case "vault" where action == "encrypt":
            try args.validate(1...1)
            let target = URL(fileURLWithPath: args.positionals[0])
            let password = try vaultPassword("New vault password: ")
            guard try vaultPassword("Confirm new vault password: ") == password else {
                throw DataIssue("The vault passwords do not match.")
            }
            _ = try EncryptedVault.create(at: target, password: password, copying: cli.store.stateStore)
            try cli.emit(.object(["path": .string(target.path)]))

        case "profiles", "profile": try cli.profiles(command == "profiles" ? "list" : action, args)
        case "records", "record": try cli.records(command == "records" ? "list" : action, args)
        case "import": try cli.importRecords(args)
        case "backup", "restore", "shortcut": try cli.maintenance(command, args)
        case "search", "get", "current": try cli.lookup(command, args)
        case "selection", "export", "export-phone": try cli.exports(command, args)
        case "preset" where action == "update": try cli.updatePreset(args)
        case "presets", "preset": try cli.presets(command == "presets" ? "list" : action, args)
        case "apply": try cli.applyChanges(args)
        case "history": try cli.history(action.isEmpty ? "list" : action, args)
        default: throw DataIssue("Unknown command. See --help.")
        }
    }
    private static func vaultPassword(_ prompt: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4097)
        let useStdin = isatty(STDIN_FILENO) == 1
        var terminal = termios()
        if useStdin {
            guard tcgetattr(STDIN_FILENO, &terminal) == 0 else {
                throw DataIssue("Unable to disable terminal echo for the vault password.")
            }
            var hidden = terminal
            hidden.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
                throw DataIssue("Unable to disable terminal echo for the vault password.")
            }
        }
        defer {
            if useStdin {
                tcsetattr(STDIN_FILENO, TCSANOW, &terminal)
                try? FileHandle.standardError.write(contentsOf: Data([10]))
            }
        }
        if useStdin { try FileHandle.standardError.write(contentsOf: Data(prompt.utf8)) }
        return try buffer.withUnsafeMutableBufferPointer { storage in
            defer { _ = memset_s(storage.baseAddress, storage.count, 0, storage.count) }
            guard let text = readpassphrase(prompt, storage.baseAddress, storage.count, useStdin ? RPP_STDIN : RPP_REQUIRE_TTY),
                  let password = String(validatingUTF8: text), !password.isEmpty else {
                throw DataIssue("Enter the vault password in an interactive terminal.")
            }
            return password
        }
    }
}

struct CLICommands {
    var store: VaultFile
    let presetStore: ExportPresetStore

    init(vaultURL: URL, encrypted: EncryptedVault? = nil) {
        store = VaultFile(url: vaultURL, encrypted: encrypted)
        presetStore = ExportPresetStore(vaultURL: vaultURL, encrypted: encrypted)
    }

    mutating func load() throws -> Vault {
        guard let vault = try store.load() else {
            throw DataIssue("VeraData vault not found. Create a profile with veradata profile create NAME.")
        }
        return vault
    }

    func emit(_ json: JSONValue) throws { try emit(json.data()) }

    func emit(_ data: Data) throws {
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    func emit(_ value: String, copy: Bool) throws {
        if copy {
            let clipboard = NSPasteboard.general
            clipboard.clearContents()
            guard clipboard.setString(value, forType: .string) else { throw DataIssue("Could not copy to the clipboard.") }
        } else {
            try emit(Data((value + "\n").utf8))
        }
    }

    func profileIndex(_ selector: String?, in profiles: [Profile], option: String = "--profile") throws -> Int {
        if let selector {
            if let exact = profiles.firstIndex(where: { $0.id == selector }) { return exact }
            let names = profiles.indices.filter { profiles[$0].name.caseInsensitiveCompare(selector) == .orderedSame }
            guard let index = names.first else { throw DataIssue("Profile not found. Use a profile ID or name.") }
            guard names.count == 1 else { throw DataIssue("That profile name is ambiguous. Supply its ID.") }
            return index
        }
        guard let index = profiles.indices.first else { throw DataIssue("No profiles found.") }
        if option == "--source-profile", profiles.count > 1 {
            throw DataIssue("The import has multiple profiles. Choose one with --source-profile.")
        }
        return index
    }

    func recordIndex(_ id: String, in profile: Profile) throws -> Int {
        guard let index = profile.records.firstIndex(where: { $0.id == id }) else {
            throw DataIssue("Record not found in this profile. Use veradata records to list IDs.")
        }
        return index
    }

    func input(_ path: String) throws -> Data {
        let file = path == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { if path != "-" { try? file.close() } }
        var data = Data()
        while let next = try file.read(upToCount: 64 * 1024), !next.isEmpty {
            data.append(next)
            guard data.count <= JSONValue.maxBytes else { throw DataIssue("JSON exceeds the 16 MiB limit.") }
        }
        return data
    }

    func object(_ path: String) throws -> [String: JSONValue] {
        guard let value = try JSONValue.parse(input(path)).object else { throw DataIssue("Expected a JSON object.") }
        return value
    }
}
