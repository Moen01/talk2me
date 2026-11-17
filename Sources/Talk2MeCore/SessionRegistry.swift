import Foundation

/// A single Claude Code session hosted in a Terminal window.
public struct OrchestratorSession: Codable, Equatable, Sendable {
    public var name: String
    public var folder: String
    public var windowID: Int

    public init(name: String, folder: String, windowID: Int) {
        self.name = name
        self.folder = folder
        self.windowID = windowID
    }
}

/// Shared state between the Talk2Me app and the MCP server: which Claude Code sessions exist
/// and which Terminal window hosts the orchestrator itself.
///
/// The registry lives at ``defaultURL()`` as a JSON file. Both processes load it at startup and
/// write it after any mutation. The file is small and writes are infrequent, so last-write-wins
/// is acceptable.
public struct SessionRegistry: Codable, Equatable, Sendable {
    /// Window ID of the Terminal window running the orchestrator process, if one is live.
    public var orchestratorWindowID: Int?

    /// All currently-registered Claude Code sessions.
    public var sessions: [OrchestratorSession]

    public init(orchestratorWindowID: Int? = nil, sessions: [OrchestratorSession] = []) {
        self.orchestratorWindowID = orchestratorWindowID
        self.sessions = sessions
    }

    // MARK: - Persistence

    /// Loads the registry from `url`. Returns an empty registry when the file is missing or
    /// cannot be decoded — never throws.
    public static func load(from url: URL) -> SessionRegistry {
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(SessionRegistry.self, from: data)
        else { return SessionRegistry() }
        return registry
    }

    /// Saves the registry to `url`, creating the parent directory first if needed.
    public func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Mutation

    /// Registers a session for `folder` / `windowID` and returns the chosen name.
    ///
    /// The name is the last path component of `folder`. When that name is already taken by
    /// another session, a numeric suffix is added: `-2`, `-3`, and so on.
    @discardableResult
    public mutating func register(folder: String, windowID: Int) -> String {
        let base = URL(fileURLWithPath: folder).lastPathComponent
        let taken = Set(sessions.map(\.name))

        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }

        sessions.append(OrchestratorSession(name: candidate, folder: folder, windowID: windowID))
        return candidate
    }

    // MARK: - Pruning

    /// Returns a copy of the registry with dead sessions removed.
    ///
    /// `alive` is called with each window ID; return `true` to keep it.
    /// The ``orchestratorWindowID`` is also cleared when its window is gone.
    public func pruned(alive: (Int) -> Bool) -> SessionRegistry {
        let liveSessions = sessions.filter { alive($0.windowID) }
        let liveOrchestratorID = orchestratorWindowID.flatMap { alive($0) ? $0 : nil }
        return SessionRegistry(orchestratorWindowID: liveOrchestratorID, sessions: liveSessions)
    }

    // MARK: - Default URL

    /// `~/Library/Application Support/Talk2Me/sessions.json`
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Talk2Me/sessions.json")
    }
}
