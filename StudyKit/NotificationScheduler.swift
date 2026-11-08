import Foundation
import UserNotifications

/// Planificateur de notifications locales : rappels de session, échéances, récap hebdo.
final class NotificationScheduler {
    /// Le même planificateur pour l'app entière (iPhone et Mac).
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()

    // MARK: Autorisation

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: Sessions planifiées

    func scheduleSessionReminder(id: UUID, title: String, date: Date, minutesBefore: Int = 15, location: String = "") {
        let fireDate = date.addingTimeInterval(TimeInterval(-minutesBefore * 60))
        guard fireDate > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Session d'étude dans \(minutesBefore) min")
        content.body = location.isEmpty ? title : "\(title) · \(location)"
        content.sound = .default
        add(identifier: "session-\(id.uuidString)", content: content, date: fireDate)
    }

    // MARK: Évaluations

    func scheduleExamReminders(id: UUID, title: String, examDate: Date, daysBefore: [Int] = [3, 1]) {
        for days in daysBefore {
            let fireDate = DateUtils.addDays(-days, to: examDate)
            guard fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = Plural.count(days, "Échéance dans \(days) jour", "Échéance dans \(days) jours")
            content.body = title
            content.sound = .default
            add(identifier: "exam-\(id.uuidString)-\(days)", content: content, date: fireDate)
        }
    }

    // MARK: Pomodoro

    static let pomodoroIdentifier = "pomodoro-focus"
    static let pomodoroBreakIdentifier = "pomodoro-break"

    /// Annonce la fin du bloc **et** la fin de la pause qui suit, même app fermée.
    ///
    /// Les deux sont planifiées d'un coup, au démarrage du bloc : l'app peut être
    /// suspendue pendant toute la pause, et c'est justement là qu'on a besoin
    /// d'être rappelé à sa table.
    ///
    /// - Parameters:
    ///   - blockEndsAt: fin du bloc de travail ; `nil` si l'on est déjà en pause.
    ///   - breakKind: la pause qui suivra (ou qui est en cours).
    ///   - breakEndsAt: fin de cette pause.
    ///   - nextBlock: le numéro du bloc qui suivra la pause.
    func schedulePomodoro(blockEndsAt: Date?,
                          breakKind: PomodoroBreak,
                          breakMinutes: Int,
                          breakEndsAt: Date,
                          nextBlock: Int) {
        cancelPomodoro()
        if let blockEndsAt, blockEndsAt > Date() {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Bloc \(nextBlock - 1) terminé")
            content.body = breakKind == .long
                ? String(localized: "Pause longue de \(breakMinutes) min. Lève-toi, bois de l'eau.")
                : String(localized: "Pause de \(breakMinutes) min. Le chrono de travail s'est arrêté.")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            addRelative(identifier: Self.pomodoroIdentifier, content: content, date: blockEndsAt)
        }
        if breakEndsAt > Date() {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Fin de la pause")
            content.body = String(localized: "Bloc \(nextBlock) : on s'y remet quand tu es prêt·e.")
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            addRelative(identifier: Self.pomodoroBreakIdentifier, content: content, date: breakEndsAt)
        }
    }

