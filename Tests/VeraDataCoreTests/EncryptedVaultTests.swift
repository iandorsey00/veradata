import Foundation
import Testing
@testable import VeraDataCore

struct EncryptedVaultTests {
    private let passphrase = "Fictional vault passphrase for tests"

    @Test func completeCopiesPreserveCurrentAndHistoricalEvidenceAcrossFormats() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let localURL = folder.appendingPathComponent("vault.json")
        var local = VaultFile(url: localURL)
        _ = try local.load()
        let region = EvidenceRegion(x: 0, y: 0, width: 1, height: 1)
        var record = Record(id: "office", kind: .address, label: "Fictional office", fields: ["city": .string("Example City")])
        var vault = Vault(profiles: [Profile(id: "demo", name: "Fictional", records: [record]), Profile(name: "Second")], shortcut: .k)
        let historicalBytes = Data("Historical evidence fixture".utf8)
        let historical = EvidenceFileStore.document(for: historicalBytes, name: "Previous.pdf", kind: .pdf)
        record.evidence = [try EvidenceMark(document: historical, page: 0, region: region, record: record, keys: ["city"])]
        vault.profiles[0].records = [record]
        try local.save(vault, attachment: VaultAttachment(document: historical, bytes: historicalBytes))

        let currentBytes = Data("Current evidence fixture".utf8)
        let current = EvidenceFileStore.document(for: currentBytes, name: "Current.pdf", kind: .pdf)
        record.evidence = [try EvidenceMark(document: current, page: 0, region: region, record: record, keys: ["city"])]
        vault.profiles[0].records = [record]
        try local.save(vault, attachment: VaultAttachment(document: current, bytes: currentBytes))
        try local.stateStore.commit(summary: "Save fictional preset") { state in
            state.presets["sample"] = Data("Fictional preset fixture".utf8)
        }
        try local.stateStore.prune(keeping: 4, configure: true)
        let expectedState = try local.stateStore.snapshot()
        let expectedHistory = try local.stateStore.history().map(\.id)

        let plainURL = folder.appendingPathComponent("Plain.veradata")
        let encryptedURL = folder.appendingPathComponent("Copy.veradata")
        let decryptedURL = folder.appendingPathComponent("Decrypted.veradata")
        let plain = try VaultArchive.create(at: plainURL, copying: local.stateStore)
        let encrypted = try VaultArchive.create(at: encryptedURL, password: passphrase,
                                                copying: VaultStateStore(vaultURL: plainURL, archive: plain))
        _ = try VaultArchive.create(at: decryptedURL, copying: VaultStateStore(vaultURL: encryptedURL, archive: encrypted))
        for url in [plainURL, encryptedURL, decryptedURL] {
            let requiresPassword = try VaultArchive.requiresPassword(at: url)
            #expect(requiresPassword == (url == encryptedURL))
            let archive = try VaultArchive.open(url, password: requiresPassword ? passphrase : nil)
            let source = VaultStateStore(vaultURL: url, archive: archive)
            #expect(try source.snapshot() == expectedState)
            #expect(try source.history().map(\.id) == expectedHistory)
            #expect(try source.retention() == 4)
            let evidence = EvidenceFileStore(vaultURL: url, archive: archive)
            #expect(try evidence.read(current) == currentBytes)
            #expect(try evidence.read(historical) == historicalBytes)
            #expect(!FileManager.default.fileExists(atPath: url.path + ".evidence"))
        }
        #expect(try local.stateStore.snapshot() == expectedState)
        #expect(throws: DataIssue.self) { try VaultArchive.open(encryptedURL) }
        #expect(throws: VaultStateConflict.self) { try VaultArchive.open(plainURL, password: passphrase) }
        let obsolete = folder.appendingPathComponent("Old.veradatavault")
        try FileManager.default.copyItem(at: plainURL, to: obsolete)
        #expect(!VaultArchive.isArchiveURL(obsolete))
        #expect(throws: DataIssue.self) { try VaultArchive.open(obsolete) }

        #expect(throws: DataIssue.self) { try VaultArchive.create(at: plainURL, copying: local.stateStore) }
        #expect(throws: DataIssue.self) { try VaultStateStore(vaultURL: plainURL).snapshot() }

