import SwiftUI
import SwiftData

/// L'horloge de la barre des menus : elle seule bat, et seulement ce qu'il faut.
///
/// L'étiquette d'une `MenuBarExtra` ne suit pas un `TimelineView` de façon
/// fiable : elle relit l'état observé. Plutôt que de faire battre tout le chrono
/// (et avec lui la fenêtre), ce petit objet avance l'heure pour la seule
/// étiquette — chaque seconde si l'on veut les secondes, sinon chaque minute,
/// calée sur la minute de la session. Rien quand le chrono est arrêté.
@MainActor
@Observable
final class MenuBarClock {
    private(set) var now = Date()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored weak var timer: MacTimer?
    @ObservationIgnored weak var settings: MacSettings?

    func update() {
        ticker?.invalidate()
        ticker = nil
        now = Date()
        guard let timer, let settings, settings.showTimeInMenuBar || timer.phase == .onBreak,
              timer.phase == .running || timer.phase == .onBreak else { return }
        let step: TimeInterval = settings.menuBarSeconds ? 1 : 60
        let anchor = FocusTimerState.tickAnchor(timer.state)
        let offset = Date().timeIntervalSince(anchor).truncatingRemainder(dividingBy: step)
        let first = Date().addingTimeInterval(offset >= 0 ? step - offset : -offset)
        let ticker = Timer(fire: first, interval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        ticker.tolerance = step >= 60 ? 2 : 0.05
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }
}

/// Dans la barre des menus : un petit anneau qui se remplit avec le bloc (ou
/// se vide avec la pause), et le temps à côté.
struct MenuBarLabel: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(MenuBarClock.self) private var clock
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            // Toujours là, même fenêtre fermée : c'est d'ici que le mode étude
            // rouvre la fenêtre des cours.
            .onReceive(NotificationCenter.default.publisher(for: .macOpenMainWindow)) { _ in
                MacWindows.openMain(openWindow)
            }
    }

    @ViewBuilder
    private var label: some View {
        if timer.phase == .idle {
            Image(systemName: "timer")
        } else {
            let now = clock.now
            HStack(spacing: 4) {
                Image(nsImage: MenuBarRing.image(progress: timer.ringProgress(at: now), phase: timer.phase,
                                                 studying: timer.isStudying))
                if settings.showTimeInMenuBar {
                    Text(label(at: now)).monospacedDigit()
                }
            }
        }
    }

    private func label(at now: Date) -> String {
        let time = timer.displayTime(at: now)
        if settings.menuBarSeconds { return time.clockLabel }
        return time.minuteLabel(roundingUp: timer.countsDown)
    }
}

extension TimeInterval {
    /// « 24 min », « 1 h 05 » : le temps à la minute, pour la barre des menus.
    func minuteLabel(roundingUp: Bool) -> String {
        let minutes = Int((self / 60).rounded(roundingUp ? .up : .down))
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }
}

