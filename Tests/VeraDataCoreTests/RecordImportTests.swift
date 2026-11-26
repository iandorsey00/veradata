import Foundation
import Testing
@testable import VeraDataCore

struct RecordImportTests {
    private let job = Record(id: "job", kind: .employment, label: "Support at Example", fields: [
        "employer": .string("Example Inc"), "title": .string("Support Engineer"),
        "startDate": .string("2024-03"), "phone": .string("00123"),
        "responsibilities": .array([.string("Keep reports")]),
    ], aliases: [";title": "title"])
    private let existing = Record(id: "untouched", kind: .custom, label: "Untouched", fields: ["code": .string("0007")])

    @Test func importsAllVeraDataFormatsAndPlainObjects() throws {
        let profile = Profile(name: "Personal", records: [job, existing])
        let vault = Vault(profiles: [profile], shortcut: .off)
        let backup = try RecordImport(data: vault.data())
        #expect(backup.profiles == [profile])
        let phone = try MobileTransfer(vault: vault, selection: [profile.id: [existing.id]])
        #expect(try RecordImport(data: phone.data()).profiles[0].records == [existing])
        let selected = try SelectiveExport.data(from: profile, selection: [.init(id: job.id, fields: ["title": .whole])], format: .structured)
        let imported = try RecordImport(data: selected).profiles[0].records[0]
        #expect(imported.kind == .employment)
        #expect(imported.fields == ["title": .string("Support Engineer")])
        let flat = try RecordImport(data: Data(#"{"code":"0007","empty":"","unknown":null,"list":[false,{"note":"中文"}]}"#.utf8),
                                    fallbackLabel: "Equipment")
        let flatRecord = flat.profiles[0].records[0]
        #expect(flatRecord.kind == .custom)
        #expect(flatRecord.label == "Equipment")
        #expect(flatRecord.fields["code"] == .string("0007"))
        #expect(flatRecord.fields["empty"] == .string(""))
        #expect(flatRecord.fields["unknown"] == .null)
        #expect(flatRecord.fields["list"]?.array?.last?.object?["note"] == .string("中文"))
    }

    @Test func possibleEmploymentMatchesNeverUpdateAutomatically() throws {
        let second = Record(id: "second", kind: .employment, label: "Later job", fields: [
            "employer": .string("Example Inc"), "title": .string("Team Lead"), "startDate": .string("2025"),
        ])
        let incoming = Record(id: "new-job", kind: .employment, label: "Imported label", fields: [
            "employer": .string("EXAMPLE INC"), "title": .string("Support Engineer"), "startDate": .string("2024"),
            "endDate": .string("Present"), "location": .string("Irvine"),
        ])
        let profile = Profile(name: "Existing", records: [second, job, existing])
        let review = RecordImportReview(source: Profile(name: "Input", records: [incoming]), destination: profile)
        #expect(review.possibleMatches(for: incoming) == [job.id, second.id])
        #expect(review.initialDecision(for: incoming) == .skip)
        #expect(try review.applying([:]) == profile)
        let result = try review.applying([incoming.id: .update(job.id, fields: ["location", "endDate"])])
        #expect(result.records.map(\.id) == profile.records.map(\.id))
        #expect(result.records[0] == second && result.records[2] == existing)
        #expect(result.records[1].aliases == job.aliases)
        #expect(result.records[1].label == job.label)
        #expect(result.records[1].fields["startDate"] == .string("2024-03"))
        #expect(result.records[1].fields["responsibilities"] == job.fields["responsibilities"])
        #expect(result.records[1].fields["location"] == .string("Irvine"))
        #expect(result.records[1].fields["endDate"] == .string("Present"))
    }

    @Test func addedIdentifierConflictDoesNotReplaceExistingRecord() throws {
        let incoming = Record(id: job.id, kind: .employment, label: "New job", fields: ["title": .string("New title")])
        let review = RecordImportReview(source: Profile(name: "Incoming", records: [incoming]),
                                        destination: Profile(name: "Existing", records: [job]))
        #expect(review.initialDecision(for: incoming) == .skip)
        let result = try review.applying([incoming.id: .add])
        #expect(result.records.count == 2)
        #expect(result.records[0] == job)
        #expect(result.records[1].id != job.id)
        #expect(throws: DataIssue.self) { try review.applying([incoming.id: .update(job.id, fields: ["missing"])]) }
    }

    @Test func importAcceptsPresentOnlyForEmploymentEndDate() throws {
        let json = #"{"format":"veradata-import","version":1,"records":[{"kind":"employment","fields":{"startDate":"2024-03","endDate":"至今","employer":"Example Inc"}}]}"#
        let parsed = try RecordImport(data: Data(json.utf8))
        let record = parsed.profiles[0].records[0]
        #expect(record.label == "Example Inc")
        #expect(record.fields["endDate"] == .string("Present"))
        #expect(record.fields["startDate"] == .string("2024-03"))
        #expect(try Vault(data: Vault(profiles: parsed.profiles).data()).profiles[0].records[0] == record)
        let education = json.replacingOccurrences(of: "employment", with: "education")
        #expect(throws: DataIssue.self) { try RecordImport(data: Data(education.utf8)) }
        let future = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")
        #expect(throws: DataIssue.self) { try RecordImport(data: Data(future.utf8)) }
    }

    @Test func explicitlyReplacingWithNullDoesNotCopyOmittedFieldsOrCrossRecordKinds() throws {
        let first = Record(kind: .employment, label: "Update one", fields: ["title": .null])
        let second = Record(kind: .employment, label: "Update two", fields: ["title": .string("Another title")])
        let review = RecordImportReview(source: Profile(name: "Incoming", records: [first, second]),
                                        destination: Profile(name: "Existing", records: [job, existing]))
        let result = try review.applying([first.id: .update(job.id, fields: ["title"])])
        #expect(result.records[0].fields["title"] == .null)
        #expect(result.records[0].fields["employer"] == job.fields["employer"])
        #expect(throws: DataIssue.self) { try review.applying([first.id: .update(existing.id, fields: ["title"])]) }
        #expect(throws: DataIssue.self) {
            try review.applying([first.id: .update(job.id, fields: ["title"]), second.id: .update(job.id, fields: ["title"])])
        }
    }
}
