import SwiftUI
import SwiftData
import Charts

/// La journée : par quoi commencer (un clic lance le chrono, ou le mode
/// étude), l'horaire du jour, ce qu'il y a à faire, les échéances, le temps du
/// jour et de la semaine, chaque cours.
///
/// Cette page se recalculait **chaque seconde** pendant une session (elle lisait
/// l'heure du chrono) : planning, requête de toutes les sessions, graphique.
/// Elle ne relit plus que les données ; les secondes vivent dans de petites
/// vues à part (`MacClock.swift`).
struct MacTodayView: View {
    var open: (UUID, UUID?) -> Void
    var goFocus: () -> Void

    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]
    /// Huit jours suffisent (aujourd'hui, la semaine, le graphique de 7 jours).
    @Query private var sessions: [StudySession]
    @Query private var events: [LinkedCalendarEvent]
    @Query(filter: #Predicate<LinkedTask> { !$0.isDone }, sort: \LinkedTask.dueDate) private var openTasks: [LinkedTask]
    @Environment(MacStore.self) private var store

    init(open: @escaping (UUID, UUID?) -> Void, goFocus: @escaping () -> Void) {
        self.open = open
        self.goFocus = goFocus
        let since = DateUtils.addDays(-8, to: DateUtils.startOfDay(Date()))
        _sessions = Query(filter: #Predicate<StudySession> { $0.startedAt >= since },
                          sort: \StudySession.startedAt, order: .reverse)
        let dayStart = DateUtils.startOfDay(Date())
        let dayEnd = DateUtils.addDays(1, to: dayStart)
        _events = Query(filter: #Predicate<LinkedCalendarEvent> { $0.startsAt >= dayStart && $0.startsAt < dayEnd },
                        sort: \LinkedCalendarEvent.startsAt)
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        // Les séances manquées restent, estompées : on peut se raviser d'un clic.
        let todayEvents = events.filter { $0.isAcademic }
        let deadlines = Deadline.upcoming(in: tracked, days: 14).filter { $0.date >= Date() }
        let summaries = tracked.map { WeekCourseSummary(course: $0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                news
                if timer.phase != .idle { RunningNowCard(open: goFocus) }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 22) {
                        weekCourses(summaries)
                        taskList
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 22) {
                        if !todayEvents.isEmpty { schedule(todayEvents) }
                        if !deadlines.isEmpty { deadlineList(deadlines) }
                        todaySessions
                        weekChart
                    }
                    .frame(width: 330)
                }
            }
            .padding(Carnet.pagePadding)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Aujourd'hui")
    }

    /// « Nouveau dans tes cours » — ce que la relecture automatique a ajouté
    /// (ici ou sur l'iPhone), jusqu'à ce qu'on le ferme (ici ou là-bas).
    @ViewBuilder
    private var news: some View {
        let news = SettingsStore.mergedNews("", adding: store.preferences.contentRefreshNews)
        if !news.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Carnet.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nouveau dans tes cours").fontWeight(.semibold).foregroundStyle(Carnet.ink)
                    Text(news).font(.callout).foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                Button { store.preferences.contentRefreshNews = "" } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Carnet.inkSecondary)
                    .help("Masquer")
            }
            .paperSheet(padding: 14)
        }
    }

    // MARK: En-tête

    /// « Dimanche 4 octobre » : la majuscule au premier mot seulement.
    private static var dayTitle: String {
        let label = DateUtils.fullDayLabel(Date())
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Le semestre des cours suivis, lu comme sur l'iPhone (`AcademicTerm.resolve`) :
    /// le premier cours de la liste pouvait appartenir à un autre semestre.
    private var weekTitle: String {
        if let term = AcademicTerm.resolve(from: tracked.compactMap(\.term)), term.isRunning {
            return "Semaine \(term.currentWeek)"
        }
        return "Cette semaine"
    }

    /// Le temps de la semaine, compté comme partout (`StudyTime`).
    private var weekSeconds: Int {
        _ = sessions.count
        return StudyTime.thisWeek(in: context)
    }

    private var header: some View {
        let goal = settings.dailyGoalSeconds(in: context)
        let week = weekSeconds
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Kicker(weekTitle)
                Text(Self.dayTitle).font(Carnet.serif(34)).foregroundStyle(Carnet.ink)
            }
            Spacer()
            TodayStudyText(savedSeconds: TodayTotal.saved(in: context)) { today in
                AnyView(
                    HStack(spacing: 14) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(DateUtils.hoursLabel(seconds: today))
                                .font(Carnet.clock(28))
                                .foregroundStyle(Carnet.ink)
                            Text("sur \(DateUtils.hoursLabel(seconds: goal)) · \(DateUtils.hoursLabel(seconds: week + (today - TodayTotal.saved(in: context)))) cette semaine")
                                .font(.caption)
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                        ZStack {
                            TimerRing(progress: Double(today) / Double(max(goal, 1)),
                                      tint: today >= goal ? Carnet.correct : MacStyle.goalTint, lineWidth: 5)
                            if today >= goal {
                                Image(systemName: "checkmark").font(.headline).foregroundStyle(Carnet.correct)
                            }
                        }
                        .frame(width: 50, height: 50)
                    }
                )
            }
            .help("Objectif du jour")
        }
    }

    // MARK: Les cours de la semaine

    private func weekCourses(_ summaries: [WeekCourseSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: weekTitle)
            if summaries.isEmpty {
                Text("Aucun cours suivi. Ajoute-en un avec + dans la barre latérale.")
                    .foregroundStyle(Carnet.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperSheet(padding: 14)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                ForEach(summaries, id: \.course.id) { summary in
                    // Le cours visé lui-même ouvre « À rattraper » (`MacCourseView`).
                    Button { open(summary.course.id, nil) } label: {
                        WeekCourseCard(summary: summary, openLate: { open(summary.course.id, summary.course.id) })
                    }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Tâches

    /// Les tâches ouvertes des fournisseurs reliés sur l'iPhone (Rappels,
    /// Todoist…), dues dans la semaine ou en retard. Elles se cochent sur
    /// l'iPhone, qui parle au fournisseur.
    @ViewBuilder
    private var taskList: some View {
        let soon = DateUtils.addDays(7, to: DateUtils.startOfDay(Date()))
        let due = openTasks.filter { task in task.dueDate.map { $0 < soon } ?? false }.prefix(8)
        if !due.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Tâches")
                VStack(spacing: 0) {
                    ForEach(Array(due)) { task in
                        HStack(spacing: 10) {
                            Image(systemName: "circle").foregroundStyle(Carnet.inkTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).foregroundStyle(Carnet.ink).lineLimit(1)
                                Text([task.course?.displayCode, task.dueDate.map(DateUtils.countdownLabel(to:)), task.provider.label]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(task.isOverdue ? Carnet.wrong : Carnet.inkSecondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        if task.id != due.last?.id { PaperRule(inset: 34) }
                    }
                }
                .paperSheet(padding: 6)
            }
        }
    }

    // MARK: Colonne de droite

    private func schedule(_ events: [LinkedCalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Horaire du jour")
            if let live = DeskSchedule.current(in: DeskSchedule.classes(from: events)) {
                FollowClassButton(klass: live)
            }
            VStack(spacing: 0) {
                ForEach(events) { event in
                    EventLine(event: event)
                    if event.id != events.last?.id { PaperRule(inset: 54) }
                }
            }
            .paperSheet(padding: 6)
        }
    }

    private func deadlineList(_ items: [Deadline]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Échéances", trailing: "14 jours")
            VStack(spacing: 0) {
                ForEach(items.prefix(6)) { item in
                    Button { open(item.courseID, item.targetID) } label: { DeadlineLine(item: item) }
                        .buttonStyle(.plain)
                    if item.id != items.prefix(6).last?.id { PaperRule(inset: 54) }
                }
            }
            .paperSheet(padding: 6)
        }
    }

    @ViewBuilder
    private var todaySessions: some View {
        let today = sessions.filter { Calendar.current.isDateInToday($0.startedAt) }
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Sessions du jour",
                         trailing: today.isEmpty ? nil : DateUtils.hoursLabel(seconds: today.reduce(0) { $0 + $1.durationSeconds }))
            VStack(spacing: 0) {
                if today.isEmpty {
                    Text(timer.phase == .idle ? "Pas encore de session." : "Session en cours.")
                        .font(.callout)
                        .foregroundStyle(Carnet.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                ForEach(today) { session in
                    SessionRow(session: session, compact: true)
                        .padding(.horizontal, 10)
                    if session.id != today.last?.id { PaperRule() }
                }
            }
            .paperSheet(padding: 6)
        }
    }

    private var weekChart: some View {
        // Compté comme partout : sessions et cours suivis (`StudyTime`).
        let _ = sessions.count
        let first = DateUtils.addDays(-6, to: DateUtils.startOfDay(Date()))
        let blocks = StudyTime.blocks(in: context, from: first, to: DateUtils.addDays(7, to: first))
        let days = (0..<7).map { offset -> (day: Date, seconds: Int) in
            let day = DateUtils.addDays(offset, to: first)
            return (day, blocks.filter { DateUtils.startOfDay($0.start) == day }.reduce(0) { $0 + $1.seconds })
        }
        let goalHours = Double(settings.dailyGoalSeconds(in: context)) / 3600
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "7 derniers jours")
            if days.allSatisfy({ $0.seconds == 0 }) {
                Text("Pas encore de temps compté cette semaine.")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperSheet(padding: 14)
            } else {
            Chart {
                ForEach(days, id: \.day) { day in
                    BarMark(x: .value("Jour", day.day, unit: .day), y: .value("Heures", Double(day.seconds) / 3600))
                        .foregroundStyle(Double(day.seconds) / 3600 >= goalHours ? Carnet.correct : Carnet.ink.opacity(0.75))
                        .cornerRadius(3)
                }
                RuleMark(y: .value("Objectif", goalHours))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(MacStyle.goalTint)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Carnet.rule)
                    AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h)) h") } }
                }
            }
            .frame(height: 120)
            .paperSheet(padding: 14)
            }
        }
    }
}

