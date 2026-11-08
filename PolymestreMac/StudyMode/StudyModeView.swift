import SwiftUI
import SwiftData

/// L'écran plein du mode étude : le choix avant de commencer, la session,
/// puis « c'est fait ».
struct StudyModeView: View {
    @Bindable var screen: StudyModeController.Screen
    var browser: StudyBrowserModel
    var desk: StudyDesk

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        ZStack {
            StudyBackground(tint: tint)
            switch screen.stage {
            case .setup:
                // Défilable : la carte grandit (cours à l'horaire, outils
                // ouverts) et ne doit jamais déborder d'un petit écran.
                GeometryReader { proxy in
                    ScrollView {
                        StudySetupView(screen: screen, courses: tracked)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.never)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .session:
                if timer.studyIsOver, timer.taskType == .lecture {
                    LectureDoneView(course: tracked.first { $0.id == timer.courseID })
                        .transition(.opacity)
                } else if timer.studyIsOver {
                    StudyDoneView()
                        .transition(.opacity)
                } else if timer.phase == .idle {
                    // La session a été terminée ailleurs : l'écran va se fermer.
                    ProgressView().controlSize(.large)
                } else {
                    StudyWorkspace(screen: screen, browser: browser, desk: desk, courses: tracked, panels: screen.panels, sideHosted: screen.sideHosted)
                        .transition(.opacity)
                }
            }
        }
        .modifier(StudyScheme(alwaysDark: settings.studyAlwaysDark))
        .tint(StudyPalette.ink)
        .animation(.smooth(duration: 0.35), value: screen.stage)
        .animation(.smooth(duration: 0.35), value: timer.studyIsOver)
        .onAppear {
            browser.sites = { [weak settings] in settings?.studySites ?? StudyMode.defaultSites }
            browser.locks = { [weak timer] in timer?.studyLocks ?? true }
        }
    }

    private var tint: Color {
        let id = screen.stage == .setup ? screen.courseID : timer.courseID
        return MacTargets.tint(tracked.first { $0.id == id })
    }
}

/// Sombre d'office, ou l'apparence du Mac (Réglages › Mode étude › « Toujours sombre »).
private struct StudyScheme: ViewModifier {
    var alwaysDark: Bool

    func body(content: Content) -> some View {
        if alwaysDark {
            content.environment(\.colorScheme, .dark).preferredColorScheme(.dark)
        } else {
            content
        }
    }
}

/// Le fond : le papier de nuit, et une lueur de la couleur du cours.
private struct StudyBackground: View {
    var tint: Color
    @State private var ground = DeskGround.shared

    var body: some View {
        ZStack {
            StudyPalette.ground
            // Le fond d'écran, flouté une fois, sous le papier de nuit : le verre du
            // dessus a quelque chose à traverser.
            if let image = ground.image {
                // Rogné, et sans effet sur la mise en page : une image « remplir » rend sa
                // taille débordante au parent, et la fenêtre devenait plus large que l'écran.
                Color.clear
                    .overlay { Image(nsImage: image).resizable().scaledToFill() }
                    .clipped()
                    .overlay(StudyPalette.ground.opacity(0.86))
                    .allowsHitTesting(false)
            }
            RadialGradient(colors: [tint.opacity(0.14), .clear], center: .topLeading, startRadius: 40, endRadius: 900)
            RadialGradient(colors: [tint.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 700)
        }
        .ignoresSafeArea()
        .onAppear { ground.load() }
    }
}

// MARK: - Avant de commencer

private struct StudySetupView: View {
    @Bindable var screen: StudyModeController.Screen
    let courses: [Course]

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @State private var minutes = 50
    /// Sans heure de fin : on termine quand on a fini.
    @State private var openEnded = false
    @State private var pomodoro = false
    @State private var classes: [ScheduledClass] = []
    @State private var chromePermission = SystemChrome.currentPermission
    @State private var trusted = AppPlacement.isTrusted
    @Environment(\.modelContext) private var context

    private var currentClass: ScheduledClass? { DeskSchedule.current(in: classes) }

    /// Ce qu'il manque avant de bloquer (`StudyReadiness`, testé).
    private var missing: [StudyReadiness.Missing] {
        StudyReadiness.missing(blocking: screen.locks, placeApps: settings.studyPlaceApps, trusted: trusted,
                               hideChrome: settings.studyHideSystemChrome, automationGranted: chromePermission == .granted)
    }

