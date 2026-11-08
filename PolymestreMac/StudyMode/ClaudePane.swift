import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Claude dans le bureau : une conversation **par série**, gardée d'un
/// lancement à l'autre. Elle connaît la série (PDF joint au début), l'exercice
/// en cours et ses questions cochées ; changer d'exercice reste dans la même
/// conversation. « Post-mortem » et « Rapport » en fin de série ; les verdicts
/// d'un post-mortem ne sont notés qu'une fois confirmés. Par l'abonnement
/// Claude, pas d'une clé d'API.
struct ClaudePane: View {
    let course: Course?
    let courses: [Course]
    var desk: StudyDesk
    /// La fenêtre principale n'a que la conversation « EPFL » (le système).
    var onlySystem = false
    /// Les gestes de la fenêtre qui l'accueille (ranger, ancrer, détacher), au bout de l'en-tête.
    var accessory: AnyView? = nil

    /// La conversation de la série, ou celle du système entier (brief, plan,
    /// revue, synchronisation), quand le fichier du projet a des boutons pour lui.
    enum Scope: String { case series, system }
    /// La « série » de la conversation du système.
    static let systemID = UUID(uuidString: "00000000-0000-0000-0000-0000000E9F10")!

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var draft = ""
    @State private var attachments: [ClaudeTutor.Attachment] = []
    @State private var previews: [NSImage] = []
    @State private var attachSeries = true
    @State private var config: ClaudeChat.Config?
    @State private var scopeChoice: Scope = .series
    /// Le modèle d'une commande préparée (capture, fichier), pour l'envoi.
    @State private var pendingModel: String?
    @FocusState private var focused: Bool
    @State private var showsContext = false
    /// Une autre série que celle du chrono, choisie dans le menu.
    @State private var seriesChoice: UUID?
    /// L'énoncé d'un exercice Botafogo, lu sur le site (Claude ne recevait rien).
    @State private var siteStatements: [UUID: String] = [:]
    /// Les pages de copie jointes (par nom de pièce jointe) : leurs empreintes,
    /// retenues pour cette conversation quand le message part.
    @State private var copyPrints: [String: CopyPrints] = [:]
    /// « Ta copie n'a pas changé » : dit un instant au-dessus de la saisie.
    @State private var copyNotice: String?

    private struct CopyPrints { let key: String; let prints: [String] }

    private var file: ClaudeProject.File? { config?.file }
    private var hasSystem: Bool { !(file?.commands(.system).isEmpty ?? true) }
    private var scope: Scope { onlySystem ? .system : (hasSystem ? scopeChoice : .series) }
    private var chatID: UUID? { scope == .system ? Self.systemID : series?.id }

    private var exercise: Exercise? { course?.allExercises.first { $0.id == timer.targetID } }

    /// La série de la conversation : celle de l'exercice en cours, sinon la
    /// série de la semaine.
    private var series: ExerciseSeries? {
        if let seriesChoice, let chosen = course?.sortedSeries.first(where: { $0.id == seriesChoice }) { return chosen }
        if let series = exercise?.series { return series }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        let week = course?.currentWeek ?? 0
        return all.first { $0.plannedWeek >= week && !$0.isComplete } ?? all.last
    }

    private var seriesAddress: String? {
        let address = exercise.map { $0.statementURLString.isEmpty ? ($0.series?.urlString ?? "") : $0.statementURLString }
            ?? series?.urlString ?? ""
        return address.isEmpty ? nil : address
    }

