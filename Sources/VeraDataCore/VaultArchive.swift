import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

public struct VaultAttachment: Sendable {
    public let document: EvidenceDocument
    public let bytes: Data

    public init(document: EvidenceDocument, bytes: Data) {
        self.document = document
        self.bytes = bytes
    }
}

public typealias EncryptedVault = VaultArchive

/// A complete working vault stored in one file. Passwords are used only to derive a key.
public struct VaultArchive: Sendable {
    struct Revision: Codable {
        let revision: VaultRevision
        let state: VaultState
    }

    struct Contents: Codable {
        var state: VaultState
        var documents: [String: Data]
        var revisions: [Revision] = []
        var retention: Int = VaultStateStore.defaultRetention
    }

    public static let fileExtension = "veradata"
    public static let plainFileExtension = "veradatavault"
    private static let magic = Data("VERADATA\u{01}".utf8)
    private static let plainHeader = Data("VERADATAVAULT\u{01}".utf8)
    private static let saltLength = 16
    private static let maxBytes = 256 * 1024 * 1024
    private let header: Data
    private let key: SymmetricKey?
    public let url: URL

    public static func isEncryptedURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    public static func isArchiveURL(_ url: URL) -> Bool {
        isEncryptedURL(url) || url.pathExtension.lowercased() == plainFileExtension
    }

    public static func open(_ url: URL, password: String? = nil) throws -> Self {
        try checkFormat(url, password: password)
        return try coordinate(url) { location in
            let bytes = try readFile(location)
            let file: Self
            if let password {
                let header = try readEncryptedHeader(bytes)
                file = Self(header: header, key: try derive(password, salt: Data(header.suffix(saltLength))), url: url)
            } else {
                file = Self(header: plainHeader, key: nil, url: url)
            }
            _ = try file.decode(bytes)
            return file
        }
    }

    public static func create(at url: URL, password: String? = nil, copying source: VaultStateStore? = nil,
                              initialVault: Vault = Vault()) throws -> Self {
        try checkFormat(url, password: password)
        let file: Self
        if let password {
            guard password.count >= 12 else { throw DataIssue("Use a vault password with at least 12 characters.") }
            var salt = Data(count: saltLength)
            let random = salt.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard random == errSecSuccess else { throw DataIssue("Unable to generate a vault salt.") }
            file = Self(header: magic + salt, key: try derive(password, salt: salt), url: url)
        } else {
            file = Self(header: plainHeader, key: nil, url: url)
        }
        let contents = try source?.completeContents(initialVault: initialVault)
            ?? Contents(state: VaultState(vaultData: initialVault.data(), presets: [:]), documents: [:])
        let bytes = try file.encode(contents)
        try coordinate(url, writing: []) { try publish(bytes, at: $0, replacing: false) }
        return file
    }

    public func backup(to destination: URL) throws {
        guard destination.pathExtension.lowercased() == url.pathExtension.lowercased() else {
            throw DataIssue("Use the same filename extension as the source vault.")
        }
        let bytes = try backupData()
        try Self.coordinate(destination, writing: []) { try Self.publish(bytes, at: $0, replacing: false) }
    }

    public func backupData() throws -> Data {
        try Self.coordinate(url) { location in
            let bytes = try Self.readFile(location)
            _ = try decode(bytes)
            return bytes
        }
    }

    func contents() throws -> Contents {
        try Self.coordinate(url) { try decode(Self.readFile($0)) }
    }

    func update<T>(_ edit: (inout Contents) throws -> (result: T, changed: Bool)) throws -> T {
        try Self.coordinate(url, writing: .forReplacing) { location in
            try Self.checkConflicts(location)
            let original = try Self.readFile(location)
            var contents = try decode(original)
            let outcome = try edit(&contents)
            if outcome.changed {
                let updated = try encode(contents)
                try Self.checkConflicts(location)
                guard try Self.readFile(location) == original else { throw VaultStateConflict.stale }
                try Self.publish(updated, at: location, replacing: true)
            }
            return outcome.result
        }
    }

    static func references(in vault: Vault) -> [EvidenceDocument] {
        vault.profiles.flatMap(\.records).flatMap(\.evidence).map(\.document)
    }

    private static func checkFormat(_ url: URL, password: String?) throws {
        if isEncryptedURL(url) {
            guard password != nil else { throw DataIssue("Unlock the encrypted vault first.") }
        } else {
            guard url.pathExtension.lowercased() == plainFileExtension else {
                throw DataIssue("Choose a .veradatavault or .veradata file.")
            }
            guard password == nil else { throw DataIssue("Use the .veradata filename extension.") }
        }
    }

    private static func checkConflicts(_ url: URL) throws {
        if !(NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).isEmpty {
            throw VaultStateConflict.cloud
        }
    }

