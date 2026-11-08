import AppKit
import SwiftData
import SwiftUI

// MARK: - Bureau

/// L'accueil du bureau : le grand cadran, l'exercice, la suite — et les
/// raccourcis vers chaque outil.
struct StudyDeskHome: View {
    let course: Course?
    var tint: Color
    var desk: StudyDesk
    var open: (StudyMode.Tool) -> Void
    @Environment(MacTimer.self) private var timer
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var allCourses: [Course]
    @Query private var groups: [StudyGroup]
    @State private var classes: [ScheduledClass] = []

    var moment: DeskMoment = .series
    /// Les sections de l'accueil « en cours » et « révision », fournies par le bureau.
    var lecturePart: ((LectureDeskView.Part) -> AnyView)?
    var revisionPart: ((RevisionDeskView.Part) -> AnyView)?
    @State private var placements: [DeskWidgets.Placement] = []
    @State private var editing = false

    // MARK: Le plan de travail

    /// Les reprises dues du cours.
    private var due: [Exercise] {
        course.map { SeriesReview.redoQueue([$0]).filter { ($0.redoDueAt ?? .distantFuture) <= Date() } } ?? []
    }

    private var widgetContext: DeskWidgets.Context {
        DeskWidgets.Context(moment: moment, hasCourse: course != nil, hasSeries: series != nil,
                            inGroup: timer.state?.groupSession != nil,
                            hasTarget: course?.allExercises.contains { $0.id == timer.targetID } ?? false,
                            redosDue: due.count, daysToExam: course?.nextSitting?.daysUntil)
    }

    private var shown: [DeskWidgets.Placement] {
        DeskWidgets.merged(defaults: DeskWidgets.defaults(widgetContext), stored: placements.isEmpty ? nil : placements)
    }

    private func save(_ list: [DeskWidgets.Placement]) {
        placements = list
        UserDefaults.standard.set(DeskWidgets.encode(list), forKey: DeskWidgets.storageKey(moment))
    }

