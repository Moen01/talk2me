import CryptoKit
import Foundation
import Testing
@testable import Talk2MeCore

struct UpdateCheckerTests {
    private let page = "https://github.com/Moen01/talk2me/releases/tag/"
    private let download = "https://github.com/Moen01/talk2me/releases/download/"

    private func release(_ tag: String, assets: [String] = ["Talk2Me.zip", "SHA256SUMS"]) -> Data {
        let list = assets.map { #"{"name":"\#($0)","browser_download_url":"\#(download)\#(tag)/\#($0)"}"# }
        return Data(#"{"tag_name":"\#(tag)","html_url":"\#(page)\#(tag)","assets":[\#(list.joined(separator: ","))]}"#.utf8)
    }

    @Test func newerReleaseIsAvailableWithItsDownloads() throws {
        let result = try UpdateChecker.parse(release("v0.2.0"), status: 200, currentVersion: "0.1.0")
        #expect(result == .available(UpdateChecker.Update(
            version: "0.2.0",
            page: URL(string: page + "v0.2.0")!,
            archive: URL(string: download + "v0.2.0/Talk2Me.zip")!,
            checksums: URL(string: download + "v0.2.0/SHA256SUMS")!
        )))
    }

    @Test func releaseWithoutTheZipCanOnlyBeOpened() throws {
        let result = try UpdateChecker.parse(release("v0.2.0", assets: []), status: 200, currentVersion: "0.1.0")
        guard case .available(let update) = result else { Issue.record("expected an update"); return }
        #expect(update.archive == nil)
        #expect(update.checksums == nil)
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

struct UpdateArchiveTests {
    private func file(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk2me-archive-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func hash(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func matchingChecksumPasses() throws {
        let url = try file("zip bytes")
        defer { try? FileManager.default.removeItem(at: url) }
        let sums = "\(hash("other"))  Talk2Me.dmg\n\(hash("zip bytes"))  Talk2Me.zip\n"
        try UpdateArchive.verify(url, checksums: sums, name: "Talk2Me.zip")
    }

    @Test func changedFileFails() throws {
        let url = try file("tampered")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: UpdateError.checksumMismatch) {
            try UpdateArchive.verify(url, checksums: "\(hash("zip bytes"))  Talk2Me.zip\n", name: "Talk2Me.zip")
        }
    }

    @Test func fileMissingFromChecksumsFails() throws {
        let url = try file("zip bytes")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: UpdateError.checksumMismatch) {
            try UpdateArchive.verify(url, checksums: "\(hash("zip bytes"))  Talk2Me.dmg\n", name: "Talk2Me.zip")
        }
    }
}
