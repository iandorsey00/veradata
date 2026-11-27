import Foundation

/// A local vault with optimistic conflict detection and recoverable replacement.
public struct VaultFile {
    public let url: URL
    private var revision: Data?
    private var loaded = false
    private var observed = FileObservation()
    public let encrypted: EncryptedVault?

    public init(url: URL, encrypted: EncryptedVault? = nil) {
        self.url = url
        self.encrypted = encrypted?.url == url ? encrypted : nil
    }

    public var stateStore: VaultStateStore { VaultStateStore(vaultURL: url, encrypted: encrypted) }

    private struct FileObservation: Equatable {
        var inode: UInt64?
        var modified: Date?
        var size: UInt64?

        init() {}

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.uint64Value
        }
    }

    public static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["VERADATA_VAULT_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL.applicationSupportDirectory.appending(path: "VeraData/vault.json")
    }

    public mutating func load() throws -> Vault? {
        let observation = encrypted == nil ? FileObservation() : try FileObservation(url)
        let data = try stateStore.vaultBytes()
        let vault = try data.map(Vault.init(data:))
        observed = observation
        revision = data
        loaded = true
        return vault
    }

    public func hasExternalChanges() throws -> Bool {
        if encrypted != nil { return try !loaded || FileObservation(url) != observed }
        let bytes = try stateStore.vaultBytes()
        return !loaded || bytes != revision
    }

    public mutating func save(_ vault: Vault, summary: String = "Update vault", attachment: VaultAttachment? = nil) throws {
        guard loaded else { throw DataIssue("Open the current vault before saving.") }
        let data = try vault.data()
        let expected = revision
        try stateStore.commit(summary: summary, attachment: attachment) { state in
            guard state.vaultData == expected else { throw VaultStateConflict.stale }
            // Older files may use different whitespace for the exact same vault.
            if let current = state.vaultData, try Vault(data: current) == vault { return }
            state.vaultData = data
        }
        if try expected.map(Vault.init(data:)) != vault { revision = data }
        // Leave the previously observed stamp in place so an external change is never masked.
    }

    /// Replace the current file after an explicit restore, even if its JSON cannot be decoded.
    public mutating func restore(_ vault: Vault) throws {
        let data = try vault.data()
        let result = try stateStore.commit(summary: "Restore backup") { state in
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
