import Foundation

/// A snapshot of explicitly selected records. Its envelope is distinct from backups.
public struct MobileTransfer: Equatable, Sendable {
    public let profiles: [Profile]
    public var recordCount: Int { profiles.reduce(0) { $0 + $1.records.count } }

    private static let format = "veradata-mobile"
    private static let version = "1"

    public init(vault: Vault, selection: [Profile.ID: Set<Record.ID>]) throws {
        let profiles = vault.profiles.compactMap { profile -> Profile? in
            guard let ids = selection[profile.id] else { return nil }
            let records = profile.records.filter { ids.contains($0.id) }
            guard !records.isEmpty else { return nil }
            return Profile(id: profile.id, name: profile.name, records: records)
        }
        try self.init(profiles: profiles)
    }

    private init(profiles: [Profile]) throws {
        guard !profiles.isEmpty, profiles.allSatisfy({ !$0.records.isEmpty }) else {
            throw DataIssue("Select at least one record to transfer.")
        }
        self.profiles = try Vault(profiles: profiles).validated().profiles
    }

    public init(data: Data) throws {
        let root = try JSONValue.parse(data)
        guard let envelope = root.object, envelope["format"]?.string == Self.format else {
            throw DataIssue("Choose a VeraData iPhone transfer file exported from the Mac.")
        }
        guard envelope["version"]?.scalarText == Self.version, case .number? = envelope["version"],
              Set(envelope.keys) == ["format", "version", "profiles"],
              let profiles = envelope["profiles"]?.array else {
            throw DataIssue("This iPhone transfer format is unsupported or incomplete.")
        }
        try self.init(profiles: Vault.decodeProfiles(profiles))
    }

    public func data() throws -> Data {
        try JSONValue.object([
            "format": .string(Self.format),
            "version": .number(JSONNumber(Self.version)),
            "profiles": Vault.encodeProfiles(profiles),
        ]).data()
    }

    public static func read(_ url: URL) throws -> MobileTransfer {
        try MobileTransfer(data: VaultFile.readData(url))
    }
}