/// La session en cours, en grand, sur Aujourd'hui.
private struct RunningNowCard: View {
    @Environment(MacTimer.self) private var timer
    @Query(sort: \Course.code) private var courses: [Course]
    var open: () -> Void

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        let tint = MacTargets.tint(course)
        HStack(spacing: 18) {
            LiveTimerRing(tint: tint, lineWidth: 5)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                TimerTimeline { date in
                    Kicker(timer.isStudying ? "Mode étude" : (timer.statusLabel(at: date) ?? "En cours"), color: tint)
                }
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(24))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(1)
                Text(course?.name ?? "Session libre").foregroundStyle(Carnet.inkSecondary).lineLimit(1)
            }
            Spacer()
            TimerClockText(font: MacStyle.clock(38))
            TimerControls(size: 40, tint: tint)
            if timer.isStudying {
                Button("Mode étude") { StudyModeController.shared.present() }.buttonStyle(.paper)
            } else {
                Button("Ouvrir", action: open).buttonStyle(.paper)
            }
        }
        .paperSheet(padding: 20, highlighted: tint.opacity(0.5))
    }
}

/// Un cours dans la semaine : théorie, exercices et corrections de la
/// semaine, le retard (corrections comprises) — comme sur l'iPhone.
private struct WeekCourseCard: View {
    let summary: WeekCourseSummary
    var openLate: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        let course = summary.course
        let week = summary.week
        let tint = Carnet.tint(course.colorHex)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CourseTag(code: course.displayCode, tint: tint)
                Spacer()
                if summary.late > 0 {
                    Button(action: openLate) {
                        HStack(spacing: 2) {
                            Text("\(summary.late) en retard")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Carnet.wrong)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ce qui est à rattraper")
                } else {
                    Label("À jour", systemImage: "checkmark").font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
            }
            Text(course.name).font(Carnet.serif(18)).foregroundStyle(Carnet.ink).lineLimit(2, reservesSpace: true)
            HStack(spacing: 14) {
                meter("Théorie", week.watchedCount, week.videoCount, tint)
                meter("Exercices", week.doneCount, week.exerciseCount, tint)
                if week.doneCount > 0 { meter("Corrigés", week.correctedCount, week.doneCount, tint) }
            }
            if !summary.corrections.isEmpty {
                // Hors retard : celles des séries échues sont dans « N en retard ».
                Text("\(summary.corrections.toCorrect) à corriger cette semaine")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
            }
        }
        .paperSheet(padding: 16, highlighted: hovering ? tint.opacity(0.6) : nil)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func meter(_ title: String, _ done: Int, _ total: Int, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(ui: title).font(.caption).foregroundStyle(Carnet.inkSecondary)
                Spacer()
                Text("\(done)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(Carnet.ink)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Carnet.rule)
                    Capsule().fill(tint).frame(width: proxy.size.width * min(1, Double(done) / Double(max(total, 1))))
                }
            }
            .frame(height: 4)
        }
    }
}

