import CryptoKit
import Foundation
import Darwin

/// One coherent view of the existing vault and its adjacent preset files.
public struct VaultState: Codable, Equatable, Sendable {
    public var vaultData: Data?
    public var presets: [String: Data]

    public var token: String {
        // Frame the components independently so equal concatenations cannot collide.
        var hash = SHA256()
        hash.update(data: Data((vaultData.map { "vault:\($0.count)\n" } ?? "absent\n").utf8))
        if let vaultData { hash.update(data: vaultData) }
        for name in presets.keys.sorted() {
            guard let bytes = presets[name] else { continue }
            hash.update(data: Data("\(name):\(bytes.count)\n".utf8))
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func vault() throws -> Vault? { try vaultData.map(Vault.init(data:)) }

    public func preset(_ name: String) throws -> ExportPreset {
        let name = try ExportPreset.normalizedName(name)
        guard let data = presets[name] else { throw DataIssue("Export preset not found.") }
        let preset = try JSONDecoder().decode(ExportPreset.self, from: data)
        guard preset.name == name else { throw DataIssue("The export preset filename does not match its contents.") }
        return preset
    }

    public mutating func setPreset(_ preset: ExportPreset) throws {
        guard try ExportPreset.normalizedName(preset.name) == preset.name else {
            throw DataIssue("The export preset filename does not match its contents.")
        }
        // Avoid counting an identical preset as a change due to JSON key order.
        let encoded = try Self.encode(preset)
        if let previous = presets[preset.name],
           let previousPreset = try? JSONDecoder().decode(ExportPreset.self, from: previous),
           try Self.encode(previousPreset) == encoded { return }
        presets[preset.name] = encoded
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

public struct VaultRevision: Codable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let summary: String
    public let records: [String]
    public let presets: [String]
    public let recoverable: Bool
}

public struct VaultCommit: Sendable {
    public let changed: Bool
    public let revision: VaultRevision?
}

public enum VaultStateConflict: LocalizedError {
    case stale, busy, cloud

    public var errorDescription: String? {
        switch self {
        case .stale: return VeraText.text("The vault or presets changed on disk. Review the latest state and try again.")
        case .busy: return VeraText.text("Another VeraData process is writing. Try again in a moment.")
        case .cloud: return VeraText.text("This vault has conflicting cloud versions. Save both versions before resolving the conflict in your cloud provider.")
        }
    }
}

/// All cooperating readers recover pending work before observing vault or preset data.
public struct VaultStateStore: Sendable {
    private struct Snapshot: Codable {
        let revision: VaultRevision
        let state: VaultState
    }

    private struct Journal: Codable {
        let version: Int
        let before: Snapshot
        let after: VaultState
    }

    public static let defaultRetention = 30
    public let vaultURL: URL
    var afterVaultWrite: (@Sendable () throws -> Void)?

    public let archive: VaultArchive?
    public var encrypted: EncryptedVault? { VaultArchive.isEncryptedURL(vaultURL) ? archive : nil }

    public init(vaultURL: URL, archive: VaultArchive? = nil) {
        self.vaultURL = vaultURL
        self.archive = archive?.url == vaultURL ? archive : nil
    }

    public init(vaultURL: URL, encrypted: EncryptedVault?) {
        self.init(vaultURL: vaultURL, archive: encrypted)
    }

    private var folder: URL { vaultURL.deletingLastPathComponent() }
    private var presetsFolder: URL { folder.appendingPathComponent(vaultURL.lastPathComponent + ".export-presets") }
    private var historyFolder: URL { folder.appendingPathComponent(vaultURL.lastPathComponent + ".history") }
    private var journalURL: URL { historyFolder.appendingPathComponent(".pending") }
    private var limitURL: URL { historyFolder.appendingPathComponent(".retention") }

    public func snapshot() throws -> VaultState {
        if let archive { return try archive.contents().state }
        return try locked { try readState() }
    }

    func completeContents(initialVault: Vault) throws -> VaultArchive.Contents {
        if let archive { return try archive.contents() }
        return try locked {
            var state = try readState()
            if state.vaultData == nil { state.vaultData = try initialVault.data() }
            let revisions = try revisionFiles().map { id in
                let saved = try readRevision(id)
                return VaultArchive.Revision(revision: saved.revision, state: saved.state)
            }
            var documents: [String: Data] = [:]
            let files = EvidenceFileStore(vaultURL: vaultURL)
            let states = [state] + revisions.filter(\.revision.recoverable).map(\.state)
            for snapshot in states {
                guard let vault = try snapshot.vault() else { continue }
                for document in VaultArchive.references(in: vault) where documents[document.digest] == nil {
                    documents[document.digest] = try files.read(document)
                }
            }
            return try VaultArchive.Contents(state: state, documents: documents, revisions: revisions, retention: readRetention())
        }
    }

    /// Cheap vault-only reads let the desktop check for external edits without loading all presets.
    public func vaultBytes() throws -> Data? {
        if let archive { return try archive.contents().state.vaultData }
        return try locked { try optionalData(vaultURL) }
    }

    @discardableResult
    public func commit(expected: String? = nil, summary: String, attachment: VaultAttachment? = nil,
                       _ edit: (inout VaultState) throws -> Void) throws -> VaultCommit {
        if let archive {
            return try archive.update { contents in
                let before = contents.state
                if let expected, expected != before.token { throw VaultStateConflict.stale }
                var after = before
                try edit(&after)
                guard before != after else { return (VaultCommit(changed: false, revision: nil), false) }
                if let attachment {
                    guard attachment.document.matches(attachment.bytes) else {
                        throw DataIssue("The evidence file does not match the reviewed document.")
                    }
                    contents.documents[attachment.document.digest] = attachment.bytes
                }
                return (try persistArchive(&contents, after: after, summary: summary), true)
            }
        }
        return try locked(create: true) {
            let before = try readState()
            if let expected, expected != before.token { throw VaultStateConflict.stale }
            var after = before
            try edit(&after)
            if before != after, let attachment {
                try EvidenceFileStore(vaultURL: vaultURL).save(attachment.bytes, for: attachment.document)
            }
            return try persist(before: before, after: after, summary: summary)
        }
    }

    public func history() throws -> [VaultRevision] {
        if let archive { return try archive.contents().revisions.map(\.revision) }
        return try locked { try revisionFiles().map { try readRevision($0).revision } }
    }

    public func revision(_ id: String) throws -> (revision: VaultRevision, state: VaultState) {
        if let archive {
            let saved = try archiveRevision(id, in: archive.contents())
            return (saved.revision, saved.state)
        }
        return try locked {
            let saved = try readRevision(id)
            return (saved.revision, saved.state)
        }
    }

    @discardableResult
    public func restore(_ id: String, expected: String) throws -> VaultCommit {
        if let archive {
            return try archive.update { contents in
                guard expected == contents.state.token else { throw VaultStateConflict.stale }
                let saved = try archiveRevision(id, in: contents)
                let result = try persistArchive(&contents, after: saved.state, summary: "Restore revision")
                return (result, result.changed)
            }
        }
        return try locked(create: true) {
            let before = try readState()
            guard expected == before.token else { throw VaultStateConflict.stale }
            let saved = try readRevision(id)
            guard saved.revision.recoverable else { throw DataIssue("This revision has no readable vault to restore.") }
            return try persist(before: before, after: saved.state, summary: "Restore revision")
        }
    }

    public func retention() throws -> Int {
        if let archive { return try archive.contents().retention }
        return try locked { try readRetention() }
    }

    /// Keep at least one readable state when the history contains one.
    public func prune(keeping count: Int, configure: Bool = false) throws {
        guard (1...500).contains(count) else { throw DataIssue("Keep between 1 and 500 revisions.") }
        if let archive {
            try archive.update { contents in
                let oldCount = contents.revisions.count
                let oldLimit = contents.retention
                if configure { contents.retention = count }
                if oldCount > count {
                    contents.revisions.removeLast(oldCount - count)
                    trimDocuments(&contents)
                }
                return ((), oldLimit != contents.retention || oldCount != contents.revisions.count)
            }
            return
        }
        try locked(create: configure) {
            if configure { try write(Data(String(count).utf8), to: limitURL) }
            try trimHistory(keeping: count)
        }
    }

    public func pruningCandidates(keeping count: Int) throws -> [String] {
        guard (1...500).contains(count) else { throw DataIssue("Keep between 1 and 500 revisions.") }
        if let archive { return try archive.contents().revisions.dropFirst(count).map(\.revision.id) }
        return try locked { try prunableRevisions(keeping: count) }
    }

    private func readRetention() throws -> Int {
        guard let data = try optionalData(limitURL) else { return Self.defaultRetention }
        guard let count = Int(String(decoding: data, as: UTF8.self)), (1...500).contains(count) else {
            throw DataIssue("The revision retention setting is invalid.")
        }
        return count
    }

    private func persist(before: VaultState, after: VaultState, summary: String) throws -> VaultCommit {
        guard before != after else { return VaultCommit(changed: false, revision: nil) }
        try validate(after)
        let head = try revisionFiles().first
        let revision = makeRevision(before: before, after: after, summary: summary, head: head)
        // Publishing this one private file is the commit point. A crash after it replays the same change.
        let journal = Journal(version: 1, before: Snapshot(revision: revision, state: before), after: after)
        try write(VaultState.encode(journal), to: journalURL)
        do { try replay(journal) }
        catch { throw DataIssue("The change was saved for recovery. Reopen VeraData or run the command again to recover it.") }
        // Retention is housekeeping and must not report an already-published transaction as failed.
        try? trimHistory(keeping: readRetention())
        return VaultCommit(changed: true, revision: before.vaultData == nil && before.presets.isEmpty ? nil : revision)
    }

    private func makeRevision(before: VaultState, after: VaultState, summary: String, head: String?) -> VaultRevision {
        let diff = StateDifference(before: before, after: after)
        let date = Date()
        let lastSequence = head.flatMap { Int64($0.prefix(16)) } ?? 0
        let sequence = max(Int64(date.timeIntervalSince1970 * 1_000_000), lastSequence + 1)
        let id = String(format: "%016lld", sequence) + "-" + UUID().uuidString.lowercased()
        return VaultRevision(id: id, date: date, summary: summary, records: diff.records,
                             presets: diff.presets, recoverable: (try? before.vault()) != nil)
    }

    private func archiveRevision(_ id: String, in contents: VaultArchive.Contents) throws -> VaultArchive.Revision {
        guard let saved = contents.revisions.first(where: { $0.revision.id == id }) else {
            throw DataIssue("Revision not found.")
        }
        return saved
    }

    private func persistArchive(_ contents: inout VaultArchive.Contents, after: VaultState,
                                  summary: String) throws -> VaultCommit {
        let before = contents.state
        guard before != after else { return VaultCommit(changed: false, revision: nil) }
        try validate(after)
        let revision = makeRevision(before: before, after: after, summary: summary, head: contents.revisions.first?.revision.id)
        contents.revisions.insert(VaultArchive.Revision(revision: revision, state: before), at: 0)
        contents.state = after
        if contents.revisions.count > contents.retention {
            contents.revisions.removeLast(contents.revisions.count - contents.retention)
        }
        trimDocuments(&contents)
        return VaultCommit(changed: true, revision: revision)
    }

    private func trimDocuments(_ contents: inout VaultArchive.Contents) {
        let states = [contents.state] + contents.revisions.map(\.state)
        let digests = Set(states.compactMap { try? $0.vault() }.flatMap { VaultArchive.references(in: $0) }.map(\.digest))
        contents.documents = contents.documents.filter { digests.contains($0.key) }
    }

    private func validate(_ state: VaultState) throws {
        _ = try state.vault()
        for (name, data) in state.presets {
            guard try ExportPreset.normalizedName(name) == name, data.count <= JSONValue.maxBytes else {
                throw DataIssue("Invalid preset filename or size.")
            }
        }
    }

    private func readState() throws -> VaultState {
        let names = try names(in: presetsFolder)
        var presets: [String: Data] = [:]
        for file in names where file.hasSuffix(".json") {
            let name = String(file.dropLast(5))
            guard (try? ExportPreset.normalizedName(name)) == name else { continue }
            let url = presetsFolder.appendingPathComponent(file)
            guard try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            presets[name] = try optionalData(url)
        }
        return VaultState(vaultData: try optionalData(vaultURL), presets: presets)
    }

    private func replay(_ journal: Journal) throws {
        guard journal.version == 1 else { throw DataIssue("The pending VeraData transaction format is unsupported.") }
        try validate(journal.after)
        let before = journal.before.state
        let after = journal.after
        let currentVault = try optionalData(vaultURL)
        guard currentVault == before.vaultData || currentVault == after.vaultData else { throw VaultStateConflict.stale }
        let changedPresets = Set(before.presets.keys).union(after.presets.keys).sorted().filter {
            before.presets[$0] != after.presets[$0]
        }
        var unfinished: [String] = []
        for name in changedPresets {
            guard try ExportPreset.normalizedName(name) == name else { throw DataIssue("Invalid preset filename.") }
            let current = try optionalData(presetsFolder.appendingPathComponent(name + ".json"))
            guard current == before.presets[name] || current == after.presets[name] else { throw VaultStateConflict.stale }
            if current != after.presets[name] { unfinished.append(name) }
        }
        let location = try revisionURL(journal.before.revision.id)
        if before.vaultData != nil || !before.presets.isEmpty {
            try write(VaultState.encode(journal.before), to: location)
        }

        if currentVault != after.vaultData {
            if let data = after.vaultData { try write(data, to: vaultURL) }
            else { try remove(vaultURL) }
            try afterVaultWrite?()
        }
        for name in unfinished {
            let path = presetsFolder.appendingPathComponent(name + ".json")
            if let data = after.presets[name] { try write(data, to: path) }
            else { try remove(path) }
        }
        try remove(journalURL)
    }

    private func locked<T>(create: Bool = false, _ operation: () throws -> T) throws -> T {
        guard !VaultArchive.isArchiveURL(vaultURL) else { throw DataIssue("Open the vault first.") }
        if create { try privateDirectory(folder) }
        let lockPath = folder.appendingPathComponent(".vault.lock").path
        var lock = open(lockPath, create ? O_CREAT | O_RDWR | O_NOFOLLOW : O_RDONLY | O_NOFOLLOW, 0o600)
        if lock < 0 && errno == ENOENT && !create {
            lock = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            if lock < 0 && (errno == ENOENT || errno == EACCES || errno == EPERM || errno == EROFS) {
                let result = try operation()
                guard !FileManager.default.fileExists(atPath: lockPath) else { throw VaultStateConflict.busy }
                return result
            }
        }
        guard lock >= 0 else { throw DataIssue("Unable to open the local vault lock.") }
        defer { close(lock) }
        guard flock(lock, (create ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw VaultStateConflict.busy }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            if !create {
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw VaultStateConflict.busy }
            }
            if let data = try optionalData(journalURL, bounded: false) {
                try replay(JSONDecoder().decode(Journal.self, from: data))
                try? trimHistory(keeping: readRetention())
            }
        }
        if create {
            for directory in [folder, historyFolder, presetsFolder] {
                for entry in try names(in: directory) where entry.hasPrefix(".veradata-write-") {
                    try remove(directory.appendingPathComponent(entry))
                }
            }
        }
        return try operation()
    }

    private func revisionFiles() throws -> [String] {
        try names(in: historyFolder).filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted(by: >)
    }

    private func revisionURL(_ id: String) throws -> URL {
        guard id.wholeMatch(of: #/[0-9]{16}-[a-f0-9-]{36}/#) != nil else { throw DataIssue("Invalid revision ID.") }
        return historyFolder.appendingPathComponent(id + ".json")
    }

    private func readRevision(_ id: String) throws -> Snapshot {
        guard let data = try optionalData(revisionURL(id), bounded: false) else { throw DataIssue("Revision not found.") }
        let saved = try JSONDecoder().decode(Snapshot.self, from: data)
        guard saved.revision.id == id else { throw DataIssue("The revision filename does not match its contents.") }
        return saved
    }

    private func trimHistory(keeping count: Int) throws {
        for id in try prunableRevisions(keeping: count) { try remove(revisionURL(id)) }
    }

    private func prunableRevisions(keeping count: Int) throws -> [String] {
        let ids = try revisionFiles()
        guard ids.count > count else { return [] }
        let keep = Array(ids.prefix(count))
        let older = ids.dropFirst(count)
        let hasRecovery = try keep.contains { try readRevision($0).revision.recoverable }
        let protected = hasRecovery ? nil : try older.first { try readRevision($0).revision.recoverable }
        return older.filter { $0 != protected }
    }

    private func names(in url: URL) throws -> [String] {
        do { return try FileManager.default.contentsOfDirectory(atPath: url.path) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return [] }
    }

    private func optionalData(_ url: URL, bounded: Bool = true) throws -> Data? {
        do { return try bounded ? VaultFile.readData(url) : Data(contentsOf: url) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return nil }
    }

    private func privateDirectory(_ path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try privateDirectory(parent)
        let temporary = parent.appendingPathComponent(".veradata-write-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DataIssue("Unable to create a private VeraData file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary); try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw DataIssue("Unable to replace a VeraData file.") }
        try syncDirectory(parent)
    }

    private func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 else {
            if errno == ENOENT { return }
            throw DataIssue("Unable to remove a VeraData file.")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else { throw DataIssue("Unable to open a VeraData storage directory.") }
        defer { close(descriptor) }
        if fsync(descriptor) != 0 && errno != EINVAL && errno != ENOTSUP {
            throw DataIssue("Unable to synchronize a VeraData storage directory.")
        }
    }
}