/// L'anneau de la barre des menus, dessiné en image « modèle » : le système
/// le teinte comme les autres icônes (clair, sombre, contraste accru).
enum MenuBarRing {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(progress: Double, phase: MacTimer.Phase, studying: Bool = false) -> NSImage {
        // 48 pas suffisent à l'œil, et l'image ne change qu'à chaque pas.
        let step = Int((max(0, min(1, progress)) * 48).rounded())
        let key = "\(step)-\(phase)-\(studying)"
        if let cached = cache[key] { return cached }
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 1.6
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let fraction = phase == .onBreak ? 1 - Double(step) / 48 : Double(step) / 48
            if fraction > 0 {
                let arc = NSBezierPath()
                let center = NSPoint(x: rect.midX, y: rect.midY)
                arc.appendArc(withCenter: center, radius: inset.width / 2, startAngle: 90,
                              endAngle: 90 - 360 * fraction, clockwise: true)
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            NSColor.black.setFill()
            if phase == .paused {
                NSBezierPath(rect: NSRect(x: rect.midX - 2.2, y: rect.midY - 2.5, width: 1.6, height: 5)).fill()
                NSBezierPath(rect: NSRect(x: rect.midX + 0.6, y: rect.midY - 2.5, width: 1.6, height: 5)).fill()
            } else if phase == .onBreak {
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.5, y: rect.midY - 1.5, width: 3, height: 3)).fill()
            } else if studying {
                // Le mode étude : un cadenas minuscule, un rond plein.
                NSBezierPath(ovalIn: NSRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        if cache.count > 300 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Le panneau de la barre des menus : **le carnet d'un coup d'œil**.
///
/// La date et le temps du jour, ce qui se passe à l'horaire (le cours en
/// cours, le suivant), le chrono — un rang : le cours, le travail, la cible,
/// « Démarrer » —, les échéances qui arrivent et les gestes de tous les jours
/// (note rapide, agenda, bilan). Pendant une session : le cadran et ses gestes.
/// Rien n'y est proposé « à faire » : seulement ce qui est.
struct MenuBarTimerView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    /// Le jour seulement : le panneau n'a pas à relire tout l'historique.
    @Query private var today: [StudySession]
    @Query private var events: [LinkedCalendarEvent]
    /// Pourquoi le cours est déjà choisi (« Séance d'exercices de MATH-101 en cours »).
    @State private var contextReason: String?

    init() {
        let start = TodayTotal.startOfToday
        let end = DateUtils.addDays(1, to: start)
        _today = Query(filter: #Predicate<StudySession> { $0.startedAt >= start })
        _events = Query(filter: #Predicate<LinkedCalendarEvent> { $0.startsAt >= start && $0.startsAt < end },
                        sort: \LinkedCalendarEvent.startsAt)
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var course: Course? { tracked.first { $0.id == timer.courseID } }
    private var tint: Color { timer.phase == .onBreak ? MacStyle.breakTint : MacTargets.tint(course) }
    private var schedule: [LinkedCalendarEvent] { events.filter { $0.isAcademic && !$0.isSkipped } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            PaperRule()
            Group {
                if timer.phase == .idle {
                    idle
                } else {
                    running
                }
            }
            .padding(16)
            if timer.phase == .idle {
                hub
            }
            if let update = MacUpdater.shared.available {
                PaperRule()
                Button { MacUpdater.shared.download() } label: {
                    Label("Polymestre \(update.version) est disponible — télécharger", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            PaperRule()
            footer
        }
        .frame(width: 340)
        .background(Carnet.ground)
        .tint(Carnet.ink)
        .animation(.smooth(duration: 0.25), value: timer.phase)
        .onAppear(perform: preselectFromSchedule)
    }

    // MARK: En-tête

    /// La date, la semaine, et le temps du jour sur son objectif.
    private var header: some View {
        let goal = settings.dailyGoalSeconds(in: context)
        let _ = today.count
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DateUtils.fullDayLabel(Date()))
                    .font(Carnet.serif(.headline))
                    .foregroundStyle(Carnet.ink)
                if let term = AcademicTerm.resolve(from: tracked.compactMap(\.term)), term.isRunning {
                    Text("Semaine \(term.currentWeek) sur \(term.totalWeeks)")
                        .font(.caption)
                        .foregroundStyle(Carnet.inkSecondary)
                }
            }
            Spacer()
            TodayStudyText(savedSeconds: TodayTotal.saved(in: context)) { seconds in
                AnyView(
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(DateUtils.hoursLabel(seconds: seconds)) / \(DateUtils.hoursLabel(seconds: goal))")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(seconds >= goal ? Carnet.correct : Carnet.inkSecondary)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Carnet.rule)
                                Capsule().fill(seconds >= goal ? Carnet.correct : MacStyle.goalTint)
                                    .frame(width: proxy.size.width * min(1, Double(seconds) / Double(max(goal, 1))))
                            }
                        }
                        .frame(width: 96, height: 4)
                    }
                )
            }
            .help("Aujourd'hui, sur le septième de l'objectif de la semaine")
        }
    }

    // MARK: En session

