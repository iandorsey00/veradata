import Testing
@testable import VeraDataCore

struct AppUpdateTests {
    @Test func choosesTheHighestNewerStableVersionRegardlessOfTagOrder() {
        let tags = ["v0.10.0", "v0.9.19", "v0.11.2", "v0.11.0", "v0.50.0-rc.1", "v0.99.0/other"]
        let expected = "https://github.com/iandorsey00/veradata/tree/v0.11.2"
        #expect(AppUpdate.newerVersionURL(installed: "0.9.9", tags: tags)?.absoluteString == expected)
        #expect(AppUpdate.newerVersionURL(installed: "0.10.0", tags: tags)?.absoluteString == expected)
    }

    @Test func suppressesTheUpdateForCurrentOrUnrecognizedVersions() {
        let tags = ["v0.10.0", "v0.9.0", "v1.0.0-beta.1", "v999999999999999999999999.0.0", "v1.00.0"]
        #expect(AppUpdate.newerVersionURL(installed: "0.10.0", tags: tags) == nil)
        #expect(AppUpdate.newerVersionURL(installed: "0.12.0", tags: tags) == nil)
        #expect(AppUpdate.newerVersionURL(installed: "development", tags: tags) == nil)
    }
}
