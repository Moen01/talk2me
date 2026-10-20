import Foundation
import Testing
@testable import Talk2MeCore

struct UpdateCheckerTests {
    private func release(_ tag: String) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/Moen01/talk2me/releases/tag/\#(tag)"}"#.utf8)
    }

    @Test func newerReleaseIsAvailable() throws {
        let result = try UpdateChecker.parse(release("v0.2.0"), status: 200, currentVersion: "0.1.0")
        #expect(result == .available(version: "0.2.0",
                                     page: URL(string: "https://github.com/Moen01/talk2me/releases/tag/v0.2.0")!))
    }

    @Test func sameOrOlderReleaseIsUpToDate() throws {
        #expect(try UpdateChecker.parse(release("v0.1.0"), status: 200, currentVersion: "0.1.0") == .upToDate)
        #expect(try UpdateChecker.parse(release("0.1.0"), status: 200, currentVersion: "0.10.0") == .upToDate)
    }

    @Test func comparesNumericallyNotAsText() throws {
        let result = try UpdateChecker.parse(release("v0.10.0"), status: 200, currentVersion: "0.9.0")
        #expect(result != .upToDate)
    }

    @Test func missingReleaseIsAnError() {
        // GitHub answers 404 for a private repository or one with no releases.
        #expect(throws: UpdateError.unavailable(404)) {
            try UpdateChecker.parse(Data("{}".utf8), status: 404, currentVersion: "0.1.0")
        }
    }

    @Test func unexpectedJSONIsAnError() {
        #expect(throws: UpdateError.badResponse) {
            try UpdateChecker.parse(Data(#"{"message":"x"}"#.utf8), status: 200, currentVersion: "0.1.0")
        }
    }
}
