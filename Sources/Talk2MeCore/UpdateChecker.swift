import CryptoKit
import Foundation

public enum UpdateError: Error, LocalizedError, Equatable {
    case unavailable(Int)
    case badResponse
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable(404): "No published release was found."
        case .unavailable(let status): "GitHub answered with status \(status)."
        case .badResponse: "GitHub sent an unexpected reply."
        case .checksumMismatch: "The download does not match the release checksum."
        }
    }
}

/// Asks GitHub for the newest Talk2Me release.
public enum UpdateChecker {
    public static let latestRelease = URL(string: "https://api.github.com/repos/Moen01/talk2me/releases/latest")!
    static let archiveName = "Talk2Me.zip"
    static let checksumsName = "SHA256SUMS"

    public struct Update: Equatable, Sendable {
        public let version: String
        public let page: URL
        /// Nil when the release has no Talk2Me.zip or SHA256SUMS; then it can only be opened in the browser.
        public let archive: URL?
        public let checksums: URL?
    }

    public enum Result: Equatable, Sendable {
        case upToDate
        case available(Update)
    }

    public static func check(currentVersion: String, session: URLSession = .shared) async throws -> Result {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try parse(data, status: status, currentVersion: currentVersion)
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]?
    }

    /// `releases/latest` already skips drafts and pre-releases.
    static func parse(_ data: Data, status: Int, currentVersion: String) throws -> Result {
        guard status == 200 else { throw UpdateError.unavailable(status) }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw UpdateError.badResponse }
        // Tags look like "v0.1.0"; CFBundleShortVersionString is "0.1.0".
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard ClaudeCodeBackend.compareVersions(latest, currentVersion) == .orderedDescending else { return .upToDate }
        func asset(_ name: String) -> URL? { release.assets?.first { $0.name == name }?.browser_download_url }
        return .available(Update(
            version: latest,
            page: release.html_url,
            archive: asset(archiveName),
            checksums: asset(checksumsName)
        ))
    }
}

public enum UpdateArchive {
    /// Checks a downloaded file against a `shasum -a 256` listing. This catches a broken or swapped
    /// download; it is not a signature, since the listing comes from the same release.
    public static func verify(_ file: URL, checksums: String, name: String) throws {
        let expected = checksums.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            .first { $0.count == 2 && $0[1] == name }?
            .first.map { $0.lowercased() }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let expected, expected == actual else { throw UpdateError.checksumMismatch }
    }
}
