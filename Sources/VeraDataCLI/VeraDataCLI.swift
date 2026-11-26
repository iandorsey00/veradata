import Foundation
import VeraDataCore
import Darwin

@main
struct VeraDataCLI {
    private static let usage = """
        Usage:
          veradata export --preset NAME [--vault PATH]
          veradata presets [--vault PATH]
          veradata --help

        Save an export preset in VeraData’s export preview first.
        Export writes JSON to stdout. Diagnostics go to stderr.
        With no --vault, use the same vault as the desktop app.
        """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("--help") || arguments == ["-h"] {
            print(usage)
            return
        }
        do { try run(arguments) }
        catch {
            let message = "veradata: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        let command = arguments[0]
        let flags = Array(arguments.dropFirst())
        guard flags.count.isMultiple(of: 2) else { throw DataIssue("Each option needs a value. See --help.") }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: flags.count, by: 2) {
            let flag = flags[index]
            guard (flag == "--vault" || flag == "--preset"), options[flag] == nil,
                  !flags[index + 1].isEmpty else { throw DataIssue("Invalid or duplicate option. See --help.") }
            options[flag] = flags[index + 1]
        }
        let vaultURL = options["--vault"].map { URL(fileURLWithPath: $0) } ?? VaultFile.defaultURL
        let presets = ExportPresetStore(vaultURL: vaultURL)
        switch command {
        case "export":
            guard let name = options["--preset"] else { throw DataIssue("Supply --preset NAME. See --help.") }
            var store = VaultFile(url: vaultURL)
            guard let vault = try store.load() else { throw DataIssue("VeraData vault not found.") }
            let data = try presets.load(name).data(from: vault)
            try FileHandle.standardOutput.write(contentsOf: data)
        case "presets":
            guard options["--preset"] == nil else { throw DataIssue("The presets command does not take --preset.") }
            for name in try presets.names() { print(name) }
        default: throw DataIssue("Unknown command. See --help.")
        }
    }
}
