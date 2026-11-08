import Foundation

/// Claude, par l'abonnement, pour une réponse d'un trait (la fiche de
/// révision) : `claude -p`, sans outils ni réglages, le message par l'entrée
/// standard (plusieurs centaines de milliers de caractères n'iraient pas en
/// argument), la réponse en JSON.
enum RevisionSheetClaude {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func write(instructions: String, prompt: String) async throws -> String {
        guard let executable = ClaudeChat.executable else {
            // Sans Claude Code : le tuteur gratuit, dans le mode qui porte cette consigne.
            guard FreeTutor.mode(for: instructions) != nil else { throw ClaudeChat.Failure.notInstalled }
            return try await FreeTutor.write(instructions: instructions, prompt: prompt)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try run(executable, instructions: instructions, prompt: prompt))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func run(_ executable: URL, instructions: String, prompt: String) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-p", "--output-format", "json",
            "--tools", "", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands",
            "--setting-sources", "", "--no-session-persistence",
            "--system-prompt", instructions,
        ]
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polymestre/claude-sheet", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // L'abonnement, jamais une clé d'API exportée par le shell.
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Écrire et lire en même temps : un long message remplirait le tuyau.
        DispatchQueue.global(qos: .userInitiated).async {
            stdin.fileHandleForWriting.write(Data(prompt.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        var errorText = Data()
        let errorReader = DispatchQueue(label: "claude-sheet-stderr")
        errorReader.async { errorText = stderr.fileHandleForReading.readDataToEndOfFile() }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errorReader.sync {}
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            let detail = String(decoding: errorText.isEmpty ? output.prefix(300) : errorText.prefix(300), as: UTF8.self)
            throw Failure(message: String(localized: "Claude n'a pas répondu (\(process.terminationStatus)) : \(detail)"))
        }
        if object["is_error"] as? Bool == true {
            throw Failure(message: "Claude : \(object["result"] as? String ?? "erreur")")
        }
        return object["result"] as? String ?? ""
    }
}