    private func message(for item: StudyReadiness.Missing) -> LocalizedStringKey {
        switch item {
        case .accessibility: return "Poser GoodNotes et les autres apps permises dans le bureau : autorise l'Accessibilité."
        case .systemEvents: return chromePermission == .denied
            ? "Dock et barre des menus : refusé, ils resteront visibles (Réglages Système › Automatisation)."
            : "Cacher aussi le Dock et la barre des menus ?"
        }
    }

    private var course: Course? { courses.first { $0.id == screen.courseID } }
    private var tint: Color { MacTargets.tint(course) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Kicker("Mode étude", color: tint)
                Text("On s'y met ?")
                    .font(StudyType.hero)
                    .foregroundStyle(StudyPalette.ink)
                Text("Seulement tes outils de cours, jusqu'à la fin.")
                    .font(.title3)
                    .foregroundStyle(StudyPalette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let klass = currentClass, screen.taskType != .lecture || screen.courseID != klass.slot.courseID {
                // Un cours à l'horaire, maintenant : le suivre, jusqu'à sa fin.
                Button {
                    screen.courseID = klass.slot.courseID
                    screen.taskType = .lecture
                    screen.targetID = nil
                    minutes = LectureClock.studyMinutes(for: klass.slot, now: Date())
                    openEnded = false
                    pomodoro = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: DeskMoment.lecture.icon).font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Suivre le cours · \(klass.slot.courseCode)").font(.headline)
                            Text("\(klass.kindLabel)\(klass.location.isEmpty ? "" : " · \(klass.location)") · jusqu'à \(DateUtils.time.string(from: klass.slot.end))")
                                .font(.caption).opacity(0.8)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                    }
                    .padding(14)
                    .foregroundStyle(StudyPalette.ground)
                    .background(Carnet.tint(klass.colorHex), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            field(String(localized: "Sur quoi")) {
                VStack(alignment: .leading, spacing: 12) {
                    FlowLayout(spacing: 7) {
                        CourseChip(title: String(localized: "Libre"), color: StudyPalette.inkSecondary, selected: screen.courseID == nil) {
                            screen.courseID = nil
                            screen.targetID = nil
                        }
                        ForEach(courses) { item in
                            CourseChip(title: item.displayCode, color: Carnet.tint(item.colorHex), selected: screen.courseID == item.id) {
                                screen.courseID = item.id
                                screen.targetID = nil
                            }
                            .help(item.name)
                        }
                    }
                    HStack(spacing: 10) {
                        Picker("Travail", selection: $screen.taskType) {
                            ForEach(TaskType.choices + [.lecture]) { Label($0.label, systemImage: $0.icon).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: screen.taskType) { _, _ in screen.targetID = nil }
                        if let course {
                            TargetMenu(course: course, taskType: screen.taskType, selection: $screen.targetID)
                        }
                    }
                }
            }

            field(String(localized: "Durée")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(StudyMode.durations, id: \.self) { value in
                            durationChip(value < 60 ? "\(value) min" : (value % 60 == 0 ? "\(value / 60) h" : "\(value / 60) h \(value % 60)"),
                                         selected: !openEnded && minutes == value) {
                                minutes = value
                                openEnded = false
                            }
                        }
                        durationChip(String(localized: "Sans fin"), icon: "infinity", selected: openEnded) { openEnded = true }
                            .help("Pas d'heure de fin : tu termines quand tu as fini.")
                    }
                    // Une durée libre, en minutes, ou une heure de fin.
                    HStack(spacing: 8) {
                        TextField("min", value: Binding(get: { minutes },
                                                        set: { minutes = min(max($0, StudyMode.minuteRange.lowerBound), StudyMode.minuteRange.upperBound)
                                                               openEnded = false }),
                                  format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                        Stepper("", value: Binding(get: { minutes }, set: { minutes = $0; openEnded = false }),
                                in: StudyMode.minuteRange, step: 5).labelsHidden()
                        Text("min, jusqu'à").foregroundStyle(StudyPalette.inkSecondary)
                        DatePicker("Jusqu'à", selection: Binding(get: { Date().addingTimeInterval(Double(minutes) * 60) },
                                                                 set: { minutes = StudyMode.minutes(until: $0); openEnded = false }),
                                   displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                    .opacity(openEnded ? 0.45 : 1)
                }
            }

            HStack(alignment: .top, spacing: 36) {
            field(String(localized: "Rythme")) {
                Toggle(isOn: $pomodoro) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pomodoro").foregroundStyle(StudyPalette.ink)
                        Text("\(settings.focusMinutes) min de travail, \(settings.shortBreakMinutes) min de pause.")
                            .font(.caption)
                            .foregroundStyle(StudyPalette.inkSecondary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Carnet.correct)
                .disabled(timer.phase != .idle)
            }
            }

            field(String(localized: "Blocage")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Bindable(screen).locks) {
                        Text("Bloquer le reste").foregroundStyle(StudyPalette.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(Carnet.correct)
                    // Une fois le blocage en route, les Réglages sont fermés : c'est ici
                    // qu'on autorise ce dont le blocage a besoin.
                    ForEach(missing, id: \.self) { item in
                        HStack(spacing: 10) {
                            Text(message(for: item))
                                .font(.caption)
                                .foregroundStyle(StudyPalette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if item == .accessibility || chromePermission != .denied {
                                Button("Autoriser") {
                                    if item == .accessibility { AppPlacement.requestTrust() } else { chromePermission = SystemChrome.request() }
                                }
                                .buttonStyle(PaperButtonStyle())
                            }
                        }
                    }
                }
            }

            if screen.locks {
                field(String(localized: "Ouverts")) {
                    StudyToolStrip(course: course)
                }
            }

            HStack(spacing: 12) {
                Button("Annuler") { StudyModeController.shared.cancelSetup() }
                    .buttonStyle(PaperButtonStyle(large: true))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(endLabel)
                    .font(.callout)
                    .foregroundStyle(StudyPalette.inkSecondary)
                Button {
                    settings.studyMinutes = minutes
                    settings.studyOpenEnded = openEnded
                    settings.studyPomodoro = pomodoro
                    StudyModeController.shared.begin(minutes: openEnded ? nil : minutes, pomodoro: pomodoro)
                } label: {
                    Label(timer.phase == .idle ? "Commencer" : "Verrouiller la session", systemImage: "lock.fill")
                        .padding(.horizontal, 10)
                }
                .buttonStyle(InkButtonStyle(large: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 720)
        .deskGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onAppear {
            minutes = settings.studyMinutes
            openEnded = settings.studyOpenEnded
            pomodoro = timer.phase == .idle ? settings.studyPomodoro : (timer.state?.pomodoro ?? false)
            classes = DeskSchedule.today(context: context)
            fitLecture()
        }
        .task {
            // Lue hors du fil principal : elle peut lancer System Events.
            if settings.studyHideSystemChrome { chromePermission = await SystemChrome.resolvePermission() }
            // L'autorisation se donne dans les Réglages Système : on relit chaque seconde.
            while !Task.isCancelled {
                trusted = AppPlacement.isTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: screen.courseID) { _, _ in fitLecture() }
        .onChange(of: screen.taskType) { _, _ in fitLecture() }
    }

    /// Suivre un cours (le panneau, l'accueil, le choix ici) : jusqu'à sa fin,
    /// sans Pomodoro — un cours ne s'interrompt pas toutes les 25 minutes.
    private func fitLecture() {
        if classes.isEmpty { classes = DeskSchedule.today(context: context) }
        guard screen.taskType == .lecture else { return }
        pomodoro = false
        openEnded = false
        if let klass = currentClass, klass.slot.courseID == screen.courseID {
            minutes = LectureClock.studyMinutes(for: klass.slot, now: Date())
        }
    }

    private var endLabel: String {
        if openEnded { return String(localized: "sans heure de fin") }
        return String(localized: "jusqu'à ") + DateUtils.time.string(from: Date().addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private func durationChip(_ title: String, icon: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.body.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? StudyPalette.ground : StudyPalette.ink)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(selected ? StudyPalette.ink : StudyPalette.raisedMore, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Carnet.serif(.title3)).foregroundStyle(StudyPalette.ink)
            content()
        }
    }
}

/// Les outils permis, en petites icônes.
private struct StudyToolStrip: View {
    let course: Course?
    @Environment(MacSettings.self) private var settings

    var body: some View {
        let tools = StudyTools.tools(for: course, settings: settings)
        // En flux, et non en rangée : huit outils de 70 pt dépassaient la
        // carte et poussaient toute la mise en page hors du cadre.
        FlowLayout(spacing: 6) {
            ForEach(tools) { tool in
                VStack(spacing: 5) {
                    StudyToolIcon(tool: tool, size: 32)
                    Text(tool.title)
                        .font(.caption2)
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: 64)
                .help(tool.title)
            }
        }
    }
}

// MARK: - La session

/// Le temps du mode étude : ce qui reste (wall clock, même en pause).
struct StudyTimeline<Content: View>: View {
    @Environment(MacTimer.self) private var timer
    var interval: TimeInterval = 1
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        let anchor = StudyMode.tickAnchor(timer.state)
        TimelineView(TickSchedule(anchor: anchor, interval: interval, active: timer.isStudying)) { context in
            content(context.date)
        }
    }
}

/// Le grand cadran : ce qui reste du mode étude, le temps de travail dessous.
struct StudyDial: View {
    @Environment(MacTimer.self) private var timer
    var tint: Color
    var size: CGFloat

    var body: some View {
        ZStack {
            StudyTimeline { date in
                TimerRing(progress: StudyMode.progress(timer.state, at: date), tint: tint, lineWidth: 5, graduated: true)
            }
            VStack(spacing: 8) {
                TimerTimeline { date in
                    Kicker(timer.phase == .paused ? String(localized: "En pause") : (timer.statusLabel(at: date) ?? (StudyMode.isOpenEnded(timer.state) ? String(localized: "Sans fin") : String(localized: "Reste"))),
                           color: timer.phase == .onBreak ? MacStyle.breakTint : tint)
                }
                StudyTimeline { date in
                    Text(StudyMode.clock(timer.state, at: date).clockLabel)
                        .font(Carnet.clock(size * 0.24))
                        .foregroundStyle(StudyPalette.ink)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Image(systemName: timer.phase == .onBreak ? "cup.and.saucer" : "timer")
                    TimerClockText(font: .callout.monospacedDigit())
                    Text(timer.state?.pomodoro == true ? (timer.phase == .onBreak ? "de pause" : String(localized: "du bloc")) : "de travail")
                }
                .font(.callout)
                .foregroundStyle(StudyPalette.inkSecondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Ce qu'on travaille : la cible, ses questions, la suite.
struct StudyTargetCard: View {
    let course: Course?
    var tint: Color
    @Environment(MacTimer.self) private var timer

    var body: some View {
        let exercise = course?.allExercises.first { $0.id == timer.targetID }
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let course { CourseTag(code: course.displayCode, tint: tint) }
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(.largeTitle))
                    .foregroundStyle(StudyPalette.ink)
                    .lineLimit(2)
                if let exercise, !exercise.title.isEmpty, exercise.title != exercise.displayNumber {
                    Text(exercise.title).foregroundStyle(StudyPalette.inkSecondary).lineLimit(2)
                }
            }
            if let exercise, exercise.hasSubQuestions {
                SubQuestionChecklist(exercise: exercise, tint: tint, onDark: true)
            }
            if let course, timer.phase != .onBreak {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker("Ensuite")
                    UpNextList(course: course, limit: 3)
                }
            }
            if let exercise {
                HStack {
                    ExerciseQuickMark(exercise: exercise)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudyPalette.raised.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(StudyPalette.rule))
    }
}

/// Un bouton qu'il faut tenir : le temps d'y penser.
///
/// Le même geste que sur l'iPhone (`HoldToActButton` dans `StudyKit`) : un appui
/// long suivi par `onLongPressGesture` était rendu au défilement ou à la fenêtre
/// qui glisse, et « Terminer » ne terminait pas. Un clic simple ne fait rien
/// tant qu'on n'a pas tenu : un appui bref dit quoi faire.
struct HoldButton: View {
    let title: String
    var systemImage: String
    /// Secondes à tenir ; `0` : un clic suffit.
    var hold: Double
    var action: () -> Void

    var body: some View {
        HoldToActButton(duration: hold, action: action) { pressing in
            Label(pressing ? "Maintiens…" : title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(StudyPalette.ink)
                .padding(.horizontal, 20)
                .frame(height: 40)
        }
        .accessibilityLabel(title)
    }
}

// MARK: - Outils

/// Les outils de la session : les pages du cours, puis Moodle, Claude, GoodNotes…
@MainActor
enum StudyTools {
    static func tools(for course: Course?, settings: MacSettings) -> [StudyMode.Tool] {
        var links: [String] = []
        if let course {
            links.append(course.moodleURLString)
            links.append(contentsOf: course.contentSources)
        }
        var tools = StudyMode.tools(courseName: course?.name, courseLinks: links)
        // Seulement les apps permises et installées ; seulement les sites permis.
        tools.removeAll { tool in
            switch tool.kind {
            case .app(let bundleID, _):
                return !settings.studyApps.contains(bundleID) || !StudyModeController.isInstalled(bundleID)
            case .web(let url):
                return !StudyMode.isAllowed(url: url, sites: settings.studySites)
            }
        }
        // Les autres apps permises (Aperçu, Calculette…), après.
        let listed = Set(tools.compactMap { tool -> String? in
            if case .app(let id, _) = tool.kind { return id }
            return nil
        })
        for bundleID in settings.studyApps where !listed.contains(bundleID) && bundleID != "com.apple.finder"
            && StudyModeController.isInstalled(bundleID) {
            tools.append(StudyMode.Tool(id: "app:" + bundleID, title: StudyModeController.name(for: bundleID),
                                        subtitle: "App", icon: "app", kind: .app(bundleID: bundleID, scheme: "")))
        }
        return tools
    }
}

struct StudyToolIcon: View {
    let tool: StudyMode.Tool
    var size: CGFloat = 44

    var body: some View {
        switch tool.kind {
        case .app(let bundleID, _):
            if let image = StudyModeController.icon(for: bundleID) {
                Image(nsImage: image).resizable().frame(width: size, height: size)
            } else {
                symbol
            }
        case .web:
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: tool.icon)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(StudyPalette.ink)
            .frame(width: size, height: size)
            .background(StudyPalette.raisedMore, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

// MARK: - C'est fait

/// La fin d'un cours suivi : enchaîner sur la série, prolonger, terminer.
private struct LectureDoneView: View {
    let course: Course?
    @Environment(MacTimer.self) private var timer

    var body: some View {
        let start = course.flatMap { c in timer.state?.sessionStartedAt }
        let count = course.map { c in LectureMarkStore.shared.marks.filter { $0.courseID == c.id && $0.at >= (start ?? .distantFuture) }.count } ?? 0
        LectureAfterClass(course: course, markCount: count, startSeries: {
            guard let course else { return }
            let next = FocusTargets.exercises(of: course.series, for: .exercise).upNext.first
            timer.retarget(courseID: course.id, taskType: .exercise, targetID: next?.id)
            timer.extendStudy(minutes: 50)
            StudyModeController.shared.desk.pane = .exercise
        }, extend: {
            timer.extendStudy(minutes: 25)
        }, finish: {
            timer.finish()
        })
    }
}

private struct StudyDoneView: View {
    @Environment(MacTimer.self) private var timer

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(Carnet.correct)
            Text("C'est fait.")
                .font(StudyType.heroDone)
                .foregroundStyle(StudyPalette.ink)
            TimerTimeline(interval: 60) { date in
                Text("\(DateUtils.durationLabel(seconds: Int(timer.elapsed(at: date)))) de travail.")
                    .font(.title3)
                    .foregroundStyle(StudyPalette.inkSecondary)
            }
            HStack(spacing: 12) {
                Button { timer.leaveStudy() } label: { Text("Continuer sans") }
                    .buttonStyle(PaperButtonStyle(large: true))
                Button { timer.extendStudy(minutes: 25) } label: { Label("Encore 25 min", systemImage: "plus") }
                    .buttonStyle(PaperButtonStyle(large: true))
                Button { timer.finish() } label: { Label("Terminer", systemImage: "checkmark") }
                    .buttonStyle(InkButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(60)
    }
}

// MARK: - Le voile

/// Par-dessus une app fermée pendant le mode étude.
struct StudyShieldView: View {
    var screen: StudyModeController.Screen
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        ZStack {
            StudyPalette.ground.opacity(0.97).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "moon.stars.fill")
                    .font(.largeTitle.weight(.light))
                    .foregroundStyle(StudyPalette.inkSecondary)
                Text("\(screen.blockedName ?? "Cette app") attendra")
                    .font(StudyType.heroShield)
                    .foregroundStyle(StudyPalette.ink)
                StudyTimeline(interval: 60) { date in
                    Text(StudyMode.isOpenEnded(timer.state) ? "Sans heure de fin : termine quand tu as fini."
                         : "Encore \(StudyMode.remaining(timer.state, at: date).minuteLabel(roundingUp: true)).")
                        .font(.title3)
                        .foregroundStyle(StudyPalette.inkSecondary)
                }
                HStack(spacing: 14) {
                    ForEach(StudyTools.tools(for: course, settings: settings).filter(\.isApp).prefix(4)) { tool in
                        Button {
                            if case .app(let id, _) = tool.kind { StudyModeController.shared.openApp(bundleID: id) }
                        } label: {
                            HStack(spacing: 8) {
                                StudyToolIcon(tool: tool, size: 22)
                                Text(tool.title)
                            }
                        }
                        .buttonStyle(PaperButtonStyle(large: true))
                    }
                    Button {
                        StudyModeController.shared.returnToStudy()
                    } label: {
                        Label("Retour", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(InkButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
            .padding(60)
        }
        .environment(\.colorScheme, .dark)
    }
}

extension StudyMode.Tool {
    var isApp: Bool {
        if case .app = kind { return true }
        return false
    }
}

extension Notification.Name {
    /// « Ranger le bureau » : l'arrangement du moment, malgré ce qu'on a déplacé.
    static let studyTidyDesk = Notification.Name("study.tidyDesk")
    static let macOpenMainWindow = Notification.Name("mac.openMainWindow")
}
