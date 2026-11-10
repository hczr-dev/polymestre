import SwiftUI
import SwiftData

/// La page Chrono : le cadran en grand, et tout ce qui tourne autour d'une
/// session — sur quoi, la suite, le temps par exercice, le récapitulatif, le
/// mode étude.
struct MacFocusView: View {
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]
    @Query private var today: [StudySession]

    init() {
        let start = TodayTotal.startOfToday
        _today = Query(filter: #Predicate<StudySession> { $0.startedAt >= start })
    }

    private var tracked: [Course] { courses.filter(\.isTracked) }
    private var course: Course? { tracked.first { $0.id == timer.courseID } }
    private var tint: Color { MacTargets.tint(course) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                if let link = timer.state?.groupSession {
                    // Lancée ou rejointe sur l'iPhone : l'horloge est celle du groupe.
                    Label("Session ensemble · \(link.groupName)", systemImage: "person.2.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Carnet.ink)
                        .padding(.top, 12)
                }
                dial
                    .padding(.top, 12)
                TimerControls(size: 64, tint: tint)
                VStack(spacing: 16) {
                    if let recap = timer.recap, timer.phase == .idle {
                        RecapCard(recap: recap, courses: tracked).paperSheet()
                    }
                    if timer.phase == .idle {
                        setupCard
                        studyCard
                            } else {
                        if timer.isStudying { studyRunningCard } else { studyCard }
                        targetCard
                        segmentsCard
                    }
                    LiveGoalBar(sessions: today)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: 540)
            }
            .padding(Carnet.pagePadding)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Chrono")
        .animation(.smooth(duration: 0.3), value: timer.phase)
        .animation(.smooth(duration: 0.3), value: timer.recap)
    }

    // MARK: Cadran

    private var dial: some View {
        ZStack {
            LiveTimerRing(tint: tint, lineWidth: 6, graduated: true)
            VStack(spacing: 8) {
                TimerTimeline { date in
                    Kicker(statusLine(at: date), color: timer.phase == .onBreak ? MacStyle.breakTint : tint)
                }
                TimerClockText(font: MacStyle.clock(66), idle: idleClock)
                Text(headline)
                    .font(.callout)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 210)
                if timer.state?.pomodoro == true {
                    TimerTimeline(interval: 60) { date in
                        if let status = timer.pomodoroStatus(at: date) {
                            PomodoroDots(completed: status.completedBlocks, every: settings.longBreakEvery, tint: tint)
                                .padding(.top, 4)
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 300)
    }

    private var idleClock: String {
        timer.pomodoro ? TimeInterval(settings.focusMinutes * 60).clockLabel : "00:00"
    }

    private func statusLine(at date: Date) -> String {
        switch timer.phase {
        case .idle: return timer.pomodoro ? "Pomodoro" : String(localized: "Prêt")
        case .running: return timer.isStudying ? String(localized: "Mode étude") : (timer.statusLabel(at: date) ?? (course?.displayCode ?? String(localized: "En cours")))
        case .paused, .onBreak: return timer.statusLabel(at: date) ?? String(localized: "En pause")
        }
    }

    private var headline: String {
        let what = MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID)
        guard let course else { return what }
        return "\(course.displayCode) · \(what)"
    }

    // MARK: Au repos

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: String(localized: "Nouvelle session"))
            TimerSetup(courses: tracked)
        }
        .paperSheet()
    }

    /// Le mode étude, proposé à côté du chrono.
    private var studyCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.title2)
                .foregroundStyle(Carnet.ink)
                .frame(width: 40, height: 40)
                .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: Carnet.tileCorner, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mode étude").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                Text("Seulement tes outils de cours.")
                    .font(.caption)
                    .foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(timer.phase == .idle ? "Entrer…" : "Verrouiller…") {
                StudyModeController.shared.presentSetup(courseID: timer.courseID, taskType: timer.taskType, targetID: timer.targetID)
            }
            .buttonStyle(.ink)
        }
        .paperSheet()
    }

    private var studyRunningCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.fill").foregroundStyle(Carnet.ink)
            TimerTimeline(interval: 60) { date in
                Text((StudyMode.isOpenEnded(timer.state) ? String(localized: "Mode étude · sans fin") : String(localized: "Mode étude · reste \(StudyMode.remaining(timer.state, at: date).minuteLabel(roundingUp: true))")))
                    .foregroundStyle(Carnet.ink)
            }
            Spacer()
            Button("Ouvrir") { StudyModeController.shared.present() }.buttonStyle(.ink)
        }
        .paperSheet()
    }


    // MARK: En session

    @ViewBuilder
    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: String(localized: "Sur quoi"))
                Spacer()
                if let course {
                    TargetMenu(course: course, taskType: timer.taskType, selection: Binding(
                        get: { timer.targetID },
                        set: { timer.retarget(courseID: course.id, taskType: timer.taskType, targetID: $0) }))
                }
            }
            if timer.targetID != nil {
                HStack {
                    Text("Sur cet exercice").foregroundStyle(Carnet.inkSecondary)
                    Spacer()
                    TimerTimeline { date in
                        Text(timer.targetElapsed(at: date).clockLabel).monospacedDigit().foregroundStyle(Carnet.ink)
                    }
                }
                .font(.callout)
            }
            if let course, let exercise = course.allExercises.first(where: { $0.id == timer.targetID }), exercise.hasSubQuestions {
                PaperRule()
                SubQuestionChecklist(exercise: exercise, tint: tint)
            }
            if let course {
                PaperRule()
                Kicker("Ensuite")
                UpNextList(course: course)
            } else {
                Text("Pas de cours choisi.")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
                Menu("Choisir un cours") {
                    ForEach(tracked) { item in
                        Button(item.displayCode) { timer.retarget(courseID: item.id, taskType: timer.taskType) }
                    }
                }
                .fixedSize()
            }
        }
        .paperSheet()
    }

    @ViewBuilder
    private var segmentsCard: some View {
        if (timer.state?.segments?.count ?? 0) > 0 {
            TimerTimeline(interval: 5) { date in
                let parts = timer.state?.allocation(at: date) ?? []
                if parts.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: String(localized: "Cette session"))
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            let partCourse = tracked.first { $0.id == part.courseID }
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(MacTargets.tint(partCourse)).frame(width: 3, height: 14)
                                Text(MacTargets.headline(course: partCourse, taskType: part.taskType, targetID: part.targetID))
                                    .lineLimit(1)
                                    .foregroundStyle(Carnet.ink)
                                Spacer()
                                Text(part.seconds.clockLabel).monospacedDigit().foregroundStyle(Carnet.inkSecondary)
                            }
                            .font(.callout)
                        }
                    }
                    .paperSheet()
                }
            }
        }
    }
}

