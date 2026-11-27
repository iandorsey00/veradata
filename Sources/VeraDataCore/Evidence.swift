import CryptoKit
import Foundation

/// Fractional bounds measured from the top left of the displayed, rotated page.
public struct EvidenceRegion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var isValid: Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
    }
}

public struct EvidenceDocument: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case pdf, image }

    public let digest: String
    public let name: String
    public let kind: Kind

    var isValid: Bool {
        EvidenceDigest.isValid(digest) && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func matches(_ bytes: Data) -> Bool {
        !bytes.isEmpty && bytes.count <= EvidenceFileStore.maxBytes && EvidenceDigest.hash(bytes) == digest
    }
}

/// A single marked area can support several fields. Each field has its own reviewed value fingerprint.
public struct EvidenceMark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let document: EvidenceDocument
    public let page: Int
    public let region: EvidenceRegion
    public let checkedAt: Date
    public let fields: [String: String]

    public init(id: UUID = UUID(), document: EvidenceDocument, page: Int, region: EvidenceRegion,
                record: Record, keys: Set<String>, checkedAt: Date = Date()) throws {
        self.id = id
        self.document = document
        self.page = page
        self.region = region
        self.checkedAt = checkedAt
        var fields: [String: String] = [:]
        for key in keys {
            guard let digest = try Self.fingerprint(in: record, key: key) else {
                throw DataIssue("Choose fields with a stored value.")
            }
            fields[key] = digest
        }
        self.fields = fields
        try validate()
    }

    public func matches(_ key: String, in record: Record) -> Bool {
        guard let checked = fields[key] else { return false }
        return (try? Self.fingerprint(in: record, key: key)) == checked
    }

    public static func reviewValue(in record: Record, key: String) -> JSONValue? {
        if key == "formatted", let lines = record.renderedMailingLines { return .string(lines) }
        return record.fields[key]
    }

    public static func canCheck(_ value: JSONValue?) -> Bool {
        guard let value, value != .null else { return false }
        if let text = value.string { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let list = value.array { return !list.isEmpty }
        if let object = value.object { return !object.isEmpty }
        return true
    }

    private static func fingerprint(in record: Record, key: String) throws -> String? {
        let value = reviewValue(in: record, key: key)
        guard let value, canCheck(value) else { return nil }
        return EvidenceDigest.hash(try value.data())
    }

    func validate() throws {
        guard document.isValid, page >= 0, document.kind == .pdf || page == 0, region.isValid,
              checkedAt.timeIntervalSinceReferenceDate.isFinite, !fields.isEmpty,
              fields.allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  EvidenceDigest.isValid($0.value) }) else {
            throw DataIssue("Invalid evidence mark.")
        }
    }
}

enum EvidenceDigest {
    static func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ digest: String) -> Bool { digest.wholeMatch(of: #/[0-9a-f]{64}/#) != nil }
}

/// Local, immutable copies. By keeping files after unlinking marks, revision restore can still open them.
public struct EvidenceFileStore {
    public static let maxBytes = 25 * 1024 * 1024
    public let directory: URL
    private let stateStore: VaultStateStore

    public init(vaultURL: URL, archive: VaultArchive? = nil) {
        directory = vaultURL.deletingLastPathComponent().appendingPathComponent(vaultURL.lastPathComponent + ".evidence")
        stateStore = VaultStateStore(vaultURL: vaultURL, archive: archive)
    }

    public init(vaultURL: URL, encrypted: EncryptedVault?) {
        self.init(vaultURL: vaultURL, archive: encrypted)
    }

    public static func readInput(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maxBytes + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= maxBytes else { throw DataIssue("Choose a file up to 25 MiB.") }
        return bytes
    }

    public static func document(for bytes: Data, name: String, kind: EvidenceDocument.Kind) -> EvidenceDocument {
        EvidenceDocument(digest: EvidenceDigest.hash(bytes), name: name, kind: kind)
    }

    public func save(_ bytes: Data, for document: EvidenceDocument) throws {
        guard !VaultArchive.isArchiveURL(stateStore.vaultURL) else {
            throw DataIssue("Save the evidence and mark together in the vault.")
        }
        let location = try path(for: document)
        guard document.matches(bytes) else {
            throw DataIssue("The evidence file does not match the reviewed document.")
        }
        if (try? read(document)) != nil { return }
        try stateStore.write(bytes, to: location)
    }

    public func contains(_ document: EvidenceDocument) -> Bool {
        if stateStore.archive != nil { return document.isValid }
        if VaultArchive.isArchiveURL(stateStore.vaultURL) { return false }
        guard let location = try? path(for: document),
              let attributes = try? location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return attributes.isRegularFile == true && attributes.isSymbolicLink != true
    }

    public func read(_ document: EvidenceDocument) throws -> Data {
        if let archive = stateStore.archive {
            guard let bytes = try archive.contents().documents[document.digest], document.matches(bytes) else {
                throw DataIssue("The local copy of this evidence is missing or damaged.")
            }
            return bytes
        }
        guard contains(document) else { throw DataIssue("The local copy of this evidence is missing.") }
        let bytes = try Self.readInput(path(for: document))
        guard document.matches(bytes) else {
            throw DataIssue("The local evidence file changed. Attach the document again to review it.")
        }
        return bytes
    }

    private func path(for document: EvidenceDocument) throws -> URL {
        guard document.isValid else { throw DataIssue("Invalid evidence document.") }
        return directory.appendingPathComponent(document.digest)
    }
}
