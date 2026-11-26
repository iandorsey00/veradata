import Foundation
import Testing
@testable import VeraDataCore

struct VeraDataTests {
    private var demoURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VeraDataApp/Resources/demo.json")
    }

    private func demo() throws -> Vault { try VaultFile.readBackup(demoURL) }

    @Test func testDemoRoundTripAndLabels() throws {
        let original = try demo()
        let encoded = try original.data()
        #expect(try Vault(data: encoded) == original)
        #expect(try Vault(data: encoded).data() == encoded)
        #expect(original.profiles[0].records.filter { $0.kind == .employment }.count == 5)
        let duplicateNames = original.profiles[0].records.filter { $0.label == "Juniper Signal Works" }
        #expect(Set(duplicateNames.map(\.id)).count == 2)
        #expect(duplicateNames[0].subtitle != duplicateNames[1].subtitle)
    }

    @Test func testStrictJSONPreservesNumericLexemesAndUntrustedText() throws {
        let raw = #"{"huge":900719925474099312345678901234567890,"decimal":1.000000000000000000002e-500,"emoji":"\uD83D\uDD11","code":"000184","empty":"","unknown":null,"literal":"{{field}} <tag>","array":[-0,true,false]}"#
        let value = try JSONValue.parse(Data(raw.utf8))
        #expect(value.object?["huge"]?.scalarText == "900719925474099312345678901234567890")
        #expect(value.object?["decimal"]?.scalarText == "1.000000000000000000002e-500")
        #expect(value.object?["emoji"]?.string == "🔑")
        #expect(value.object?["code"] == .string("000184"))
        #expect(value.object?["empty"] == .string(""))
        #expect(value.object?["unknown"] == JSONValue.null)
        #expect(nil == value.object?["missing"])
        #expect(value.object?["literal"]?.string == "{{field}} <tag>")
        #expect(value.object?["array"]?.array?.first?.scalarText == "-0")
        #expect(try JSONValue.parse(value.data()) == value)
    }

    @Test func testStrictJSONReportsUnsupportedInput() {
        let badInputs = [
            #"{"key":1,"\u006bey":2}"#, #"{"key":1,}"#, #"{"key":01}"#, #"{"key":1e+}"#,
            #"{"key":2.}"#, #"[1 2]"#, #"[]"# + " null", #"/* comment */ {}"#,
            #""\uD800""#, "\"bad\u{0001}\"", "truefalse", #"{"a":"unterminated}"#,
        ]
        for raw in badInputs {
            #expect(throws: (any Error).self) { try JSONValue.parse(Data(raw.utf8)) }
        }
        #expect(throws: (any Error).self) { try JSONValue.parse(Data([0x22, 0xff, 0x22])) }
        let deeplyNested = String(repeating: "[", count: 70) + "null" + String(repeating: "]", count: 70)
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(deeplyNested.utf8)) }
    }

    @Test func testUnsupportedVersionAndInvalidTypedFields() throws {
        let old = #"{"version":0,"profiles":[],"settings":{"searchShortcut":"space"}}"#
        let future = old.replacingOccurrences(of: ":0", with: ":2")
        for raw in [old, future] {
            #expect(throws: (any Error).self) { try Vault(data: Data(raw.utf8)) }
        }
        let bad = Record(kind: .employment, label: "Fictional employer",
                         fields: ["startDate": .string("2023-02-29")])
        #expect(throws: (any Error).self) { try bad.validate() }
        let profile = Profile(name: "Demo", records: [bad, bad])
        #expect(throws: (any Error).self) { try Vault(profiles: [profile]).data() }
        var original = try demo()
        original.profiles[0].records.append(original.profiles[0].records[0])
        #expect(throws: (any Error).self) { try original.data() }
    }

    @Test func testPartialDatesAndPhoneFormats() throws {
        #expect(nil != PartialDate("2000-02-29"))
        #expect(nil == PartialDate("1900-02-29"))
        #expect(nil == PartialDate("0000"))
        #expect(nil == PartialDate("2024-4"))
        #expect(nil == PartialDate("2024-04-31"))
        let profile = try demo().profiles[0]
        let phone = try #require(profile.records[0].values.first { $0.label == "Phone number" })
        #expect(phone.representations.map(\.text) == ["+1 (202) 555-0142", "12025550142", "+12025550142"])
        let firstRole = try #require(profile.records.first { $0.id == "juniper-lead" })
        let date = try #require(firstRole.values.first { $0.label == "Start date" })
        #expect(date.representations.map(\.text) == ["2024-03", "2024", "03", "2024-03"])
        let yearOnly = try #require(profile.records.first { $0.id == "glasswater" }?.values.first { $0.label == "Start date" })
        #expect(yearOnly.representations.map(\.label) == ["As stored", "Year"])
        let duties = try #require(firstRole.values.first { $0.label == "Responsibilities" })
        #expect(duties.representations[1].text.hasPrefix("• Maintain"))
    }

    @Test func testSearchScopesFiveJobsAndFindsRepresentations() throws {
        let index = RetrievalIndex(records: try demo().profiles[0].records)
        #expect(index.search("phone").first?.field?.display == "+1 (202) 555-0142")
        #expect(index.search("电话").first?.record?.id == "morgan-reed")
        #expect(index.search(";PH").first?.field?.label == "Phone number")
        #expect(index.search(";p").isEmpty)
        let jobs = index.search("Juniper").filter { $0.field == nil }
        #expect(jobs.map { $0.record?.id } == ["juniper-lead", "juniper-coordinator"])
        #expect(index.search("start year", recordID: "juniper-lead").first?.preferredFormat?.text == "2024")
        #expect(index.search("start month", recordID: "juniper-coordinator").first?.preferredFormat?.text == "07")
        #expect(index.search("start year month", recordID: "juniper-coordinator").first?.preferredFormat?.text == "2022-07")
        #expect(index.search("telephone", recordID: "juniper-lead").isEmpty)
        #expect(index.search("residential address").first?.record?.id == "cedar-current")
        #expect(index.search("Orchard").first?.record?.id == "orchard-previous")
    }

    @Test func testNestedSearchAndSelectiveExport() throws {
        let fields: [String: JSONValue] = [
            "job/ref": .object(["lookup~key": .string("00100")]),
            "empty": .string(""), "unknown": .null, "plain": .string("{{literal}}"),
            "large": .number(try JSONNumber("123456789012345678901234567890")),
        ]
        let record = Record(kind: .custom, label: "Shipping history", fields: fields)
        let search = RetrievalIndex(records: [record])
        #expect(search.search("lookup key").first?.field?.id == "/job~1ref/lookup~0key")
        #expect(search.search("00100").first?.field?.display == "00100")
        let projected = record.projection(keys: ["job/ref", "empty", "unknown", "large", "missing"])
        #expect(projected == .object(["empty": .string(""), "unknown": .null, "large": fields["large"]!]))
        #expect(nil == projected.object?["plain"])
    }

    @Test func testClockValuesUseLocalDayAndUnambiguousTimestampFormats() throws {
        let index = RetrievalIndex(records: try demo().profiles[0].records)
        let now = Date(timeIntervalSince1970: 1_735_691_399)
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let locale = Locale(identifier: "en_US")
        let today = try #require(index.search("today", recordID: "juniper-lead", now: now,
                                              timeZone: zone, locale: locale).first)
        #expect(today.currentValue == .today)
        #expect(today.representations.map(\.text) == ["2024-12-31", "December 31, 2024"])
        let stamp = try #require(index.search("timestamp", now: now, timeZone: zone, locale: locale).first)
        #expect(stamp.representations.map(\.text) == ["2024-12-31T16:29:59-08:00", "2025-01-01T00:29:59Z", "1735691399"])
        let later = try #require(index.search("timestamp", now: now.addingTimeInterval(1), timeZone: zone).first)
        #expect(later.id == stamp.id)
        #expect(later.representations.last?.text == "1735691400")
        #expect(index.search("start date", recordID: "juniper-lead").first?.currentValue == nil)
    }

    @Test func testSavedCoordinatePairPreservesPrecisionAndRejectsOutOfRange() throws {
        let fields: [String: JSONValue] = ["latitude": .string("+045.0000"), "longitude": .number(try JSONNumber("-123.0000001"))]
        let address = Record(kind: .address, label: "Fictional address", fields: fields)
        let result = RetrievalIndex(records: [address]).search("geocoords").first
        #expect(result?.representations.first?.text == "45.0000, -123.0000001")
        #expect(AddressCoordinates(fields: ["latitude": .string("90.00000001"), "longitude": .string("180")]) == nil)
        #expect(AddressCoordinates(fields: ["latitude": .string("45.0")]) == nil)
        #expect(AddressCoordinates(fields: ["latitude": .string("-90.00"), "longitude": .string("180.0")]) != nil)

        var oldRecord = address
        oldRecord.fields["latitude"] = .object(["legacy": .string("north")])
        try oldRecord.validate()
        #expect(oldRecord.values.allSatisfy { $0.label != "Coordinates" })
    }

    @Test func testMobileTransferIncludesOnlySelectedRecordsAndKeepsCanonicalData() throws {
        let original = try demo()
        let source = original.profiles[0]
        let other = Profile(id: "other", name: "另一个人", records: [
            Record(id: "morgan-reed", kind: .custom, label: "Unselected private record",
                   fields: ["reference": .string("private-value")])
        ])
        let vault = Vault(profiles: original.profiles + [other], shortcut: .off)
        let transfer = try MobileTransfer(vault: vault, selection: [source.id: ["morgan-reed", "juniper-lead"]])
        let data = try transfer.data()
        #expect(transfer.recordCount == 2)
        #expect(transfer.profiles.map(\.id) == [source.id])
        #expect(transfer.profiles[0].records.map(\.id) == ["morgan-reed", "juniper-lead"])
        #expect(transfer.profiles[0].records[0].fields["Reference code"] == .string("000184"))
        #expect(transfer.profiles[0].records[0].aliases[";ph"] == "phone")
        #expect(try MobileTransfer(data: data) == transfer)
        #expect(!String(decoding: data, as: UTF8.self).contains("private-value"))
        #expect(!String(decoding: data, as: UTF8.self).contains("searchShortcut"))
        #expect(throws: (any Error).self) { try MobileTransfer(data: vault.data()) }
        #expect(throws: (any Error).self) { try Vault(data: data) }
        #expect(throws: (any Error).self) { try MobileTransfer(vault: vault, selection: [:]) }
    }

    @Test func testBilingualSearchAndLocalizedText() throws {
        let records = try demo().profiles[0].records
        let index = RetrievalIndex(records: records)
        #expect(VeraText.text("Job title", language: "zh-Hans") == "职位名称")
        #expect(VeraText.text("Job title", language: "en") == "Job title")
        #expect(index.search("职位名称", recordID: "juniper-lead").first?.field?.value == .string("Operations Lead"))
        #expect(index.search("job title", recordID: "juniper-lead").first?.field?.value == .string("Operations Lead"))
        #expect(index.search("开始日期 月", recordID: "juniper-lead").first?.preferredFormat?.text == "03")
        let custom = Record(kind: .custom, label: "Translation", fields: ["Job title": .string("职位")])
        #expect(custom.values.first?.localizesLabel == false)
    }

    @Test func testFreshBackupRestoreAndConflictingWrites() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let primary = base.appendingPathComponent("primary/vault.json")
        let restored = base.appendingPathComponent("restored/vault.json")
        var first = VaultFile(url: primary)
        var other = VaultFile(url: primary)
        var fresh = VaultFile(url: restored)
        let vault = try demo()
        #expect(try first.load() == nil)
        #expect(try other.load() == nil)
        try first.save(vault)
        #expect(throws: (any Error).self) { try other.save(Vault()) }
        #expect(try first.load() == vault)
        #expect(try fresh.load() == nil)
        try fresh.save(VaultFile.readBackup(primary))
        #expect(try fresh.load() == vault)
        let mode = try FileManager.default.attributesOfItem(atPath: primary.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func testUnreadableDataIsPreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("vault.json")
        let broken = Data("{{".utf8)
        try broken.write(to: url)
        var store = VaultFile(url: url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(Vault()) }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func testSearchPerformanceOnLargeFictionalProfile() throws {
        let sample = try #require(demo().profiles[0].records.first { $0.kind == .employment })
        let records = (1...300).map { number in
            Record(id: "employer-\(number)", kind: .employment, label: "Fictional employer \(number)",
                   fields: sample.fields)
        }
        let index = RetrievalIndex(records: records)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<10 {
                #expect(index.search("employer 250 start year").first?.preferredFormat?.text == "2024")
            }
        }
        print("300-record debug search, 10 queries: \(elapsed)")
    }
}
