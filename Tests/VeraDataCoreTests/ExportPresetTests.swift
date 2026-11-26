import Foundation
import Testing
@testable import VeraDataCore

struct ExportPresetTests {
    private let selection = [
        ExportRecordSelection(id: "job", fields: [
            "title": .whole, "responsibilities": .items([1]), "details": .whole,
        ]),
    ]

    private func profile(_ id: String = "example") -> Profile {
        Profile(id: id, name: "Fictional profile", records: [
            Record(id: "job", kind: .employment, label: "Fictional job", fields: [
                "title": .string("Coordinator"),
                "responsibilities": .array([.string("Private draft"), .string("Published guides")]),
                "details": .object(["location": .string("Fictional office")]),
            ]),
        ])
    }

    @Test func presetUsesCurrentScalarsAndRetainsReviewedListItems() throws {
        var source = profile()
        let preset = try ExportPreset(name: "example", profile: source, selection: selection, format: .structured)
        let saved = try JSONEncoder().encode(preset)
        let contents = String(decoding: saved, as: UTF8.self)
        for value in ["Coordinator", "Private draft", "Published guides", "Fictional office"] {
            #expect(!contents.contains(value))
        }
        let restored = try JSONDecoder().decode(ExportPreset.self, from: saved)
        source.records[0].fields["title"] = .string("Documentation Lead")
        let exported = try restored.data(from: Vault(profiles: [source]))
        let output = try #require(JSONValue.parse(exported).object?["records"]?.array?.first?.object?["fields"]?.object)
        #expect(output["title"] == .string("Documentation Lead"))
        #expect(output["responsibilities"] == .array([.string("Published guides")]))
    }

    @Test func changedListsObjectsAndMissingFieldsRequireReview() throws {
        let source = profile()
        let preset = try ExportPreset(name: "example", profile: source, selection: selection, format: .structured)
        var changed = source
        changed.records[0].fields["responsibilities"] = .array([.string("Published guides"), .string("Private draft")])
        #expect(throws: DataIssue.self) { try preset.selection(in: changed) }
        changed = source
        changed.records[0].fields["details"] = .object(["location": .string("Fictional office"), "new": .bool(true)])
        #expect(throws: DataIssue.self) { try preset.selection(in: changed) }
        changed = source
        changed.records[0].fields.removeValue(forKey: "title")
        #expect(throws: DataIssue.self) { try preset.selection(in: changed) }
        #expect(throws: DataIssue.self) { try preset.selection(in: profile("other")) }
    }

    @Test func resumePresetCanExportSelectedValuesWithoutMarkdown() throws {
        var source = profile()
        source.records[0].fields["responsibilities"] = .array([
            .string("Private draft"), .string("Published [guides]"),
        ])
        let selected = [ExportRecordSelection(id: "job", fields: [
            "title": .whole, "responsibilities": .items([1]),
        ])]
        let preset = try ExportPreset(name: "example", profile: source, selection: selected, format: .veraFlowResume)
        let vault = Vault(profiles: [source])
        let structured = try JSONValue.parse(preset.data(from: vault, as: .structured))
        #expect(structured.object?["format"] == .string("veradata-selection"))
        #expect(structured.object?["records"]?.array?.first?.object?["fields"]?.object == [
            "title": .string("Coordinator"),
            "responsibilities": .array([.string("Published [guides]")]),
        ])
        let resume = try JSONValue.parse(preset.data(from: vault))
        #expect(resume.object?["experience_markdown"] != nil)
        source.records[0].fields["responsibilities"] = .array([.string("Changed item")])
        #expect(throws: DataIssue.self) {
            try preset.data(from: Vault(profiles: [source]), as: .structured)
        }
    }

    @Test func presetsAreVaultScopedAndRequireExplicitReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExportPresetStore(vaultURL: root.appending(path: "vault.json"))
        let otherStore = ExportPresetStore(vaultURL: root.appending(path: "other.json"))
        let preset = try ExportPreset(name: "Example", profile: profile(), selection: selection, format: .structured)
        try store.save(preset)
        #expect(preset.name == "example")
        #expect(try store.names() == ["example"])
        #expect(try otherStore.names().isEmpty)
        #expect(try store.names(for: "other").isEmpty)
        #expect(throws: DataIssue.self) { try store.save(preset) }
        try store.save(preset, replace: true)
        let otherProfile = try ExportPreset(name: "example", profile: profile("other"), selection: selection, format: .structured)
        #expect(throws: DataIssue.self) { try store.save(otherProfile, replace: true) }
        #expect(try store.load("EXAMPLE").profileID == "example")
        #expect(throws: DataIssue.self) { try store.load("../example") }
    }
}
