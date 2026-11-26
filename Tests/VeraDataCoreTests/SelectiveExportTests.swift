import Foundation
import Testing
@testable import VeraDataCore

struct SelectiveExportTests {
    private let contact = Record(id: "contact", kind: .contact, label: "Hidden name", fields: [
        "name": .string("Morgan Example"), "email": .string("morgan@example.com"),
        "phone": .string("+1 202 555 0100"),
    ])
    private let job = Record(id: "job", kind: .employment, label: "Hidden employer label", fields: [
        "employer": .string("Juniper [Labs]"), "title": .string("Operations Lead"),
        "startDate": .string("2024"), "endDate": .null,
        "responsibilities": .array([.string("Kept reports"), .string("Private draft"), .string("Led <reviews>")]),
        "supervisor": .string("Unselected supervisor"),
        "metadata": .object(["id": .string("00123"), "empty": .string("")]),
    ], aliases: [";hidden": "title"])
    private let education = Record(id: "education", kind: .education, label: "Hidden school label", fields: [
        "institution": .string("Fictional College"), "qualification": .string("BS"),
    ])

    private var profile: Profile { Profile(id: "private-profile", name: "Private profile", records: [contact, job, education]) }

    @Test func structuredSelectionKeepsTypesAndExplicitOrder() throws {
        let data = try SelectiveExport.data(from: profile, selection: [
            .init(id: education.id, fields: ["institution": .whole]),
            .init(id: job.id, fields: ["responsibilities": .items([2, 0]), "metadata": .whole, "endDate": .whole]),
        ], format: .structured)
        let result = try #require(JSONValue.parse(data).object)
        let records = try #require(result["records"]?.array)
        #expect(result["format"] == .string("veradata-selection"))
        #expect(records.compactMap { $0.object?["kind"]?.string } == ["education", "employment"])
        #expect(records[1].object?["fields"]?.object == [
            "responsibilities": .array([.string("Kept reports"), .string("Led <reviews>")]),
            "endDate": .null,
            "metadata": .object(["id": .string("00123"), "empty": .string("")]),
        ])
        let json = String(decoding: data, as: UTF8.self)
        for omitted in ["Hidden", "Private", "contact", "supervisor", "aliases", "Juniper"] {
            #expect(!json.contains(omitted))
        }
    }

    @Test func resumeSelectionProducesFlatLiteralMarkdown() throws {
        let data = try SelectiveExport.data(from: profile, selection: [
            .init(id: contact.id, fields: ["name": .whole, "phone": .whole]),
            .init(id: job.id, fields: ["employer": .whole, "title": .whole, "startDate": .whole, "responsibilities": .items([2])]),
            .init(id: education.id, fields: ["institution": .whole]),
        ], format: .veraFlowResume)
        let result = try #require(JSONValue.parse(data).object)
        #expect(result["name"] == .string("Morgan Example"))
        #expect(result["phone"] == .string("+1 202 555 0100"))
        #expect(result["experience_markdown"] == .string(#"""
        ### Operations Lead · Juniper \[Labs\]
        2024

        - Led \<reviews\>
        """#))
        #expect(result["education_markdown"] == .string("### Fictional College"))
        #expect(result["email"] == nil)
        #expect(result.values.allSatisfy { $0.string != nil })
    }

    @Test func singleRecordFormatRetainsExistingFlatContract() throws {
        let data = try SelectiveExport.data(from: profile, selection: [
            .init(id: job.id, fields: ["title": .whole, "endDate": .whole]),
        ], format: .flatRecord)
        #expect(try JSONValue.parse(data) == .object(["title": .string("Operations Lead"), "endDate": .null]))
    }

    @Test func invalidSelectionFailsInsteadOfExportingExtraData() {
        #expect(throws: DataIssue.self) {
            try SelectiveExport.data(from: profile, selection: [
                .init(id: job.id, fields: ["responsibilities": .items([5])]),
            ], format: .structured)
        }
        #expect(throws: DataIssue.self) {
            try SelectiveExport.data(from: profile, selection: [
                .init(id: job.id, fields: ["supervisor": .whole]),
            ], format: .veraFlowResume)
        }
        #expect(throws: DataIssue.self) {
            try SelectiveExport.data(from: profile, selection: [
                .init(id: job.id, fields: ["title": .whole]),
                .init(id: job.id, fields: ["title": .whole]),
            ], format: .structured)
        }
        #expect(throws: DataIssue.self) {
            try SelectiveExport.data(from: profile, selection: [
                .init(id: "gone", fields: ["title": .whole]),
            ], format: .structured)
        }
    }
}