        let records = try Vault(data: vault.recordsBackupData())
        record.evidence = []
        vault.profiles[0].records = [record]
        #expect(records == vault)
    }

    @Test func migratesRecordsPresetsAndEvidenceAndKeepsBackupsEncrypted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = folder.appendingPathComponent("vault.json")
        let destination = folder.appendingPathComponent("Work.veradata")
        let backup = folder.appendingPathComponent("Work-Backup.veradata")
        var address = Record(id: "address", kind: .address, label: "Fictional office", fields: ["city": .string("Example City")])
        let evidenceBytes = Data("Fictional evidence content".utf8)
        let document = EvidenceFileStore.document(for: evidenceBytes, name: "Fictional.pdf", kind: .pdf)
        address.evidence = [try EvidenceMark(document: document, page: 0,
                              region: EvidenceRegion(x: 0, y: 0, width: 1, height: 1), record: address, keys: ["city"])]
        let vault = Vault(profiles: [Profile(id: "demo", name: "Fictional", records: [address])])
        var local = VaultFile(url: original)
        _ = try local.load()
        try local.save(vault, attachment: VaultAttachment(document: document, bytes: evidenceBytes))
        try local.stateStore.commit(summary: "Save fictional preset fixture") { state in
            state.presets["sample"] = Data("Fictional preset bytes".utf8)
        }
        let source = try local.stateStore.snapshot()

        let encrypted = try EncryptedVault.create(at: destination, password: passphrase, copying: local.stateStore)
        #expect(try local.stateStore.snapshot() == source)
        let ciphertext = try Data(contentsOf: destination)
        #expect(ciphertext.range(of: Data("Fictional".utf8)) == nil)
        #expect(ciphertext.range(of: evidenceBytes) == nil)
        let reopened = try EncryptedVault.open(destination, password: passphrase)
        var file = VaultFile(url: destination, encrypted: reopened)
        #expect(try file.load() == vault)
        #expect(try file.stateStore.snapshot().presets == source.presets)
        #expect(try EvidenceFileStore(vaultURL: destination, encrypted: reopened).read(document) == evidenceBytes)
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".evidence"))
        #expect(!FileManager.default.fileExists(atPath: destination.path + ".history"))

        try encrypted.backup(to: backup)
        #expect(try Data(contentsOf: backup) == ciphertext)
        #expect(try EncryptedVault.open(backup, password: passphrase).contents().state.vault() == vault)
        #expect(throws: DataIssue.self) { try encrypted.backup(to: backup) }
        #expect(throws: DataIssue.self) { try EncryptedVault.open(destination, password: "Different fictional password") }

        var damaged = ciphertext
        damaged[damaged.count - 1] ^= 1
        let broken = folder.appendingPathComponent("Damaged.veradata")
        try damaged.write(to: broken)
        #expect(throws: DataIssue.self) { try EncryptedVault.open(broken, password: passphrase) }
        #expect(throws: DataIssue.self) { try VaultStateStore(vaultURL: destination).snapshot() }
    }

    @Test func independentVaultsRejectStaleEditsAndRestoreEncryptedRevisions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let workURL = folder.appendingPathComponent("Work.veradata")
        let projectURL = folder.appendingPathComponent("Project-7.veradata")
        let work = try EncryptedVault.create(at: workURL, password: passphrase)
        let project = try EncryptedVault.create(at: projectURL, password: passphrase)
        var first = VaultFile(url: workURL, encrypted: work)
        let other = try EncryptedVault.open(workURL, password: passphrase)
        var second = VaultFile(url: workURL, encrypted: other)
        let firstVersion = try first.load()
        let secondVersion = try second.load()
        var proposed = try #require(firstVersion)
        var stale = try #require(secondVersion)
        proposed.profiles[0].name = "Fictional updated"
        try first.save(proposed)
        #expect(try second.hasExternalChanges())
        stale.profiles[0].name = "Fictional stale"
        #expect(throws: VaultStateConflict.self) { try second.save(stale) }
        #expect(try second.load() == proposed)
        #expect(try project.contents().state.vault()?.profiles[0].name == "Personal")
        let state = first.stateStore
        let revision = try #require(state.history().first)
        try state.restore(revision.id, expected: state.snapshot().token)
        #expect(try first.load()?.profiles[0].name == "Personal")
        #expect(try state.history().count == 2)
    }

    @Test func createsAndRemovesEvidenceInTheSameEncryptedTransaction() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Database.veradata")
        let encrypted = try EncryptedVault.create(at: url, password: passphrase)
        var file = VaultFile(url: url, encrypted: encrypted)
        let opened = try file.load()
        var vault = try #require(opened)
        var address = Record(id: "address", kind: .address, label: "Fictional office", fields: ["city": .string("Example City")])
        let bytes = Data("Fictional evidence".utf8)
        let document = EvidenceFileStore.document(for: bytes, name: "Fictional.pdf", kind: .pdf)
        address.evidence = [try EvidenceMark(document: document, page: 0, region: .init(x: 0, y: 0, width: 1, height: 1),
                                              record: address, keys: ["city"])]
        vault.profiles[0].records = [address]
        let previous = try Data(contentsOf: url)
        #expect(throws: DataIssue.self) { try file.save(vault) }
        #expect(try Data(contentsOf: url) == previous)
        try file.save(vault, attachment: VaultAttachment(document: document, bytes: bytes))
        #expect(try encrypted.contents().documents[document.digest] == bytes)
        vault.profiles[0].records = []
        try file.save(vault)
        #expect(try encrypted.contents().documents[document.digest] == bytes)
        vault.profiles[0].name = "Fictional new name"
        try file.save(vault)
        try file.stateStore.prune(keeping: 1)
        #expect(try encrypted.contents().documents.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Database.veradata"])
    }
}
