import SwiftUI
import UIKit
import SwiftData
#if canImport(FamilyControls) && SCREEN_TIME
import FamilyControls
#endif

// MARK: - Entrer en mode étude

/// Dans le chrono : « Mode étude » et sa durée. Lance (ou verrouille) la
/// session ; le Mac suit, et se ferme au reste lui aussi.
struct StudyModeEntry: View {
    var courseID: UUID?
    var taskType: TaskType
    var targetID: UUID?

    @Environment(AppContainer.self) private var app
    @State private var showingSetup = false
    @State private var showingCustom = false
    /// Bloquer le reste (apps, sites) pendant le mode étude. Retenu d'une fois sur l'autre.
    @AppStorage("studyMode.blocking") private var blocking = false

    var body: some View {
        if app.focus.isStudying {
            Button {
                app.router.showingStudyMode = true
            } label: {
                Label("Mode étude", systemImage: "moon.stars.fill")
            }
            .buttonStyle(.carnetSecondaryWide)
        } else {
        Menu {
                Section("Mode étude") {
                    ForEach(StudyMode.durations, id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60)")") {
                            enter(minutes)
                        }
                    }
                    Button("Sans fin", systemImage: "infinity") { enter(nil) }
                    Button("Autre durée…", systemImage: "clock") { showingCustom = true }
                }
                if StudyLock.isAvailable {
                    Toggle("Bloquer le reste", isOn: $blocking)
                    if blocking, !StudyLock.shared.isAuthorized {
                        Button("Réglages", systemImage: "gearshape") { showingSetup = true }
                    }
                }
            } label: {
                Label("Mode étude", systemImage: "moon.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.carnetSecondaryWide)
            .sheet(isPresented: $showingSetup) {
                NavigationStack { StudyModeSettingsView() }
            }
            .sheet(isPresented: $showingCustom) {
                StudyCustomDuration { minutes in
                    showingCustom = false
                    enter(minutes)
                }
                .presentationDetents([.height(320)])
            }
        }
    }

    private func enter(_ minutes: Int?) {
        app.focus.enterStudy(minutes: minutes, courseID: courseID, taskType: taskType, targetID: targetID,
                             locks: blocking && StudyLock.isAvailable)
        // L'autorisation et les apps permises se demandent dans l'écran du mode
        // étude, quel que soit le chemin par lequel on y entre.
        app.router.showingStudyMode = true
    }
}

// MARK: - L'écran plein

/// « Mode étude » dans un menu (une série, un exercice) : la durée, et la
/// session part sur ce qu'on regardait. Sur le Mac, le même geste est dans le
/// menu de chaque cours ; sur l'iPhone, il n'était que dans le chrono.
struct StudyModeMenu: View {
    var courseID: UUID?
    var targetID: UUID?

    @Environment(AppContainer.self) private var app
    @AppStorage("studyMode.blocking") private var blocking = false

    var body: some View {
        Menu {
            ForEach(StudyMode.durations, id: \.self) { minutes in
                Button(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60)")") {
                    app.focus.enterStudy(minutes: minutes, courseID: courseID, taskType: .exercise,
                                         targetID: targetID, locks: blocking && StudyLock.isAvailable)
                    app.router.showingStudyMode = true
                }
            }
            Button("Sans fin", systemImage: "infinity") {
                app.focus.enterStudy(minutes: nil, courseID: courseID, taskType: .exercise,
                                     targetID: targetID, locks: blocking && StudyLock.isAvailable)
                app.router.showingStudyMode = true
            }
        } label: {
            Label("Mode étude", systemImage: "moon.stars")
        }
    }
}