struct SessionRow: View {
    let session: StudySession
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.taskType.icon)
                .foregroundStyle(Carnet.tint(session.course))
                .frame(width: 20)
            Text(session.course?.displayCode ?? "Sans cours").fontWeight(.medium).foregroundStyle(Carnet.ink)
            if !compact { Text(session.taskType.label).foregroundStyle(Carnet.inkSecondary) }
            if let target = session.targetLabel {
                Text(target).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
            }
            Spacer()
            Text(DateUtils.time.string(from: session.startedAt)).foregroundStyle(Carnet.inkSecondary).monospacedDigit()
            Text(session.durationSeconds < 60 ? "< 1 min" : session.durationLabel)
                .monospacedDigit()
                .foregroundStyle(session.durationSeconds < 60 ? Carnet.inkSecondary : Carnet.ink)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }
}

/// Le cours de maintenant : « Suivre le cours » ouvre le mode étude dessus,
/// bureau « En cours », jusqu'à la fin du créneau (Aujourd'hui, la barre des
/// menus).
struct FollowClassButton: View {
    let klass: ScheduledClass
    var compact = false
    @Environment(MacTimer.self) private var timer

    private var following: Bool {
        timer.isStudying && timer.courseID == klass.slot.courseID && timer.taskType == .lecture
    }

    var body: some View {
        Button {
            if following {
                StudyModeController.shared.present()
            } else {
                StudyModeController.shared.presentSetup(courseID: klass.slot.courseID, taskType: .lecture)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: DeskMoment.lecture.icon).font(compact ? .callout : .title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(following ? "Revenir au cours" : "Suivre le cours · \(klass.slot.courseCode)")
                        .font(compact ? .callout.weight(.semibold) : .headline)
                    Text([klass.kindLabel, klass.location.isEmpty ? nil : klass.location,
                          "jusqu'à \(DateUtils.time.string(from: klass.slot.end))"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).opacity(0.85).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right").font(.caption.weight(.bold))
            }
            .padding(compact ? 10 : 14)
            .foregroundStyle(Carnet.ground)
            .background(Carnet.tint(klass.colorHex), in: RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Le mode étude sur ce cours : la semaine sur Moodle, l'horloge du cours, les repères")
    }
}
