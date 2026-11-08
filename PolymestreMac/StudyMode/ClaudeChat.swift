import AppKit
import Foundation
import Observation
import OSLog

/// Une conversation avec Claude, **par l'abonnement** : un processus `claude`
/// (Claude Code, déjà connecté au compte Claude) par conversation.
///
/// Une conversation **par série** : son identifiant de session vient de la
/// série (`ClaudeTutor.sessionID`), Claude Code la garde sur le disque, et on
/// la reprend (`--resume`) — l'app peut être quittée, la conversation reste.
/// Changer d'exercice ne change pas de conversation : le nouvel exercice est
/// annoncé dans le message suivant. Les arguments, les messages et la lecture
/// du flux sont dans `ClaudeTutor` (pur, testé).
@MainActor
@Observable
final class ClaudeChat: Identifiable {
    struct Message: Identifiable, Equatable {
        enum Role { case student, claude }
        let id = UUID()
        var role: Role
        var text: String
        /// « Post-mortem », « Rapport » : une demande faite d'un bouton.
        var label: String?
        var attachments: [String] = []
        /// L'exercice sur lequel l'étudiant·e a écrit (pour les séparateurs de la conversation).
        var exercise: String?
        var images: [NSImage] = []
        var isStreaming = false
        var error: String?

        static func == (a: Message, b: Message) -> Bool {
            a.id == b.id && a.text == b.text && a.isStreaming == b.isStreaming && a.error == b.error
        }
    }

    /// Comment lancer Claude Code : isolé, ou dans le projet EPFL.
    struct Config: Equatable {
        var profile: ClaudeTutor.Profile = .isolated
        /// Le dossier de travail de `claude` (le projet, ou un dossier à lui).
        var folder: URL
        var mcpConfigPath: String?
        var allowedTools: [String] = []
        var tools: [String] = ClaudeProject.baseTools
        var deniedServers: [String] = []
        /// Ce qui est permis, en clair.
        var permissions: String
        /// Le fichier du projet (`polymestre.json`) : boutons, modèles, compétences.
        var file: ClaudeProject.File?
        /// Ce qui est noté après une série (carnet, reprise, indices).
        var review = SeriesReview.Features()

        static var isolated: Config {
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Polymestre/claude", isDirectory: true)
            return Config(folder: folder, permissions: String(localized: "aucun outil"))
        }
    }

    let id = UUID()
    /// La série de la conversation (`nil` : une conversation libre).
    let seriesID: UUID?
    let config: Config
    private(set) var sessionID: UUID
    private(set) var messages: [Message] = []
    private(set) var isThinking = false
    private(set) var isAnswering = false
    /// La conversation telle que le tuteur gratuit l'a reçue (sans Claude Code).
    @ObservationIgnored private var tutorHistory: [(role: String, content: String)] = []
    /// L'outil en cours (« Notion », « compétence »), pendant une réponse.
    private(set) var activeTool: String?
    /// Où en est la fenêtre de 5 h de l'abonnement (0 → 1).
    private(set) var usage: Double?
    /// Ce que Claude Code a annoncé au démarrage (compétences, MCP, permissions).
    private(set) var info: ClaudeTutor.SessionInfo?
    /// La taille du contexte de la dernière réponse, en jetons.
    private(set) var contextTokens: Int?
    var mode: ClaudeTutor.Mode = .tutor
    private var modeSent: ClaudeTutor.Mode?
    /// La série a été présentée à Claude (premier message, ou conversation reprise).
    private(set) var opened = false
    /// L'exercice dont Claude a reçu le contexte en dernier.
    private var exerciseSent: UUID?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var stderrText = ""
    /// La dernière ligne envoyée, et si une réponse a commencé : une session
    /// introuvable se relance une fois, avec la même ligne.
    @ObservationIgnored private var lastLine: String?
    @ObservationIgnored private var receivedAny = false
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var forceResume: Bool?
    /// Le modèle demandé pour le prochain message, et celui du processus en cours.
    @ObservationIgnored private var requestedModel: String?
    @ObservationIgnored private var runningModel: String?
    @ObservationIgnored private let log = Logger(subsystem: "ch.polymestre.mac", category: "claude")