    var body: some View {
        Group {
            if let config {
                let chat = desk.chat(series: chatID, config: config)
                VStack(spacing: 0) {
                    header(chat)
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                    if scope == .series, exercise != nil { strip(chat) }
                    if !ClaudeChat.isAvailable, chat.messages.isEmpty {
                        notInstalled
                    } else {
                        conversation(chat)
                    }
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                    composer(chat)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: settingsKey) {
            // Le dossier du projet, son CLAUDE.md, ses compétences : une fois par
            // réglage, gardés dans le bureau (préparés dès l'entrée en mode
            // étude) — Claude s'ouvre sans attendre.
            let key = settingsKey
            if let cached = desk.claudeConfig(for: key) { config = cached; return }
            let fresh = await ClaudeProjectSetup.config(settings: settings, courses: courses)
            desk.storeClaudeConfig(fresh, for: key)
            config = fresh
        }
        .onChange(of: config) { _, _ in
            takePending()
            #if DEBUG
            if CommandLine.arguments.contains("-claudeDemo"), let chat, let series {
                let numbers = series.sortedExercises.map(\.exerciseNumber)
                let a = numbers.first ?? "1", b = numbers.dropFirst().first ?? "2", c = numbers.dropFirst(2).first ?? "3"
                chat.debugInject([
                    (true, "Je bloque sur le \(b), je ne vois pas comment montrer que la suite est croissante."),
                    (false, "Regarde le signe de $x_{n+1} - x_n$ : que vaut-il, écrit sur un dénominateur commun ?\n\n```polymestre\nindice \(b) | 2 | Étudier le signe de x_{n+1} - x_n sur un dénominateur commun\n```"),
                    (true, "Clore la série"),
                    (false, "Bilan : le \(a) est juste ; au \(b) tu as conclu sans vérifier que $cn + d > 0$.\n\n```polymestre\n\(a) : juste\n\(b) : faux\nerreur \(b) | méthode | conclu sur le signe sans vérifier que cn + d > 0 | vérifier le signe du dénominateur avant de conclure | suites monotones\nerreur \(c) | étourderie | signe perdu en développant | recopier la ligne avant de développer\nreprise \(b) | méthode : le signe du dénominateur oublié | Écris x_{n+1} - x_n comme une seule fraction\n```")
                ], exercises: ["Série 6 · Exercice \(b)", "Série 6 · Exercice \(b)"])
            }
            #endif
            #if DEBUG
            // `-claudeAsk "…"` : une vraie question, pour vérifier la chaîne entière.
            if let index = CommandLine.arguments.firstIndex(of: "-claudeAsk"), index + 1 < CommandLine.arguments.count,
               let config, desk.chat(series: chatID, config: config).messages.isEmpty {
                send(CommandLine.arguments[index + 1])
            }
            #endif
        }
        .onChange(of: desk.pendingQuestion) { _, _ in takePending() }
        .onChange(of: desk.pendingDraftAttachment?.name) { _, _ in takePending() }
        .task(id: exercise?.id) { await loadSiteStatement() }
    }

    /// Un exercice Botafogo n'a pas d'énoncé importé : on le lit sur le site,
    /// tel que la page le montre, pour que Claude sache de quoi on parle.
    private func loadSiteStatement() async {
        guard let exercise, exercise.statement.isEmpty, siteStatements[exercise.id] == nil, let course,
              let site = course.contentSources.compactMap(URL.init(string:)).first(where: { ContentSource.detect(host: $0.host) == .botafogo })
        else { return }
        let book = desk.sites.botafogo(site)
        await book.load(site)
        var blocks: [BotafogoBlock]?
        if let path = BotafogoLinks.coursPath(exercise.statementURLString), let page = await book.page(path), !page.isEmpty {
            blocks = page
        } else if let seriesPath = exercise.series.flatMap({ BotafogoLinks.coursPath($0.urlString) }), let page = await book.page(seriesPath) {
            let exercises = BotafogoPage.exercises(page)
            let position = exercise.series?.sortedExercises.firstIndex { $0.id == exercise.id } ?? 0
            if exercises.indices.contains(position) { blocks = exercises[position].blocks }
        }
        if let blocks, !blocks.isEmpty { siteStatements[exercise.id] = BotafogoPage.text(blocks) }
    }

    private var settingsKey: String { Self.configKey(settings: settings) }

    /// Ce dont dépend la configuration : les réglages, et le fichier du projet
    /// relu quand il change (sa date).
    static func configKey(settings: MacSettings) -> String {
        let modified = (try? FileManager.default.attributesOfItem(atPath: ClaudeProjectSetup.fileURL(settings: settings).path))?[.modificationDate] as? Date
        return "\(settings.claudeProject)|\(settings.claudeProjectFolder)|\(settings.claudePolymestreMCP)|\(MacLocalMCP.shared.url?.absoluteString ?? "")|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    private var chat: ClaudeChat? {
        config.map { desk.chat(series: chatID, config: $0) }
    }

    // MARK: En-tête

    private var tint: Color { Carnet.tint(course?.colorHex ?? "") }

    private func header(_ chat: ClaudeChat) -> some View {
        HStack(spacing: 10) {
            conversationMenu
            if scope == .series, let series { exerciseMenu(series) }
            Spacer(minLength: 8)
            if let usage = chat.usage, usage >= 0.5 {
                Text("abonnement \(Int(usage * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(usage > 0.8 ? Carnet.wrong : Carnet.inkTertiary)
                    .help("Fenêtre de 5 h de ton abonnement Claude")
            }
            Button { showsContext.toggle() } label: {
                Image(systemName: "brain.head.profile")
                    .overlay(alignment: .topTrailing) {
                        if contextRows(chat).contains(where: { $0.state == .warning }) {
                            Circle().fill(Carnet.review).frame(width: 7, height: 7).offset(x: 4, y: -3)
                        }
                    }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Carnet.inkSecondary)
            .help("Ce que Claude sait")
            .popover(isPresented: $showsContext, arrowEdge: .bottom) {
                ClaudeContextPanel(rows: contextRows(chat), refreshCopy: scope == .series ? {
                    Task { await NotesStore.shared.refresh(force: true) }
                } : nil)
            }
            Menu {
                Button("Nouvelle conversation", systemImage: "square.and.pencil") { chat.startOver() }
                if chat.config.profile == .project {
                    Divider()
                    Button("Ouvrir le dossier du projet", systemImage: "folder") { NSWorkspace.shared.open(chat.config.folder) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Carnet.inkSecondary)
            if let accessory { accessory }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    /// Où on en est, sous l'en-tête : l'exercice, l'échelle d'indices, les questions, la copie, et la façon de répondre.
    private func strip(_ chat: ClaudeChat) -> some View {
        let state = tutorState
        return HStack(spacing: 12) {
            if state.tutor {
                HStack(spacing: 4) {
                    ForEach(1...4, id: \.self) { level in
                        Circle().fill(level <= state.hintLevel ? tint : Carnet.rule).frame(width: 7, height: 7)
                    }
                }
                .help(state.hintLevel == 0 ? "Aucun indice donné sur cet exercice"
                      : "Indices donnés : niveau \(state.hintLevel) sur 4 (\(TutorFramework.levelName(state.hintLevel)))")
            }
            if state.questionsTotal > 0 {
                Text("\(state.questionsDone)/\(state.questionsTotal)")
                    .font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkSecondary)
                    .help("Questions cochées")
            }
            if let copy = state.copy {
                Label(copy.pagesSeen.isEmpty ? "copie pas envoyée" : "p. \(TutorFramework.ranges(copy.pagesSeen)) vues",
                      systemImage: "pencil.and.scribble")
                    .font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                    .help("Les pages de ta copie que Claude a reçues dans cette conversation")
            }
            Spacer(minLength: 4)
            Menu {
                Picker("Façon de répondre", selection: Binding(get: { chat.mode }, set: { chat.mode = $0 })) {
                    ForEach(ClaudeTutor.Mode.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Text(chat.mode.label).font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Carnet.sheetRaised, in: Capsule())
                    .foregroundStyle(Carnet.ink)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(chat.mode == .tutor ? "Tuteur : des indices, pas la solution" : "Explications : tout expliquer, solutions comprises")
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Carnet.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Carnet.rule).frame(height: 1) }
    }

    /// La conversation : la série (une par série), ou la conversation
    /// générale (brief, semaine, revue — les commandes du projet).
    private var conversationMenu: some View {
        Menu {
            if !onlySystem, let course {
                Section(course.displayCode) {
                    ForEach(course.sortedSeries.filter { !$0.exercises.isEmpty }) { item in
                        Button {
                            seriesChoice = item.id
                            scopeChoice = .series
                        } label: {
                            if scope == .series, item.id == series?.id { Label(name(item), systemImage: "checkmark") } else { Text(name(item)) }
                        }
                    }
                }
            }
            if hasSystem {
                Section("Hors série") {
                    Button { scopeChoice = .system } label: {
                        if scope == .system { Label("Général : brief, semaine, revue…", systemImage: "checkmark") }
                        else { Text("Général : brief, semaine, revue…") }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(scope == .system ? "Général" : (series.map(name) ?? "Claude"))
                    .font(Carnet.serif(.title3, weight: .medium))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text(scope == .system ? "brief, semaine, revue" : (course?.displayCode ?? ""))
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
        .help("Changer de conversation (une par série)")
    }

    private func exerciseMenu(_ series: ExerciseSeries) -> some View {
        Menu {
            ForEach(series.sortedExercises) { item in
                Button {
                    if let course { timer.retarget(courseID: course.id, taskType: .exercise, targetID: item.id) }
                } label: {
                    if item.id == timer.targetID { Label(item.displayNumber, systemImage: "checkmark") } else { Text(item.displayNumber) }
                }
            }
        } label: {
            Text(exercise?.displayNumber ?? "Aucun exercice")
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(tint.opacity(exercise == nil ? 0.06 : 0.16), in: Capsule())
                .foregroundStyle(exercise == nil ? Carnet.inkSecondary : Carnet.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("L'exercice dont Claude reçoit le contexte (c'est aussi celui du chrono)")
    }

    /// Ce que Claude a sous les yeux, ligne par ligne.
    private func contextRows(_ chat: ClaudeChat) -> [ClaudeContextPanel.Row] {
        var rows: [ClaudeContextPanel.Row] = []
        if chat.config.profile == .project {
            let skill = file?.seriesSkill
            let loaded = skill.map { chat.info?.hasSkill($0) ?? ClaudeProjectSetup.linkedSkills(settings: settings).contains($0) } ?? false
            rows.append(.init(icon: "folder", title: String(localized: "Ton projet : ") + chat.config.folder.lastPathComponent,
                              detail: skill.map { loaded ? String(localized: "compétence \($0) chargée") : String(localized: "compétence \($0) introuvable") } ?? String(localized: "CLAUDE.md, ta mémoire, tes compétences"),
                              state: skill == nil || loaded ? .ok : .warning))
        } else {
            rows.append(.init(icon: "lock", title: String(localized: "Claude seul"), detail: String(localized: "sans outils ni projet — allume « Mon projet Claude » dans les réglages"),
                              state: .info))
        }
        guard scope == .series else {
            if let tools = toolsRow(chat) { rows.append(tools) }
            return rows
        }
        if let series {
            let address = seriesAddress
            let pdf = address.map { if case .ready? = desk.document($0) { return true }; return false } ?? false
            let site = exercise.flatMap { siteStatements[$0.id] } != nil
            rows.append(.init(icon: "doc.text", title: name(series),
                              detail: pdf ? (chat.opened ? String(localized: "énoncé envoyé au début") : String(localized: "l'énoncé (PDF) part avec le premier message"))
                                  : (site ? String(localized: "énoncé lu sur le site du cours") : String(localized: "Claude n'a que les numéros et les titres")),
                              state: pdf || site ? .ok : .warning))
        }
        if let exercise {
            let questions = exercise.leafSubQuestions.count
            rows.append(.init(icon: "pencil", title: exercise.displayNumber,
                              detail: questions > 0 ? String(localized: "\(exercise.subQuestionDoneCount)/\(questions) questions cochées") : nil, state: .ok))
            if settings.reviewHints {
                let hints = exercise.hints
                rows.append(.init(icon: "lightbulb", title: hints.isEmpty ? String(localized: "Aucun indice encore") : Plural.count(hints.count, "\(hints.count) indice sur cet exercice", "\(hints.count) indices sur cet exercice"),
                                  detail: hints.last.map { String(localized: "dernier : niveau \($0.level) — \($0.text)") }, state: hints.isEmpty ? .missing : .info))
            }
        } else {
            rows.append(.init(icon: "pencil", title: String(localized: "Pas d'exercice en cours"), detail: String(localized: "choisis-en un : Claude saura où tu en es"), state: .missing))
        }
        if let copy = currentCopy {
            let age = Date().timeIntervalSince(copy.modified)
            rows.append(.init(icon: "pencil.and.scribble", title: String(localized: "Ta copie : ") + copy.title,
                              detail: String(localized: "sauvegardée \(copy.modified.formatted(.relative(presentation: .named)))")
                                + (age > 3 * 3600 ? String(localized: " — GoodNotes n'envoie tes dernières pages qu'app ouverte : ouvre-la sur l'iPad, ou « Sauvegarder maintenant »") : ""),
                              state: age > 3 * 3600 ? .warning : .ok,
                              help: String(localized: "\(copy.notebook) · seules les pages que Claude n'a pas encore vues partent (nouvelles ou modifiées)")))
        } else {
            rows.append(.init(icon: "pencil.and.scribble", title: String(localized: "Copie introuvable dans tes notes"),
                              detail: String(localized: "range ta série dans un cahier du cours (« Série \(series?.seriesNumber ?? 0) »), ou joins une photo"), state: .missing))
        }
        if let tools = toolsRow(chat) { rows.append(tools) }
        if let tokens = chat.contextTokens {
            rows.append(.init(icon: "gauge.with.dots.needle.33percent", title: String(localized: "Contexte : \(tokens >= 1000 ? "\(tokens / 1000) k" : "\(tokens)") jetons"),
                              detail: file?.model(for: nil, scope: .series).map { String(localized: "modèle \($0)") }, state: .info))
        }
        return rows
    }

    /// Les outils de Claude en **une** ligne : une ligne par serveur MCP noyait le contexte
    /// (une vingtaine de lignes, la plupart des plugins que tu n'utilises pas ici). Les noms
    /// sont dans l'infobulle ; ce qui n'est pas connecté n'est pas une alerte.
    private func toolsRow(_ chat: ClaudeChat) -> ClaudeContextPanel.Row? {
        let servers = chat.info?.mcpServers ?? []
        guard !servers.isEmpty else { return nil }
        let on = servers.filter { $0.status == "connected" }
        let off = servers.filter { $0.status != "connected" }
        let label = { (server: ClaudeTutor.SessionInfo.MCPServer) in ClaudeTutor.toolLabel("mcp__" + server.name) }
        var help = ""
        if !on.isEmpty { help += String(localized: "Connectés : ") + on.map(label).joined(separator: ", ") }
        if !off.isEmpty { help += (help.isEmpty ? "" : "\n") + String(localized: "À connecter (claude puis /mcp dans le Terminal) : ") + off.map(label).joined(separator: ", ") }
        return .init(icon: "point.3.connected.trianglepath.dotted", title: Plural.count(on.count, "Outils : \(on.count) connecté", "Outils : \(on.count) connectés"),
                     detail: off.isEmpty ? nil : String(localized: "\(off.count) à connecter — voir l'infobulle"), state: on.isEmpty ? .info : .ok, help: help)
    }

    private func name(_ series: ExerciseSeries) -> String {
        series.title.isEmpty ? series.displayName : series.title
    }

    // MARK: Conversation

    private func conversation(_ chat: ClaudeChat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty { welcome }
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        if message.role == .student, let label = message.exercise, label != Self.previousExercise(chat.messages, before: index) {
                            ExerciseDivider(title: TutorFramework.shortExercise(label))
                        }
                        MessageView(message: message, thinking: chat.isThinking && message.isStreaming,
                                    tool: message.isStreaming ? chat.activeTool : nil)
                            .id(message.id)
                        if message.role == .claude, !message.isStreaming, let series {
                            let report = SeriesReview.parse(message.text)
                            if report.needsConfirmation {
                                ReviewCard(report: report, series: series, features: chat.config.review,
                                           ladder: file?.redo ?? RedoLadder.Config())
                            }
                            if chat.config.review.hints {
                                ForEach(Array(report.hints.enumerated()), id: \.offset) { _, hint in
                                    HintChip(hint: hint, series: series)
                                }
                                .task(id: message.id) { SeriesReview.recordHints(report.hints, in: series) }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// L'exercice du message d'étudiant·e précédent (pour ne poser un séparateur que quand il change).
    private static func previousExercise(_ messages: [ClaudeChat.Message], before index: Int) -> String? {
        messages[..<index].last(where: { $0.role == .student && $0.exercise != nil })?.exercise
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(scope == .system ? "On fait quoi ?" : (exercise.map { String(localized: "On attaque l'\($0.displayNumber.lowercased()) ?") } ?? (series == nil ? String(localized: "Une question ?") : String(localized: "On attaque ?"))))
                .font(StudyType.displaySmall).foregroundStyle(Carnet.ink)
            Text(scope == .system
                 ? "La conversation générale : ton brief, ta semaine, ta revue — les commandes de ton projet."
                 : "Une seule conversation pour toute la série : Claude suit l'exercice du chrono, garde les indices donnés et, à la fin, propose de noter tes erreurs et ce qu'il faut refaire.")
                .foregroundStyle(Carnet.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.top, 24)
    }

    // MARK: Suggestions et commandes

    /// La série est finie et pas encore close (des exercices faits sans correction).
    private var readyToClose: Bool {
        guard let series, !series.requiredExercises.isEmpty else { return false }
        return series.requiredExercises.allSatisfy { ExerciseStage($0).isDone } && series.exercises.contains { $0.isDone && !$0.isCorrected }
    }

    private func postMortem() {
        if let command = file?.commands(.series).first(where: { $0.verdicts == true }) {
            run(command)
        } else {
            send(ClaudeTutor.postMortemPrompt(useSkill: usesSkill, features: settings.reviewFeatures(file)), label: String(localized: "Clore la série"),
                 model: file?.model(for: nil, scope: .system))
        }
    }

    /// Trois gestes au plus, selon le moment : clore une série finie, un
    /// indice et une vérification sur l'exercice en cours, sinon la notion.
    private var suggestions: [ClaudeSuggestion] {
        guard scope == .series else {
            return (file?.commands(.system) ?? []).prefix(3).map { command in
                ClaudeSuggestion(id: command.id, label: command.label, icon: command.icon) { run(command) }
            }
        }
        var list: [ClaudeSuggestion] = []
        if readyToClose {
            list.append(ClaudeSuggestion(id: "close", label: String(localized: "Clore la série"), icon: "checkmark.seal", primary: true,
                                         help: String(localized: "Comparer ta copie au corrigé : corrections, carnet d'erreurs, exercices à refaire"),
                                         action: postMortem))
        }
        if exercise != nil {
            // Selon l'état (l'échelle d'indices, une question posée, la copie), pas toujours les trois mêmes.
            let asks = chat?.messages.last(where: { $0.role == .claude && !$0.isStreaming }).map { TutorFramework.asksQuestion($0.text) } ?? false
            for next in TutorFramework.suggestions(tutorState, replyAsksQuestion: asks) { list.append(suggestion(next)) }
        } else {
            list.append(ClaudeSuggestion(id: "explain", label: String(localized: "La notion de la série"), icon: "book") {
                send("Quelles notions cette série fait-elle travailler ? Où les revoir dans le cours ?")
            })
        }
        return Array(list.prefix(3))
    }

    private func suggestion(_ next: TutorFramework.Next) -> ClaudeSuggestion {
        switch next {
        case .hint(let level):
            return ClaudeSuggestion(id: "hint\(level)", label: level == 1 ? String(localized: "Un indice") : String(localized: "Indice \(level)"), icon: "lightbulb",
                                    help: String(localized: "Niveau \(level) sur 4 : \(TutorFramework.levelName(level))")) {
                send(TutorFramework.hintPrompt(after: level - 1))
            }
        case .tryIt:
            return ClaudeSuggestion(id: "try", label: String(localized: "J'essaie"), icon: "pencil", help: String(localized: "Écrire ta tentative : Claude te dit où est la première erreur")) {
                if draft.isEmpty { draft = "Ma tentative : " }
                focused = true
            }
        case .check:
            return ClaudeSuggestion(id: "check", label: currentCopy == nil ? String(localized: "Vérifie-moi") : String(localized: "Vérifie ma copie"), icon: "checkmark.circle",
                                    help: currentCopy.map { String(localized: "Envoie « \($0.title) » (sauvegardée \($0.modified.formatted(.relative(presentation: .named))))") }) {
                let copy = currentCopy
                Task {
                    let attached = await copy.asyncMap { await attachCopy($0) } ?? nil
                    send(ClaudeTutor.QuickAction.check.prompt + (attached == false ? "\n\n(Ma copie n'a pas changé depuis mon dernier envoi : relis les pages que tu as déjà.)" : ""),
                         model: .some(file?.model(for: nil, scope: .system)))
                }
            }
        case .nextStep:
            return ClaudeSuggestion(id: "next", label: "Étape suivante", icon: "arrow.right.circle") { send(ClaudeTutor.QuickAction.nextStep.prompt) }
        case .explain:
            return ClaudeSuggestion(id: "explain", label: "La notion", icon: "book") { send(ClaudeTutor.QuickAction.explain.prompt) }
        case .solution:
            return ClaudeSuggestion(id: "solution", label: String(localized: "La solution"), icon: "eye") {
                send(ClaudeTutor.QuickAction.solution.prompt, model: .some(file?.model(for: nil, scope: .system)))
            }
        }
    }

    // MARK: L'état du tuteur

    /// Ce que Claude doit savoir à ce message, et ce que le bandeau montre : l'exercice, l'échelle
    /// d'indices déjà montée, les questions cochées, les pages de la copie déjà reçues.
    private var tutorState: TutorFramework.State {
        var state = TutorFramework.State(tutor: (chat?.mode ?? .tutor) == .tutor)
        guard scope == .series else { return state }
        if let exercise {
            state.exercise = "\(exercise.series.map { "Série \($0.seriesNumber) · " } ?? "")\(exercise.displayNumber)"
            state.marked = exercise.correctness.map { .corrected($0.label.lowercased()) } ?? (exercise.isDone ? .done : .notMarked)
            state.hintLevel = exercise.hints.map(\.level).max() ?? 0
            state.questionsDone = exercise.subQuestionDoneCount
            state.questionsTotal = exercise.leafSubQuestions.count
        }
        if let copy = currentCopy, let chat {
            let seen = Self.seenCopy(chat, copy)
            state.copy = .init(notebook: copy.title, pagesSeen: seen.pages, total: seen.total)
        }
        return state
    }

    /// Les pages de la copie que cette conversation a reçues (leurs numéros dans le cahier).
    private static func seenCopy(_ chat: ClaudeChat, _ copy: NotesLibrary.Document) -> (pages: [Int], total: Int) {
        let key = "claude.seenPages.\(chat.sessionID.uuidString).\(copy.path)"
        return (UserDefaults.standard.array(forKey: key) as? [Int] ?? [], UserDefaults.standard.integer(forKey: key + ".total"))
    }

    private static func rememberSeen(_ chat: ClaudeChat, path: String, pages: [Int], total: Int) {
        let key = "claude.seenPages.\(chat.sessionID.uuidString).\(path)"
        let known = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
        UserDefaults.standard.set(Array(Set(known + pages)).sorted(), forKey: key)
        UserDefaults.standard.set(total, forKey: key + ".total")
    }

    /// Toutes les commandes, rangées : les gestes du tuteur, celles de la
    /// série (le fichier du projet), puis la conversation générale.
    private var commandsMenu: some View {
        Menu {
            if scope == .series {
                Section("Sur l'exercice") {
                    ForEach(ClaudeTutor.QuickAction.allCases) { action in
                        Button(action.label, systemImage: action.icon) {
                            if action == .check || action == .solution {
                                send(action.prompt, model: .some(file?.model(for: nil, scope: .system)))
                            } else {
                                send(action.prompt)
                            }
                        }
                    }
                }
                Section("Sur la série") {
                    if let commands = file?.commands(.series), !commands.isEmpty {
                        ForEach(commands) { command in Button(command.label, systemImage: command.icon) { run(command) } }
                    } else {
                        Button("Clore la série", systemImage: "checkmark.seal", action: postMortem).disabled(series?.doneCount == 0)
                        Button("Rapport", systemImage: "doc.text.magnifyingglass") {
                            send(ClaudeTutor.reportPrompt, label: "Rapport", model: file?.model(for: nil, scope: .system))
                        }
                    }
                }
            }
            if let commands = file?.commands(.system), !commands.isEmpty {
                Section("Général") {
                    ForEach(commands) { command in
                        Button(command.label, systemImage: command.icon) {
                            scopeChoice = .system
                            run(command)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "command")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Carnet.inkSecondary)
        .help("Toutes les commandes (les tiennes viennent de polymestre.json)")
    }

    /// Les valeurs d'une commande du fichier : le cours, la série, l'exercice.
    private var placeholders: ClaudeProject.Placeholders {
        ClaudeProject.Placeholders(code: course?.displayCode ?? "", course: course.map { ClaudeProject.shortCourseName($0.name) } ?? "",
                                   seriesNumber: series.map { "\($0.seriesNumber)" } ?? "", seriesTitle: series.map(name) ?? "",
                                   exercise: exercise?.exerciseNumber ?? "")
    }

    private func run(_ command: ClaudeProject.File.Command) {
        var prompt = ClaudeProject.expand(command.prompt, placeholders)
        if command.verdicts == true { prompt += "\n\n" + SeriesReview.instruction(features: settings.reviewFeatures(file)) }
        let model = file?.model(for: command, scope: command.scope)
        if command.capture == true || command.attach == true {
            // D'abord la copie ou le fichier ; l'envoi reste à l'étudiant·e.
            draft = prompt
            pendingModel = model
            if command.capture == true { capture() } else { pick() }
            return
        }
        send(prompt, label: command.label, model: model)
    }

    private var notInstalled: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.largeTitle).foregroundStyle(Carnet.inkSecondary)
            Text("Le tuteur gratuit répond").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
            Text("Pose ta question ci-dessous. Pour Claude (ton abonnement, il lit le PDF de la série) : installe Claude Code, puis tape `claude` une fois dans le Terminal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Carnet.inkSecondary)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Saisie

    private func composer(_ chat: ClaudeChat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                // Sur une ligne, qui défile quand la fenêtre est étroite.
                ScrollView(.horizontal, showsIndicators: false) {
                    SuggestionRow(suggestions: suggestions, tint: tint, disabled: chat.isAnswering)
                }
                commandsMenu
            }
            if let copyNotice {
                Label(copyNotice, systemImage: "pencil.and.scribble")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                    .transition(.opacity)
            }
            if !attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                        HStack(spacing: 6) {
                            if index < previews.count {
                                Image(nsImage: previews[index]).resizable().scaledToFill().frame(width: 34, height: 34)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            } else {
                                Image(systemName: "doc.richtext")
                            }
                            Text(attachment.name).font(.caption).lineLimit(1)
                            Button {
                                copyPrints[attachments[index].name] = nil
                                attachments.remove(at: index)
                                if index < previews.count { previews.remove(at: index) }
                            } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain)
                        }
                        .padding(6)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    if let copy = currentCopy {
                        Button("Ma copie : \(copy.title)", systemImage: "pencil.and.scribble") { Task { await attachCopy(copy) } }
                        Button("Renvoyer toute ma copie", systemImage: "arrow.clockwise") { Task { await attachCopy(copy, everything: true) } }
                    }
                    Button("Joindre un fichier…", systemImage: "paperclip", action: pick)
                    Divider()
                    Toggle("Joindre la série", isOn: $attachSeries)
                } label: {
                    Image(systemName: "plus.circle").font(.title2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Carnet.inkSecondary)
                if let copy = currentCopy {
                    let stale = Date().timeIntervalSince(copy.modified) > 3 * 3600
                    Button { Task { await attachCopy(copy) } } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "pencil.and.scribble").font(.title3)
                            Text(copy.modified.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(stale ? Carnet.review : Carnet.inkSecondary)
                    .help("Joindre ta copie « \(copy.title) », sauvegardée \(copy.modified.formatted(.relative(presentation: .named)))"
                          + (stale ? String(localized: " — ouvre GoodNotes sur l'iPad pour envoyer tes dernières pages") : ""))
                }
                TextField(scope == .system ? "Ta demande" : (chat.mode == .tutor ? String(localized: "Où tu bloques ?") : String(localized: "Ta question")), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(10)
                    .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Carnet.rule))
                    .onSubmit { send(draft) }
                if chat.isAnswering {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.title) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.ink)
                        .help("Arrêter")
                } else {
                    Button { send(draft) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .buttonStyle(.plain)
                        .foregroundStyle(draft.isEmpty && attachments.isEmpty ? Carnet.inkTertiary : Carnet.ink)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(draft.isEmpty && attachments.isEmpty)
                }
            }
        }
        .padding(12)
        .background(Carnet.ground)
        .onDrop(of: [.image, .pdf, .fileURL], isTargeted: nil) { providers in
            drop(providers)
            return true
        }
        .onPasteCommand(of: [.image, .png, .tiff]) { providers in drop(providers) }
        // Continuity Camera : clic droit › « Prendre une photo » / « Numériser
        // des documents » avec l'iPhone, sans quitter le mode étude.
        .importsItemProviders([.image, .pdf]) { providers in
            drop(providers)
            return true
        }
        .task { await NotesStore.shared.refresh() }
    }

    // MARK: Gestes

    private func takePending() {
        if let draft = desk.pendingDraftAttachment {
            desk.pendingDraftAttachment = nil
            attachments.append(draft)
            if case .image = draft.kind, let image = NSImage(data: draft.data) { previews.append(image) }
            focused = true
        }
        guard config != nil, let question = desk.pendingQuestion else { return }
        attachSeries = desk.pendingAttachSeries
        desk.pendingQuestion = nil
        if let attachment = desk.pendingAttachment {
            // « Vérifier ma copie » : ta copie GoodNotes part avec la question —
            // seulement ses pages que la conversation n'a pas encore vues.
            desk.pendingAttachment = nil
            if let path = attachment.notebookPath, let copy = NotesStore.shared.documents.first(where: { $0.path == path }) {
                Task {
                    let attached = await attachCopy(copy)
                    send(question + (attached == false ? "\n\n(Ma copie n'a pas changé depuis mon dernier envoi : relis les pages que tu as déjà.)" : ""))
                }
            } else {
                attachments.append(attachment)
                send(question)
            }
        } else if question == ClaudeTutor.QuickAction.check.prompt {
            // Pas de copie trouvée dans tes notes : on te laisse la joindre.
            draft = question
            pick()
        } else {
            send(question)
        }
    }

    /// La compétence de série du fichier du projet, si elle est là.
    private var seriesSkill: String? {
        guard let chat, chat.config.profile == .project, let skill = file?.seriesSkill else { return nil }
        let loaded = chat.info?.hasSkill(skill) ?? ClaudeProjectSetup.linkedSkills(settings: settings).contains(skill)
        return loaded ? skill : nil
    }

    private var usesSkill: Bool { seriesSkill != nil }

    /// - Parameter model: `nil` → le modèle par défaut de la conversation
    ///   (`tutor` en série, `system` dans la conversation EPFL).
    private func send(_ text: String, label: String? = nil, model: String?? = nil) {
        // « regarde la page 4 » : cette page de ta copie part avec le message (avant, Claude ne recevait
        // rien et répondait d'après la page qu'il croyait se rappeler).
        let pages = scope == .series ? TutorFramework.copyPageRequest(in: text) : []
        if !pages.isEmpty, let copy = currentCopy, !(chat?.isAnswering ?? true) {
            Task {
                await attachPages(copy, pages)
                deliver(text, label: label, model: model)
            }
        } else {
            deliver(text, label: label, model: model)
        }
    }

    private func deliver(_ text: String, label: String?, model: String?? ) {
        guard let chat else { return }
        var files = attachments
        var pdfAttached = false
        if scope == .series, attachSeries, !chat.opened, let address = seriesAddress,
           case .ready(let url)? = desk.document(address), let data = try? Data(contentsOf: url) {
            files.insert(.init(kind: .pdf, data: data, name: series.map(name) ?? String(localized: "Série"), origin: .series(series.map(name) ?? String(localized: "Série"))), at: 0)
            pdfAttached = true
        }
        var state = tutorState
        let origins = files.map { file -> TutorFramework.Origin in
            if let origin = file.origin { return origin }
            if case .image = file.kind { return .photo }
            return .file(file.name)
        }
        var situation = scope == .series
            ? ClaudeChat.Situation(series: series.map { seriesContext($0, pdfAttached: pdfAttached) },
                                   exerciseID: exercise?.id, exercise: context, skill: seriesSkill)
            : ClaudeChat.Situation(series: nil, exerciseID: nil, exercise: ClaudeTutor.Context(), skill: nil)
        if scope == .series {
            state.tutor = chat.mode == .tutor
            situation.card = TutorFramework.card(state, attached: origins)
            situation.exerciseLabel = state.exercise
            // Les pages de la copie qui partent : retenues pour la prochaine fois.
            for case .copy(_, let pages, let total, _) in origins {
                if let path = files.first(where: { $0.notebookPath != nil })?.notebookPath { Self.rememberSeen(chat, path: path, pages: pages, total: total) }
            }
        }
        let chosen: String? = model ?? pendingModel ?? file?.model(for: nil, scope: scope == .series ? .series : .system)
        chat.send(text, label: label, attachments: files, images: previews, model: chosen, situation: situation)
        // Les pages de copie parties : la conversation les a, on ne les renverra plus.
        for file in files {
            guard let entry = copyPrints[file.name] else { continue }
            let known = UserDefaults.standard.stringArray(forKey: entry.key) ?? []
            UserDefaults.standard.set(Array(Set(known + entry.prints)), forKey: entry.key)
        }
        copyPrints = [:]
        draft = ""
        attachments = []
        previews = []
        pendingModel = nil
    }

    private func seriesContext(_ series: ExerciseSeries, pdfAttached: Bool) -> ClaudeTutor.SeriesContext {
        ClaudeTutor.SeriesContext(
            courseCode: course?.displayCode, courseName: course?.name, title: name(series),
            week: series.plannedWeek > 0 ? series.plannedWeek : nil,
            due: series.dueDate.map { $0.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_CH"))) },
            exercises: series.sortedExercises.map { item in
                let status = item.correctness.map { $0.label.lowercased() } ?? (item.isDone ? String(localized: "fait") : String(localized: "à faire"))
                return .init(number: item.exerciseNumber, title: item.title, status: status + (item.isBonus ? " (bonus)" : ""))
            },
            pdfAttached: pdfAttached)
    }

    private var context: ClaudeTutor.Context {
        let questions = exercise?.leafSubQuestions.map { "\($0.path) \($0.text)\($0.isDone ? " (fait)" : "")" } ?? []
        return ClaudeTutor.Context(courseCode: course?.displayCode, courseName: course?.name,
                                   exercise: exercise.map { "\($0.series.map { "Série \($0.seriesNumber) · " } ?? "")\($0.displayNumber)" },
                                   statement: exercise.map { $0.statement.isEmpty ? (siteStatements[$0.id] ?? "") : $0.statement }, questions: questions,
                                   doneQuestions: exercise?.subQuestionDoneCount ?? 0,
                                   correction: exercise?.correctness?.label, hint: exercise?.hint.isEmpty == false ? exercise?.hint : nil)
    }

    /// Ta copie de la série en cours, dans tes notes.
    private var currentCopy: NotesLibrary.Document? {
        guard scope == .series, let series, let course else { return nil }
        return NotesStore.shared.copy(for: series, course: course, among: courses)
    }

    /// Joindre ta copie : seulement les pages que cette conversation n'a pas
    /// encore reçues (nouvelles ou modifiées depuis le dernier envoi), au lieu
    /// du cahier entier à chaque fois. `true` : jointe ; `false` : rien de neuf
    /// (Claude a déjà tout) ; `nil` : illisible.
    @discardableResult
    private func attachCopy(_ copy: NotesLibrary.Document, everything: Bool = false) async -> Bool? {
        guard let chat, let url = NotesStore.shared.url(copy) else { return nil }
        let key = "claude.sentPages.\(chat.sessionID.uuidString).\(copy.path)"
        let sent: Set<String> = everything ? [] : Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard let delta = await Task.detached(priority: .userInitiated, operation: {
            NotesStore.copyDelta(url: url, alreadySent: sent)
        }).value else { return nil }
        if delta.isEmpty {
            flashCopyNotice(String(localized: "Ta copie n'a pas changé depuis ton dernier envoi : Claude l'a déjà"))
            return false
        }
        // Une seule version de la copie dans le message.
        attachments.removeAll { $0.notebookPath == copy.path }
        let name = delta.title(copy.title, firstTime: sent.isEmpty)
        attachments.append(.init(kind: .pdf, data: delta.data, name: name, notebookPath: copy.path,
                                 origin: .copy(notebook: copy.title, pages: delta.pages, total: delta.total, requested: false)))
        copyPrints[name] = CopyPrints(key: key, prints: delta.fingerprints)
        if !sent.isEmpty {
            flashCopyNotice(String(localized: "Seulement les pages \(NotesStore.CopyDelta.ranges(delta.pages)) : Claude a déjà les autres"))
        }
        focused = true
        return true
    }

    /// Des pages précises de la copie (« regarde la page 4 ») : jointes telles qu'elles sont maintenant.
    private func attachPages(_ copy: NotesLibrary.Document, _ pages: [Int]) async {
        guard let chat, let url = NotesStore.shared.url(copy) else { return }
        guard let delta = await Task.detached(priority: .userInitiated, operation: {
            NotesStore.copyPages(url: url, pages: pages)
        }).value else { return }
        guard !delta.isEmpty else {
            flashCopyNotice(String(localized: "Ta copie a \(delta.total) pages : pas de page \(TutorFramework.ranges(pages))"))
            return
        }
        attachments.removeAll { $0.notebookPath == copy.path }
        let name = "\(copy.title) — page\(delta.pages.count > 1 ? "s" : "") \(TutorFramework.ranges(delta.pages)) sur \(delta.total)"
        attachments.append(.init(kind: .pdf, data: delta.data, name: name, notebookPath: copy.path,
                                 origin: .copy(notebook: copy.title, pages: delta.pages, total: delta.total, requested: true)))
        copyPrints[name] = CopyPrints(key: "claude.sentPages.\(chat.sessionID.uuidString).\(copy.path)", prints: delta.fingerprints)
    }

    private func flashCopyNotice(_ text: String) {
        copyNotice = text
        Task {
            try? await Task.sleep(for: .seconds(4))
            if copyNotice == text { copyNotice = nil }
        }
    }

    /// La capture interactive du système (un viseur, comme ⇧⌘4).
    private func capture() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("polymestre-capture-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", file.path]
        process.terminationHandler = { _ in
            Task { @MainActor in
                guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return }
                attachments.append(.init(kind: .image(mime: "image/png"), data: data, name: "Capture"))
                previews.append(image)
                focused = true
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        try? process.run()
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url) }
    }

    private func add(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        if url.pathExtension.lowercased() == "pdf" {
            attachments.append(.init(kind: .pdf, data: data, name: url.lastPathComponent))
        } else if let image = NSImage(data: data), let png = image.pngData {
            attachments.append(.init(kind: .image(mime: "image/png"), data: png, name: url.lastPathComponent))
            previews.append(image)
        }
    }

    private func drop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add(url) }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage, let png = image.pngData else { return }
                    Task { @MainActor in
                        attachments.append(.init(kind: .image(mime: "image/png"), data: png, name: "Image"))
                        previews.append(image)
                    }
                }
            }
        }
    }
}

/// « — Exercice 6.3 — » : où la conversation change d'exercice (et qui reste après un relancement).
private struct ExerciseDivider: View {
    let title: String
    var series: String?

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Carnet.rule).frame(height: 1)
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Carnet.inkSecondary).fixedSize()
            Rectangle().fill(Carnet.rule).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

private struct MessageView: View {
    let message: ClaudeChat.Message
    let thinking: Bool
    var tool: String?

    var body: some View {
        switch message.role {
        case .student:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    HStack {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, image in
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                if !message.attachments.isEmpty {
                    Label(message.attachments.joined(separator: ", "), systemImage: "paperclip")
                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
                if let label = message.label {
                    Label(label, systemImage: "checklist")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Carnet.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else if !message.text.isEmpty {
                    Text(message.text)
                        .foregroundStyle(Carnet.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .claude:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle")
                    .foregroundStyle(Carnet.ink)
                    .frame(width: 26, height: 26)
                    .background(Carnet.sheetRaised, in: Circle())
                VStack(alignment: .leading, spacing: 8) {
                    if let error = message.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Carnet.wrong)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if message.text.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(tool.map { "\($0)…" } ?? (thinking ? "Claude réfléchit…" : "…")).foregroundStyle(Carnet.inkSecondary)
                        }
                    } else {
                        RichTextView(text: SeriesReview.withoutBlocks(message.text), size: 14.5)
                        if let tool, message.isStreaming {
                            Label("\(tool)…", systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(Carnet.inkTertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}
