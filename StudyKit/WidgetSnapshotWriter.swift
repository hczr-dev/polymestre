import Foundation
import SwiftData
import WidgetKit

/// Publie l'état de l'app dans le conteneur partagé et recharge les widgets —
/// **le même instantané** sur l'iPhone et le Mac (`WidgetSnapshot`).
///
/// Appelé après chaque enregistrement (groupé), quand l'app change d'état et
/// quand le chrono change.
@MainActor
enum WidgetSnapshotWriter {

    static func refresh(context: ModelContext, settings: SettingsStore) {
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let tracked = courses.filter(\.isTracked)
        let snapshot = WidgetSnapshot(
            updatedAt: Date(),
            courses: tracked.map(widgetCourse),
            timer: widgetTimer(FocusTimerStore.load(), courses: courses),
            week: widgetWeek(tracked: tracked, context: context, settings: settings),
            schedule: schedule(context: context),
            deadlines: Deadline.upcoming(in: tracked, days: 60)
                .filter { $0.kind != .solutions && $0.date >= Date() }
                .prefix(3)
                .map { WidgetDeadline(id: $0.id, title: $0.title, courseCode: $0.courseCode,
                                      date: $0.date, colorHex: $0.colorHex) })

        // Rien de visible n'a changé (une note de correction, un titre de
        // session) : pas de rechargement. iOS accorde aux widgets un budget de
        // rechargements, et chacun réveille l'extension.
        if var previous = WidgetBridge.read() {
            previous.updatedAt = snapshot.updatedAt
            if previous == snapshot { return }
        }
        WidgetBridge.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        // Le contrôle « Pause du chrono » lit le même instantané.
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
        #endif
    }

    /// Rafraîchissement **groupé** : plusieurs enregistrements rapprochés (cocher
    /// trois questions de suite) ne rechargent les widgets qu'une fois.
    private static var pending: Task<Void, Never>?

