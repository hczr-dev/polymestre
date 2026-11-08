import SwiftUI
import SwiftData

/// Le bureau du mode étude : une barre en haut (ce qui reste, sur quoi, les
/// gestes), une colonne d'outils à gauche, l'outil choisi au centre. Tout est
/// natif — la série en PDF, le cours (Polymestre, Moodle, Botafogo), Claude
/// par l'abonnement, la calculatrice ; le navigateur reste pour le reste.
struct StudyWorkspace: View {
    @Bindable var screen: StudyModeController.Screen
    @Bindable var browser: StudyBrowserModel
    @Bindable var desk: StudyDesk
    let courses: [Course]
    /// La barre du haut et la colonne d'outils sont des fenêtres à part (`-studyPanels`).
    var panels = false
    /// Le volet d'à côté est lui aussi une fenêtre à part : le centre n'en garde rien.
    var sideHosted = false
    /// Cette instance ne montre que le volet d'à côté (la fenêtre du volet).
    var onlySide = false

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.modelContext) private var context
    /// L'horaire du jour, relu chaque minute (le cours en cours, la suite).
    @State private var classes: [ScheduledClass] = []
    /// Relu toutes les 30 s : le bilan des cinq dernières minutes en dépend.
    @State private var now = Date()
    /// Une app d'écriture (GoodNotes) est au premier plan : l'énoncé passe à côté.
    @State private var frontWriting = false
    /// Le voile de pause / bilan qu'on a écarté (jusqu'au prochain changement).
    @State private var dismissedTakeover: DeskArrangement.Takeover?

    private var course: Course? { courses.first { $0.id == timer.courseID } }
    private var tint: Color { MacTargets.tint(course) }
    private var moment: DeskMoment {
        DeskSchedule.moment(taskType: timer.taskType, inGroup: timer.state?.groupSession != nil, course: course)
    }

    var body: some View {
        if onlySide {
            // La fenêtre du volet : la poignée à gauche, puis les onglets d'à côté.
            HStack(spacing: 0) {
                ScreenSplitHandle(desk: desk)
                    .frame(width: 9)
                    .overlay { Rectangle().fill(Carnet.rule).frame(width: 1).allowsHitTesting(false) }
                side
            }
            .background(Carnet.ground)
            .environment(\.colorScheme, .dark)
        } else {
            whole
        }
    }

    private var whole: some View {
        VStack(spacing: 0) {
            if !panels {
                StudyTopBar(course: course, tint: tint, moment: moment, openMusic: { desk.pane = .music }, openResource: openResource)
                Rectangle().fill(Carnet.rule).frame(height: 1)
            }
            HStack(spacing: 0) {
                if !panels {
                    StudyRail(desk: desk, browser: browser, course: course)
                    Rectangle().fill(Carnet.rule).frame(width: 1)
                }
                ZStack(alignment: .topLeading) {
                    DeskSplit(desk: desk, sideHosted: sideHosted) {
                        center
                    } side: {
                        side
                    }
                    ClaudeLayer(desk: desk) {
                        Frozen(key: course?.id) {
                            ClaudePane(course: course, courses: courses, desk: desk, accessory: AnyView(floatingClaudeButtons))
                        }
                        .equatable()
                    }
                }
            }
        }
        .overlay { DeskNoticeStack() }
        .overlay { takeoverView }
        .animation(.smooth(duration: 0.3), value: layout.takeover)
        .onChange(of: layout.takeover) { _, _ in dismissedTakeover = nil }
        .onChange(of: arrangementKey) { _, _ in arrange(force: false) }
        .onReceive(NotificationCenter.default.publisher(for: .studyTidyDesk)) { _ in arrange(force: true) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Polymestre lui-même qui revient devant ne change rien : on garde l'état d'avant.
            guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { frontWriting = false; return }
            frontWriting = app?.bundleIdentifier.map(StudyMode.writingApps.contains) ?? false
        }
        .onChange(of: arrangementContext.solutionAvailable) { old, new in
            if !old, new, arrangementContext.hasTarget {
                DeskNotifications.shared.post(.solution, String(localized: "Le corrigé de cette série est publié"), icon: "checkmark.seal")
            }
        }
        .task { await watchNotices() }
        .task {
            // Ed : les nouveaux fils du cours étudié, relus toutes les cinq minutes.
            while !Task.isCancelled {
                await EdWatcher.shared.poll(courses: courses.filter { $0.id == timer.courseID }, hub: desk.sites)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .studyEdThreadsRead)) { note in
            if let id = note.object as? UUID { EdWatcher.shared.markSeen(id, hub: desk.sites, courses: courses) }
        }
        .task {
            arrange(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                // Relu seulement quand cela peut changer quelque chose : en cours
                // (la pause), ou dans les dernières minutes (le bilan).
                let left = StudyMode.remaining(timer.state, at: Date()) / 60
                if moment == .lecture || (!StudyMode.isOpenEnded(timer.state) && left <= Double(DeskArrangement.wrapUpMinutes + 2)) {
                    now = Date()
                }
            }
        }
        .background(paneShortcuts)
        // Music suivi pendant toute la session (le petit lecteur de la barre du haut).
        .musicAttached()
        .sheet(item: $desk.signIn) { site in
            SignInSheet(site: site) { desk.signedIn(site) }
        }
        // En entrant dans le bureau : chaque site, sans rien afficher, avec la
        // session Microsoft déjà là (rien ne se passe si elle n'y est pas).
        .task {
            if !SchoolConnect.shared.allConnected { await SchoolConnect.shared.connectAll(prompting: true) }
        }
        // Claude prêt avant qu'on l'ouvre.
        .task { await desk.prepareClaude(settings: settings, courses: courses) }
        .task {
            while !Task.isCancelled {
                classes = DeskSchedule.today(context: context)
                let wake = DeskSchedule.nextChange(in: classes)
                try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow + 0.5)))
            }
        }
    }

    // MARK: Ce qui mérite une notification

    /// Un cours qui commence, une pause qui arrive : dits en haut du bureau, puisque
    /// le Centre de notifications est fermé pendant un blocage.
    private func watchNotices() async {
        var told: Set<UUID> = []
        var warnedBlock = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            let date = Date()
            if let next = DeskSchedule.next(in: classes, after: date), !told.contains(next.id),
               next.slot.start.timeIntervalSince(date) <= LectureClock.lead {
                told.insert(next.id)
                let minutes = max(1, Int((next.slot.start.timeIntervalSince(date) / 60).rounded(.up)))
                DeskNotifications.shared.post(.classSoon,
                                              "\(next.slot.courseCode) commence dans \(minutes) min" + (next.location.isEmpty ? "" : " · \(next.location)"),
                                              icon: "person.wave.2")
            }
            if timer.phase == .running, let status = timer.pomodoroStatus(at: date),
               status.remaining > 0, status.remaining <= 60, warnedBlock != status.blockNumber {
                warnedBlock = status.blockNumber
                DeskNotifications.shared.post(.breakSoon, String(localized: "Pause dans une minute"), icon: "cup.and.saucer")
            }
        }
    }

    // MARK: Le bureau s'arrange

    /// Ce que le bureau sait du moment (voir `DeskArrangement`).
    private var arrangementContext: DeskArrangement.Context {
        var context = DeskArrangement.Context(moment: moment)
        context.isTheory = timer.taskType.canonical == .theory
        context.phase = !timer.isStudying ? .ended : (timer.phase == .onBreak ? .onBreak : (timer.phase == .paused ? .paused : .running))
        let exercise = course?.allExercises.first { $0.id == timer.targetID }
        context.hasTarget = exercise != nil
        context.targetDone = exercise?.isDone ?? false
        let series = exercise?.series
        context.seriesComplete = exercise != nil && (series?.isComplete ?? false)
        context.solutionAvailable = series.map { solutionAddress($0) != nil } ?? false
        if let series, let course { context.hasCopy = NotesStore.shared.copy(for: series, course: course, among: courses) != nil }
        context.hasCourseNotes = course != nil
        context.writingApp = frontWriting
        if !StudyMode.isOpenEnded(timer.state) { context.minutesLeft = Int(StudyMode.remaining(timer.state, at: now) / 60) }
        if moment == .lecture, let klass = DeskSchedule.latest(of: course?.id, in: classes),
           case .pause = LectureClock.phase(of: klass.slot, at: now) {
            context.classBreak = true
        }
        return context
    }

    private var layout: DeskArrangement.Layout { DeskArrangement.layout(for: arrangementContext) }
    private var arrangementKey: String { DeskArrangement.signature(arrangementContext) }

    /// À un changement de moment (ou « Ranger le bureau ») : le centre, le côté
    /// et Claude se mettent en place, sauf ce que l'étudiant·e a déplacé.
    private func arrange(force: Bool) {
        let key = arrangementKey
        desk.pins = DeskArrangement.pins(desk.pins, previous: desk.lastSignature, current: key)
        guard force || key != desk.lastSignature else { return }
        desk.lastSignature = key
        #if DEBUG
        // `-studyPane …` (essais de débogage) : l'outil demandé reste, rien ne le déplace.
        if !force, CommandLine.arguments.contains("-studyPane") { desk.pins.center = true }
        #endif
        if force { desk.pins = DeskArrangement.Pins() }
        let wanted = layout
        let apply = DeskArrangement.applicable(wanted, pins: desk.pins)
        desk.applying = true
        defer { desk.applying = false }
        if let center = apply.center, let pane = StudyDesk.Pane(rawValue: center.rawValue) { desk.pane = pane }
        if let sides = apply.side {
            if let first = sides.compactMap(sideItem).first { desk.openSide(first) }
            desk.sideOpen = wanted.sideOpen
        }
        if apply.claude { desk.showClaude() }
    }

    /// Ce que `DeskArrangement.Side` ouvre : une entrée de ce que le volet propose déjà.
    private func sideItem(for side: DeskArrangement.Side) -> StudyDesk.SideItem? {
        let entries = sideSuggestions.flatMap(\.entries).map(\.item)
        switch side {
        case .series: return entries.first { $0.kind == .series }
        case .copy: return entries.first { if case .notebook = $0.kind { return true } else { return false } }
        case .solution: return entries.first { if case .reading(.pdf) = $0.kind { return $0.title == String(localized: "Corrigé") } else { return false } }
        case .courseNotes: return entries.first { $0.kind == .courseNotes }
        case .sheet: return entries.first { $0.kind == .sheet }
        }
    }

    // MARK: Ce qui prend l'écran

    @ViewBuilder
    private var takeoverView: some View {
        let kind = layout.takeover
        if kind != .none, dismissedTakeover != kind {
            ZStack {
                if kind != .wrapUp {
                    Color.black.opacity(0.4).ignoresSafeArea()
                        .onTapGesture { dismissedTakeover = kind }
                }
                VStack {
                    if kind == .wrapUp { Spacer() }
                    takeoverCard(kind)
                        .padding(kind == .wrapUp ? 24 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity)
        }
    }

    private func takeoverCard(_ kind: DeskArrangement.Takeover) -> some View {
        let minutes = arrangementContext.minutesLeft ?? 0
        let title: String, detail: String, icon: String
        switch kind {
        case .onBreak:
            title = String(localized: "Pause"); detail = String(localized: "Lève les yeux. Le bloc suivant t'attend."); icon = "cup.and.saucer"
        case .paused:
            title = String(localized: "En pause"); detail = String(localized: "Le temps ne compte plus."); icon = "pause.circle"
        case .classBreak:
            title = String(localized: "Pause du cours"); detail = String(localized: "Le cours reprend dans quelques minutes."); icon = "person.wave.2"
        default:
            title = String(localized: "Plus que \(minutes) min"); detail = String(localized: "Note où tu t'arrêtes, ou prolonge."); icon = "hourglass"
        }
        let exercise = course?.allExercises.first { $0.id == timer.targetID }
        return VStack(spacing: 14) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(StudyPalette.inkSecondary)
            Text(title).font(Carnet.serif(.title)).foregroundStyle(StudyPalette.ink)
            Text(detail).font(.callout).foregroundStyle(StudyPalette.inkSecondary)
            if kind == .onBreak {
                // La pause qui s'écoule, et ce qui vient après.
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer")
                    TimerClockText(font: .title2.monospacedDigit())
                }
                .foregroundStyle(StudyPalette.ink)
                if let status = timer.pomodoroStatus() {
                    Text("Ensuite : bloc \(status.completedBlocks + 1)").font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            if kind == .wrapUp, let exercise {
                // Où tu en es sur l'exercice en cours : un geste, avant que la session finisse.
                VStack(spacing: 6) {
                    Text(exercise.displayNumber + " : sûr·e ?").font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                    HStack(spacing: 8) {
                        ForEach(ConfidenceLevel.allCases) { level in
                            Button { exercise.confidence = level } label: {
                                Label(level.label, systemImage: level.icon)
                                    .font(.callout.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .foregroundStyle(exercise.confidence == level ? Carnet.ground : level.color)
                                    .background(exercise.confidence == level ? level.color : level.color.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                switch kind {
                case .onBreak:
                    Button("Écourter la pause") { timer.skipBreak() }.deskButton(prominent: true)
                    Button("Rester ici") { dismissedTakeover = kind }.deskButton()
                case .paused:
                    Button("Reprendre") { timer.resume() }.deskButton(prominent: true)
                    Button("Plus tard") { dismissedTakeover = kind }.deskButton()
                case .wrapUp:
                    if !StudyMode.isOpenEnded(timer.state) {
                        Button("Encore 25 min") { timer.extendStudy(minutes: 25) }.deskButton()
                    }
                    Button("D'accord") { dismissedTakeover = kind }.deskButton(prominent: true)
                default:
                    Button("D'accord") { dismissedTakeover = kind }.deskButton(prominent: true)
                }
            }
            .deskGlassGroup()
        }
        .padding(28)
        .frame(width: 380)
        .deskGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: Le centre

    /// Un outil à la fois ; ceux déjà ouverts restent vivants, cachés, et
    /// reviennent tels qu'on les a laissés.
    private var center: some View {
        // Chaque outil à une taille exacte : ce qui bouge dedans (une horloge,
        // l'avancée d'un morceau) n'oblige plus à recalculer la mise en page des
        // outils cachés à côté, ni celle du bureau.
        GeometryReader { geometry in
        ZStack {
            ForEach(StudyDesk.Pane.allCases.filter { desk.opened.contains($0) }) { which in
                let shown = desk.pane == which
                Group {
                    if which == .desk {
                        home
                    } else {
                        // Rendu une fois : changer d'outil, ouvrir le volet ou le
                        // redimensionner ne recalcule pas les outils cachés.
                        Frozen(key: [which.rawValue, course?.id.uuidString ?? ""]) { tool(which) }
                            .equatable()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .disabled(!shown)
                    .accessibilityHidden(!shown)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Carnet.ground.opacity(desk.pane == .desk ? 0 : 1))
    }

    @ViewBuilder
    private func tool(_ which: StudyDesk.Pane) -> some View {
        switch which {
        case .desk:
            home
        case .exercise:
            ExercisePane(course: course, desk: desk, openWeb: openWeb)
        case .course:
            CoursePane(course: course, desk: desk.sites, openWeb: openWeb, ask: { desk.ask($0, attachSeries: false) },
                       sendBeside: { reading, title in openBeside(reading, title: title) }, hasNotesTool: true,
                       go: { destination in
                           switch destination {
                           case .exercise(let exercise):
                               timer.retarget(courseID: course?.id, taskType: .exercise, targetID: exercise.id)
                               desk.pane = .exercise
                           case .notes:
                               desk.pane = .notes
                           }
                       })
        case .notes:
            NotesPane(course: course, sendBeside: { path, title in
                desk.openSide(.init(kind: .notebook(path: path), title: title, icon: "pencil.and.scribble", courseID: course?.id))
            })
        case .calc:
            CalcPane(desk: desk.calc, openWeb: openWeb)
        case .music:
            MusicPane()
        case .web:
            if browser.tabs.isEmpty {
                StudyWebHome(course: course, open: open)
            } else {
                StudyBrowserPane(browser: browser, tint: tint) { desk.pane = .desk }
                    .padding(14)
            }
        }
    }

    /// Le Bureau : l'accueil selon le moment (en cours, révision, séance).
    @ViewBuilder
    private var home: some View {
        switch moment {
        case .lecture where course != nil:
            StudyDeskHome(course: course, tint: tint, desk: desk, open: open, moment: moment, lecturePart: { part in
                AnyView(LectureDeskView(course: course!,
                                        klass: DeskSchedule.latest(of: course?.id, in: classes),
                                        next: DeskSchedule.next(in: classes),
                                        hub: desk.sites, compact: true, openCourse: openCourse,
                                        openApp: { bundleID, _ in StudyModeController.shared.openApp(bundleID: bundleID) },
                                        openWeb: openWeb, only: part))
            })
        case .revision where course != nil:
            StudyDeskHome(course: course, tint: tint, desk: desk, open: open, moment: moment, revisionPart: { part in
                AnyView(RevisionDeskView(course: course!, compact: true, openCourse: openCourse, work: { exercise in
                    timer.retarget(courseID: course?.id, taskType: .exercise, targetID: exercise.id)
                    desk.pane = .exercise
                }, only: part))
            })
        default:
            StudyDeskHome(course: course, tint: tint, desk: desk, open: open, moment: moment)
        }
    }

    // MARK: À côté

    /// Les onglets d'à côté de ce cours (et Claude, de tous les cours).
    private var sideItems: [StudyDesk.SideItem] {
        desk.sideItems.filter { $0.courseID == nil || $0.courseID == course?.id }
    }

    private var side: some View {
        VStack(spacing: 0) {
            SideTabBar(desk: desk, items: sideItems, tint: tint)
            Rectangle().fill(Carnet.rule).frame(height: 1)
            GeometryReader { geometry in
            ZStack {
                if !sideItems.contains(where: { $0.id == desk.sideSelection }) {
                    SidePicker(groups: sideSuggestions, openIDs: sideItems, tint: tint) { item in
                        if item.kind == .claude { desk.dockClaude() } else { desk.openSide(item) }
                    }
                }
                ForEach(sideItems) { item in
                    let shown = item.id == desk.sideSelection
                    Frozen(key: [item.id.uuidString, course?.id.uuidString ?? ""]) { sideContent(item) }
                        .equatable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .disabled(!shown)
                        .accessibilityHidden(!shown)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background(Carnet.ground)
    }

    @ViewBuilder
    private func sideContent(_ item: StudyDesk.SideItem) -> some View {
        switch item.kind {
        case .series:
            // Au centre, la série n'a pas besoin d'être à côté — sauf si le centre est
            // à une app d'écriture : l'énoncé est alors à côté.
            if desk.pane == .exercise && !frontWriting {
                SidePlaceholder(icon: "doc.text", text: "La série est au centre.",
                                action: ("Mettre le cours au centre", { desk.pane = .course }))
            } else {
                ExercisePane(course: course, desk: desk, openWeb: openWeb, compact: true)
            }
        case .claude:
            ClaudePane(course: course, courses: courses, desk: desk, accessory: AnyView(
                DeskIconButton(icon: "macwindow", help: "Détacher : Claude flotte par-dessus") { desk.floatClaude() }
            ))
        case .calc:
            CalcPane(desk: desk.calc, openWeb: openWeb)
        case .courseNotes:
            if let course {
                ScrollView { CourseNotesView(course: course).padding(18) }
            }
        case .sheet:
            if let course {
                RevisionSheetView(course: course, desk: desk.sites, openPoly: { path in openBeside(.botafogo(title: path, url: path), title: polyTitle(path)) },
                                  compact: true)
            }
        case .poly:
            if let course, let site = botafogoSite {
                BotafogoPairedPoly(book: desk.sites.botafogo(site), site: site, focus: focusSeries, desk: desk.sites, openWeb: openWeb,
                                   ask: { desk.ask($0, attachSeries: false) }, tint: Carnet.tint(course.colorHex))
            }
        case .notebook(let path):
            NotebookReader(path: path)
        case .reading(let reading):
            CoursePane(course: course, desk: desk.sites, openWeb: openWeb, ask: { desk.ask($0, attachSeries: false) }, document: reading)
        }
    }

    /// Ce qu'on peut ouvrir à côté, rangé : l'exercice, tes notes, le cours, les outils.
    private var sideSuggestions: [SidePicker.Group] {
        guard let course else { return [] }
        let id = course.id
        var groups: [SidePicker.Group] = []
        let series = currentSeries
        var work: [SidePicker.Entry] = []
        if let series {
            let name = series.title.isEmpty ? series.displayName : series.title
            work.append(.init(item: .init(kind: .series, title: name, icon: "doc.text", courseID: id), detail: String(localized: "L'énoncé, les exercices, j'ai fini")))
            if let copy = NotesStore.shared.copy(for: series, course: course, among: courses) {
                work.append(.init(item: .init(kind: .notebook(path: copy.path), title: String(localized: "Ma copie"), icon: "pencil.and.scribble", courseID: id),
                                  detail: copy.title))
            }
            if let address = solutionAddress(series) {
                work.append(.init(item: .init(kind: .reading(.pdf(title: String(localized: "Corrigé"), address: address)), title: String(localized: "Corrigé"), icon: "checkmark.seal", courseID: id),
                                  detail: name))
            }
        }
        if botafogoSite != nil {
            work.append(.init(item: .init(kind: .poly, title: String(localized: "Polycopié"), icon: "book.closed", courseID: id),
                              detail: String(localized: "Ouvert sur la matière de la série")))
        }
        if !work.isEmpty { groups.append(.init(title: String(localized: "Pour l'exercice"), entries: work)) }

        var notes: [SidePicker.Entry] = [
            .init(item: .init(kind: .courseNotes, title: String(localized: "Notes du cours"), icon: "text.alignleft", courseID: id), detail: String(localized: "Markdown"))
        ]
        let copyPath = series.flatMap { NotesStore.shared.copy(for: $0, course: course, among: courses)?.path }
        for document in NotesStore.shared.documents(for: course, among: courses).filter({ $0.path != copyPath }).sorted(by: { $0.modified > $1.modified }).prefix(6) {
            notes.append(.init(item: .init(kind: .notebook(path: document.path), title: document.title, icon: "pencil.and.scribble", courseID: id),
                               detail: document.modified.formatted(.relative(presentation: .named))))
        }
        groups.append(.init(title: String(localized: "Tes notes"), entries: notes))

        var material: [SidePicker.Entry] = [
            .init(item: .init(kind: .sheet, title: String(localized: "Fiche"), icon: "list.bullet.rectangle", courseID: id), detail: String(localized: "Ta fiche de révision"))
        ]
        for resource in course.sortedResources.prefix(6) {
            let reading: CoursePane.Reading? = resource.kind == .poly ? .botafogo(title: resource.title, url: resource.address) : ResourceLibrary.reading(for: resource)
            guard let reading else { continue }
            material.append(.init(item: .init(kind: .reading(reading), title: resource.title, icon: resource.kind.icon, courseID: id),
                                  detail: String(localized: "Gardé")))
        }
        groups.append(.init(title: String(localized: "Le cours"), entries: material))

        var tools: [SidePicker.Entry] = [
            .init(item: .init(kind: .calc, title: String(localized: "Calcul"), icon: "function", courseID: nil), detail: String(localized: "La calculatrice"))
        ]
        if desk.claudePlacement == .floating {
            tools.append(.init(item: .init(kind: .claude, title: "Claude", icon: "sparkle", courseID: nil), detail: String(localized: "Ancré ici au lieu de flotter")))
        }
        groups.append(.init(title: String(localized: "Outils"), entries: tools))
        return groups
    }

    private var floatingClaudeButtons: some View {
        HStack(spacing: 0) {
            DeskIconButton(icon: "sidebar.right", help: "Ancrer à droite, dans le volet d'à côté") { desk.dockClaude() }
            DeskIconButton(icon: "minus", help: "Ranger Claude (⌘J)") { desk.claudeShown = false }
        }
    }

    // MARK: Ouvrir

    /// La série du moment : celle de l'exercice suivi, sinon celle de la semaine.
    private var currentSeries: ExerciseSeries? {
        if let current = course?.allExercises.first(where: { $0.id == timer.targetID })?.series { return current }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        return all.first { $0.plannedWeek >= (course?.currentWeek ?? 0) && !$0.isComplete } ?? all.last
    }

    /// Le PDF du corrigé, une fois publié.
    private func solutionAddress(_ series: ExerciseSeries) -> String? {
        guard !series.solutionURLString.isEmpty, !BotafogoLinks.isPage(series.solutionURLString),
              series.solutionURLString != series.urlString,
              series.solutionsAt.map({ $0 <= Date() }) ?? true else { return nil }
        return series.solutionURLString
    }

    private var botafogoSite: URL? {
        course?.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    private func polyTitle(_ path: String) -> String {
        botafogoSite.flatMap { desk.sites.botafogo($0).section(path)?.title } ?? String(localized: "Polycopié")
    }

    /// La page Botafogo de la série de l'exercice en cours (le polycopié ouvert sur sa matière).
    private var focusSeries: String? {
        (currentSeries?.urlString).flatMap(BotafogoLinks.coursPath)
    }

    /// Un document du cours, gardé à côté.
    private func openBeside(_ reading: CoursePane.Reading, title: String) {
        let icon: String
        switch reading {
        case .pdf: icon = "doc.richtext"
        case .botafogo: icon = "book.closed"
        case .video, .edx, .edxMoment, .edxPlaylist: icon = "play.rectangle"
        case .edThread, .edLesson: icon = "bubble.left.and.bubble.right"
        default: icon = "doc"
        }
        desk.openSide(.init(kind: .reading(reading), title: title, icon: icon, courseID: course?.id))
    }

    /// Ouvre l'onglet Cours sur ce que l'accueil demande (diapositives, Ed…).
    private func openCourse(_ request: SiteHub.Request) {
        desk.sites.request = request
        desk.pane = .course
    }

    /// Une ressource gardée, ouverte **à côté** de ce qu'on fait : la fiche-
    /// résumé à côté de l'énoncé, sans quitter l'exercice.
    private func openResource(_ resource: SavedResource) {
        if resource.kind == .web, !resource.isFile, let url = URL(string: resource.address) {
            openWeb(url, resource.title)
            return
        }
        let reading: CoursePane.Reading? = resource.kind == .poly
            ? .botafogo(title: resource.title, url: resource.address)
            : ResourceLibrary.reading(for: resource)
        if let reading { openBeside(reading, title: resource.title) }
    }

    private func openWeb(_ url: URL, _ title: String) {
        browser.open(url, title: title)
        desk.pane = .web
    }

    /// Un outil : un site → l'onglet Web, une app → l'app, sinon le bon onglet.
    private func open(_ tool: StudyMode.Tool) {
        switch tool.kind {
        case .web(let url):
            openWeb(url, tool.title)
        case .app(let bundleID, _):
            StudyModeController.shared.openApp(bundleID: bundleID)
        }
    }

    /// ⌘1…⌘7 : l'outil du centre ; ⌘J : Claude ; ⌘\ : le volet d'à côté ;
    /// ⌃⇥ : l'onglet d'à côté suivant.
    private var paneShortcuts: some View {
        ZStack {
            ForEach(StudyDesk.Pane.allCases) { pane in
                Button("") { desk.pane = pane }
                    .keyboardShortcut(pane.shortcut, modifiers: [.command])
            }
            Button("") { desk.toggleClaude() }
                .keyboardShortcut("j", modifiers: [.command])
            Button("") { desk.sideOpen.toggle() }
                .keyboardShortcut("\\", modifiers: [.command])
            Button("") { desk.cycleSide(by: 1, among: sideItems) }
                .keyboardShortcut(.tab, modifiers: [.control])
            Button("") { desk.cycleSide(by: -1, among: sideItems) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

}