    init(seriesID: UUID?, config: Config) {
        self.seriesID = seriesID
        self.config = config
        sessionID = ClaudeTutor.sessionID(seriesID: seriesID ?? Self.freeSeries, profile: config.profile,
                                          generation: Self.generation(seriesID, config.profile))
        restore()
    }

    #if DEBUG
    /// `-claudeDemo` : une conversation d'exemple (captures), sans appeler Claude.
    func debugInject(_ demo: [(student: Bool, text: String)], exercises: [String] = []) {
        guard messages.isEmpty else { return }
        var students = 0
        messages = demo.map { item in
            defer { if item.student { students += 1 } }
            return Message(role: item.student ? .student : .claude, text: item.text,
                           exercise: item.student && exercises.indices.contains(students) ? exercises[students] : nil)
        }
        opened = true
    }
    #endif

    /// La « série » d'une conversation libre.
    private static let freeSeries = UUID(uuidString: "00000000-0000-0000-0000-00000000F4EE")!

    // MARK: Session gardée

    /// Une nouvelle conversation incrémente la génération : un autre identifiant.
    private static func generationKey(_ seriesID: UUID?, _ profile: ClaudeTutor.Profile) -> String {
        "mac.claude.generation.\((seriesID ?? freeSeries).uuidString).\(profile.rawValue)"
    }

    private static func generation(_ seriesID: UUID?, _ profile: ClaudeTutor.Profile) -> Int {
        UserDefaults.standard.integer(forKey: generationKey(seriesID, profile))
    }

