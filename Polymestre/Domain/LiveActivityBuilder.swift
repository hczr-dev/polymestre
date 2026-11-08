import Foundation

/// L'état de la Live Activity du chrono, construit **sans ActivityKit**.
///
/// L'iPhone s'en sert pour son îlot ; le Mac aussi, pour le pousser à l'iPhone
/// verrouillé par APNs (via le relais) : un « play » sur le Mac se voit sur
/// l'écran verrouillé sans que l'app de l'iPhone ait à se réveiller.
enum LiveActivityBuilder {

    /// Les attributs figés de l'activité (mêmes noms de champs que
    /// `StudyActivityAttributes`, pour qu'APNs puisse en démarrer une).
    struct Attributes: Codable, Equatable {
        var courseCode: String
        var courseName: String
        var taskLabel: String
        var taskIcon: String
        var target: String?
    }

    static func attributes(for state: FocusTimerState, course: Course?) -> Attributes {
        Attributes(courseCode: course?.displayCode ?? String(localized: "Sans cours"),
                   courseName: course?.name ?? String(localized: "Session libre"),
                   taskLabel: state.taskType.label,
                   taskIcon: state.taskType.icon,
                   target: targetLabel(state, course: course))
    }

    /// « 3.4 » : le numéro seul — « Exercices · 3.4 » se lit, « Exercices ·
    /// Exercice 3.4 » bégaie, et l'îlot n'a pas la place de bégayer.
    static func targetLabel(_ state: FocusTimerState, course: Course?) -> String? {
        guard let course, let targetID = state.targetID else { return nil }
        if let exercise = course.allExercises.first(where: { $0.id == targetID }) {
            return exercise.exerciseNumber
        }
        if let item = course.theoryItems.first(where: { $0.id == targetID }) {
            return item.number
        }
        return nil
    }

    static func exercise(for state: FocusTimerState, course: Course?) -> Exercise? {
        guard let course, let targetID = state.targetID else { return nil }
        return course.allExercises.first { $0.id == targetID }
    }

    /// Construit l'état à publier depuis le chrono et sa cible.
    static func state(timer: FocusTimerState,
                      settings: PomodoroSettings,
                      exercise: Exercise?,
                      course: Course? = nil,
                      now: Date = Date()) -> ActivityTimerState {
        let elapsed = timer.elapsed(at: now)
        let settings = timer.cycle(or: settings)
        var block: ActivityPomodoro?
        if timer.pomodoro {
            if let pause = timer.currentBreak {
                let completed = Int((timer.cycleAccumulated / settings.blockDuration).rounded())
                block = .onBreak(kind: pause.kind.rawValue,
                                 startedAt: pause.startedAt,
                                 endsAt: pause.endsAt,
                                 completedBlocks: completed)
            } else {
                let status = PomodoroEngine.status(elapsed: elapsed, focusMinutes: settings.focusMinutes, origin: timer.cycleOriginSeconds)
                block = ActivityPomodoro.make(blockNumber: status.blockNumber,
                                              elapsedInBlock: status.elapsedInBlock,
                                              remaining: status.remaining,
                                              completedBlocks: status.completedBlocks,
                                              running: timer.isRunning,
                                              now: now)
            }
        }
        // `hasSubQuestions` et non `leafSubQuestions.isEmpty` : un exercice sans
        // sous-questions ne doit pas publier « 0/0 », qui allumerait le bouton
        // « question suivante » sur une cible qui n'en a aucune.
        let leaves = exercise?.hasSubQuestions == true ? exercise?.leafSubQuestions : nil
        var state = ActivityTimerState.make(elapsed: elapsed,
                                            running: timer.isRunning,
                                            questionsDone: leaves.map { $0.filter(\.isDone).count },
                                            questionsTotal: leaves.map(\.count),
                                            pomodoro: block,
                                            title: course?.displayCode ?? String(localized: "Session libre"),
                                            subtitle: ActivityTimerState.subtitle(task: timer.taskType.label,
                                                                                  target: targetLabel(timer, course: course)),
                                            now: now)
        state.colorHex = course?.colorHex
        state.sessionStartedAt = timer.sessionStartedAt
        return state
    }

    /// L'activité montre-t-elle une session **plus récente** que celle d'ici ?
    /// Alors l'état d'ici est périmé : on n'y touche pas.
    static func isNewer(_ shown: ActivityTimerState, than session: Date?) -> Bool {
        guard let shown = shown.sessionStartedAt, let session else { return false }
        return shown.timeIntervalSince(session) > 1
    }

    /// Combien de temps une pause reste « fraîche » sur l'écran verrouillé.
    static let pausedFreshness: TimeInterval = 2 * 3600

    /// Quand l'activité devient périmée : la fin d'une pause Pomodoro (seule
    /// l'app sait la suite), deux heures pour un chrono arrêté, jamais s'il tourne.
    static func staleDate(for state: ActivityTimerState, now: Date = Date()) -> Date? {
        if let breakEnd = state.pomodoro?.breakEndsAt { return breakEnd }
        return state.isRunning ? nil : now.addingTimeInterval(pausedFreshness)
    }

    /// Ce que le relais pousse à l'îlot de l'iPhone (JSON) : `update` avec
    /// l'état et les attributs (pour démarrer une activité si aucune ne vit),
    /// ou `end` quand la session est fermée.
    static func push(event: String, state: ActivityTimerState, attributes: Attributes?, now: Date = Date()) -> Data? {
        let encoder = JSONEncoder() // dates en secondes depuis 2001 : ce qu'ActivityKit décode
        guard let stateJSON = try? JSONSerialization.jsonObject(with: encoder.encode(state)) else { return nil }
        var payload: [String: Any] = ["event": event, "state": stateJSON]
        if let attributes, let attributesJSON = try? JSONSerialization.jsonObject(with: encoder.encode(attributes)) {
            payload["attributes"] = attributesJSON
        }
        if let stale = staleDate(for: state, now: now) { payload["stale"] = stale.timeIntervalSince1970 }
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}