    static func scheduleRefresh(context: ModelContext, settings: SettingsStore) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            refresh(context: context, settings: settings)
        }
    }

    private static func widgetCourse(_ course: Course) -> WidgetCourse {
        let week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
        let total = week.videoCount + week.exerciseCount
        let done = week.watchedCount + week.doneCount
        let theory = week.videoCount - week.watchedCount
        let exercises = week.exerciseCount - week.doneCount
        var parts: [String] = []
        if theory > 0 { parts.append("\(theory) théorie") }
        if exercises > 0 { parts.append(Plural.count(exercises, "\(exercises) exo", "\(exercises) exos")) }
        let summary = total == 0 ? "rien de prévu" : (parts.isEmpty ? "à jour" : "reste " + parts.joined(separator: " · "))
        return WidgetCourse(id: course.id.uuidString, code: course.displayCode, colorHex: course.colorHex,
                            done: done, total: total, summary: summary,
                            name: course.name,
                            theoryDone: week.watchedCount, theoryTotal: week.videoCount,
                            exercisesDone: week.doneCount, exercisesTotal: week.exerciseCount,
                            late: ProgressEngine.lateCount(for: course),
                            lateChanges: lateChanges(of: course))
    }

    /// Le retard aux instants où il changera de lui-même, sur huit jours —
    /// seulement là où il change.
    private static func lateChanges(of course: Course, now: Date = Date()) -> [WidgetCount]? {
        var last = ProgressEngine.lateCount(for: course, now: now)
        var changes: [WidgetCount] = []
        for date in LateWork.changeDates(of: course, from: now) {
            let value = ProgressEngine.lateCount(for: course, now: date)
            if value != last { changes.append(WidgetCount(from: date, value: value)) }
            last = value
        }
        return changes.isEmpty ? nil : changes
    }

    private static func widgetWeek(tracked: [Course], context: ModelContext,
                                   settings: SettingsStore) -> WidgetWeek {
        let start = DateUtils.startOfWeek(Date())
        let end = DateUtils.addDays(7, to: start)
        // La même somme qu'« Aujourd'hui » : sessions et cours suivis.
        let blocks = StudyTime.blocks(in: context, from: start, to: end)
        let workload = WorkloadEngine.aggregateWeekly(courses: tracked, hoursPerCredit: settings.hoursPerCredit,
                                                      from: start, to: end)
        let term = AcademicTerm.resolve(from: tracked.compactMap(\.term))
        return WidgetWeek(weekStart: start,
                          number: term.flatMap { $0.isRunning ? $0.currentWeek : nil },
                          totalWeeks: term?.totalWeeks,
                          actualSeconds: StudyTime.total(blocks),
                          expectedSeconds: workload.expectedSeconds,
                          days: StudyTime.days(of: blocks, weekStart: start))
    }

    /// Aujourd'hui et demain : séances de l'horaire, sessions planifiées,
    /// évaluations.
    private static func schedule(context: ModelContext) -> [WidgetEvent] {
        let start = DateUtils.startOfDay(Date())
        let end = DateUtils.addDays(2, to: start)
        let events = (try? context.fetch(FetchDescriptor<LinkedCalendarEvent>(
            predicate: #Predicate { $0.startsAt >= start && $0.startsAt < end }))) ?? []
        let planned = (try? context.fetch(FetchDescriptor<PlannedSession>(
            predicate: #Predicate { $0.startsAt >= start && $0.startsAt < end }))) ?? []
        let exams = (try? context.fetch(FetchDescriptor<Exam>(
            predicate: #Predicate { $0.date >= start && $0.date < end }))) ?? []
        var items: [WidgetEvent] = []
        // Les événements « toute la journée » (anniversaires, congés) ne sont pas
        // un horaire : ils remplissaient le widget de « 00:00 – 23:59 ».
        for event in events where event.startsAt >= start && event.startsAt < end
            && event.durationSeconds < 20 * 3600 && event.isAcademic {
            items.append(WidgetEvent(id: "event-\(event.id)", start: event.startsAt, end: event.endsAt,
                                     title: event.title,
                                     subtitle: [event.course?.displayCode, event.location.isEmpty ? nil : event.location]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     colorHex: event.course?.colorHex ?? "#6B655A"))
        }
        for session in planned where session.startsAt >= start && session.startsAt < end {
            items.append(WidgetEvent(id: "planned-\(session.id)", start: session.startsAt, end: session.endsAt,
                                     title: session.title,
                                     subtitle: [session.course?.displayCode, session.location.isEmpty ? nil : session.location]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     colorHex: session.course?.colorHex ?? "#6B655A"))
        }
        for exam in exams where exam.date >= start && exam.date < end {
            items.append(WidgetEvent(id: "exam-\(exam.id)", start: exam.date, end: nil,
                                     title: exam.title.isEmpty ? exam.kind.label : exam.title,
                                     subtitle: [exam.course?.displayCode, exam.location.isEmpty ? nil : exam.location]
                                        .compactMap { $0 }.joined(separator: " · "),
                                     colorHex: exam.course?.colorHex ?? "#6B655A"))
        }
        return items.sorted { $0.start < $1.start }
    }

    private static func widgetTimer(_ state: FocusTimerState?, courses: [Course]) -> WidgetTimer? {
        guard let state, state.isRunning || state.isRestorable() else { return nil }
        let course = courses.first { $0.id == state.courseID }
        let label = state.contextLabel.isEmpty
            ? [course?.displayCode ?? "Session libre", state.taskType.label].joined(separator: " · ")
            : state.contextLabel
        let elapsed = state.elapsed()
        return WidgetTimer(label: label, colorHex: course?.colorHex ?? "#5247E6",
                           effectiveStart: Date().addingTimeInterval(-elapsed),
                           isRunning: state.isRunning, elapsedWhenPaused: elapsed,
                           breakEndsAt: state.currentBreak?.endsAt,
                           breakLabel: state.currentBreak?.kind.label)
    }
}