    /// Le fichier où Claude Code garde la conversation.
    private var sessionFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(ClaudeTutor.sessionFolderName(workingDirectory: config.folder.path), isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased() + ".jsonl")
    }

    private var hasSession: Bool { FileManager.default.fileExists(atPath: sessionFile.path) }

    /// Réaffiche une conversation déjà commencée.
    private func restore() {
        guard let data = try? Data(contentsOf: sessionFile) else { return }
        messages = ClaudeTutor.history(jsonl: String(decoding: data, as: UTF8.self)).map {
            Message(role: $0.fromStudent ? .student : .claude, text: $0.text, exercise: $0.exercise)
        }
        opened = !messages.isEmpty
    }

    /// Repartir de zéro sur cette série (l'ancienne reste sur le disque).
    func startOver() {
        close()
        let key = Self.generationKey(seriesID, config.profile)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        sessionID = ClaudeTutor.sessionID(seriesID: seriesID ?? Self.freeSeries, profile: config.profile,
                                          generation: Self.generation(seriesID, config.profile))
        messages = []
        opened = false
        exerciseSent = nil
        modeSent = nil
        info = nil
        contextTokens = nil
    }

    /// Le chemin de `claude`, s'il est installé.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeTutor.candidatePaths(home: home)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }

    static var isAvailable: Bool { executable != nil }

    /// `-mac.claudeModel haiku` (débogage) : un essai qui coûte peu ; sinon le
    /// modèle par défaut de l'abonnement.
    private static var debugModel: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "mac.claudeModel")
        #else
        return nil
        #endif
    }

    // MARK: Envoyer

    /// Ce qu'il faut pour présenter la série et l'exercice en cours.
    struct Situation {
        var series: ClaudeTutor.SeriesContext?
        var exerciseID: UUID?
        var exercise: ClaudeTutor.Context
        /// La compétence à lancer au premier message (projet EPFL).
        var skill: String?
        /// L'état du tuteur pour ce message (`TutorFramework.card`) : l'exercice, les indices déjà donnés, les pièces jointes.
        var card = ""
        var exerciseLabel: String?
    }

    /// - Parameter model: le modèle de ce message (`nil` : celui de
    ///   l'abonnement). Un autre modèle que celui du processus en cours le
    ///   relance sur la même session (`--resume --model …`) : des indices
    ///   légers, puis un post-mortem avec un modèle plus fort, sans perdre le fil.
    func send(_ text: String, label: String? = nil, attachments: [ClaudeTutor.Attachment] = [], images: [NSImage] = [],
              model: String? = nil, situation: Situation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty, !isAnswering else { return }
        if model != runningModel, let process, process.isRunning {
            close()
        }
        requestedModel = model
        let free = !Self.isAvailable
        if !free {
            do {
                try startIfNeeded()
            } catch {
                messages.append(Message(role: .claude, text: "", error: error.localizedDescription))
                return
            }
        }
        var prompt = ""
        if !opened, let series = situation.series {
            prompt += ClaudeTutor.openingMessage(series: series, exercise: situation.exerciseID == nil ? nil : situation.exercise,
                                                 skill: situation.skill)
            exerciseSent = situation.exerciseID
        } else if !opened {
            prompt += ClaudeTutor.contextPreamble(situation.exercise)
            exerciseSent = situation.exerciseID
        } else if let exerciseID = situation.exerciseID, exerciseID != exerciseSent {
            prompt += ClaudeTutor.exerciseSwitch(situation.exercise)
            exerciseSent = exerciseID
        }
        opened = true
        if modeSent != mode {
            if modeSent != nil || config.profile == .project {
                prompt += mode == .tutor
                    ? "(Mode tuteur : des indices, pas la solution.)\n\n"
                    : "(Mode explications : tu peux tout expliquer et donner des solutions.)\n\n"
            }
            modeSent = mode
        }
        prompt += situation.card
        if prompt.hasPrefix("/") {
            // La compétence d'abord, la question ensuite.
            prompt += "\n\n" + (trimmed.isEmpty ? "Regarde ce que je t'envoie." : trimmed)
        } else {
            prompt += trimmed.isEmpty ? "Regarde ce que je t'envoie." : trimmed
        }
        messages.append(Message(role: .student, text: trimmed, label: label, attachments: attachments.map(\.chip),
                                exercise: situation.exerciseLabel, images: images))
        messages.append(Message(role: .claude, text: "", isStreaming: true))
        isAnswering = true
        isThinking = true
        if free {
            // Sans Claude Code : le tuteur gratuit du serveur (le texte seulement, sans pièces jointes).
            tutorHistory.append((role: "user", content: prompt))
            let history = tutorHistory
            Task { @MainActor in
                do {
                    let answer = try await FreeTutor.ask(messages: history)
                    tutorHistory.append((role: "assistant", content: answer.text))
                    if let index = messages.lastIndex(where: { $0.role == .claude && $0.isStreaming }) { messages[index].text = answer.text }
                    finishStreaming(error: nil)
                } catch {
                    tutorHistory.removeLast()
                    finishStreaming(error: error.localizedDescription)
                }
            }
            return
        }
        let line = ClaudeTutor.userLine(text: prompt, attachments: attachments) + "\n"
        lastLine = line
        receivedAny = false
        retried = false
        input?.write(Data(line.utf8))
    }

    /// Arrête la réponse en cours (Claude Code n'a pas d'interruption en mode
    /// flux : le processus s'arrête, la conversation reprendra au message suivant).
    func stop() {
        process?.terminate()
        finishStreaming(error: nil)
    }

    func close() {
        process?.terminate()
        process = nil
        input = nil
    }

    // MARK: Processus

    enum Failure: LocalizedError {
        case notInstalled
        var errorDescription: String? {
            String(localized: "Claude Code n'est pas installé. Installe-le (claude.com/code), puis tape `claude` une fois dans le Terminal.")
        }
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        guard let executable = Self.executable else { throw Failure.notInstalled }
        let process = Process()
        process.executableURL = executable
        let resume = forceResume ?? hasSession
        forceResume = nil
        process.arguments = ClaudeTutor.arguments(.init(profile: config.profile, sessionID: sessionID.uuidString.lowercased(),
                                                        resume: resume, systemPrompt: ClaudeTutor.systemPrompt(mode: mode, features: config.review),
                                                        mcpConfigPath: config.mcpConfigPath, allowedTools: config.allowedTools,
                                                        tools: config.tools, deniedServers: config.deniedServers,
                                                        model: Self.debugModel ?? requestedModel))
        runningModel = requestedModel
        try? FileManager.default.createDirectory(at: config.folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = config.folder
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        // Jamais de clé d'API : l'abonnement, même si le shell en exporte une.
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in
                self?.stderrText += text
                self?.log.notice("claude stderr : \(text, privacy: .public)")
            }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            let id = ObjectIdentifier(ended)
            Task { @MainActor in self?.ended(status: status, process: id) }
        }
        stderrText = ""
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        // Une conversation reprise connaît déjà la consigne, pas le mode courant.
        modeSent = resume ? nil : mode
        log.notice("claude lancé (\(self.config.profile.rawValue, privacy: .public), \(resume ? "reprise" : "nouvelle", privacy: .public))")
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = ClaudeTutor.parse(line: line) else { continue }
            receivedAny = true
            switch event {
            case .started(let info):
                self.info = info
            case .thinking:
                isThinking = true
            case .tool(let name):
                activeTool = ClaudeTutor.toolLabel(name)
                if let index = messages.lastIndex(where: { $0.role == .claude && $0.isStreaming }), !messages[index].text.isEmpty,
                   !messages[index].text.hasSuffix("\n\n") {
                    messages[index].text += "\n\n"
                }
            case .text(let piece):
                isThinking = false
                activeTool = nil
                if let index = messages.lastIndex(where: { $0.role == .claude }) { messages[index].text += piece }
            case .usage(let value):
                usage = value
            case .finished(let error, let tokens):
                if let tokens { contextTokens = tokens }
                finishStreaming(error: error)
            }
        }
    }

    private func finishStreaming(error: String?) {
        isAnswering = false
        isThinking = false
        activeTool = nil
        guard let index = messages.lastIndex(where: { $0.role == .claude && $0.isStreaming }) else { return }
        messages[index].isStreaming = false
        // Claude répond pendant qu'on lit autre chose : on le dit.
        if error == nil, !StudyModeController.shared.desk.claudeVisible {
            DeskNotifications.shared.post(.claude, String(localized: "Claude a répondu"), icon: "sparkle")
            StudyModeController.shared.desk.claudeUnread = true
        }
        if let error {
            messages[index].error = error.lowercased().contains("login") || error.lowercased().contains("auth")
                ? String(localized: "Claude Code n'est pas connecté. Tape `claude` dans le Terminal pour te connecter.")
                : error
        }
    }

    private func ended(status: Int32, process id: ObjectIdentifier) {
        // Un processus remplacé (changement de modèle, nouvelle conversation)
        // ne touche pas à celui qui l'a remplacé.
        if let process, ObjectIdentifier(process) != id { return }
        process = nil
        input = nil
        // La session a disparu, ou existe déjà : on relance une fois, même message.
        if isAnswering, !receivedAny, !retried, let line = lastLine,
           let recovery = ClaudeTutor.sessionRecovery(stderr: stderrText) {
            retried = true
            forceResume = recovery == .resume
            log.notice("claude relancé (\(recovery == .resume ? "reprise" : "nouvelle", privacy: .public))")
            do {
                try startIfNeeded()
                input?.write(Data(line.utf8))
                return
            } catch {}
        }
        if isAnswering {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            finishStreaming(error: status == 0 ? nil : (detail.isEmpty ? String(localized: "Claude s'est arrêté (code \(status)).") : detail))
        }
    }
}