    private var running: some View {
        VStack(spacing: 14) {
            if let link = timer.state?.groupSession {
                Label("Session ensemble · \(link.groupName)", systemImage: "person.2.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Carnet.inkSecondary)
            }
            ZStack {
                LiveTimerRing(tint: tint, lineWidth: 6, graduated: true)
                VStack(spacing: 3) {
                    TimerTimeline { date in
                        Text(timer.statusLabel(at: date) ?? course?.displayCode ?? "En cours")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .tracking(1)
                            .foregroundStyle(tint)
                    }
                    TimerClockText(font: MacStyle.clock(32))
                    if timer.state?.pomodoro == true {
                        TimerTimeline(interval: 60) { date in
                            if let status = timer.pomodoroStatus(at: date) {
                                PomodoroDots(completed: status.completedBlocks, every: settings.longBreakEvery, tint: tint)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
            }
            .frame(width: 150, height: 150)
            .frame(maxWidth: .infinity)

            VStack(spacing: 2) {
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(.headline))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text(course?.name ?? "Sans cours")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            TimerControls(size: 46, tint: tint)

            if timer.isStudying {
                Button {
                    StudyModeController.shared.present()
                } label: {
                    Label("Mode étude", systemImage: "moon.stars.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle())
            }

            if let course, timer.phase != .onBreak {
                VStack(alignment: .leading, spacing: 4) {
                    Kicker("Passer à").padding(.horizontal, 8)
                    UpNextList(course: course, limit: 3)
                }
            }
        }
    }

    // MARK: Au repos

    @ViewBuilder
    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recap = timer.recap {
                RecapCard(recap: recap, courses: tracked)
                PaperRule()
            }
            setupRow
            if let contextReason, timer.courseID != nil {
                Label(contextReason, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
            }
            HStack(spacing: 8) {
                Button {
                    timer.start()
                } label: {
                    Label("Démarrer", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle(tint: course.map { _ in tint }, large: true))
                .keyboardShortcut(.defaultAction)
                pomodoroToggle
                Button {
                    StudyModeController.shared.presentSetup(courseID: timer.courseID)
                } label: {
                    Image(systemName: "moon.stars")
                }
                .buttonStyle(PaperButtonStyle(large: true))
                .help("Mode étude")
            }
        }
    }

    /// Le cours, le travail et la cible, sur **un** rang de menus.
    private var setupRow: some View {
        TimerSetupRow(courses: tracked) { contextReason = nil }
    }

    /// Pomodoro ou chrono libre, en une pastille : « 25 » quand il est actif.
    private var pomodoroToggle: some View {
        Button {
            timer.pomodoro.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: timer.pomodoro ? "timer" : "stopwatch")
                if timer.pomodoro {
                    Text("\(settings.focusMinutes)").font(.callout.monospacedDigit().weight(.semibold))
                }
            }
        }
        .buttonStyle(PaperButtonStyle(large: true))
        .help(timer.pomodoro ? "Pomodoro \(settings.focusMinutes)/\(settings.shortBreakMinutes) min — cliquer pour un chrono libre"
                              : "Chrono libre — cliquer pour un Pomodoro")
    }

    /// Le cours de l'horaire choisi d'avance : la séance d'exercices en cours,
    /// celle qui commence bientôt, ou le cours qui vient de finir.
    private func preselectFromSchedule() {
        guard timer.phase == .idle, timer.courseID == nil else { return }
        let ids = Set(tracked.map(\.id))
        let slots = schedule.compactMap { event -> FocusContext.Slot? in
            guard let course = event.course, ids.contains(course.id) else { return nil }
            return FocusContext.Slot(courseID: course.id, courseCode: course.displayCode, kind: event.kind,
                                     start: event.startsAt, end: event.endsAt)
        }
        guard let suggestion = FocusContext.suggestion(now: Date(), slots: slots) else { return }
        timer.courseID = suggestion.courseID
        timer.taskType = suggestion.taskType
        contextReason = suggestion.reason
    }

    // MARK: Le carnet

    /// Ce qui est, sans rien proposer : l'horaire du moment, les échéances,
    /// et les gestes de tous les jours.
    private var hub: some View {
        VStack(alignment: .leading, spacing: 12) {
            nowLine
            deadlines
            ClaudeMeasureMenuLine()
            HStack(spacing: 8) {
                HubAction(title: "Note", icon: "note.text.badge.plus") {
                    MacWindows.openMain(openWindow)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        NotificationCenter.default.post(name: .macQuickNote, object: nil)
                    }
                }
                .help("Note rapide (⇧⌘N)")
                HubAction(title: "Agenda", icon: "calendar") { go("agenda") }
                HubAction(title: String(localized: "Bilan"), icon: "chart.bar.xaxis") { go("stats") }
                if let course {
                    HubAction(title: course.displayCode, icon: "book.closed") { go("code:" + course.displayCode) }
                        .help("Ouvrir \(course.name)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    /// Le cours en cours à l'horaire, sinon le prochain de la journée.
    @ViewBuilder
    private var nowLine: some View {
        let now = Date()
        if let live = DeskSchedule.current(in: DeskSchedule.classes(from: schedule), at: now) {
            FollowClassButton(klass: live, compact: true)
        } else if let current = schedule.first(where: { $0.startsAt <= now && now < $0.endsAt }) {
            scheduleLine(current, prefix: String(localized: "Maintenant"), until: true)
        } else if let next = schedule.first(where: { $0.startsAt > now }) {
            scheduleLine(next, prefix: String(localized: "À \(DateUtils.time.string(from: next.startsAt))"), until: false)
        }
    }

    private func scheduleLine(_ event: LinkedCalendarEvent, prefix: String, until: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Carnet.tint(event.course)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(prefix + (until ? " · jusqu'à \(DateUtils.time.string(from: event.endsAt))" : ""))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Carnet.inkSecondary)
                Text([event.course?.displayCode ?? event.title, event.kind.label, event.location.isEmpty ? nil : event.location]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var deadlines: some View {
        let items = Deadline.upcoming(in: tracked, days: 7).filter { $0.date >= Date() }.prefix(3)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Kicker("Échéances")
                ForEach(Array(items)) { item in
                    Button { go("code:" + item.courseCode) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .foregroundStyle(item.kind == .exam ? Carnet.wrong : Carnet.tint(item.colorHex))
                                .frame(width: 16)
                            Text(item.title).lineLimit(1).foregroundStyle(Carnet.ink)
                            Text(item.courseCode).foregroundStyle(Carnet.inkSecondary)
                            Spacer(minLength: 4)
                            Text(DateUtils.countdownLabel(to: item.date))
                                .foregroundStyle(item.kind == .exam ? Carnet.wrong : Carnet.inkSecondary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func go(_ page: String) {
        MacWindows.openMain(openWindow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .macGoTo, object: page)
        }
    }

    // MARK: Pied

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                MacWindows.openMain(openWindow)
            } label: {
                Label("Ouvrir Polymestre", systemImage: "macwindow")
            }
            .labelStyle(.titleAndIcon)
            Spacer()
            Button {
                settings.floatingTimer.toggle()
                MiniTimerPanel.shared.update()
            } label: {
                Image(systemName: settings.floatingTimer ? "pip.fill" : "pip")
            }
            .help(settings.floatingTimer ? "Masquer le chrono" : "Chrono flottant")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Réglages (⌘,)")
            Menu {
                if AppDistribution.feedbackAddress != nil {
                    Button("Signaler un problème…") { MacFeedback.send() }
                }
                Button("Quitter") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .foregroundStyle(Carnet.inkSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Un geste du carnet : une icône, un mot.
private struct HubAction: View {
    let title: String
    let icon: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.caption2.weight(.medium)).lineLimit(1)
            }
            .foregroundStyle(Carnet.ink)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(hovering ? Carnet.sheetRaised : Carnet.sheet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Ouvrir la fenêtre principale depuis n'importe où, l'app au premier plan
/// (et dans le Dock tant que la fenêtre est ouverte).
enum MacWindows {
    @MainActor
    static func openMain(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