    func cancelPomodoro() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.pomodoroIdentifier,
                                                                   Self.pomodoroBreakIdentifier])
    }

    /// À la seconde près : un rappel de fin de bloc arrondi à la minute sonnerait
    /// jusqu'à 59 s trop tôt.
    private func addRelative(identifier: String, content: UNMutableNotificationContent, date: Date) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow),
                                                        repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }

    // MARK: Rappel quotidien

    func scheduleDailyReminder(hour: Int, body: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["daily-reminder"])
        let content = UNMutableNotificationContent()
        content.title = "Polymestre"
        content.body = body
        content.sound = .default
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "daily-reminder", content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }

    // MARK: Récap hebdomadaire

    func scheduleWeeklyRecap(weekday: Int = 1, hour: Int = 19, body: String) {
        center.removePendingNotificationRequests(withIdentifiers: ["weekly-recap"])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Récap de la semaine")
        content.body = body
        content.sound = .default
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "weekly-recap", content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }

    // MARK: Annulation

    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func cancelSession(id: UUID) {
        cancel(identifier: "session-\(id.uuidString)")
    }

    func cancelExam(id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: ["exam-\(id.uuidString)-3",
                                                                   "exam-\(id.uuidString)-1"])
    }

    /// Retire les rappels **planifiés par les données** (sessions, évaluations,
    /// quotidien, hebdo) — pas le Pomodoro en cours, qui appartient au chrono.
    func cancelScheduled() async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter {
            $0 != Self.pomodoroIdentifier && $0 != Self.pomodoroBreakIdentifier
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }

    // MARK: Interne

    private func add(identifier: String, content: UNMutableNotificationContent, date: Date) {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        Task { try? await center.add(request) }
    }

    /// Replanifie tous les rappels à partir des données actuelles.
    ///
    /// Appelé quand l'app passe en arrière-plan : c'est ce qui fait qu'une
    /// évaluation ajoutée ou une session planifiée a bien son rappel, sans que
    /// l'étudiant·e ait à appuyer sur un bouton dans les réglages.
    func rescheduleAll(sessions: [PlannedSession],
                       exams: [Exam],
                       settings: SettingsStore,
                       weeklySummary: String) async {
        guard await authorizationStatus() == .authorized else { return }
        await cancelScheduled()
        for session in sessions where !session.isPast {
            scheduleSessionReminder(id: session.id,
                                    title: session.title,
                                    date: session.startsAt,
                                    location: session.location)
        }
        for exam in exams where exam.date > Date() {
            scheduleExamReminders(id: exam.id,
                                  title: "\(exam.course?.code ?? "") · \(exam.title)",
                                  examDate: exam.date)
        }
        if settings.dailyReminderEnabled {
            scheduleDailyReminder(hour: settings.dailyReminderHour,
                                  body: String(localized: "Pensez à consulter ce qui reste à faire cette semaine."))
        }
        if settings.weeklyRecapEnabled {
            scheduleWeeklyRecap(weekday: 1, hour: 19, body: weeklySummary)
        }
    }
}

import SwiftData

extension NotificationScheduler {
    /// Relit la base et replanifie tout. Point d'entrée unique pour l'app.
    @MainActor
    func rescheduleFromStore(context: ModelContext, settings: SettingsStore) async {
        let planned = (try? context.fetch(FetchDescriptor<PlannedSession>())) ?? []
        let exams = (try? context.fetch(FetchDescriptor<Exam>())) ?? []
        let weekSeconds = StudyTime.thisWeek(in: context)
        await rescheduleAll(sessions: planned,
                            exams: exams,
                            settings: settings,
                            weeklySummary: String(localized: "Cette semaine : \(DateUtils.hoursLabel(seconds: weekSeconds)) de travail."))
        // Le jour d'examen s'affiche sur l'écran verrouillé, et il se déclenche par
        // le temps, pas par un geste : le raccord se fait là où les rappels sont
        // replanifiés — c'est le seul endroit que l'app traverse de toute façon
        // quand les évaluations changent.
        #if os(iOS)
        ExamActivityController.reconcile(exams: exams)
        if settings.classStartNotice { scheduleClassStarts(context: context) }
        #endif
    }

    /// « MATH-101 commence » deux minutes avant chaque cours des trois
    /// prochains jours : un toucher ouvre le bureau du cours, en direct.
    @MainActor
    func scheduleClassStarts(context: ModelContext, now: Date = Date()) {
        let horizon = now.addingTimeInterval(3 * 86_400)
        let descriptor = FetchDescriptor<LinkedCalendarEvent>(
            predicate: #Predicate { $0.startsAt > now && $0.startsAt < horizon },
            sortBy: [SortDescriptor(\.startsAt)])
        let events = (try? context.fetch(descriptor)) ?? []
        for item in DeskSchedule.classes(from: events) where item.slot.kind == .lecture || item.slot.kind == .exerciseSession {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "\(item.slot.courseCode) commence")
            content.body = [item.kindLabel, item.location.isEmpty ? nil : item.location,
                            String(localized: "Touche pour ouvrir le cours en direct.")].compactMap { $0 }.joined(separator: " · ")
            content.categoryIdentifier = "class-start"
            content.userInfo = ["lectureCourseID": item.slot.courseID.uuidString]
            add(identifier: "class-\(item.id.uuidString)", content: content, date: item.slot.start.addingTimeInterval(-120))
        }
    }
}
