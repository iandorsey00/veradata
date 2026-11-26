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

    @Test func standardResumeSelectionUsesEligibleFieldsAndOnlyTheChosenContact() throws {
        let other = Record(id: "other", kind: .contact, label: "Other", fields: ["name": .string("Other contact")])
        let custom = Record(id: "custom", kind: .custom, label: "Notes", fields: ["note": .string("Private note")])
        let source = Profile(id: profile.id, name: profile.name, records: [other, contact, job, custom, education])
        let selection = SelectiveExport.standardResumeSelection(in: source, contactID: contact.id)
        #expect(selection.map(\.id) == [contact.id, job.id, education.id])
        #expect(selection[1].fields["responsibilities"] == .whole)
        #expect(selection[1].fields["supervisor"] == nil)
        #expect(selection[1].fields["metadata"] == nil)
        let withoutContact = SelectiveExport.standardResumeSelection(in: source, contactID: nil)
        #expect(withoutContact.map(\.id) == [job.id, education.id])
        let output = try #require(JSONValue.parse(
            SelectiveExport.data(from: source, selection: selection, format: .veraFlowResume)
        ).object)
        #expect(output["name"] == .string("Morgan Example"))
        #expect(output["experience_markdown"]?.string?.contains("Kept reports") == true)
    }

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

    @Test func fictionalResumeSelectionFeedsThePDFTemplate() throws {
        func record(_ id: String, _ kind: RecordKind, _ fields: [String: JSONValue]) -> Record {
            Record(id: id, kind: kind, label: "Hidden display name", fields: fields)
        }
        let contact = record("c", .contact, [
            "name": .string("Alex Lin 林晓"), "headline": .string("Logistics and documentation coordinator"),
            "email": .string("alex.lin@example.com"), "phone": .string("+1 503 555 0148"),
            "portfolio": .string("https://example.com/portfolio"), "website": .string("https://hidden.example.com"),
            "summary": .string("Coordinates readable bilingual documents and reliable shipment handoffs."),
        ])
        let first = record("a", .employment, [
            "title": .string("Dispatch Coordinator"), "employer": .string("North Depot"),
            "startDate": .string("2023"), "endDate": .string("2026"), "location": .string("Portland"),
            "responsibilities": .array([.string("Coordinated 32 monthly shipments."), .string("支持中英文文件。"), .string("Hidden bullet")]),
        ])
        let second = record("b", .employment, [
            "title": .string("Operations Assistant"), "employer": .string("Harbor Studio"),
            "startDate": .string("2020"), "endDate": .string("2023"), "location": .string("Seattle"),
            "responsibilities": .array([.string("Prepared daily handoff notes.")]),
        ])
        let education = record("e", .education, [
            "qualification": .string("B.A."), "institution": .string("Example College"),
            "startDate": .string("2016"), "endDate": .string("2020"),
        ])
        let skills = record("s", .custom, [
            "skills": .array([.string("Dispatch documentation"), .string("English and Mandarin"), .string("Hidden skill")]),
        ])
        let project = record("p", .custom, [
            "title": .string("Intake redesign"), "details": .string("Built a bilingual checklist."),
        ])
        let secondProject = record("q", .custom, [
            "title": .string("Dispatch playbook"), "details": .string("Consolidated procedures into one guide."),
        ])
        let unselected = record("u", .custom, ["title": .string("Hidden project")])
        let profile = Profile(id: "sample", name: "Example", records: [contact, second, first, education, skills, secondProject, project, unselected])
        func select(_ record: Record, excluding omitted: Set<String> = [], section: ResumeSection? = nil) -> ExportRecordSelection {
            .init(id: record.id, fields: Dictionary(uniqueKeysWithValues: record.fields.keys.filter { !omitted.contains($0) }.map { ($0, .whole) }), resumeSection: section)
        }
        var firstSelection = select(first)
        firstSelection.fields["responsibilities"] = .items([0, 1])
        let data = try SelectiveExport.data(from: profile, selection: [
            select(contact, excluding: ["website"]), firstSelection, select(second), select(education),
            .init(id: skills.id, fields: ["skills": .items([0, 1])], resumeSection: .skills),
            select(project, section: .projects), select(secondProject, section: .projects),
        ], format: .veraFlowResume)
        let result = try #require(JSONValue.parse(data).object)
        #expect(result["links_markdown"] == .string("[Portfolio](<https://example.com/portfolio>)"))
        #expect(result["skills_markdown"] == .string("- Dispatch documentation\n- English and Mandarin"))
        #expect(result["projects_markdown"] == .string("### Intake redesign\n\n- Built a bilingual checklist.\n\n### Dispatch playbook\n\n- Consolidated procedures into one guide."))
        #expect(result["experience_markdown"]?.string?.hasPrefix("### Dispatch Coordinator") == true)
        #expect(!String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("hidden"))
        let contactOnly = try SelectiveExport.data(from: profile, selection: [
            .init(id: contact.id, fields: ["name": .whole]),
        ], format: .veraFlowResume)
        #expect(try JSONValue.parse(contactOnly) == .object(["name": .string("Alex Lin 林晓")]))
        #expect(throws: DataIssue.self) {
            try SelectiveExport.data(from: profile, selection: [select(project)], format: .veraFlowResume)
        }
        if let path = ProcessInfo.processInfo.environment["VERADATA_RESUME_FIXTURE"] {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
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
