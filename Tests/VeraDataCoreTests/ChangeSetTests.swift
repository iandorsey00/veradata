import Foundation
import Testing
@testable import VeraDataCore

struct ChangeSetTests {
    private enum Interruption: Error { case stopped }

    private func fixture(at directory: URL) throws -> VaultStateStore {
        let url = directory.appending(path: "vault.json")
        var vaultFile = VaultFile(url: url)
        _ = try vaultFile.load()
        let profile = Profile(id: "demo", name: "Fictional Demo", records: [
            Record(id: "contact", kind: .contact, label: "Fictional contact", fields: ["name": .string("Alex Example")]),
            Record(id: "job", kind: .employment, label: "Fictional job",
                   fields: ["title": .string("Coordinator"), "responsibilities": .array([.string("Prepared a guide.")])]),
        ])
        try vaultFile.save(Vault(profiles: [profile]))
        let preset = try ExportPreset(name: "demo-resume", profile: profile, selection: [
            .init(id: "contact", fields: ["name": .whole]),
            .init(id: "job", fields: ["title": .whole, "responsibilities": .whole]),
        ], format: .veraFlowResume)
        try ExportPresetStore(vaultURL: url).save(preset)
        return VaultStateStore(vaultURL: url)
    }

    private func changes() throws -> ChangeSet {
        try ChangeSet(data: Data("""
        {"version":1,"profile":"demo","operations":[
          {"operation":"record.update","record":"contact","fields":{"headline":"Operations Associate"}},
          {"operation":"record.update","record":"job","fields":{"responsibilities":["Revised the guide.","Checked records."]}},
          {"operation":"preset.update","preset":"demo-resume","record":"contact","fields":{"headline":true}}
        ]}
        """.utf8))
    }

    @Test func transactionReviewsCommitsAndRestoresBothFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixture(at: directory)
        let before = try store.snapshot()
        let previousHistory = try store.history().count
        let change = try changes()
        let review = try change.preview(in: before)
        #expect(review.changed)
        #expect(review.difference.entries.count == 3)
        #expect(try store.snapshot() == before)
        #expect(try store.history().count == previousHistory)
        let result = try change.commit(to: store, expected: review.token)
        let revision = try #require(result.revision)
        let after = try store.snapshot()
        let savedVault = try after.vault()
        let vault = try #require(savedVault)
        let output = try after.preset("demo-resume").data(from: vault)
        #expect(String(decoding: output, as: UTF8.self).contains("Operations Associate"))
        #expect(try store.history().count == previousHistory + 1)
        #expect(throws: VaultStateConflict.self) { try change.commit(to: store, expected: review.token) }
        let noOp = try change.preview(in: after)
        #expect(!noOp.changed)
        #expect(try change.commit(to: store, expected: noOp.token).changed == false)
        #expect(try store.history().count == previousHistory + 1)
        _ = try store.restore(revision.id, expected: after.token)
        #expect(try store.snapshot() == before)
        let newest = try #require(store.history().first)
        #expect(try store.revision(newest.id).state == after)
        let url = directory.appending(path: "vault.json.history").appending(path: newest.id + ".json")
        let permission = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permission == 0o600)
        try store.prune(keeping: 1, configure: true)
        #expect(try store.history().count == 1)
        #expect(try store.retention() == 1)
    }

    @Test func interruptedCommitReplaysExactlyOnceAndInvalidChangesDoNotWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var store = try fixture(at: directory)
        let before = try store.snapshot()
        let count = try store.history().count
        let invalid = try ChangeSet(data: Data("""
        {"version":1,"profile":"demo","operations":[
          {"operation":"record.update","record":"contact","fields":{"headline":"Draft change"}},
          {"operation":"record.update","record":"job","fields":{"startDate":"invalid"}}
        ]}
        """.utf8))
        #expect(throws: DataIssue.self) { try invalid.preview(in: before) }
        #expect(try store.snapshot() == before)
        #expect(try store.history().count == count)

        let change = try changes()
        let token = try change.preview(in: before).token
        store.afterVaultWrite = { throw Interruption.stopped }
        #expect(throws: DataIssue.self) { try change.commit(to: store, expected: token) }
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "vault.json.history/.pending").path))
        let reopened = VaultStateStore(vaultURL: store.vaultURL)
        let state = try reopened.snapshot()
        #expect(try state.vault()?.profiles[0].records[0].fields["headline"] == .string("Operations Associate"))
        let definition = try state.preset("demo-resume").definition()
        #expect(definition.records[0].fields["headline"] == .whole)
        #expect(try reopened.history().count == count + 1)
        #expect(try reopened.snapshot() == state)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "vault.json.history/.pending").path))
    }

    @Test func presetPatchDoesNotReapproveAnUntouchedSelectiveList() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try fixture(at: directory)
        var file = VaultFile(url: store.vaultURL)
        let savedVault = try file.load()
        var vault = try #require(savedVault)
        let presets = ExportPresetStore(vaultURL: store.vaultURL)
        try presets.save(ExportPreset(name: "selective", profile: vault.profiles[0], selection: [
            .init(id: "contact", fields: ["name": .whole]),
            .init(id: "job", fields: ["title": .whole, "responsibilities": .items([0])]),
        ], format: .veraFlowResume))
        vault.profiles[0].records[1].fields["responsibilities"] = .array([.string("Different item.")])
        try file.save(vault)
        let change = try ChangeSet(data: Data("""
        {"version":1,"profile":"demo","operations":[
          {"operation":"preset.update","preset":"selective","record":"job","fields":{"title":false}}
        ]}
        """.utf8))
        let review = try change.preview(in: store.snapshot())
        _ = try change.commit(to: store, expected: review.token)
        let preset = try presets.load("selective")
        #expect(throws: DataIssue.self) { try preset.data(from: vault) }
    }
}