    var body: some View {
        let list = shown
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(course.map { $0.name } ?? String(localized: "Ta session"))
                        .font(Carnet.serif(.title2)).foregroundStyle(StudyPalette.ink).lineLimit(1)
                    Spacer()
                    Button(editing ? "Terminé" : "Organiser") { editing.toggle() }
                        .buttonStyle(.paper)
                        .help("Masquer, agrandir ou déplacer les cartes : retenu pour ce moment")
                }
                DeskWidgetGrid {
                    ForEach(list.filter { !$0.hidden }) { placement in
                        card(placement, in: list)
                            .layoutValue(key: DeskWidgetGrid.SpanKey.self, value: placement.size.span)
                    }
                }
                if editing, list.contains(where: \.hidden) {
                    Text("Masquées").font(Carnet.serif(.title3)).foregroundStyle(StudyPalette.ink).padding(.top, 8)
                    FlowLayout(spacing: 8) {
                        ForEach(list.filter(\.hidden)) { placement in
                            Button { save(DeskWidgets.toggled(placement.kind, in: list)) } label: {
                                Label(title(placement.kind), systemImage: "plus.circle")
                            }
                            .buttonStyle(.paper)
                        }
                    }
                }
            }
            .padding(40)
        }
        .onAppear { load() }
        .onChange(of: moment) { _, _ in load() }
        .task {
            while !Task.isCancelled {
                classes = DeskSchedule.today(context: context)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func load() {
        placements = DeskWidgets.decode(UserDefaults.standard.data(forKey: DeskWidgets.storageKey(moment))) ?? []
    }

    /// L'outil du centre où une carte mène (« zoomer » dessus).
    private func centerPane(for kind: DeskWidgets.Kind) -> StudyDesk.Pane? {
        switch kind {
        case .target, .upNext, .redo: return .exercise
        case .music: return .music
        case .lectureWeek, .lectureTheory, .revisionSheet, .revisionPast, .revisionTheory: return .course
        default: return nil
        }
    }

    /// Ce qu'une carte met dans le volet d'à côté.
    private func sideItem(for kind: DeskWidgets.Kind) -> StudyDesk.SideItem? {
        let id = course?.id
        switch kind {
        case .target, .upNext, .redo: return .init(kind: .series, title: String(localized: "Série"), icon: "doc.text", courseID: id)
        case .revisionSheet, .revisionExam: return .init(kind: .sheet, title: String(localized: "Fiche"), icon: "list.bullet.rectangle", courseID: id)
        case .steps, .lectureTheory: return .init(kind: .courseNotes, title: String(localized: "Notes du cours"), icon: "text.alignleft", courseID: id)
        default: return nil
        }
    }

    /// Une carte, avec ses réglages quand on organise.
    @ViewBuilder
    private func card(_ placement: DeskWidgets.Placement, in list: [DeskWidgets.Placement]) -> some View {
        content(placement.kind, size: placement.size)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contextMenu {
                if let pane = centerPane(for: placement.kind) {
                    Button { desk.pane = pane } label: { Label("Ouvrir au centre", systemImage: "arrow.up.left.and.arrow.down.right") }
                }
                if let item = sideItem(for: placement.kind) {
                    Button { desk.openSide(item) } label: { Label("Mettre à côté", systemImage: "sidebar.right") }
                }
                if placement.kind == .claude {
                    Button { desk.dockClaude() } label: { Label("Ancrer à côté", systemImage: "sidebar.right") }
                }
                Divider()
                Button { save(DeskWidgets.resized(placement.kind, in: list)) } label: { Label("Changer la taille", systemImage: "square.resize") }
                Button { save(DeskWidgets.toggled(placement.kind, in: list)) } label: { Label("Masquer", systemImage: "eye.slash") }
            }
            .overlay(alignment: .topTrailing) {
                // Zoomer : la carte mène à son outil, au centre.
                if !editing, let pane = centerPane(for: placement.kind) {
                    Button { desk.pane = pane } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudyPalette.inkTertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ouvrir au centre")
                    .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if editing {
                    HStack(spacing: 2) {
                        editButton("chevron.left", "Avant") { save(DeskWidgets.moved(placement.kind, by: -1, in: list)) }
                        editButton("chevron.right", "Après") { save(DeskWidgets.moved(placement.kind, by: 1, in: list)) }
                        editButton("arrow.up.left.and.arrow.down.right", "Taille") { save(DeskWidgets.resized(placement.kind, in: list)) }
                        editButton("eye.slash", "Masquer") { save(DeskWidgets.toggled(placement.kind, in: list)) }
                    }
                    .padding(4)
                    .deskGlass(in: Capsule())
                    .padding(8)
                }
            }
    }

    private func editButton(_ icon: String, _ help: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.caption.weight(.semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudyPalette.ink)
        .help(help)
    }

    private func title(_ kind: DeskWidgets.Kind) -> String {
        switch kind {
        case .session: return String(localized: "Session")
        case .target: return String(localized: "Exercice")
        case .upNext: return String(localized: "Ensuite")
        case .steps: return String(localized: "Ta session")
        case .redo: return String(localized: "Reprises")
        case .exam: return String(localized: "Examen")
        case .music: return String(localized: "Musique")
        case .today: return String(localized: "Aujourd'hui")
        case .claude: return "Claude"
        case .courses: return String(localized: "Sur quoi ?")
        case .accounts: return String(localized: "Comptes")
        case .deadlines: return String(localized: "Échéances")
        case .group: return String(localized: "Groupe")
        case .lectureClock: return String(localized: "Le cours")
        case .lectureMarks: return String(localized: "Repères")
        case .lectureTools: return String(localized: "Outils du cours")
        case .lectureWeek: return String(localized: "La semaine")
        case .lectureTheory: return String(localized: "Théorie")
        case .revisionExam: return String(localized: "Examen")
        case .revisionSheet: return String(localized: "Fiche")
        case .revisionPast: return String(localized: "Annales")
        case .revisionRedo: return String(localized: "À refaire")
        case .revisionTheory: return String(localized: "Théorie")
        }
    }

    /// Le fond d'une carte : du verre, jamais sur ce qu'on lit.
    private func glassCard<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        inner()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deskGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func content(_ kind: DeskWidgets.Kind, size: DeskWidgets.Size) -> some View {
        switch kind {
        case .session:
            glassCard {
                StudyDial(tint: tint, size: size == .small ? 220 : (size == .medium ? 280 : 320))
                    .frame(maxWidth: .infinity)
            }
        case .target:
            StudyTargetCard(course: course, tint: tint)
        case .upNext:
            if let course {
                glassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Kicker("Ensuite")
                        UpNextList(course: course, limit: size == .small ? 2 : 4)
                    }
                }
            }
        case .steps:
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    // Les étapes et leur ordre : Personnaliser › Ta session (les mêmes sur l'iPhone).
                    // Seulement celles qui ont un sens ici : pas de « Faire la série » sans série,
                    // pas de débrief avant la fin.
                    ForEach(Array(SessionFlow.load().steps.filter(applies).enumerated()), id: \.element) { index, item in
                        switch item {
                        case .course:
                            step(index + 1, item.title, detail: theoryDetail, icon: "books.vertical", done: theoryLeft == 0) { desk.pane = .course }
                        case .series:
                            step(index + 1, item.title, detail: seriesDetail, icon: "doc.text", done: series?.isComplete == true) {
                                if let next = nextExercise, let course { timer.retarget(courseID: course.id, taskType: .exercise, targetID: next.id) }
                                desk.pane = .exercise
                            }
                        case .help:
                            step(index + 1, item.title, detail: "Un indice, ou fais vérifier ta copie", icon: "sparkle", done: false) { desk.showClaude() }
                        case .debrief:
                            step(index + 1, item.title, detail: debriefDetail, icon: "checklist", done: false) { desk.showClaude() }
                        }
                    }
                    toolsRow
                }
            }
        case .redo:
            redoCard
        case .exam:
            examCard
        case .music:
            glassCard {
                if StudyMusic.shared.nowPlaying.hasTrack {
                    MusicNowPlayingCard(compact: true)
                } else {
                    // Au repos, la carte ne reste pas vide : elle mène au choix de la musique.
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Musique", systemImage: "music.note").font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink)
                        Text(StudyMusic.shared.automationDenied ? "Music n'est pas autorisé (Réglages Système › Automatisation)." : "Rien ne joue.")
                            .font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                        Button { desk.pane = .music } label: { Label("Choisir", systemImage: "arrow.up.forward") }.buttonStyle(.paper)
                    }
                }
            }
        case .today:
            todayCard
        case .claude:
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Claude", systemImage: "sparkle").font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink)
                    Text(lastClaudeAnswer ?? String(localized: "Un indice, ou fais vérifier ta copie."))
                        .font(.callout).foregroundStyle(StudyPalette.inkSecondary).lineLimit(4)
                    Button { desk.showClaude() } label: { Label("Demander", systemImage: "arrow.up.forward") }
                        .buttonStyle(.paper)
                }
            }
        case .courses:
            glassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sur quoi ?").font(Carnet.serif(.title3)).foregroundStyle(StudyPalette.ink)
                    FlowLayout(spacing: 7) {
                        ForEach(allCourses.filter(\.isTracked)) { item in
                            CourseChip(title: item.displayCode, color: Carnet.tint(item.colorHex), selected: false) {
                                timer.retarget(courseID: item.id, taskType: .exercise)
                            }
                            .help(item.name)
                        }
                    }
                }
            }
        case .accounts:
            glassCard { accounts }
        case .deadlines: deadlinesCard
        case .group: groupCard
        case .lectureClock: glassCard { lecturePart?(.clock) }
        case .lectureMarks: glassCard { lecturePart?(.marks) }
        case .lectureTools: glassCard { lecturePart?(.tools) }
        case .lectureWeek: glassCard { lecturePart?(.week) }
        case .lectureTheory: glassCard { lecturePart?(.theory) }
        case .revisionExam: glassCard { revisionPart?(.exam) }
        case .revisionSheet: glassCard { revisionPart?(.sheet) }
        case .revisionPast: glassCard { revisionPart?(.past) }
        case .revisionRedo: glassCard { revisionPart?(.redo) }
        case .revisionTheory: glassCard { revisionPart?(.theory) }
        }
    }

    /// La dernière réponse de Claude, pour qu'elle reste sous les yeux.
    private var lastClaudeAnswer: String? {
        desk.chats[course?.allExercises.first { $0.id == timer.targetID }?.series?.id]?.messages
            .last { $0.role == .claude && !$0.text.isEmpty }?.text
    }

    private var redoCard: some View {
        Group {
            if let first = due.first {
                Button {
                    if let course { timer.retarget(courseID: course.id, taskType: .exercise, targetID: first.id) }
                    desk.pane = .exercise
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.counterclockwise.circle.fill").font(.title2).foregroundStyle(Carnet.review)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(due.count == 1 ? "Une reprise due : \(first.displayNumber)" : "\(due.count) reprises dues")
                                .font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink)
                            Text("Sur papier, l'énoncé seul, sans tes notes — 15 min chacune").font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                    }
                    .padding(16)
                    .background(Carnet.review.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Carnet.review.opacity(0.35)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                glassCard { Label("Aucune reprise due", systemImage: "checkmark").foregroundStyle(StudyPalette.inkSecondary) }
            }
        }
    }

    private var examCard: some View {
        glassCard {
            if let exam = course?.nextSitting {
                let days = exam.daysUntil
                VStack(alignment: .leading, spacing: 4) {
                    Kicker("Examen")
                    Text(days == 0 ? String(localized: "Aujourd'hui") : String(localized: "Dans \(days) j"))
                        .font(Carnet.serif(.title)).foregroundStyle(StudyPalette.ink)
                    Text(exam.date.formatted(.dateTime.weekday(.wide).day().month())).font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                }
            } else {
                Label("Pas d'examen à venir", systemImage: "calendar").foregroundStyle(StudyPalette.inkSecondary)
            }
        }
    }

    /// Les échéances de la semaine (tous les cours suivis) : évaluations, séries à rendre, corrigés.
    private var deadlinesCard: some View {
        let list = Deadline.upcoming(in: allCourses.filter(\.isTracked), days: 7).prefix(5)
        return glassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Échéances").font(Carnet.serif(.title3)).foregroundStyle(StudyPalette.ink)
                if list.isEmpty {
                    Text("Rien cette semaine.").font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                }
                ForEach(Array(list)) { deadline in
                    HStack(spacing: 10) {
                        Image(systemName: deadline.icon).foregroundStyle(Carnet.tint(deadline.colorHex)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(deadline.title).font(.callout.weight(.medium)).foregroundStyle(StudyPalette.ink).lineLimit(1)
                            Text("\(deadline.courseCode) · " + deadline.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                        }
                    }
                }
            }
        }
    }

    /// Le groupe de la session commune : qui est là, et leur temps cette semaine.
    private var groupCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(timer.state?.groupSession?.groupName ?? "Groupe", systemImage: "person.2.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink)
                let members = groups.first { $0.remoteID == timer.state?.groupSession?.groupID }?.members.sorted { $0.weeklySeconds > $1.weeklySeconds } ?? []
                ForEach(Array(members.prefix(5))) { member in
                    HStack {
                        Text(member.isMe ? "Toi" : (member.displayName.isEmpty ? "—" : member.displayName)).font(.callout).foregroundStyle(StudyPalette.ink)
                        Spacer()
                        Text(DateUtils.durationLabel(seconds: member.weeklySeconds)).font(.caption.monospacedDigit()).foregroundStyle(StudyPalette.inkSecondary)
                    }
                }
                if members.isEmpty { Text("Chrono commun en cours.").font(.callout).foregroundStyle(StudyPalette.inkSecondary) }
            }
        }
    }

    private var todayCard: some View {
        glassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aujourd'hui").font(Carnet.serif(.title3)).foregroundStyle(StudyPalette.ink)
                let upcoming = classes.filter { $0.slot.end > Date() }.prefix(4)
                if upcoming.isEmpty {
                    Text("Plus rien à l'horaire.").font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                }
                ForEach(Array(upcoming)) { klass in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Carnet.tint(klass.colorHex)).frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(klass.slot.courseCode) · \(klass.kindLabel)").font(.callout.weight(.medium)).foregroundStyle(StudyPalette.ink)
                            Text(DateUtils.time.string(from: klass.slot.start) + " – " + DateUtils.time.string(from: klass.slot.end)
                                 + (klass.location.isEmpty ? "" : " · \(klass.location)"))
                                .font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                        }
                    }
                }
            }
        }
    }

    private var toolsRow: some View {
        HStack(spacing: 8) {
            mini(.calc)
            mini(.web)
            Button { desk.showClaude() } label: { Label("Claude", systemImage: "sparkle") }
                .buttonStyle(.paper)
        }
        .padding(.top, 4)
    }

    /// Une étape de « Ta session » n'est montrée que si elle a un sens maintenant.
    private func applies(_ item: SessionFlow.Step) -> Bool {
        guard course != nil else { return false }
        switch item {
        case .course: return true
        case .series: return series != nil
        case .help: return series != nil && series?.isComplete != true
        case .debrief: return series.map { $0.requiredExercises.allSatisfy { ExerciseStage($0).isDone } } ?? false
        }
    }

    // MARK: Le fil de la session

    /// Clore la série : quand elle est finie, c'est le moment.
    private var debriefDetail: String {
        guard let series else { return String(localized: "Clore la série avec Claude quand elle est finie") }
        if series.requiredExercises.allSatisfy({ ExerciseStage($0).isDone }), series.exercises.contains(where: { $0.isDone && !$0.isCorrected }) {
            return String(localized: "La série est finie : clos-la avec Claude (corrections, erreurs, à refaire)")
        }
        return String(localized: "Quand la série est finie : corrections, erreurs, à refaire")
    }

    private var series: ExerciseSeries? {
        if let current = course?.allExercises.first(where: { $0.id == timer.targetID })?.series { return current }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        return all.first { $0.plannedWeek >= (course?.currentWeek ?? 0) && !$0.isComplete } ?? all.last
    }

    private var nextExercise: Exercise? { series.flatMap { ExerciseFlow.resumePoint(in: $0.sortedExercises) } }

    private var theoryLeft: Int {
        guard let course else { return 0 }
        return course.sortedTheoryItems.filter { $0.plannedWeek == course.currentWeek && !$0.isWatched }.count
    }

    private var theoryDetail: String {
        theoryLeft == 0 ? "À jour pour cette semaine" : "\(theoryLeft) à voir cette semaine"
    }

    private var seriesDetail: String {
        guard let series else { return "Pas de série" }
        let name = series.title.isEmpty ? series.displayName : series.title
        return "\(name) · \(series.doneCount)/\(series.requiredExercises.count)" + (nextExercise.map { " · ensuite \($0.displayNumber)" } ?? "")
    }

    private func step(_ number: Int, _ title: String, detail: String, icon: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(done ? Carnet.correct.opacity(0.25) : StudyPalette.raisedMore)
                    if done { Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(Carnet.correct) }
                    else { Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(StudyPalette.ink) }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(StudyPalette.ink)
                    Text(detail).font(.caption).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: icon).foregroundStyle(StudyPalette.inkTertiary)
            }
            .padding(12)
            .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudyPalette.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mini(_ pane: StudyDesk.Pane) -> some View {
        Button { desk.pane = pane } label: { Label(pane.title, systemImage: pane.icon) }
            .buttonStyle(.paper)
    }

    /// Les comptes EPFL : connectés sans rien demander, ou un bouton.
    private var accounts: some View {
        let connect = SchoolConnect.shared
        return FlowLayout(spacing: 12) {
            ForEach(SchoolConnect.Site.allCases) { site in
                let state = connect.state(site)
                HStack(spacing: 4) {
                    Circle().fill(state == .connected ? Carnet.correct
                                  : state == .failed ? Carnet.wrong
                                  : state == .needsYou ? Carnet.review : StudyPalette.inkTertiary)
                        .frame(width: 6, height: 6)
                    Text(site.title).font(.caption2).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1).fixedSize()
                }
            }
            if connect.isRunning {
                ProgressView().controlSize(.mini)
            } else if let site = connect.signInSite {
                Button(site == .mediaspace ? "Mot de passe edu-ID" : "Confirmer que c'est toi") { desk.signIn = site }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(StudyPalette.ink)
            } else if SchoolConnect.Site.allCases.contains(where: { connect.state($0) == .failed }) {
                Button("Réessayer") { Task { await connect.connectAll(prompting: true) } }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(StudyPalette.ink)
            }
        }
        .padding(.top, 6)
    }

    private func shortcut(_ pane: StudyDesk.Pane, _ detail: String) -> some View {
        Button { desk.pane = pane } label: {
            HStack(spacing: 14) {
                Image(systemName: pane.icon)
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(StudyPalette.raisedMore, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .foregroundStyle(StudyPalette.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.body.weight(.medium)).foregroundStyle(StudyPalette.ink)
                    Text(detail).font(.caption).foregroundStyle(StudyPalette.inkSecondary)
                }
                Spacer()
                Text("⌘\(String(pane.shortcut.character))").font(.caption.monospacedDigit()).foregroundStyle(StudyPalette.inkTertiary)
            }
            .padding(12)
            .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(StudyPalette.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
