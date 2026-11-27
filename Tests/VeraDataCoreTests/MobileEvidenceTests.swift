import Foundation
import Testing
@testable import VeraDataCore

struct MobileEvidenceTests {
    private let area = EvidenceRegion(x: 0.1, y: 0.25, width: 0.6, height: 0.2)

    @Test func transfersOnlyExplicitEvidenceAndReusesTheOriginalBytes() throws {
        let pdf = Data("Fictional PDF source".utf8)
        let image = Data("Fictional image source".utf8)
        let visible = EvidenceFileStore.document(for: pdf, name: "Fictional letter.pdf", kind: .pdf)
        let excluded = EvidenceFileStore.document(for: image, name: "Fictional image.png", kind: .image)
        var first = Record(id: "address", kind: .address, label: "Fictional address",
                           fields: ["city": .string("Example City"), "line1": .string("4 Example Street")])
        let mark = try EvidenceMark(document: visible, page: 2, region: area, record: first, keys: ["city", "line1"])
        first.evidence = [mark, try EvidenceMark(document: excluded, page: 0, region: area, record: first, keys: ["line1"])]
        var second = first
        second.evidence = [mark]
        let vault = Vault(profiles: [Profile(id: "first", name: "First", records: [first]),
                                     Profile(id: "second", name: "Second", records: [second])])
        let records: [Profile.ID: Set<Record.ID>] = ["first": ["address"], "second": ["address"]]
        let without = try MobileTransfer(vault: vault, selection: records)
        #expect(try JSONValue.parse(without.data()).object?["version"]?.scalarText == "1")
        #expect(without.profiles.allSatisfy { $0.records[0].evidence.isEmpty })

        let pick = MobileTransfer.EvidencePick(profileID: "first", recordID: "address", digest: visible.digest)
        let transfer = try MobileTransfer(vault: vault, selection: records, evidence: [pick]) { doc in
            #expect(doc == visible)
            return pdf
        }
        let reloaded = try MobileTransfer(data: transfer.data())
        #expect(reloaded == transfer)
        #expect(reloaded.evidenceDocumentCount == 1)
        #expect(reloaded.profiles[0].records[0].evidence == [mark])
        #expect(reloaded.profiles[1].records[0].evidence.isEmpty)
        #expect(reloaded.evidenceBytes(for: visible) == pdf)
        #expect(reloaded.evidenceBytes(for: excluded) == nil)

        let secondPick = MobileTransfer.EvidencePick(profileID: "second", recordID: "address", digest: visible.digest)
        var loads = 0
        let both = try MobileTransfer(vault: vault, selection: records, evidence: [pick, secondPick]) { _ in
            loads += 1
            return pdf
        }
        #expect(loads == 1)
        #expect(both.evidenceDocumentCount == 1)
        #expect(both.profiles.allSatisfy { $0.records[0].evidence == [mark] })
    }

    @Test func tamperedMissingAndUnreferencedEvidenceCannotBeImported() throws {
        let pdf = Data("Fictional PDF source".utf8)
        let document = EvidenceFileStore.document(for: pdf, name: "Fictional.pdf", kind: .pdf)
        var record = Record(id: "address", kind: .address, label: "Fictional address", fields: ["city": .string("Example City")])
        record.evidence = [try EvidenceMark(document: document, page: 0, region: area, record: record, keys: ["city"])]
        let vault = Vault(profiles: [Profile(id: "demo", name: "Fictional", records: [record])])
        let pick = MobileTransfer.EvidencePick(profileID: "demo", recordID: "address", digest: document.digest)
        let transfer = try MobileTransfer(vault: vault, selection: ["demo": ["address"]], evidence: [pick]) { _ in pdf }
        var envelope = try #require(JSONValue.parse(transfer.data()).object)
        envelope["documents"] = .object([document.digest: .string(Data("Tampered file".utf8).base64EncodedString())])
        #expect(throws: DataIssue.self) { try MobileTransfer(data: JSONValue.object(envelope).data()) }
        envelope["documents"] = .object([:])
        #expect(throws: DataIssue.self) { try MobileTransfer(data: JSONValue.object(envelope).data()) }
        envelope["documents"] = .object([document.digest: .string(pdf.base64EncodedString()),
                                         String(repeating: "a", count: 64): .string(pdf.base64EncodedString())])
        #expect(throws: DataIssue.self) { try MobileTransfer(data: JSONValue.object(envelope).data()) }
    }
}
