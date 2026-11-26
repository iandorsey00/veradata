import VeraDataCore

struct CLIArguments {
    private static let switches: Set<String> = ["--help", "-h", "--yes", "--apply", "--replace", "--values", "--copy", "--all"]
    private static let repeatable: Set<String> = ["--set", "--unset", "--record", "--exclude", "--pick"]
    private let switches: Set<String>
    private let values: [String: [String]]
    let positionals: [String]

    init(_ arguments: [String]) throws {
        var values: [String: [String]] = [:]
        var switches: Set<String> = []
        var positionals: [String] = []
        var input = arguments.makeIterator()
        while let arg = input.next() {
            if arg == "--" {
                while let literal = input.next() { positionals.append(literal) }
                break
            }
            if Self.switches.contains(arg) {
                guard switches.insert(arg).inserted else { throw DataIssue("Duplicate option \(arg).") }
            } else if arg.hasPrefix("--") {
                guard let value = input.next(), !value.hasPrefix("--") else {
                    throw DataIssue("\(arg) needs a value. See --help.")
                }
                guard values[arg] == nil || Self.repeatable.contains(arg) else {
                    throw DataIssue("Duplicate option \(arg).")
                }
                values[arg, default: []].append(value)
            } else {
                positionals.append(arg)
            }
        }
        self.values = values
        self.switches = switches
        self.positionals = positionals
    }

    func has(_ option: String) -> Bool { switches.contains(option) }
    func one(_ option: String) -> String? { values[option]?.first }
    func many(_ option: String) -> [String] { values[option] ?? [] }

    func validate(_ count: ClosedRange<Int>, _ options: Set<String> = [], vault: Bool = true) throws {
        var allowed = options
        if vault { allowed.insert("--vault") }
        if let invalid = Set(values.keys).union(switches).subtracting(allowed).sorted().first {
            throw DataIssue("Unsupported option \(invalid) for this command. See --help.")
        }
        guard count.contains(positionals.count) else {
            throw DataIssue("Wrong number of arguments. See --help.")
        }
        if let path = one("--vault"), path.isEmpty { throw DataIssue("--vault needs a file path.") }
    }

    func requireConfirmation() throws {
        guard has("--yes") else { throw DataIssue("This command changes or removes stored data. Run again with --yes to confirm.") }
    }

    func validateInputPaths(_ paths: [String?]) throws {
        guard paths.compactMap({ $0 }).filter({ $0 == "-" }).count <= 1 else {
            throw DataIssue("Use stdin for at most one input per command.")
        }
    }
}