    private static func coordinate<T>(_ url: URL, writing: NSFileCoordinator.WritingOptions? = nil,
                                      _ work: (URL) throws -> T) throws -> T {
        let resolved = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        if !isCloudLocation(resolved) { return try localLock(resolved, write: writing != nil, work) }
        var error: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        if let writing {
            coordinator.coordinate(writingItemAt: url, options: writing, error: &error) { location in
                result = Result { try work(location) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { location in
                result = Result { try work(location) }
            }
        }
        if let error { throw error }
        guard let result else { throw DataIssue("Unable to coordinate access to the vault.") }
        return try result.get()
    }

    private static func isCloudLocation(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { return true }
        let path = url.path
        return path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/")
    }

    private static func localLock<T>(_ url: URL, write: Bool, _ work: (URL) throws -> T) throws -> T {
        let folder = URL.temporaryDirectory.appendingPathComponent("VeraData-Encrypted-Locks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let lock = Darwin.open(folder.appendingPathComponent(digest).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw DataIssue("Unable to open the local vault lock.") }
        defer { close(lock) }
        guard flock(lock, (write ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else { throw VaultStateConflict.busy }
        return try work(url)
    }

    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        let input = Data(password.utf8)
        guard !input.isEmpty, input.count <= 4096 else { throw DataIssue("Enter a valid vault password.") }
        var output = Data(count: 32)
        let status = output.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                input.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress,
                                          input.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                                          out.bindMemory(to: UInt8.self).baseAddress, out.count)
                }
            }
        }
        guard status == kCCSuccess else { throw DataIssue("Unable to derive the vault encryption key.") }
        return SymmetricKey(data: output)
    }

    private static func readEncryptedHeader(_ bytes: Data) throws -> Data {
        let length = magic.count + saltLength
        guard bytes.count >= length + 28, bytes.starts(with: magic) else {
            throw DataIssue("This file is not a supported encrypted VeraData vault.")
        }
        return Data(bytes.prefix(length))
    }

    private func decode(_ bytes: Data) throws -> Contents {
        let plaintext: Data
        if let key {
            guard try Self.readEncryptedHeader(bytes) == header else { throw VaultStateConflict.stale }
            do {
                let sealed = try AES.GCM.SealedBox(combined: bytes.dropFirst(header.count))
                plaintext = try AES.GCM.open(sealed, using: key, authenticating: header)
            } catch { throw DataIssue("The vault password is incorrect or the file is damaged.") }
        } else {
            guard bytes.starts(with: header) else { throw DataIssue("This file is not a supported unencrypted VeraData vault.") }
            plaintext = Data(bytes.dropFirst(header.count))
        }
        let contents = try JSONDecoder().decode(Contents.self, from: plaintext)
        try validate(contents)
        return contents
    }

    private func encode(_ contents: Contents) throws -> Data {
        try validate(contents)
        let plaintext = try VaultState.encode(contents)
        let overhead = header.count + (key == nil ? 0 : 28)
        guard plaintext.count <= Self.maxBytes - overhead else {
            throw DataIssue("The vault is full. Back it up, then prune revisions or remove evidence.")
        }
        guard let key else { return header + plaintext }
        guard let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header).combined else {
            throw DataIssue("Unable to encrypt the vault.")
        }
        return header + sealed
    }

    private func validate(_ contents: Contents) throws {
        guard (1...500).contains(contents.retention), let vault = try contents.state.vault() else {
            throw DataIssue("The vault contents are invalid.")
        }
        for document in Self.references(in: vault) {
            guard let bytes = contents.documents[document.digest], !bytes.isEmpty else {
                throw DataIssue("A document referenced by the vault is missing.")
            }
        }
    }

    private static func readFile(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 && errno == ENOENT {
            throw DataIssue("The vault is missing or has not downloaded. Check the file in Finder.")
        }
        guard descriptor >= 0 else { throw DataIssue("Unable to open the vault.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw DataIssue("Choose a regular vault file.")
        }
        let data = try file.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw DataIssue("The vault exceeds the size limit.") }
        return data
    }

    private static func publish(_ bytes: Data, at url: URL, replacing: Bool) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".veradata-vault-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DataIssue("Unable to create a vault file in this folder.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); unlink(temporary.path) }
        try file.write(contentsOf: bytes)
        try file.synchronize()
        let result = replacing ? rename(temporary.path, url.path) : renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            if errno == EEXIST { throw DataIssue("A file with that name already exists. Choose another name.") }
            throw DataIssue("Unable to save the vault.")
        }
        let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY)
        if directory >= 0 {
            _ = fsync(directory)
            close(directory)
        }
    }
}
