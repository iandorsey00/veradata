import Foundation

/// A snapshot of explicitly selected records. Its envelope is distinct from backups.
public struct MobileTransfer: Equatable, Sendable {
    public struct EvidencePick: Hashable, Sendable {
        public let profileID: Profile.ID
        public let recordID: Record.ID
        public let digest: String

        public init(profileID: Profile.ID, recordID: Record.ID, digest: String) {
            self.profileID = profileID
            self.recordID = recordID
            self.digest = digest
        }
    }

    public let profiles: [Profile]
    public var recordCount: Int { profiles.reduce(0) { $0 + $1.records.count } }
    public var evidenceDocumentCount: Int { documents.count }

    private let documents: [String: Data]
    private static let format = "veradata-mobile"
    private static let maxAttachmentsBytes = 32 * 1024 * 1024
    private static let maxEvidenceTransferBytes = 64 * 1024 * 1024

    public init(vault: Vault, selection: [Profile.ID: Set<Record.ID>],
                evidence: Set<EvidencePick> = [], readEvidence: ((EvidenceDocument) throws -> Data)? = nil) throws {
        var requested = evidence
        var documents: [String: Data] = [:]
        var totalBytes = 0
        let profiles = try vault.profiles.compactMap { profile -> Profile? in
            guard let ids = selection[profile.id] else { return nil }
            let records = try profile.records.filter { ids.contains($0.id) }.map { record in
                var copy = record
                copy.verifications = [:]
                copy.evidence = record.evidence.filter { mark in
                    evidence.contains(EvidencePick(profileID: profile.id, recordID: record.id, digest: mark.document.digest))
                }
                for mark in copy.evidence {
                    let document = mark.document
                    requested.remove(EvidencePick(profileID: profile.id, recordID: record.id, digest: document.digest))
                    if documents[document.digest] == nil {
                        guard let readEvidence else { throw DataIssue("The selected evidence could not be loaded.") }
                        let bytes = try readEvidence(document)
                        totalBytes += bytes.count
                        guard totalBytes <= Self.maxAttachmentsBytes else { throw Self.attachmentLimit }
                        documents[document.digest] = bytes
                    }
                }
                return copy
            }
            guard !records.isEmpty else { return nil }
            return Profile(id: profile.id, name: profile.name, records: records)
        }
        guard requested.isEmpty else { throw DataIssue("The selected evidence changed. Reopen Export for iPhone and select it again.") }
        try self.init(profiles: profiles, documents: documents)
    }

    private init(profiles: [Profile], documents: [String: Data]) throws {
        guard !profiles.isEmpty, profiles.allSatisfy({ !$0.records.isEmpty }) else {
            throw DataIssue("Select at least one record to transfer.")
        }
        self.profiles = try Vault(profiles: profiles).validated().profiles
        let references = profiles.flatMap { $0.records }.flatMap { $0.evidence }.map(\.document)
        guard Set(references.map(\.digest)) == Set(documents.keys) else {
            throw DataIssue("The evidence files do not match the selected records.")
        }
        guard documents.values.reduce(0, { $0 + $1.count }) <= Self.maxAttachmentsBytes else { throw Self.attachmentLimit }
        var verified: Set<String> = []
        for reference in references where verified.insert(reference.digest).inserted {
            guard let bytes = documents[reference.digest], reference.matches(bytes) else {
                throw DataIssue("An evidence file is damaged or does not match the transfer.")
            }
        }
        self.documents = documents
    }

    public init(data: Data) throws {
        guard data.count <= Self.maxEvidenceTransferBytes else { throw Self.transferLimit }
        let root = try JSONValue.parse(data, maxBytes: Self.maxEvidenceTransferBytes)
        guard let envelope = root.object, envelope["format"]?.string == Self.format else {
            throw DataIssue("Choose a VeraData iPhone transfer file exported from the Mac.")
        }
        guard case .number(let version)? = envelope["version"], let profiles = envelope["profiles"]?.array else {
            throw DataIssue("This iPhone transfer format is unsupported or incomplete.")
        }
        let commonKeys: Set<String> = ["format", "version", "profiles"]
        switch version.raw {
        case "1" where Set(envelope.keys) == commonKeys:
            guard data.count <= JSONValue.maxBytes else { throw Self.transferLimit }
            try self.init(profiles: Vault.decodeProfiles(profiles), documents: [:])
        case "2" where Set(envelope.keys) == commonKeys.union(["documents"]):
            guard let encoded = envelope["documents"]?.object, !encoded.isEmpty else {
                throw DataIssue("The evidence files do not match the selected records.")
            }
            _ = try JSONValue.array(profiles).data()
            var bytesSoFar = 0
            let documents = try encoded.mapValues { value in
                guard let string = value.string, let bytes = Data(base64Encoded: string) else {
                    throw DataIssue("An evidence file is damaged or does not match the transfer.")
                }
                bytesSoFar += bytes.count
                guard bytesSoFar <= Self.maxAttachmentsBytes else { throw Self.attachmentLimit }
                return bytes
            }
            try self.init(profiles: Vault.decodeProfiles(profiles, includeEvidence: true), documents: documents)
        default:
            throw DataIssue("This iPhone transfer format is unsupported or incomplete.")
        }
    }

    public func evidenceBytes(for document: EvidenceDocument) -> Data? { documents[document.digest] }

    public func data() throws -> Data {
        let includeEvidence = !documents.isEmpty
        let exportedProfiles = try Vault.encodeProfiles(profiles, includeEvidence: includeEvidence)
        var fields: [String: JSONValue] = [
            "format": .string(Self.format),
            "version": .number(try JSONNumber(includeEvidence ? "2" : "1")),
            "profiles": exportedProfiles,
        ]
        if includeEvidence {
            _ = try exportedProfiles.data()
            fields["documents"] = .object(documents.mapValues { .string($0.base64EncodedString()) })
        }
        return try JSONValue.object(fields).data(maxBytes: includeEvidence ? Self.maxEvidenceTransferBytes : JSONValue.maxBytes)
    }

    public static func read(_ url: URL) throws -> MobileTransfer {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maxEvidenceTransferBytes + 1) ?? Data()
        return try MobileTransfer(data: data)
    }

    private static var attachmentLimit: DataIssue {
        DataIssue("An iPhone transfer can include up to 32 MiB of evidence. Deselect some documents and export again.")
    }

    private static var transferLimit: DataIssue {
        DataIssue("The iPhone transfer file exceeds its size limit.")
    }
}