/// L'écran du mode étude sur l'iPhone : le temps qui reste, ce qu'on fait,
/// les outils permis. Papier de nuit, comme sur le Mac.
struct StudyModeScreen: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @State private var browsing: BrowsedLink?
    /// Le tuteur gratuit, sans l'app Claude.
    @State private var tutorQuestion: TutorQuestion?
    @State private var tab: StudyTab = StudyTab(rawValue: StudyModeScreen.launchTab ?? "") ?? .desk
    /// L'onglet imposé par `-studyTab` (captures). `PreviewLaunch` n'existe
    /// qu'en Debug : sans ce garde, la build Release (l'archive) ne compile pas.
    private static var launchTab: String? {
        #if DEBUG
        PreviewLaunch.string(PreviewLaunch.studyTabFlag)
        #else
        nil
        #endif
    }
    @State private var calc = CalcModel()
    @Environment(\.openURL) private var openURL
    @Environment(\.modelContext) private var context
    /// L'horaire du jour, relu chaque minute.
    @State private var classes: [ScheduledClass] = []
    @State private var lock = StudyLock.shared
    @State private var music = StudyMusic.shared
    /// Premier verrou sans réglage : autoriser le Temps d'écran, ou choisir les
    /// apps permises — avant de se retrouver sans GoodNotes.
    @State private var showingLockSetup = false
    /// Le bureau complet même quand la session est sur le Mac.
    @AppStorage("study.fullDeskWithMac") private var fullDeskWithMac = false
    @State private var showingAllowedApps = false
    /// Le même arrangement que sur le Mac (`DeskArrangement`) : l'onglet suit le moment,
    /// sauf si on a choisi un onglet soi-même (jusqu'au moment suivant).
    @State private var lastArrangement: String?
    @State private var tabPinned = false
    /// La pause ou le bilan qu'on a écarté (jusqu'au prochain changement).
    @State private var dismissedTakeover: DeskArrangement.Takeover?

    /// Les onglets du mode étude — les mêmes outils que le bureau du Mac.
    enum StudyTab: String, CaseIterable, Identifiable {
        case desk, series, course, calc, music
        var id: String { rawValue }
        var title: String {
            switch self {
            case .desk: return String(localized: "Bureau")
            case .series: return String(localized: "Série")
            case .course: return String(localized: "Cours (au singulier)")
            case .calc: return String(localized: "Calcul")
            case .music: return String(localized: "Musique")
            }
        }
        var icon: String {
            switch self {
            case .desk: return "moon.stars"
            case .series: return "doc.text"
            case .course: return "books.vertical"
            case .calc: return "function"
            case .music: return "music.note"
            }
        }
    }

    private var focus: FocusController { app.focus }
    private var course: Course? { courses.first { $0.id == focus.state?.courseID } }
    private var tint: Color { course.map { Carnet.tint($0.colorHex) } ?? Carnet.ink }
    private var moment: DeskMoment {
        DeskSchedule.moment(taskType: focus.state?.taskType ?? .exercise, inGroup: focus.state?.groupSession != nil, course: course)
    }

    /// Ce que le bureau sait du moment (voir `DeskArrangement`, le même qu'au Mac).
    private var arrangementContext: DeskArrangement.Context {
        var context = DeskArrangement.Context(moment: moment)
        context.isTheory = (focus.state?.taskType ?? .exercise).canonical == .theory
        let exercise = course?.allExercises.first { $0.id == focus.state?.targetID }
        context.hasTarget = exercise != nil
        context.targetDone = exercise?.isDone ?? false
        context.seriesComplete = exercise != nil && (exercise?.series?.isComplete ?? false)
        switch focus.phase() {
        case .onBreak: context.phase = .onBreak
        case .paused: context.phase = .paused
        default: context.phase = focus.isStudying ? .running : .ended
        }
        if let until = focus.state?.studyUntil, !StudyMode.isOpenEnded(focus.state) {
            context.minutesLeft = Int(max(0, until.timeIntervalSinceNow) / 60)
        }
        return context
    }

    /// Ce qui prend l'écran un instant : la pause, la pause du chrono, les cinq dernières minutes.
    @ViewBuilder
    private var takeoverCard: some View {
        let kind = DeskArrangement.takeover(for: arrangementContext)
        if kind != .none, kind != .classBreak, dismissedTakeover != kind {
            VStack(spacing: 12) {
                Image(systemName: kind == .onBreak ? "cup.and.saucer" : (kind == .paused ? "pause.circle" : "hourglass"))
                    .font(.largeTitle).foregroundStyle(Carnet.inkSecondary)
                Text(kind == .onBreak ? "Pause" : (kind == .paused ? String(localized: "En pause") : String(localized: "Bientôt fini")))
                    .font(Carnet.serif(.title)).foregroundStyle(Carnet.ink)
                HStack(spacing: 10) {
                    switch kind {
                    case .onBreak: Button("Écourter la pause") { focus.skipBreak() }.buttonStyle(.ink)
                    case .paused: Button("Reprendre") { focus.resume() }.buttonStyle(.ink)
                    default: Button("Encore 25 min") { focus.extendStudy(minutes: 25) }.buttonStyle(.ink)
                    }
                    Button("Plus tard") { dismissedTakeover = kind }.buttonStyle(.paper)
                }
            }
            .padding(24)
            .carnetGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(24)
            .transition(.opacity)
        }
    }

    private var arrangementKey: String { DeskArrangement.signature(arrangementContext) }

    /// À un changement de moment, l'onglet se met où le moment le veut — sauf si on a
    /// choisi le sien (épinglé jusqu'au moment suivant).
    private func arrange() {
        guard StudyModeScreen.launchTab == nil else { return }
        let key = arrangementKey
        guard key != lastArrangement else { return }
        lastArrangement = key
        tabPinned = false
        switch DeskArrangement.layout(for: arrangementContext).center {
        case .exercise: tab = .series
        case .course: tab = .course
        case .desk: tab = .desk
        default: break
        }
    }

    var body: some View {
        ZStack {
            Carnet.ground.ignoresSafeArea()
            Color.clear.frame(width: 0, height: 0)
                .onAppear { arrange() }
                .onChange(of: arrangementKey) { _, _ in arrange() }
            RadialGradient(colors: [tint.opacity(0.18), .clear], center: .top, startRadius: 20, endRadius: 520)
                .ignoresSafeArea()
            if focus.studyIsOver, focus.state?.taskType == .lecture {
                lectureDone
            } else if focus.studyIsOver {
                done
            } else {
                Group {
                    switch tab {
                    case .desk:
                        switch moment {
                        case .lecture where course != nil:
                            VStack(spacing: 0) {
                                compactHeader
                                LectureDeskView(course: course!, klass: DeskSchedule.latest(of: course?.id, in: classes),
                                                next: DeskSchedule.next(in: classes), hub: SiteHub.shared, compact: true,
                                                openCourse: openCourse,
                                                openApp: { _, scheme in if let url = URL(string: scheme) { openURL(url) } },
                                                openWeb: { url, title in browsing = BrowsedLink(title: title, url: url, icon: "globe") })
                                holdToFinish.padding(.horizontal, 20).padding(.vertical, 8)
                            }
                        case .revision where course != nil:
                            VStack(spacing: 0) {
                                compactHeader
                                RevisionDeskView(course: course!, compact: true, openCourse: openCourse) { exercise in
                                    focus.updateContext(courseID: .some(course?.id), taskType: .exercise, targetID: .some(exercise.id))
                                    tab = .series
                                }
                                holdToFinish.padding(.horizontal, 20).padding(.vertical, 8)
                            }
                        default:
                            if sessionOnMac, !fullDeskWithMac {
                                CompanionDesk { fullDeskWithMac = true }
                            } else {
                                session
                            }
                        }
                    case .series: StudySeriesPhone(course: course, courses: courses)
                    case .course:
                        CoursePane(course: course, desk: SiteHub.shared,
                                   openWeb: { url, title in browsing = BrowsedLink(title: title, url: url, icon: "globe") },
                                   ask: askClaude, compact: true,
                                   go: { destination in
                                       if case .exercise(let exercise) = destination {
                                           focus.updateContext(courseID: .some(course?.id), taskType: .exercise, targetID: .some(exercise.id))
                                           tab = .series
                                       }
                                   })
                    case .calc:
                        CalcPane(desk: calc, compact: true,
                                 openWeb: { url, title in browsing = BrowsedLink(title: title, url: url, icon: "globe") })
                    case .music:
                        MusicPane(compact: true)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 6) {
                        // Ce qui joue, au-dessus des onglets (sauf dans l'onglet Musique).
                        if tab != .music, music.nowPlaying.hasTrack {
                            MusicMiniPlayer(wide: true) { tab = .music }
                                .padding(.horizontal, 12)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        tabBar
                    }
                    .animation(.smooth(duration: 0.25), value: music.nowPlaying.hasTrack)
                }
            }
        }
        .overlay { takeoverCard }
        .sheet(item: $tutorQuestion) { question in
            PhoneTutorChat(course: course, exercise: FocusController.target(of: focus.state?.targetID, in: course).exercise,
                           first: question.text)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: DeskArrangement.takeover(for: arrangementContext)) { _, _ in dismissedTakeover = nil }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .sheet(item: Binding(get: { SiteHub.shared.signIn }, set: { SiteHub.shared.signIn = $0 })) { site in
            SignInSheet(site: site) { SiteHub.shared.signedIn(site) }
        }
        #if DEBUG
        .task {
            // `-tutorAsk "question"` : la question posée à l'ouverture (captures du tuteur).
            if let question = PreviewLaunch.string("-tutorAsk") {
                try? await Task.sleep(for: .milliseconds(800))
                askClaude(question)
            }
        }
        #endif
        .task { if !SchoolConnect.shared.allConnected { await SchoolConnect.shared.connectAll(prompting: true) } }
        .task {
            while !Task.isCancelled {
                classes = DeskSchedule.today(context: context)
                let wake = DeskSchedule.nextChange(in: classes)
                try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow + 0.5)))
            }
        }
        .sheet(item: $browsing) { InAppBrowser(link: $0) }
        .musicAttached()
        // Sous verrou, l'écran ne se referme pas d'un geste.
        .interactiveDismissDisabled(focus.isLocked)
        .onAppear { checkLockSetup() }
        .onChange(of: focus.isLocked) { _, _ in checkLockSetup() }
        .sheet(isPresented: $showingLockSetup) { NavigationStack { StudyModeSettingsView() } }
        #if canImport(FamilyControls) && SCREEN_TIME
        .familyActivityPicker(isPresented: $showingAllowedApps, selection: $lock.selection)
        #endif
    }

    /// La même session tourne sur le Mac (il l'a publiée par le lien) : l'iPhone
    /// devient son compagnon plutôt qu'un second bureau.
    private var sessionOnMac: Bool {
        #if DEBUG
        // `-companionPreview` : l'écran compagnon sans Mac (captures).
        if PreviewLaunch.isSet("-companionPreview") { return true }
        #endif
        guard let remote = CloudRelay.remoteTimer(), let state = remote.state, let mine = focus.state,
              abs(state.sessionStartedAt.timeIntervalSince(mine.sessionStartedAt)) < 2 else { return false }
        return music.remotes[remote.device]?.platform == .mac
    }

    private func checkLockSetup() {
        guard StudyLock.isAvailable, focus.isLocked else { return }
        if !lock.isAuthorized {
            showingLockSetup = true
        } else if lock.needsAllowedApps {
            showingAllowedApps = true
        }
    }

    /// Ouvre l'onglet Cours sur ce que l'accueil demande.
    private func openCourse(_ request: SiteHub.Request) {
        SiteHub.shared.request = request
        tab = .course
    }

    /// En haut du bureau « En cours » et « Révision » : ce qui reste, la forme
    /// du bureau, la pause, la sortie.
    private var compactHeader: some View {
        HStack(spacing: 12) {
            momentMenu
            if focus.isLocked {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(Carnet.inkSecondary)
                    .accessibilityLabel("Verrouillé")
            }
            Spacer(minLength: 0)
            TimelineView(.periodic(from: StudyMode.tickAnchor(focus.state), by: 1)) { context in
                Text(TimerText.clock(StudyMode.clock(focus.state, at: context.date)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Carnet.ink)
            }
            Button {
                if focus.isRunning { focus.pause() } else { focus.resume() }
            } label: {
                Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                    .frame(width: 36, height: 36)
                    .background(Carnet.ink, in: Circle())
                    .foregroundStyle(Carnet.ground)
            }
            .accessibilityLabel(focus.isRunning ? "Pause" : "Reprendre")
            if !focus.isLocked {
                Button { app.router.showingStudyMode = false } label: {
                    Image(systemName: "chevron.down").font(.headline)
                }
                .foregroundStyle(Carnet.inkSecondary)
                .accessibilityLabel("Réduire")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// La forme du bureau, à changer à la main (le chrono continue).
    private var momentMenu: some View {
        Menu {
            Button { focus.updateContext(taskType: .lecture) } label: { Label(DeskMoment.lecture.title, systemImage: DeskMoment.lecture.icon) }
            Button { focus.updateContext(taskType: .exercise) } label: { Label(DeskMoment.series.title, systemImage: DeskMoment.series.icon) }
            Button { focus.updateContext(taskType: .theory) } label: {
                Label(course?.nextSitting != nil ? DeskMoment.revision.title : TaskType.theory.label, systemImage: DeskMoment.revision.icon)
            }
        } label: {
            Label(moment.title, systemImage: moment.icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Carnet.sheetRaised, in: Capsule())
                .foregroundStyle(Carnet.ink)
        }
    }

    /// La fin d'un cours suivi : enchaîner sur la série, prolonger, terminer.
    private var lectureDone: some View {
        let start = focus.state?.sessionStartedAt ?? .distantFuture
        let count = course.map { c in LectureMarkStore.shared.marks.filter { $0.courseID == c.id && $0.at >= start }.count } ?? 0
        return LectureAfterClass(course: course, markCount: count, compact: true, startSeries: {
            guard let course else { return }
            let next = FocusTargets.exercises(of: course.series, for: .exercise).upNext.first
            focus.updateContext(courseID: .some(course.id), taskType: .exercise, targetID: .some(next?.id))
            focus.extendStudy(minutes: 50)
            tab = .series
        }, extend: {
            focus.extendStudy(minutes: 25)
        }, finish: {
            focus.finish()
            app.router.endStudyMode()
        })
    }

    private var session: some View {
        ScrollView {
            VStack(spacing: 26) {
                HStack {
                    Label("Mode étude", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(1.1)
                        .foregroundStyle(Carnet.inkSecondary)
                    Spacer()
                    if sessionOnMac, fullDeskWithMac {
                        Button { fullDeskWithMac = false } label: { Label("Compagnon", systemImage: "laptopcomputer") }
                            .font(.caption)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                    if course != nil { momentMenu }
                    if !focus.isLocked {
                        Button { app.router.showingStudyMode = false } label: {
                            Image(systemName: "chevron.down").font(.headline)
                        }
                        .foregroundStyle(Carnet.inkSecondary)
                        .accessibilityLabel("Réduire")
                    }
                }
                if let group = focus.state?.groupSession {
                    Label("Ensemble · \(group.groupName)", systemImage: "person.2.fill")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                TimelineView(.periodic(from: StudyMode.tickAnchor(focus.state), by: 1)) { context in
                    let open = StudyMode.isOpenEnded(focus.state)
                    ZStack {
                        Circle().stroke(Carnet.rule, lineWidth: 5)
                        Circle()
                            .trim(from: 0, to: max(0.001, StudyMode.progress(focus.state, at: context.date)))
                            .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 6) {
                            Text(open ? "depuis" : "reste")
                                .font(.caption.weight(.semibold)).textCase(.uppercase).tracking(1.1)
                                .foregroundStyle(tint)
                            Text(TimerText.clock(StudyMode.clock(focus.state, at: context.date)))
                                .font(.system(size: 64, weight: .regular, design: .serif))
                                .monospacedDigit()
                                .foregroundStyle(Carnet.ink)
                            Text(open ? "sans fin · depuis \(DateUtils.time.string(from: focus.state?.studySince ?? context.date))"
                                 : "jusqu'à \(DateUtils.time.string(from: focus.state?.studyUntil ?? context.date))")
                                .font(.footnote)
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                    }
                    .frame(width: 270, height: 270)
                }

                VStack(spacing: 4) {
                    if let course {
                        Text(course.displayCode).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    }
                    Text(headline)
                        .font(Carnet.serif(.title2))
                        .foregroundStyle(Carnet.ink)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 14) {
                    Button {
                        if focus.isRunning { focus.pause() } else { focus.resume() }
                    } label: {
                        Image(systemName: focus.isRunning ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 64, height: 64)
                            .background(Carnet.ink, in: Circle())
                            .foregroundStyle(Carnet.ground)
                    }
                    .accessibilityLabel(focus.isRunning ? "Pause" : "Reprendre")
                    if !StudyMode.isOpenEnded(focus.state) {
                        Button { focus.extendStudy(minutes: 25) } label: {
                            Label("25 min", systemImage: "plus")
                        }
                        .buttonStyle(.carnetSecondary)
                    }
                }

                sessionSteps

                VStack(alignment: .leading, spacing: 10) {
                    Text("Tes outils").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                    ForEach(tools) { tool in
                        Button { open(tool) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tool.icon)
                                    .font(.body.weight(.medium))
                                    .frame(width: 40, height: 40)
                                    .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tool.title).foregroundStyle(Carnet.ink)
                                    Text(tool.subtitle).font(.caption).foregroundStyle(Carnet.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
                            }
                            .padding(10)
                            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.ink)
                    }
                }

                if StudyLock.isAvailable, !StudyLock.shared.isAuthorized {
                    NavigationLink {
                        StudyModeSettingsView()
                    } label: {
                        Label("Blocage pas activé", systemImage: "exclamationmark.lock")
                            .font(.footnote)
                    }
                    .foregroundStyle(Carnet.review)
                }

                holdToFinish
                    .padding(.top, 6)
            }
            .padding(24)
        }
    }

    // MARK: Onglets et fil de la session (comme le bureau du Mac)

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(StudyTab.allCases) { item in
                Button { tabPinned = true; tab = item } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon).font(.system(size: 17, weight: tab == item ? .semibold : .regular))
                        Text(item.title).font(.caption2.weight(tab == item ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(tab == item ? Carnet.ink : Carnet.inkSecondary)
                    .background(tab == item ? Carnet.sheetRaised : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var studySeries: ExerciseSeries? {
        if let current = course?.allExercises.first(where: { $0.id == focus.state?.targetID })?.series { return current }
        let all = course?.sortedSeries.filter { !$0.exercises.isEmpty } ?? []
        return all.first { $0.plannedWeek >= (course?.currentWeek ?? 0) && !$0.isComplete } ?? all.last
    }

    /// « Ta session » : les quatre étapes, comme sur le Mac.
    private var sessionSteps: some View {
        let theoryLeft = course.map { c in c.sortedTheoryItems.filter { $0.plannedWeek == c.currentWeek && !$0.isWatched }.count } ?? 0
        let series = studySeries
        return VStack(alignment: .leading, spacing: 10) {
            Text("Ta session").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
            // Les étapes et leur ordre : Personnaliser › Ta session (les mêmes sur le Mac).
            ForEach(Array(SessionFlow.load().steps.enumerated()), id: \.element) { index, item in
                switch item {
                case .course:
                    step(index + 1, item.title, theoryLeft == 0 ? String(localized: "À jour pour cette semaine") : String(localized: "\(theoryLeft) à voir cette semaine"),
                         done: theoryLeft == 0) { tab = .course }
                case .series:
                    step(index + 1, item.title, series.map { "\($0.title.isEmpty ? $0.displayName : $0.title) · \($0.doneCount)/\($0.requiredExercises.count)" } ?? String(localized: "Pas de série"),
                         done: series?.isComplete == true) { tab = .series }
                case .help:
                    step(index + 1, item.title, String(localized: "Un indice de Claude"), done: false) { askClaude(ClaudeTutor.QuickAction.hint.prompt) }
                case .debrief:
                    step(index + 1, item.title, String(localized: "Post-mortem quand la série est corrigée"), done: false) {
                        askClaude(ClaudeTutor.postMortemPrompt(useSkill: false))
                    }
                }
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, done: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(done ? Carnet.correct.opacity(0.25) : Carnet.sheetRaised)
                    if done { Image(systemName: "checkmark").font(.callout.weight(.bold)).foregroundStyle(Carnet.correct) }
                    else { Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(Carnet.ink) }
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(Carnet.ink)
                    Text(detail).font(.caption).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(10)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Claude sur l'iPhone : la question et le contexte copiés, l'app Claude ouverte.
    /// L'app Claude si elle est là (ton abonnement), sinon le tuteur gratuit dans l'app.
    private func askClaude(_ question: String) {
        let exercise = FocusController.target(of: focus.state?.targetID, in: course).exercise
        if PhoneClaude.hasClaudeApp || !PhoneClaude.hasFreeTutor {
            UIPasteboard.general.string = StudyPhoneClaude.prompt(question, exercise: exercise, course: course)
            if let url = URL(string: "claude://") { openURL(url) }
        } else {
            tutorQuestion = TutorQuestion(text: question)
        }
    }

    /// Tenir pour terminer : une seconde et demie pour y penser. Sous verrou, la
    /// sortie d'urgence : huit secondes, et la session le note.
    ///
    /// Le geste est `HoldToActButton` et non `onLongPressGesture` : dans cette
    /// liste, l'appui long était rendu au défilement, et « Maintiens pour finir »
    /// ne finissait rien.
    private var holdToFinish: some View {
        let locked = focus.isLocked
        let duration = locked ? StudyMode.emergencyHold : 1.5
        return HoldToActButton(duration: duration) {
            focus.finish(emergency: locked)
            app.router.endStudyMode()
        } label: { holding in
            HStack(spacing: 8) {
                Image(systemName: locked ? "exclamationmark.triangle" : "checkmark")
                Text(holding ? "Maintiens…"
                     : locked ? "Sortie d'urgence · maintiens \(Int(StudyMode.emergencyHold)) s"
                              : "Maintiens pour finir")
                    .contentTransition(.opacity)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Carnet.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .accessibilityLabel(locked ? "Sortie d'urgence" : "Terminer la session")
        .accessibilityHint(locked
                           ? String(localized: "Termine et enregistre la session, notée « sortie d'urgence ».")
                           : String(localized: "Tiens le bouton \(Int(duration)) seconde pour terminer et enregistrer."))
    }

    private var done: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal").font(.system(size: 44, weight: .light)).foregroundStyle(Carnet.correct)
            Text("C'est fait.").font(.system(size: 48, design: .serif)).foregroundStyle(Carnet.ink)
            Text("Tout est rouvert.").foregroundStyle(Carnet.inkSecondary)
            Button {
                focus.finish()
                app.router.endStudyMode()
            } label: { Text("Terminer").frame(maxWidth: .infinity) }
                .buttonStyle(.carnetPrimaryWide)
            Button { focus.extendStudy(minutes: 25) } label: { Text("Encore 25 min").frame(maxWidth: .infinity) }
                .buttonStyle(.carnetSecondaryWide)
            Button("Continuer sans") {
                focus.leaveStudy()
                app.router.showingStudyMode = false
            }
            .foregroundStyle(Carnet.inkSecondary)
        }
        .padding(32)
    }

    private var headline: String {
        let target = FocusController.target(of: focus.state?.targetID, in: course)
        return target.exercise?.displayNumber ?? target.theoryItem?.displayNumber
            ?? (course == nil ? String(localized: "Session libre") : (focus.state?.taskType.label ?? ""))
    }

    private var tools: [StudyMode.Tool] {
        var links: [String] = []
        if let course { links = [course.moodleURLString] + course.contentSources }
        return StudyMode.tools(courseName: course?.name, courseLinks: links)
    }

    private func open(_ tool: StudyMode.Tool) {
        switch tool.kind {
        case .web(let url):
            browsing = BrowsedLink(title: tool.title, url: url, icon: tool.icon)
        case .app(_, let scheme):
            if let url = URL(string: scheme) { openURL(url) }
        }
    }
}

// MARK: - Réglages

/// Configurer le blocage de l'iPhone : l'autorisation du Temps d'écran, les
/// apps permises, les sites permis (les mêmes que sur le Mac).
struct StudyModeSettingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var lock = StudyLock.shared
    @State private var showingPicker = false
    @State private var newSite = ""
    /// Copie locale : la liste vit dans iCloud clé-valeur, qui n'est pas observé.
    @State private var sites: [String] = []

    var body: some View {
        Form {
            if StudyLock.isAvailable {
                Section {
                    if lock.isAuthorized {
                        Label("Autorisé", systemImage: "checkmark.shield")
                            .foregroundStyle(Carnet.correct)
                    } else {
                        Button {
                            Task { await lock.requestAuthorization() }
                        } label: {
                            Label("Autoriser", systemImage: "lock.shield")
                        }
                        if let error = lock.lastError {
                            Text(error).font(.footnote).foregroundStyle(Carnet.wrong)
                        }
                    }
                } header: {
                    CarnetFormHeader(String(localized: "Temps d'écran"))
                } footer: {
                    Text("Seulement tes apps et sites de cours, jusqu'à la fin.")
                }

                Section {
                    #if canImport(FamilyControls) && SCREEN_TIME
                    Button {
                        showingPicker = true
                    } label: {
                        LabeledContent("Apps permises", value: lock.allowedAppCount == 0 ? "aucune" : "\(lock.allowedAppCount)")
                    }
                    .disabled(!lock.isAuthorized)
                    .familyActivityPicker(isPresented: $showingPicker, selection: $lock.selection)
                    #endif
                } header: {
                    CarnetFormHeader("Apps")
                } footer: {
                    Text("Par exemple GoodNotes, Claude et Safari.")
                }
            } else {
                Section {
                    Text("Dans cette version, l'iPhone ne bloque pas les autres apps : Apple doit encore autoriser le Temps d'écran pour Polymestre. Le mode étude reste ton écran de travail, et le Mac, lui, bloque.")
                        .font(.subheadline)
                } header: {
                    CarnetFormHeader(String(localized: "Temps d'écran"))
                }
            }

            Section {
                let groups = StudyMode.siteGroups(sites)
                ForEach(groups.named, id: \.self) { site in
                    Text(verbatim: site)
                }
                .onDelete { offsets in removeSites(offsets.map { groups.named[$0] }) }
                if !groups.service.isEmpty {
                    // Connexions et hébergeurs : une ligne, dépliable pour qui veut y toucher.
                    DisclosureGroup {
                        ForEach(groups.service, id: \.self) { site in
                            Text(verbatim: site).foregroundStyle(Carnet.inkSecondary)
                        }
                        .onDelete { offsets in removeSites(offsets.map { groups.service[$0] }) }
                    } label: {
                        LabeledContent("Connexion et hébergement", value: String(localized: "\(groups.service.count) domaines"))
                    }
                }
                HStack {
                    TextField("Ajouter un site", text: $newSite)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit(addSite)
                    Button("Ajouter", action: addSite).disabled(StudyMode.normalizedDomain(newSite) == nil)
                }
            } header: {
                CarnetFormHeader(String(localized: "Sites permis"))
            } footer: {
                Text("« epfl.ch » ouvre aussi Moodle, Botafogo…")
            }
        }
        .carnetForm()
        // Sous verrou, la liste ne s'élargit pas.
        .disabled(app.focus.isLocked)
        .safeAreaInset(edge: .top) {
            if app.focus.isLocked {
                Label("Verrouillé : les réglages reviennent à la fin de la session.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    .padding(10)
            }
        }
        .navigationTitle("Mode étude")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sites = lock.sites }
    }

    private func removeSites(_ removed: [String]) {
        sites.removeAll { removed.contains($0) }
        lock.sites = sites
    }

    private func addSite() {
        guard let domain = StudyMode.normalizedDomain(newSite) else { return }
        if !sites.contains(domain) {
            sites.append(domain)
            lock.sites = sites
        }
        newSite = ""
    }
}

/// Une durée choisie à la main : en minutes, ou jusqu'à une heure.
private struct StudyCustomDuration: View {
    var start: (Int) -> Void
    @State private var minutes = 75
    @State private var byEnd = false
    @State private var end = Date().addingTimeInterval(75 * 60)

    var body: some View {
        NavigationStack {
            Form {
                Picker("Choisir", selection: $byEnd) {
                    Text("Durée").tag(false)
                    Text("Heure de fin").tag(true)
                }
                .pickerStyle(.segmented)
                if byEnd {
                    DatePicker("Jusqu'à", selection: $end, displayedComponents: .hourAndMinute)
                } else {
                    Stepper("\(minutes) min", value: $minutes, in: StudyMode.minuteRange, step: 5)
                }
            }
            .navigationTitle("Mode étude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Commencer") { start(byEnd ? StudyMode.minutes(until: end) : minutes) }
                }
            }
        }
    }
}
