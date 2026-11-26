import Foundation

/// A local vault with optimistic conflict detection and recoverable replacement.
public struct VaultFile {
    public let url: URL
    private var revision: Data?
    private var loaded = false

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["VERADATA_VAULT_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL.applicationSupportDirectory.appending(path: "VeraData/vault.json")
    }

    public mutating func load() throws -> Vault? {
        let data = try VaultStateStore(vaultURL: url).vaultBytes()
        let vault = try data.map(Vault.init(data:))
        revision = data
        loaded = true
        return vault
    }

    public func hasExternalChanges() throws -> Bool {
        let bytes = try VaultStateStore(vaultURL: url).vaultBytes()
        return !loaded || bytes != revision
    }

    public mutating func save(_ vault: Vault, summary: String = "Update vault") throws {
        guard loaded else { throw DataIssue("Open the current vault before saving.") }
        let data = try vault.data()
        let expected = revision
        try VaultStateStore(vaultURL: url).commit(summary: summary) { state in
            guard state.vaultData == expected else { throw VaultStateConflict.stale }
            // Older files may use different whitespace for the exact same vault.
            if let current = state.vaultData, try Vault(data: current) == vault { return }
            state.vaultData = data
        }
        if try expected.map(Vault.init(data:)) != vault { revision = data }
    }

    /// Replace the current file after an explicit restore, even if its JSON cannot be decoded.
    public mutating func restore(_ vault: Vault) throws {
        let data = try vault.data()
        let result = try VaultStateStore(vaultURL: url).commit(summary: "Restore backup") { state in
            if (try? state.vault()) == vault { return }
            state.vaultData = data
        }
        if result.changed { revision = data; loaded = true }
        else { _ = try load() }
    }

    public static func readBackup(_ url: URL) throws -> Vault {
        try Vault(data: readData(url))
    }

    static func readData(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: JSONValue.maxBytes + 1) ?? Data()
        guard data.count <= JSONValue.maxBytes else { throw DataIssue("JSON exceeds the 16 MiB limit.") }
        return data
    }
}
