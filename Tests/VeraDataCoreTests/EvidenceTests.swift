import Foundation
import Testing
@testable import VeraDataCore

struct EvidenceTests {
    @Test func oneAreaChecksAddressFieldsIndependentlyAndStaysPrivate() throws {
        var address = Record(id: "address", kind: .address, label: "Fictional address",
                             fields: ["line1": .string("4 Example Street"), "city": .string("Example City"),
                                      "postalCode": .string("00123")])
        let document = EvidenceFileStore.document(for: Data("fictional file".utf8), name: "Fictional letter.pdf", kind: .pdf)
        let region = EvidenceRegion(x: 0.1, y: 0.2, width: 0.6, height: 0.15)
        let mark = try EvidenceMark(document: document, page: 1, region: region, record: address,
                                    keys: ["line1", "city", "postalCode"])
        address.evidence = [mark]
        let vault = Vault(profiles: [Profile(id: "demo", name: "Fictional", records: [address])])
        var reloaded = try #require(Vault(data: vault.data()).profiles.first?.records.first)
        #expect(reloaded == address)
        #expect(reloaded.evidence[0].matches("postalCode", in: reloaded))
        reloaded.fields["postalCode"] = .string("00124")
        #expect(!reloaded.evidence[0].matches("postalCode", in: reloaded))
        #expect(reloaded.evidence[0].matches("city", in: reloaded))
        #expect(reloaded.evidence[0].matches("line1", in: reloaded))
        #expect(reloaded.json.object?["evidence"] == nil)
        let transfer = try MobileTransfer(vault: vault, selection: ["demo": ["address"]])
        #expect(try MobileTransfer(data: transfer.data()) == transfer)
        #expect(transfer.profiles[0].records[0].evidence.isEmpty)
        #expect(!String(decoding: try transfer.data(), as: UTF8.self).contains(document.name))
        #expect(throws: DataIssue.self) {
            try EvidenceMark(document: document, page: 0,
                             region: EvidenceRegion(x: 0.9, y: 0, width: 0.2, height: 1),
                             record: address, keys: ["line1"])
        }
    }

    @Test func localCopiesDeduplicateDetectTamperingAndSurviveRestoringALink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("vault.json")
        let files = EvidenceFileStore(vaultURL: url)
        let bytes = Data("fictional document".utf8)
        let document = EvidenceFileStore.document(for: bytes, name: "Fictional.png", kind: .image)
        try files.save(bytes, for: document)
        try files.save(bytes, for: document)
        let copies = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        #expect(copies == [document.digest])
        let path = files.directory.appendingPathComponent(document.digest)
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        var address = Record(id: "address", kind: .address, label: "Fictional address", fields: ["city": .string("Example City")])
        address.evidence = [try EvidenceMark(document: document, page: 0,
                              region: EvidenceRegion(x: 0, y: 0, width: 1, height: 1), record: address, keys: ["city"])]
        var vault = Vault(profiles: [Profile(id: "demo", name: "Fictional", records: [address])])
        var file = VaultFile(url: url)
        _ = try file.load()
        try file.save(vault)
        vault.profiles[0].records[0].evidence = []
        try file.save(vault)
        let state = VaultStateStore(vaultURL: url)
        let revision = try #require(state.history().first)
        try state.restore(revision.id, expected: state.snapshot().token)
        #expect(try file.load()?.profiles[0].records[0].evidence == address.evidence)
        #expect(try files.read(document) == bytes)
        try Data("edited".utf8).write(to: path)
        #expect(throws: DataIssue.self) { try files.read(document) }
    }
}
