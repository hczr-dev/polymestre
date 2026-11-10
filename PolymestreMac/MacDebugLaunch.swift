#if DEBUG
import AppKit
import SwiftData
import SwiftUI

/// Arguments de lancement du Mac pour les essais et les captures — jamais
/// compilés en Release (`-debugTimer`, `-epflConnect`, `-dumpMoodle`, `-dumpEdX`,
/// `-claudeButtons`, `-signInSheet`, `-dumpEd`, `-mathPreview`, `-debugPage`).
@MainActor
enum MacDebugLaunch {
    static func apply(timer: MacTimer, store: MacStore) {
        // `-snapshot -captureView claude-settings|claude-card|claude-menu <fichier.png>` :
        // une vue d'Avec mesure dessinée dans une fenêtre jamais montrée (transparente,
        // jamais mise devant), l'image écrite, puis on quitte.
        if let index = CommandLine.arguments.firstIndex(of: "-captureView"), index + 2 < CommandLine.arguments.count {
            let name = CommandLine.arguments[index + 1]
            let path = CommandLine.arguments[index + 2]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                ClaudeMeasureService.shared.refreshUsage(force: true)
                let content: AnyView
                let size: NSSize
                switch name {
                case "claude-card": content = AnyView(ClaudeMeasureCard().padding(24)); size = NSSize(width: 1000, height: 520)
                case "claude-menu": content = AnyView(ClaudeMeasureMenuLine().padding(16)); size = NSSize(width: 340, height: 60)
                case "recap":
                    let memory = try! ModelContainer(for: PolymestreSchema.current, configurations: [
                        ModelConfiguration(schema: PolymestreSchema.current, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
                    if CommandLine.arguments.contains("-previewSeed") { MacStore.previewSeedPublic(memory.mainContext) }
                    let ctx = ModelContext(memory)
                    let all = (try? ctx.fetch(FetchDescriptor<Course>())) ?? []
                    let c = all.first { $0.code.hasPrefix("MATH") } ?? all.first
                    let ex = c?.allExercises.first
                    let part = TimerEngine.RecordedPart(sessionID: UUID(), courseID: c?.id, taskType: .exercise,
                                                        targetID: ex?.id, seconds: 23 * 60)
                    let part2 = TimerEngine.RecordedPart(sessionID: UUID(), courseID: c?.id, taskType: .theory,
                                                         targetID: c?.theoryItems.first?.id, seconds: 11 * 60)
                    content = AnyView(SessionRecapCard(totalSeconds: 34 * 60, parts: [part, part2], endedAt: Date(),
                                                       headline: { _, type, target in
                                                           if let ex = c?.allExercises.first(where: { $0.id == target }) {
                                                               return ex.title.isEmpty ? ex.displayNumber : "\(ex.displayNumber) · \(ex.title)"
                                                           }
                                                           return type.label
                                                       },
                                                       tint: { _ in c.map { Carnet.tint($0.colorHex) } ?? Carnet.inkSecondary },
                                                       dismiss: {}, undo: {})
                        .modelContainer(memory)
                        .padding(20).frame(width: 420).background(Carnet.ground))
                    size = NSSize(width: 420, height: 460)
                case "late":
                    // « À rattraper » sur le cours de démonstration le plus en retard.
                    let memory = try! ModelContainer(for: PolymestreSchema.current, configurations: [
                        ModelConfiguration(schema: PolymestreSchema.current, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
                    MacStore.previewSeedPublic(memory.mainContext)
                    let ctx = memory.mainContext
                    let all = (try? ctx.fetch(FetchDescriptor<Course>())) ?? []
                    let course = all.first
                    // Des semaines passées avec du retard de chaque sorte.
                    if let course {
                        let titles = [["Bornes supérieures", "Parties entières", "Inégalité de Bernoulli", "Valeur absolue", "Densité de ℚ"],
                                      ["Suites récurrentes", "Monotonie d'une suite homographique", "Limite de n^{1/n}", "Critère de Cauchy"],
                                      ["Séries géométriques", "Critère de d'Alembert", "Séries alternées", "Produit de Cauchy", "Série harmonique"]]
                        for (i, week) in [4, 5, 6].enumerated() {
                            let series = ExerciseSeries(course: course, seriesNumber: week, label: week == 6 ? "b" : "", plannedWeek: week)
                            series.title = ["Borne supérieure", "Suites", "Séries"][i]
                            ctx.insert(series)
                            for (j, title) in titles[i].enumerated() {
                                let exercise = Exercise(series: series, exerciseNumber: "\(week).\(j + 1)", title: title, sortOrder: j)
                                ctx.insert(exercise)
                                switch (i + j) % 5 {
                                case 0: break
                                case 1: exercise.setDone(true)
                                case 2: exercise.correct(.wrong); exercise.redoRequired = true
                                default: exercise.correct(.correct)
                                }
                            }
                        }
                        for (n, week, title) in [("4.1", 4, "Le supremum"), ("5.1", 5, "Suites convergentes"), ("5.2", 5, "Théorème des gendarmes")] {
                            ctx.insert(TheoryItem(course: course, sectionNumber: week, number: n, title: title, kind: .video,
                                                  plannedWeek: week, sortOrder: week, urlString: ""))
                        }
                    }
                    content = AnyView(Group {
                        if let course { LateWorkView(course: course, openExercise: { _ in }, openTheory: { _ in }, openURL: { _ in }) }
                    }.modelContainer(memory).frame(width: 640, height: 1400).background(Carnet.ground))
                    size = NSSize(width: 640, height: 1400)
                case "hold":
                    // La barre « Maintiens pour finir » dans ses trois états.
                    content = AnyView(VStack(spacing: 18) {
                        HoldButton(title: "Terminer", systemImage: "checkmark", hold: 1.5) {}
                        HoldButton(title: "Sortie d'urgence", systemImage: "exclamationmark.triangle", hold: StudyMode.emergencyHold) {}
                        HoldButton(title: "Sans tenir", systemImage: "checkmark", hold: 0) {}
                    }.padding(24).frame(maxWidth: .infinity))
                    size = NSSize(width: 420, height: 220)
                case "personalize":
                    // Réglages › Personnaliser, à côté de la vraie app (base en
                    // mémoire, réglages jetables) : relire la page sans cliquer.
                    let memory = try! ModelContainer(for: PolymestreSchema.current, configurations: [
                        ModelConfiguration(schema: PolymestreSchema.current, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
                    if CommandLine.arguments.contains("-previewSeed") {
                        MacStore.previewSeedPublic(memory.mainContext)
                    }
                    content = AnyView(PersonalizeForm().modelContainer(memory).frame(width: 520).padding(.vertical, 12))
                    size = NSSize(width: 560, height: 900)

                case let page where page.hasPrefix("page-"):
                    // Une page de la fenêtre (`page-today|agenda|stats|groups|focus`), sur la vraie base.
                    let settings = StudyModeController.shared.settings ?? MacSettings()
                    let view: AnyView
                    switch page.dropFirst("page-".count) {
                    case "agenda": view = AnyView(MacAgendaView(open: { _, _ in }))
                    case "stats": view = AnyView(MacStatsView())
                    case "groups": view = AnyView(MacGroupsView())
                    case "focus": view = AnyView(MacFocusView())
                    default: view = AnyView(MacTodayView(open: { _, _ in }, goFocus: {}))
                    }
                    content = AnyView(view
                        .environment(settings).environment(timer).environment(settings.shared).environment(store)
                        .modelContainer(store.container))
                    size = NSSize(width: 1100, height: 900)
                case let page where page.hasPrefix("settings-"):
                    // Réglages › une page (`settings-general|chrono|study|accounts|claude`), avancé ouvert
                    // avec `-advanced`.
                    let key = String(page.dropFirst("settings-".count))
                    // Pour cette capture seulement : rien n'est écrit dans les vraies préférences.
                    HeadlessCapture.override(["settings.page": key,
                                              "settings.advanced.\(key)": CommandLine.arguments.contains("-advanced")])
                    let settings = StudyModeController.shared.settings ?? MacSettings()
                    content = AnyView(MacSettingsView()
                        .environment(settings).environment(timer).environment(settings.shared).environment(store)
                        .modelContainer(store.container))
                    size = NSSize(width: 760, height: CommandLine.arguments.contains("-advanced") ? 1100 : 580)
                default: content = AnyView(ClaudeMeasureSettingsPane()); size = NSSize(width: 520, height: 560)
                }
                let hosting = NSHostingView(rootView: content.frame(width: size.width, height: size.height).background(Carnet.ground))
                hosting.appearance = NSAppearance(named: .aqua)
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.alphaValue = 0
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .seconds(1.5))
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
        // `-dumpHotKeys <fichier>` : les raccourcis du système (numéro, nom, état, touche) —
        // lecture seule, sert à confirmer les numéros que le blocage éteint (spike S1).
        if let index = CommandLine.arguments.firstIndex(of: "-dumpHotKeys"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            var lines = ["disponible : \(SystemHotKeys.isAvailable)"]
            for id in 0...400 {
                guard let name = SystemHotKeys.name(id) else { continue }
                let binding = SystemHotKeys.binding(id).map { "touche \($0.code) modificateurs \(String($0.modifiers, radix: 16))" } ?? "-"
                lines.append("\(id)\t\(SystemHotKeys.isEnabled(id) ? "allumé" : "éteint")\t\(name)\t\(binding)")
            }
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            exit(0)
        }
        // `-hotKeyTrial 64,65,1,2 20` : éteint ces raccourcis 20 s (fiche écrite d'abord),
        // puis les rallume — pour vérifier à la main qu'un `kill -9` ne les laisse pas éteints
        // (spike S1b). Lancer avec `-isolatedTimer` désactive tout le reste.
        if let index = CommandLine.arguments.firstIndex(of: "-hotKeyTrial"), index + 2 < CommandLine.arguments.count {
            let ids = CommandLine.arguments[index + 1].split(separator: ",").compactMap { Int($0) }
            let seconds = Double(CommandLine.arguments[index + 2]) ?? 20
            let (disable, record) = StudyLockPlan.plan(wanted: ids, enabledNow: SystemHotKeys.isEnabled, existing: StudyLockStore.load(),
                                                       dockNow: nil, menuBarNow: nil)
            StudyLockStore.save(record)
            for id in disable { SystemHotKeys.setEnabled(id, false) }
            NSLog("hotKeyTrial : %d raccourcis éteints pour %.0f s", disable.count, seconds)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                for id in StudyLockPlan.restore(record) { SystemHotKeys.setEnabled(id, true) }
                StudyLockStore.clear()
                NSLog("hotKeyTrial : rétablis")
                exit(0)
            }
        }
        // `-debugTimer start|discard` : vérifier le chrono partagé sans cliquer.
        if let index = CommandLine.arguments.firstIndex(of: "-debugTimer"), index + 1 < CommandLine.arguments.count {
            let action = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if action == "start" { timer.start(taskType: .exercise, label: "Test du chrono partagé") }
                if action == "discard" { timer.discard() }
                // `-debugTimer setup` : le chemin du clic sur « Mode étude » (l'écran de choix), comme à la main.
                if action == "setup" { StudyModeController.shared.presentSetup() }
                if action == "study" {
                    let context = ModelContext(store.container)
                    let course = (try? context.fetch(FetchDescriptor<Course>()))?.first
                    // `-seedBotafogoSeries` : un exercice de la série Botafogo (la dernière).
                    let seriesChoice = CommandLine.arguments.contains("-seedBotafogoSeries") ? course?.sortedSeries.last : course?.sortedSeries.first
                    let exercise = seriesChoice?.sortedExercises.dropFirst().first
                    // `-studyMoment lecture|revision` : le bureau sous cette forme. Jamais
                    // de verrou en essai.
                    let moment = CommandLine.arguments.firstIndex(of: "-studyMoment").flatMap {
                        $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
                    }
                    let type: TaskType = moment == "lecture" ? .lecture : (moment == "revision" ? .theory : .exercise)
                    // `-studyOpen` : une session sans fin.
                    timer.enterStudy(minutes: CommandLine.arguments.contains("-studyOpen") ? nil : 25, courseID: course?.id, taskType: type,
                                     targetID: type == .exercise && !CommandLine.arguments.contains("-noTarget") ? exercise?.id : nil, label: "Test du mode étude", locks: false)
                    if let index = CommandLine.arguments.firstIndex(of: "-studyPane"), index + 1 < CommandLine.arguments.count,
                       let pane = StudyDesk.Pane(rawValue: CommandLine.arguments[index + 1]) {
                        StudyModeController.shared.desk.pane = pane
                    }
                    // `-studyPane claude` : Claude, flottant ; `-sideBySide` : le volet d'à côté ouvert.
                    if CommandLine.arguments.contains("claude") { StudyModeController.shared.desk.showClaude() }
                    if CommandLine.arguments.contains("-sideBySide") { StudyModeController.shared.desk.sideOpen = true }
                }
            }
        }
        // `-epflConnect` : la connexion silencieuse à chaque site, avec le résultat.
        // `-musicRemoteDemo` : un iPhone qui joue (captures du lecteur partagé).
        if CommandLine.arguments.contains("-musicRemoteDemo") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let now = Date()
                StudyMusic.shared.receive(.state(MusicLink.State(
                    device: "00000000-0000-0000-0000-0000000000AB", platform: .iphone, title: "Wait for Me", artist: "Reeve Carney",
                    album: "Hadestown (Original Broadway Cast Recording)", duration: 242, elapsed: 64, readAt: now, isPlaying: true,
                    artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/7a/a5/4c/7aa54c1a-0b0d-d3a2-7fd0-1f3b1a6a1d34/19UMGIM43231.rgb.jpg/600x600bb.jpg",
                    upNext: [.init(title: "Livin' It Up on Top", artist: "Hadestown"), .init(title: "All I've Ever Known", artist: "Eva Noblezada")],
                    updatedAt: now)))
            }
        }
        if CommandLine.arguments.contains("-epflConnect") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if CommandLine.arguments.contains("-epflOnlyMedia") { await SchoolConnect.shared.connect(.mediaspace) } else { await SchoolConnect.shared.connectAll() }
                let states = SchoolConnect.Site.allCases.map { "\($0.rawValue)=\(SchoolConnect.shared.state($0))" }.joined(separator: " ")
                FileHandle.standardError.write(Data("EPFL \(states) email=\(SchoolConnect.shared.email != nil)\n".utf8))
            }
        }
        // `-dumpMoodle <id> <fichier>` : le plan d'un cours Moodle et ce que les
        // règles en tirent, écrits dans un fichier (lecture seule, rien d'importé).
        if let index = CommandLine.arguments.firstIndex(of: "-dumpMoodle"), index + 2 < CommandLine.arguments.count,
           let courseID = Int(CommandLine.arguments[index + 1]) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await SchoolConnect.shared.ensure(.moodle)
                var lines: [String] = []
                do {
                    let client = SiteHub.shared.moodle
                    let ref = MoodleCourseRef(id: courseID, fullname: "", shortname: "")
                    let snapshot = try await client.snapshot(of: ref)
                    for section in snapshot.sections {
                        lines.append("## \(section.number) \(section.title)")
                        if !section.text.isEmpty { lines.append("   texte: \(section.text.prefix(300))") }
                        for link in section.links { lines.append("   lien[\(link.kind.rawValue)]: \(link.title) → \(link.url)") }
                        for activity in section.activities {
                            lines.append("  - [\(activity.module)\(activity.isVisible ? "" : " caché")] \(activity.name) → \(activity.link) dest=\(activity.destination ?? "-") sol=\(activity.solutionTarget ?? "-")")
                        }
                    }
                    let draft = MoodleCourseAnalyzer.draft(from: snapshot, termStart: nil, totalWeeks: 14)
                    lines.append("\n# Règles")
                    for section in draft.sections {
                        for item in section.items where item.kind == .series {
                            lines.append("S\(item.seriesNumber.map(String.init) ?? "?") sem \(item.week ?? section.week) « \(item.title) » \(item.pdfURL.isEmpty ? item.url : item.pdfURL)")
                        }
                    }
                } catch {
                    lines.append("erreur: \(error)")
                }
                try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
                FileHandle.standardError.write(Data("DUMP fini\n".utf8))
            }
        }
        // `-dumpEdX <course-v1:…> <dossier> [chapitre]` : le HTML brut des textes et
        // problèmes d'un chapitre de Courseware (lecture seule, rien n'est envoyé).
        if let index = CommandLine.arguments.firstIndex(of: "-dumpEdX"), index + 2 < CommandLine.arguments.count {
            let key = CommandLine.arguments[index + 1]
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            let chapter = index + 3 < CommandLine.arguments.count ? Int(CommandLine.arguments[index + 3]) ?? 0 : 0
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await SchoolConnect.shared.ensure(.courseware, prompting: false)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let client = SiteHub.shared.courseware
                if let outline = try? await client.outline(of: key), outline.chapters.indices.contains(chapter) {
                    var count = 0
                    for unit in outline.chapters[chapter].sequences.flatMap(\.units) {
                        for block in unit.blocks where count < 40 {
                            guard let address = block.viewURL, block.kind == .html || block.kind == .problem else { continue }
                            let html = (try? await client.blockHTML(address)) ?? ""
                            let name = String(format: "%02d-%@", count, block.kind == .html ? "html" : "problem")
                            try? ("<!-- \(unit.title) · \(block.title) · \(address) -->\n" + html)
                                .write(to: folder.appendingPathComponent(name + ".html"), atomically: true, encoding: .utf8)
                            if block.kind == .problem, let problem = try? await client.problem(address) {
                                try? ("PROMPT\n" + problem.prompt + "\n\nOPTIONS\n" + problem.groups.flatMap(\.options).map(\.label).joined(separator: "\n---\n"))
                                    .write(to: folder.appendingPathComponent(name + ".prompt.txt"), atomically: true, encoding: .utf8)
                            }
                            count += 1
                        }
                    }
                }
                FileHandle.standardError.write(Data("DUMP fini\n".utf8))
            }
        }
        // `-claudeButtons <fichier>` : l'éditeur des boutons de Claude sur ce
        // fichier (une copie, pour l'essayer sans toucher au vrai).
        if let index = CommandLine.arguments.firstIndex(of: "-claudeButtons"), index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let window = NSWindow(contentViewController: NSHostingController(rootView: ClaudeButtonsEditor(url: url)))
                window.title = "Boutons de Claude"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // `-signInSheet moodle|mediaspace` : la feuille de connexion seule.
        if let index = CommandLine.arguments.firstIndex(of: "-signInSheet"), index + 1 < CommandLine.arguments.count,
           let site = CommandLine.arguments[index + 1] == "mediaspace" ? StudySite.mediaspace : StudySite.moodle as StudySite? {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let window = NSWindow(contentViewController: NSHostingController(rootView: SignInSheet(site: site) {
                    FileHandle.standardError.write(Data("SIGNIN fini\n".utf8))
                }))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // `-dumpEd <code> <dossier>` : les fils Ed bruts d'un cours (lecture seule).
        if let index = CommandLine.arguments.firstIndex(of: "-dumpEd"), index + 2 < CommandLine.arguments.count {
            let code = CommandLine.arguments[index + 1].lowercased()
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await SchoolConnect.shared.ensure(.ed, prompting: false)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let ed = SiteHub.shared.ed
                let courses = (try? await ed.courses()) ?? []
                if let course = courses.first(where: { $0.code.lowercased().contains(code) || $0.name.lowercased().contains(code) }) {
                    let list = (try? await ed.debugGET("courses/\(course.id)/threads?limit=100&sort=new")) ?? Data()
                    try? list.write(to: folder.appendingPathComponent("threads.json"))
                    for thread in EdDiscussion.threads(json: list).prefix(100) {
                        let raw = (try? await ed.debugGET("threads/\(thread.id)")) ?? Data()
                        let text = String(decoding: raw, as: UTF8.self)
                        if text.contains("poll") {
                            try? raw.write(to: folder.appendingPathComponent("thread-\(thread.id).json"))
                            if let match = text.range(of: #"poll id=\\?"(\d+)"#, options: .regularExpression) {
                                let id = text[match].filter(\.isNumber)
                                let poll = (try? await ed.debugGET("polls/\(id)")) ?? Data()
                                try? poll.write(to: folder.appendingPathComponent("poll-\(id).json"))
                            }
                        }
                    }
                }
                FileHandle.standardError.write(Data("DUMP fini \(courses.map(\.code))\n".utf8))
            }
        }
        // `-mathPreview [adresse d'un problème Courseware]` : les formules mises
        // en page (texte d'essai, et un vrai problème, sans rien envoyer).
        if let index = CommandLine.arguments.firstIndex(of: "-mathPreview") {
            let address = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if let address { await SchoolConnect.shared.ensure(Int(address) == nil ? .courseware : .ed, prompting: false) }
                let sample = #"""
Soient V=\(\mathbb{P}_4(\mathbb{R})\), et \(T:V\to W\) définie par \(T(p(t))=p'(t)\). Soient aussi \(\mathscr{B}_V=\{1,t,t^2,t^3,t^4\}\) et les matrices \[ A_1=\begin{pmatrix} 0 & 1 & 0 & 0 & 0 \\ 0 & 0 & 2 & 0 & 0 \\ 0 & 0 & 0 & 3 & 0 \\ 0 & 0 & 0 & 0 & 4 \end{pmatrix},~ A_2=\begin{pmatrix} 0 & 4 & 0 & 0 & 0 \\ 0 & 0 & 3 & 0 & 0 \\ 0 & 0 & 0 & 2 & 0 \\ 0 & 0 & 0 & 0 & 1 \end{pmatrix}, \] Parmi les possibilités suivantes, cochez celle qui vous paraît correcte. La matrice \([T]_{\mathscr{B}_W\mathscr{B}_V}\) est donnée par \(A_1\), et \(\dim (W_1+W_2) = \dim W_1 + \dim W_2 -\dim(W_1\cap W_2)\), avec \(\dfrac{a}{b}\) et \(\operatorname{rg}(A)\leqslant n\).

## Markdown
- un point avec $x_n \to \ell$
- un lien : [Moodle](https://moodle.epfl.ch)
"""#
                let root = ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        RichTextView(text: sample, size: 15).paperSheet(padding: 16)
                        if let address, let poll = Int(address) {
                            EdPollCard(id: poll, desk: SiteHub.shared, open: { _, _ in }, openWeb: { _, _ in })
                        } else if let address {
                            EdXProblemCard(address: address, desk: SiteHub.shared, open: { _, _ in }, openWeb: { _, _ in })
                        }
                        ForEach(Array(SiteHTML.blocks("<h2 class=\"problem-header\">Contenu de la leçon</h2><h3></h3><p>Dans cette leçon, les matrices.</p><h2></h2><div><h2>objectifs</h2><h3></h3></div><ol><li>de maîtriser les notions (taille) ;<strong></strong></li><li>de comparer deux matrices.</li></ol>").enumerated()), id: \.offset) { _, block in
                            if case .markdown(let text) = block { RichTextView(text: text, size: 15) }
                        }
                    }
                    .padding(24)
                }
                .frame(width: 760, height: 820)
                .background(Carnet.ground)
                let window = NSWindow(contentViewController: NSHostingController(rootView: root))
                window.title = "Formules"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        // `-debugPage focus|stats|today` : ouvrir une page sans cliquer.
        if let index = CommandLine.arguments.firstIndex(of: "-debugPage"), index + 1 < CommandLine.arguments.count {
            let page = CommandLine.arguments[index + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if page == "palette" {
                    NotificationCenter.default.post(name: .macFocusSearch, object: nil)
                } else if page == "study" {
                    StudyModeController.shared.presentSetup()
                } else {
                    NotificationCenter.default.post(name: .macGoTo, object: page)
                }
            }
        }
    }
}
#endif
