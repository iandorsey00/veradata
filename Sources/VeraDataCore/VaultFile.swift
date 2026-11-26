import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A local vault with optimistic conflict detection and atomic replacement.
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
        let data = try currentData()
        let vault = try data.map { try Vault(data: $0) }
        revision = data
        loaded = true
        return vault
    }

    public mutating func save(_ vault: Vault) throws {
        guard loaded else { throw DataIssue("Open the current vault before saving.") }
        let data = try vault.data()
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let lock = open(folder.appendingPathComponent(".vault.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw DataIssue("Unable to open the local vault lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw DataIssue("Another instance is saving. Try again in a moment.")
        }
        guard try currentData() == revision else {
            throw DataIssue("The vault changed on disk. Reopen VeraData before making more edits.")
        }

        let pending = folder.appendingPathComponent(".vault-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: pending.path, contents: nil,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw DataIssue("Unable to create a private file for the vault.")
        }
        defer { try? manager.removeItem(at: pending) }
        let handle = try FileHandle(forWritingTo: pending)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(pending.path, url.path) == 0 else {
            throw DataIssue("Unable to replace the local vault file.")
        }
        revision = data
    }

    /// Replace the current file after an explicit restore, even if its JSON cannot be decoded.
    public mutating func restore(_ vault: Vault) throws {
        revision = try currentData()
        loaded = true
        try save(vault)
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

    private func currentData() throws -> Data? {
        do { return try Self.readData(url) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return nil }
    }
}
