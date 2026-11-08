import SwiftUI
import SwiftData

/// Tout ce que `TodayView` dérive de l'état persisté, calculé **une fois** par
/// rendu : SwiftUI réévalue une propriété calculée à chaque lecture, et les
/// agrégats reparcourent tous les cours.
private struct TodayState {
    let tracked: [Course]
    let term: AcademicTerm?
    /// La semaine en cours, du lundi au lundi suivant.
    let weekStart: Date
    /// Chaque cours dans sa semaine (progression, retard, corrections).
    let summaries: [WeekCourseSummary]
    /// La semaine du semestre, tous cours : théorie vue, exercices faits, corrigés.
    let theory: (done: Int, total: Int)
    let series: (done: Int, total: Int)
    let corrections: (done: Int, total: Int)
    /// Éléments des semaines passées pas faits (corrections comprises).
    let late: Int
    /// Temps compté (sessions et cours suivis), jour par jour, du lundi au dimanche.
    let days: [Int]
    /// Le planning du jour : séances, sessions planifiées, évaluations.
    let todayItems: [TodayItem]
    /// Évaluations, séries à rendre, corrigés publiés : les deux semaines à venir.
    let deadlines: [Deadline]
    /// Les tâches ouvertes (Rappels, Todoist…) en retard ou dues dans la semaine.
    let tasks: [LinkedTask]
}

/// Une ligne du planning du jour.
struct TodayItem: Identifiable {
    let id: String
    let start: Date
    let end: Date?
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    /// Un cours ou une séance de l'horaire : « Suivre le cours » pendant le créneau.
    var classCourseID: UUID? = nil
    /// La séance de l'horaire, pour la cocher (« J'y étais » / « manqué »).
    var event: LinkedCalendarEvent? = nil
}

