import Foundation
import Testing
@testable import Talk2MeCore

struct SessionRegistryTests {

    // MARK: - Round-trip save/load

    @Test func roundTripSaveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("sessions.json")

        var registry = SessionRegistry()
        registry.orchestratorWindowID = 42
        _ = registry.register(folder: "/Users/me/projects/catacloud-api", windowID: 10)

        try registry.save(to: url)
        let loaded = SessionRegistry.load(from: url)

        #expect(loaded == registry)
    }

    @Test func saveCreatesParentDirectory() throws {
        // Parent dir does not exist yet — save must create it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested")
        let url = dir.appendingPathComponent("sessions.json")

        try SessionRegistry().save(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Missing / corrupt file

    @Test func missingFileLoadsAsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sessions.json")
        let registry = SessionRegistry.load(from: url)
        #expect(registry == SessionRegistry())
    }

    @Test func corruptFileLoadsAsEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("sessions.json")
        try "not valid json }{".write(to: url, atomically: true, encoding: .utf8)

        let registry = SessionRegistry.load(from: url)
        #expect(registry == SessionRegistry())
    }

    // MARK: - register name deduplication

    @Test func registerUsesLastPathComponent() {
        var registry = SessionRegistry()
        let name = registry.register(folder: "/Users/me/projects/catacloud-api", windowID: 1)
        #expect(name == "catacloud-api")
    }

    @Test func registerAddsNumericSuffixOnCollision() {
        var registry = SessionRegistry()
        let first  = registry.register(folder: "/Users/me/projects/catacloud-api", windowID: 1)
        let second = registry.register(folder: "/Users/work/catacloud-api", windowID: 2)
        let third  = registry.register(folder: "/Users/other/catacloud-api", windowID: 3)
        #expect(first  == "catacloud-api")
        #expect(second == "catacloud-api-2")
        #expect(third  == "catacloud-api-3")
    }

    @Test func registerStoresSession() {
        var registry = SessionRegistry()
        _ = registry.register(folder: "/tmp/myproject", windowID: 7)
        #expect(registry.sessions.count == 1)
        #expect(registry.sessions[0].folder == "/tmp/myproject")
        #expect(registry.sessions[0].windowID == 7)
    }

    // MARK: - pruned

    @Test func prunedDropsDeadSessions() {
        var registry = SessionRegistry()
        _ = registry.register(folder: "/tmp/alive", windowID: 1)
        _ = registry.register(folder: "/tmp/dead",  windowID: 2)

        let pruned = registry.pruned { $0 == 1 }
        #expect(pruned.sessions.count == 1)
        #expect(pruned.sessions[0].windowID == 1)
    }

    @Test func prunedKeepsLiveSessions() {
        var registry = SessionRegistry()
        _ = registry.register(folder: "/tmp/a", windowID: 10)
        _ = registry.register(folder: "/tmp/b", windowID: 20)

        let pruned = registry.pruned { _ in true }
        #expect(pruned.sessions.count == 2)
    }

    @Test func prunedDropsDeadOrchestratorID() {
        var registry = SessionRegistry()
        registry.orchestratorWindowID = 99

        let pruned = registry.pruned { _ in false }
        #expect(pruned.orchestratorWindowID == nil)
    }

    @Test func prunedKeepsLiveOrchestratorID() {
        var registry = SessionRegistry()
        registry.orchestratorWindowID = 99

        let pruned = registry.pruned { $0 == 99 }
        #expect(pruned.orchestratorWindowID == 99)
    }

    // MARK: - defaultURL

    @Test func defaultURLIsInApplicationSupport() {
        let url = SessionRegistry.defaultURL()
        #expect(url.path.contains("Application Support/Talk2Me/sessions.json"))
    }
}
