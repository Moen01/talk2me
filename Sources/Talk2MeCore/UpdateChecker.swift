import Foundation

public enum UpdateError: Error, LocalizedError, Equatable {
    case unavailable(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(404): "No published release was found."
        case .unavailable(let status): "GitHub answered with status \(status)."
        case .badResponse: "GitHub sent an unexpected reply."
        }
    }
}

/// Asks GitHub for the newest Talk2Me release. It only links to the download: the app is not
/// notarized, so macOS would block an update installed in place anyway.
public enum UpdateChecker {
    public static let latestRelease = URL(string: "https://api.github.com/repos/Moen01/talk2me/releases/latest")!

    public enum Result: Equatable, Sendable {
        case upToDate
        case available(version: String, page: URL)
    }

    public static func check(currentVersion: String, session: URLSession = .shared) async throws -> Result {
        var request = URLRequest(url: latestRelease, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try parse(data, status: status, currentVersion: currentVersion)
    }

    struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    /// `releases/latest` already skips drafts and pre-releases.
    static func parse(_ data: Data, status: Int, currentVersion: String) throws -> Result {
        guard status == 200 else { throw UpdateError.unavailable(status) }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw UpdateError.badResponse }
        // Tags look like "v0.1.0"; CFBundleShortVersionString is "0.1.0".
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard ClaudeCodeBackend.compareVersions(latest, currentVersion) == .orderedDescending else { return .upToDate }
        return .available(version: latest, page: release.html_url)
    }
}
