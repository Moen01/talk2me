import AppKit
import Security
import Talk2MeCore

enum SelfUpdateError: Error, LocalizedError {
    case noDownload
    case download(Int)
    case notTalk2Me
    case wrongSigner
    case command(String)

    var errorDescription: String? {
        switch self {
        case .noDownload: "This release has no Talk2Me.zip to install."
        case .download(let status): "The download failed with status \(status)."
        case .notTalk2Me: "The download is not the expected Talk2Me version."
        case .wrongSigner: "The download is not signed with the Talk2Me certificate."
        case .command(let message): message
        }
    }
}

/// Downloads a release and replaces this copy of Talk2Me with it, then restarts.
///
/// macOS only puts the quarantine flag on files that browsers and other quarantine-aware apps
/// download. Talk2Me is neither, so the installed update opens without the "Apple could not
/// verify" warning. What is trusted is HTTPS to GitHub, the release's own SHA256SUMS, and the
/// "Talk2Me Signing" certificate: once the installed copy carries it, an update must too.
enum SelfUpdater {
    enum Step { case downloading, installing }

    @MainActor
    static func install(_ update: UpdateChecker.Update, progress: (Step) -> Void) async throws {
        guard let archive = update.archive, let checksums = update.checksums else { throw SelfUpdateError.noDownload }
        let installed = Bundle.main.bundleURL
        // On the same volume as the app, so the final swap is a rename.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: installed, create: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(.downloading)
        let zip = work.appendingPathComponent("Talk2Me.zip")
        try FileManager.default.moveItem(at: try await download(archive), to: zip)
        let sumsFile = try await download(checksums)
        let sums = try String(contentsOf: sumsFile, encoding: .utf8)
        try? FileManager.default.removeItem(at: sumsFile)
        try UpdateArchive.verify(zip, checksums: sums, name: archive.lastPathComponent)

        progress(.installing)
        let unpacked = work.appendingPathComponent("unpacked")
        try await run("/usr/bin/ditto", "-x", "-k", zip.path, unpacked.path)
        let app = unpacked.appendingPathComponent("Talk2Me.app")
        let bundle = Bundle(url: app)
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == update.version
        else { throw SelfUpdateError.notTalk2Me }
        try await run("/usr/bin/codesign", "--verify", "--strict", app.path)
        try checkSigner(of: app, matches: installed)

        // The running process keeps its open files, so the bundle can be swapped under it.
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: app)
        // terminate() never returns, so the deferred cleanup would not run.
        try? FileManager.default.removeItem(at: work)
        relaunch(installed)
    }

    /// The new copy must meet the installed copy's designated requirement, which names the
    /// signing certificate. An ad-hoc build's requirement is its own cdhash, which no other
    /// build can meet, so the check starts with the first certificate-signed version.
    private static func checkSigner(of app: URL, matches installed: URL) throws {
        var installedCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &installedCode) == errSecSuccess, let installedCode,
              SecCodeCopyDesignatedRequirement(installedCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              (text as String?)?.contains("certificate") == true
        else { return }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode,
              SecStaticCodeCheckValidity(newCode, [], requirement) == errSecSuccess
        else { throw SelfUpdateError.wrongSigner }
    }

    private static func download(_ url: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SelfUpdateError.download(status) }
        return file
    }

    /// Waits off the main thread, so the window keeps drawing "Installing…". Errors go to a file:
    /// a pipe nobody reads while the tool runs would block it once its buffer fills.
    private static func run(_ tool: String, _ arguments: String...) async throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("talk2me-update-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer {
            try? errors.close()
            try? FileManager.default.removeItem(at: log)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw SelfUpdateError.command(message.isEmpty ? "\(tool) failed." : message)
        }
    }

    /// Opens the new copy once this process has quit, so two copies never run at once.
    @MainActor
    private static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? waiter.run()
        NSApp.terminate(nil)
    }
}