/// Aujourd'hui : le tableau de bord de la semaine.
///
/// Ce qui est cadré (l'horaire, les échéances, les tâches) et où en est chaque
/// cours — théorie, exercices, corrections. Pas de « prochaine chose à faire » :
/// on sait sur quoi on travaille ; ce qu'on ne voit pas d'un coup d'œil, c'est
/// la semaine entière.
struct TodayView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Query(sort: \Course.code) private var courses: [Course]
    /// Deux semaines au plus : la semaine en cours, même si l'app reste
    /// ouverte au passage du lundi. L'historique entier n'est jamais chargé ici.
    @Query private var sessions: [StudySession]
    @Query private var plannedSessions: [PlannedSession]
    @Query private var events: [LinkedCalendarEvent]
    @Query(filter: #Predicate<LinkedTask> { !$0.isDone }, sort: \LinkedTask.dueDate) private var openTasks: [LinkedTask]

    @State private var sheet: TodaySheet?
    /// Un cours ouvert depuis « La semaine » ou une échéance.
    @State private var openedCourseDetail: Course?
    @State private var openedLate: Course?

    init() {
        let since = DateUtils.addDays(-7, to: DateUtils.startOfWeek(Date()))
        let until = DateUtils.addDays(14, to: DateUtils.startOfWeek(Date()))
        _sessions = Query(filter: #Predicate<StudySession> { $0.startedAt >= since },
                          sort: \StudySession.startedAt, order: .reverse)
        _plannedSessions = Query(filter: #Predicate<PlannedSession> { $0.startsAt >= since && $0.startsAt < until },
                                 sort: \PlannedSession.startsAt)
        _events = Query(filter: #Predicate<LinkedCalendarEvent> { $0.startsAt >= since && $0.startsAt < until },
                        sort: \LinkedCalendarEvent.startsAt)
    }

    /// Une seule passe de dérivation, réutilisée par toutes les sections du rendu.
    private func derived() -> TodayState {
        let now = Date()
        let tracked = courses.filter(\.isTracked)
        let weekStart = DateUtils.startOfWeek(now)
        let weekEnd = DateUtils.addDays(7, to: weekStart)
        let summaries = tracked.map { WeekCourseSummary(course: $0, now: now) }
        let weeks = summaries.map(\.week)
        let weekSessions = sessions.filter { $0.startedAt >= weekStart && $0.startedAt < weekEnd }
        let weekEvents = events.filter { $0.startsAt >= weekStart && $0.startsAt < weekEnd }
        let days = StudyTime.days(of: StudyTime.blocks(events: weekEvents, sessions: weekSessions), weekStart: weekStart)
        let soon = DateUtils.addDays(7, to: DateUtils.startOfDay(now))
        return TodayState(
            tracked: tracked,
            term: AcademicTerm.resolve(from: tracked.compactMap(\.term)),
            weekStart: weekStart,
            summaries: summaries,
            theory: (weeks.reduce(0) { $0 + $1.watchedCount }, weeks.reduce(0) { $0 + $1.videoCount }),
            series: (weeks.reduce(0) { $0 + $1.doneCount }, weeks.reduce(0) { $0 + $1.exerciseCount }),
            corrections: (weeks.reduce(0) { $0 + $1.correctedCount }, weeks.reduce(0) { $0 + $1.doneCount }),
            late: summaries.reduce(0) { $0 + $1.late },
            days: days,
            todayItems: todayItems(),
            deadlines: Array(Deadline.upcoming(in: tracked, days: 14).filter { $0.date >= now }.prefix(6)),
            tasks: Array(openTasks.filter { task in task.dueDate.map { $0 < soon } ?? false }.prefix(6))
        )
    }

    /// Ce qui a une **heure** aujourd'hui, dans l'ordre : c'est la journée telle
    /// qu'elle est cadrée, avant ce qu'on choisit d'y faire.
    private func todayItems() -> [TodayItem] {
        let calendar = Calendar.current
        var items: [TodayItem] = []
        for event in events where calendar.isDateInToday(event.startsAt) {
            items.append(TodayItem(id: "event-\(event.id)",
                                   start: event.startsAt,
                                   end: event.endsAt,
                                   title: event.title,
                                   subtitle: [event.course?.displayCode, event.location.isEmpty ? nil : event.location]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   icon: event.kind.icon,
                                   color: event.course.map { Carnet.tint($0.colorHex) } ?? event.kind.color,
                                   classCourseID: [.lecture, .exerciseSession].contains(event.kind) ? event.course?.id : nil,
                                   event: event))
        }
        for session in plannedSessions where calendar.isDateInToday(session.startsAt) {
            items.append(TodayItem(id: "planned-\(session.id)",
                                   start: session.startsAt,
                                   end: session.endsAt,
                                   title: session.title,
                                   subtitle: [session.course?.displayCode, session.location.isEmpty ? nil : session.location,
                                              session.isGroupSession ? session.groupName : nil]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   icon: "timer",
                                   color: .indigo))
        }
        for exam in courses.flatMap(\.exams) where calendar.isDateInToday(exam.date) {
            items.append(TodayItem(id: "exam-\(exam.id)",
                                   start: exam.date,
                                   end: nil,
                                   title: exam.title,
                                   subtitle: [exam.course?.displayCode, exam.location.isEmpty ? nil : exam.location]
                                       .compactMap { $0 }.joined(separator: " · "),
                                   icon: exam.kind.icon,
                                   color: exam.kind.color))
        }
        return items.sorted { $0.start < $1.start }
    }

    /// Vrai sur iPad, et sur un iPhone Max en paysage : assez large pour deux
    /// colonnes. Décidé par la classe de taille, jamais par le modèle d'appareil,
    /// pour que Split View et Slide Over se comportent correctement.
    private var isWide: Bool { sizeClass == .regular }

    /// Les présentations de « Aujourd'hui », en une seule valeur.
    private enum TodaySheet: Identifiable, Hashable {
        case tasks
        case quickNote
        case seriesImport(Course?, PendingImport?)

        var id: String {
            switch self {
            case .tasks: return "tasks"
            case .quickNote: return "quickNote"
            case .seriesImport(let course, let shared):
                return "seriesImport-\(course?.id.uuidString ?? "aucun")-\(shared?.receivedAt.timeIntervalSince1970 ?? 0)"
            }
        }
    }

    var body: some View {
        @Bindable var router = app.router
        let state = derived()
        return NavigationStack {
            CarnetScroll(wide: true) {
                content(state)
            }
            .navigationTitle("Aujourd'hui")
            .carnetSubtitle(dateLine(state))
            .navigationDestination(item: $openedCourseDetail) { course in
                CourseDetailView(course: course)
            }
            .navigationDestination(item: $openedLate) { course in
                LateWorkScreen(course: course)
            }
            .toolbar {
                // Moi — le bilan et les réglages — derrière l'avatar, en haut à
                // gauche ; à droite, ce qu'on ajoute. Le chrono a son bouton dans
                // la barre d'onglets, l'agenda s'ouvre depuis l'horaire, une
                // session passée se saisit depuis le chrono ou le bilan.
                ToolbarItem(placement: .topBarLeading) {
                    ProfileButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            sheet = .quickNote
                        } label: {
                            Label("Note rapide", systemImage: "note.text.badge.plus")
                        }
                        Button {
                            app.router.openContentImport()
                        } label: {
                            Label("Importer du contenu de cours", systemImage: "square.and.arrow.down.on.square")
                        }
                        Button {
                            sheet = .seriesImport(nil, nil)
                        } label: {
                            Label("Importer une série (PDF)", systemImage: "doc.badge.plus")
                        }
                        Button {
                            sheet = .tasks
                        } label: {
                            Label("Tâches", systemImage: "checklist")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Ajouter")
                }
            }
            // **Une seule** feuille pour toutes les présentations.
            //
            // Six `.sheet` enchaînés sur la même vue ne fonctionnent pas de façon
            // fiable : SwiftUI n'en honore qu'une selon l'ordre, et les autres
            // restent silencieusement sans effet — un bouton qui « ne fait rien »,
            // impossible à reproduire pour qui ne connaît pas la cause. Une
            // présentation pilotée par une valeur supprime le problème.
            .sheet(item: $sheet, onDismiss: {
                // Sans ce retour à faux, « Tâches » ne s'ouvrait qu'une fois :
                // le drapeau restait vrai, et le toucher à nouveau ne changeait rien.
                app.router.showingTasks = false
            }) { destination in
                sheetContent(destination)
            }
            .refreshable {
                await TaskSync.sync(context: context, settings: app.settings)
            }
            .onAppear {
                // Partage reçu avant que l'accueil n'existe (lancement à froid) :
                // `onChange` ne le verra jamais passer.
                if let shared = app.router.pendingImport {
                    app.router.pendingImport = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        sheet = .seriesImport(nil, shared)
                    }
                }
                #if DEBUG
                // Les captures du simulateur ne peuvent pas taper : ces drapeaux
                // ouvrent la feuille. Le changement d'état est différé d'un tour :
                // modifié pendant la première passe de mise en page, il est absorbé
                // et la feuille ne s'ouvre jamais.
                if let path = PreviewLaunch.string(PreviewLaunch.importFileFlag) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        sheet = .seriesImport(nil, PendingImport(kind: .pdf, fileName: path, text: nil, receivedAt: Date()))
                    }
                }
                if PreviewLaunch.isSet(PreviewLaunch.profileFlag)
                    || PreviewLaunch.isSet(PreviewLaunch.statsFlag)
                    || PreviewLaunch.isSet(PreviewLaunch.personalizeFlag) {
                    // La page des réglages d'abord (`-personalize`) : la pile de la
                    // feuille est prête quand elle apparaît.
                    if PreviewLaunch.isSet(PreviewLaunch.personalizeFlag) { router.debugSettingsPage = "personalize" }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        if PreviewLaunch.isSet(PreviewLaunch.profileFlag)
                            || PreviewLaunch.isSet(PreviewLaunch.personalizeFlag) { router.showingProfile = true }
                        if PreviewLaunch.isSet(PreviewLaunch.statsFlag) { router.showingStats = true }
                    }
                }
                #endif
            }
            .modifier(TodayObservers(sheet: $sheet,
                                     requests: requests,
                                     courses: courses,
                                     app: app,
                                     applyRequests: apply))
        }
    }

    /// L'accueil est **le tableau de bord de la semaine** : ce que la semaine a
    /// coûté en temps, ce que la journée a d'heures fixes, et où en est chaque
    /// cours dans sa semaine. Il ne propose plus « la prochaine chose à faire » :
    /// on sait sur quoi on travaille ; ce qu'on ne voit pas d'un coup d'œil,
    /// c'est la semaine entière.
    @ViewBuilder
    private func content(_ state: TodayState) -> some View {
        if state.tracked.isEmpty {
            CarnetEmpty(icon: "books.vertical",
                        title: String(localized: "Aucun cours suivi"),
                        message: String(localized: "Séries, vidéos et échéances, lues sur Moodle."),
                        actionTitle: String(localized: "Importer mes cours")) {
                app.router.openContentImport()
            }
        } else {
            // Un compte expiré que l'app n'a pas pu reconnecter seule.
            ConnectionBanner()
            importNews
            // Sur iPad : le temps et l'horaire à gauche, les cours à droite.
            CarnetColumns {
                WeekTimeCard(days: state.days, weekStart: state.weekStart,
                             theory: state.theory, series: state.series,
                             corrections: state.corrections, late: state.late,
                             goal: StudyGoal.weeklySeconds(goalMinutes: app.settings.weeklyGoalMinutes,
                                                           courses: state.tracked, hoursPerCredit: app.settings.hoursPerCredit)) {
                    app.router.showingStats = true
                }
                todaySchedule(state)
                // Le téléphone loin du bureau : reprises dues, quiz de la semaine.
                OnTheGoCard(courses: state.tracked) { exercise in
                    if let course = exercise.series?.course { app.router.openCourse(course.id, section: .exercises, targetID: exercise.id) }
                }
                deadlines(state)
            } trailing: {
                weekCourses(state)
                tasks(state)
            }
        }
    }

    // MARK: La semaine, cours par cours

    /// Une ligne par cours : ce que sa semaine demande (théorie, exercices), ce
    /// qui est fait, et le retard en mots.
    @ViewBuilder
    private func weekCourses(_ state: TodayState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(state.term.map { $0.isRunning ? String(localized: "Semaine \($0.currentWeek)") : String(localized: "Cours") } ?? String(localized: "Cours")) {
                Button {
                    app.router.selectedTab = .courses
                } label: {
                    HStack(spacing: 3) {
                        Text("Tous les cours")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
            }
            CarnetSheet {
                ForEach(Array(state.summaries.enumerated()), id: \.element.course.id) { index, summary in
                    Button {
                        openedCourseDetail = summary.course
                    } label: {
                        WeekCourseRow(summary: summary, openLate: { openedLate = summary.course })
                    }
                    .buttonStyle(PressableStyle(scale: 0.99))
                    if index < state.summaries.count - 1 { CarnetRule(inset: Carnet.rowInset) }
                }
            }
        }
    }

    // MARK: Échéances

    /// Évaluations, séries à rendre, corrigés publiés : les deux semaines à
    /// venir. Toucher une échéance ouvre son cours (une évaluation, l'agenda).
    @ViewBuilder
    private func deadlines(_ state: TodayState) -> some View {
        if !state.deadlines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle(String(localized: "Échéances"))
                CarnetSheet {
                    ForEach(Array(state.deadlines.enumerated()), id: \.element.id) { index, item in
                        Button {
                            if item.kind == .exam {
                                app.router.openAgenda(day: item.date, courseID: item.courseID)
                            } else {
                                openedCourseDetail = state.tracked.first { $0.id == item.courseID }
                            }
                        } label: {
                            deadlineRow(item)
                        }
                        .buttonStyle(PressableStyle(scale: 0.99))
                        if index < state.deadlines.count - 1 { CarnetRule(inset: 52) }
                    }
                }
            }
        }
    }

    private func deadlineRow(_ item: Deadline) -> some View {
        let tint = Carnet.tint(item.colorHex)
        let days = DateUtils.daysBetween(Date(), item.date)
        return HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.callout)
                .foregroundStyle(item.kind == .exam ? Carnet.wrong : tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text("\(item.courseCode) · \(item.detail)")
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(DateUtils.countdownLabel(to: item.date))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(item.kind == .exam && days <= 3 ? Carnet.wrong : Carnet.inkSecondary)
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Tâches

    /// Les tâches des fournisseurs reliés (Rappels, Todoist…) en retard ou
    /// dues dans la semaine, cochables ici ; toutes dans « Tâches ».
    @ViewBuilder
    private func tasks(_ state: TodayState) -> some View {
        if !state.tasks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CarnetSectionTitle(String(localized: "Tâches")) {
                    Button {
                        sheet = .tasks
                    } label: {
                        HStack(spacing: 3) {
                            Text("Toutes")
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                    }
                }
                CarnetSheet {
                    ForEach(Array(state.tasks.enumerated()), id: \.element.id) { index, task in
                        taskRow(task)
                        if index < state.tasks.count - 1 { CarnetRule(inset: 52) }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: LinkedTask) -> some View {
        HStack(spacing: 8) {
            CheckCircleButton(isOn: task.isDone,
                              tint: task.course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink,
                              label: String(localized: "Marquer « \(task.title) » faite")) {
                Task { await TaskSync.setDone(task, !task.isDone, context: context, settings: app.settings) }
            }
            .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.body)
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let code = task.course?.displayCode {
                        Text(code).font(.footnote.weight(.semibold))
                            .foregroundStyle(Carnet.tint(task.course?.colorHex ?? ""))
                    }
                    if let due = task.dueDate {
                        Text(DateUtils.countdownLabel(to: due))
                            .font(.footnote)
                            .foregroundStyle(task.isOverdue ? Carnet.wrong : Carnet.inkSecondary)
                    }
                    Text(task.provider.label).font(.footnote).foregroundStyle(Carnet.inkTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, Carnet.rowInset)
        .padding(.vertical, 5)
    }

    /// « Nouveau sur Moodle : MATH-101 : 1 série » — ce que la mise à jour
    /// automatique vient d'ajouter, jusqu'à ce qu'on le ferme.
    @ViewBuilder
    private var importNews: some View {
        let news = app.settings.contentRefreshNews
        if !news.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                CarnetIconTile(systemName: "sparkles", tint: Carnet.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nouveau dans tes cours").font(.subheadline.weight(.semibold)).foregroundStyle(Carnet.ink)
                    Text(news).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(Motion.snappy) { app.settings.contentRefreshNews = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Carnet.inkSecondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Masquer")
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .transition(.opacity)
        }
    }

    /// Les observations de l'accueil, sorties de la chaîne de modificateurs.
    ///
    /// Huit `.onChange` à la suite d'une vingtaine d'autres modificateurs, dans une
    /// vue qui porte une trentaine de propriétés, font échouer le vérificateur de
    /// types (« unable to type-check this expression in reasonable time »). Ce
    /// modificateur ne reçoit que ce dont il a besoin — pas la vue entière, dont
    /// le seul nom suffisait à alourdir chaque expression.
    private struct TodayObservers: ViewModifier {
        @Binding var sheet: TodaySheet?
        var requests: Requests
        var courses: [Course]
        var app: AppContainer
        var applyRequests: (Requests) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: requests) { _, state in applyRequests(state) }
                .onChange(of: app.router.shortcut) { _, shortcut in handleShortcut(shortcut) }
                .onChange(of: app.router.pendingImport) { _, shared in handleImport(shared) }
        }

        // Chaque fermeture appelle une méthode nommée : cinq `.onChange` dont le
        // corps est écrit sur place font échouer le vérificateur de types, et un
        // corps d'une ligne se lit mieux qu'un bloc imbriqué.

        private func handleShortcut(_ shortcut: ShortcutAction?) {
            guard let shortcut else { return }
            switch shortcut {
            case .importSeries:
                sheet = .seriesImport(nil, nil)
            case .startTimer:
                app.router.startFocus(courseID: nil, courseCode: "",
                                      taskType: .theory, label: String(localized: "Session libre"))
            }
            app.router.shortcut = nil
        }

        private func handleImport(_ shared: PendingImport?) {
            guard let shared else { return }
            sheet = .seriesImport(nil, shared)
            app.router.pendingImport = nil
        }


    }

    // MARK: Feuilles

    /// Les trois demandes du routeur, réunies pour n'être observées qu'une fois.
    /// Profil, statistiques et Focus sont présentés par `RootTabView` : ils
    /// s'ouvrent depuis n'importe quel onglet. Il ne reste ici que les tâches.
    private struct Requests: Equatable {
        var tasks = false
    }

    private var requests: Requests {
        Requests(tasks: app.router.showingTasks)
    }

    private func apply(_ state: Requests) {
        if state.tasks, sheet == nil { sheet = .tasks }
        else if !state.tasks, sheet == .tasks { sheet = nil }
    }

    @ViewBuilder
    private func sheetContent(_ destination: TodaySheet) -> some View {
        switch destination {
        case .tasks:
            TasksView()
        case .quickNote:
            QuickNoteSheet(preferredCourseID: app.focus.state?.courseID)
        case .seriesImport(let course, let shared):
            SeriesImportSheet(course: course,
                              initialFileURL: shared.flatMap(importFileURL),
                              initialText: shared?.text)
        }
    }

    private func importFileURL(_ shared: PendingImport) -> URL? {
        if let url = PendingImportBridge.file(for: shared) { return url }
        #if DEBUG
        // `-importFile` : un chemin absolu, le simulateur non signé n'ayant pas de
        // conteneur de groupe où l'extension de partage déposerait le fichier.
        if let path = shared.fileName, path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        #endif
        return nil
    }

    // MARK: En-tête

    private func dateLine(_ state: TodayState) -> String {
        var parts = [DateUtils.fullDayLabel(Date()).capitalizedFirst]
        if let term = state.term {
            parts.append(term.hasEnded ? String(localized: "semestre terminé") : (term.hasNotStarted ? String(localized: "semestre à venir") : String(localized: "semaine \(term.currentWeek) sur \(term.totalWeeks)")))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Horaire

    /// Ce qui a une heure aujourd'hui : cours EPFL, sessions planifiées,
    /// évaluations. Les créneaux passés restent, barrés ; toucher la feuille
    /// ouvre l'agenda.
    private func todaySchedule(_ state: TodayState) -> some View {
        let now = Date()
        let items = state.todayItems
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle(String(localized: "Horaire")) {
                Button {
                    app.router.openAgenda(day: now)
                } label: {
                    HStack(spacing: 3) {
                        Text("Agenda")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
                .accessibilityLabel("Ouvrir l'agenda")
            }
            if let live = items.first(where: { item in
                item.classCourseID != nil && item.start.addingTimeInterval(-LectureClock.lead) <= now && now < (item.end ?? item.start)
            }), let courseID = live.classCourseID {
                followCard(live, courseID: courseID, now: now)
            }
            Button {
                app.router.openAgenda(day: now)
            } label: {
                CarnetSheet {
                    if items.isEmpty {
                        CarnetRow(icon: "sun.max", tint: Carnet.review, title: String(localized: "Rien à l'horaire"))
                    } else {
                        ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { index, item in
                            scheduleRow(item, now: now)
                            if index < min(items.count, 6) - 1 { CarnetRule(inset: 74) }
                        }
                        if items.count > 6 {
                            Text("+ \(items.count - 6) autres")
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                                .padding(.leading, 74)
                                .padding(.bottom, 10)
                        }
                    }
                }
            }
            .buttonStyle(PressableStyle(scale: 0.99))
        }
    }

    /// Le cours de maintenant : un toucher, et le bureau s'ouvre dessus —
    /// la semaine sur Moodle, l'horloge du cours, les repères.
    private func followCard(_ item: TodayItem, courseID: UUID, now: Date) -> some View {
        let following = app.focus.isStudying && app.focus.state?.courseID == courseID && app.focus.state?.taskType == .lecture
        return Button {
            if following { app.router.showingStudyMode = true } else { app.router.openLectureDesk(courseID: courseID) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: DeskMoment.lecture.icon).font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(following ? "Revenir au cours" : "Suivre le cours").font(.headline)
                    Text([item.subtitle, item.end.map { "jusqu'à \(DateUtils.time.string(from: $0))" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).opacity(0.85).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.subheadline.weight(.semibold))
            }
            .padding(14)
            .foregroundStyle(Carnet.ground)
            .background(item.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Ouvre le bureau du cours, jusqu'à la fin du créneau")
    }

    private func scheduleRow(_ item: TodayItem, now: Date) -> some View {
        let isPast = (item.end ?? item.start) < now
        let isOngoing = item.start <= now && !isPast
        return HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(DateUtils.time.string(from: item.start))
                    .font(Carnet.mono(.footnote, weight: isOngoing ? .semibold : .regular))
                if let end = item.end {
                    Text(DateUtils.time.string(from: end))
                        .font(Carnet.mono(.caption2))
                        .foregroundStyle(Carnet.inkTertiary)
                }
            }
            .foregroundStyle(isPast ? Carnet.inkTertiary : Carnet.ink)
            .frame(width: 46, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(item.color)
                .opacity(isPast ? 0.35 : 1)
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.body.weight(isOngoing ? .semibold : .regular))
                        .strikethrough(isPast, color: Carnet.inkTertiary)
                        .foregroundStyle(isPast ? Carnet.inkTertiary : Carnet.ink)
                        .lineLimit(1)
                    if isOngoing {
                        Text("en cours")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Carnet.ground)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Carnet.ink, in: Capsule())
                    }
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.footnote).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // Coché = compté dans les heures (Réglages › Chrono › Ce qui compte).
            if let event = item.event, event.isCheckable(now: now) {
                let on = event.isChecked(now: now)
                CheckCircleButton(isOn: on, tint: item.color,
                                  label: on ? String(localized: "Marquer \(event.title) manqué") : String(localized: "J'étais à \(event.title)")) {
                    event.toggleChecked(now: now)
                    try? context.save()
                }
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
