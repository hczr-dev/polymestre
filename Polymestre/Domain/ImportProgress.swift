import Foundation

/// L'avancement d'un import de plusieurs cours, **pondéré par ce qui prend du
/// temps**, et le temps qu'il reste.
///
/// Un import de semestre dure une à trois minutes, et un cours ne vaut pas
/// l'autre : lire 34 activités Moodle prend dix fois plus longtemps que lire le
/// plan d'un cours qui en a trois. Compter « un cours = 25 % » faisait sauter la
/// barre puis la figer. Ici, chaque cours avance par étapes pesées selon leur
/// durée réelle mesurée ; l'étape de lecture des activités avance activité par
/// activité ; l'analyse par le modèle, qui ne dit rien pendant qu'elle travaille,
/// avance au rythme de sa durée habituelle, sans jamais s'achever avant d'avoir
/// répondu.
///
/// Pur : l'écran lui donne l'heure, ce qui le rend testable (`validate.sh`).
struct ImportProgress: Equatable {

    enum Stage: Int, CaseIterable, Comparable {
        case waiting, outline, activities, sources, analysis, writing, done

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }

        /// La part de la durée d'un cours, mesurée sur MATH-101, MATH-111,
        /// CS-107 et CS-101 (Moodle, Courseware, analyse DeepSeek).
        var weight: Double {
            switch self {
            case .waiting, .done: return 0
            case .outline: return 0.06
            case .activities: return 0.42
            case .sources: return 0.14
            case .analysis: return 0.33
            case .writing: return 0.05
            }
        }

        /// Ce qu'on dit de l'étape, en clair.
        var label: String {
            switch self {
            case .waiting: return String(localized: "en attente")
            case .outline: return String(localized: "plan du cours")
            case .activities: return String(localized: "lecture des activités")
            case .sources: return String(localized: "vidéos, MOOC et plan")
            case .analysis: return String(localized: "rangement par semaine")
            case .writing: return String(localized: "écriture")
            case .done: return String(localized: "prêt")
            }
        }

        /// Durée habituelle d'une étape qui ne donne pas de compteur.
        var typicalSeconds: Double {
            switch self {
            case .outline: return 3
            case .sources: return 8
            case .analysis: return 22
            case .writing: return 1
            default: return 10
            }
        }

        /// Les étapes qui comptent, dans l'ordre (sans attente ni fin).
        static let working: [Stage] = [.outline, .activities, .sources, .analysis, .writing]
    }

    struct Course: Equatable, Identifiable {
        let id: String
        var stage: Stage = .waiting
        var stageStartedAt: Date?
        /// Activités lues / à lire, pendant `.activities`.
        var done = 0
        var total = 0
        var failed = false
        /// Le dernier lot lu, et la durée mesurée d'un lot : entre deux lots,
        /// l'avancement glisse au rythme réel au lieu d'attendre puis sauter.
        var lastBatchAt: Date?
        /// Début et fin du cours : la durée réelle d'un cours fini sert à
        /// estimer celle des suivants.
        var startedAt: Date?
        var finishedAt: Date?
        var batchSeconds: Double = 6
        static let batchSize = 18

        /// Avancement du cours, de 0 à 1.
        func fraction(at now: Date) -> Double {
            if stage == .done { return 1 }
            var value = 0.0
            for step in Stage.working where step < stage { value += step.weight }
            guard Stage.working.contains(stage) else { return value }
            return value + stage.weight * withinStage(at: now)
        }

        /// Avancement dans l'étape en cours, de 0 à 1 (jamais 1 avant la fin).
        func withinStage(at now: Date) -> Double {
            if stage == .activities, total > 0 {
                let pending = Double(min(Course.batchSize, max(0, total - done)))
                let since = max(0, now.timeIntervalSince(lastBatchAt ?? stageStartedAt ?? now))
                let gliding = pending * min(0.9, since / max(batchSeconds, 1))
                return min(0.98, (Double(done) + gliding) / Double(total))
            }
            let elapsed = max(0, now.timeIntervalSince(stageStartedAt ?? now))
            // Approche asymptotique : 63 % à la durée habituelle, 86 % au double,
            // plafonnée — l'étape ne se « termine » qu'à l'étape suivante.
            return min(0.92, 1 - exp(-elapsed / stage.typicalSeconds))
        }
    }

    private(set) var courses: [Course] = []
    private(set) var startedAt: Date?

    init(courseIDs: [String] = [], now: Date = Date()) {
        courses = courseIDs.map { Course(id: $0) }
        startedAt = courseIDs.isEmpty ? nil : now
    }

    mutating func reset(courseIDs: [String], now: Date) {
        self = ImportProgress(courseIDs: courseIDs, now: now)
    }

    mutating func enter(_ stage: Stage, course id: String, now: Date) {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        // Jamais en arrière : un message tardif d'une étape passée est ignoré.
        guard stage > courses[index].stage else { return }
        if courses[index].startedAt == nil { courses[index].startedAt = now }
        if stage == .done { courses[index].finishedAt = now }
        courses[index].stage = stage
        courses[index].stageStartedAt = now
    }

    mutating func activities(done: Int, total: Int, course id: String, now: Date) {
        enter(.activities, course: id, now: now)
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        if done > courses[index].done, let last = courses[index].lastBatchAt ?? courses[index].stageStartedAt {
            // Moyenne glissante : un lot lent (page lourde) ne fait pas tout dévier.
            let measured = now.timeIntervalSince(last)
            courses[index].batchSeconds = courses[index].batchSeconds * 0.5 + measured * 0.5
        }
        courses[index].done = done
        courses[index].total = total
        courses[index].lastBatchAt = now
    }

    mutating func fail(course id: String, now: Date) {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        courses[index].failed = true
        courses[index].finishedAt = now
        courses[index].stage = .done
        courses[index].stageStartedAt = now
    }

    /// L'avancement global, de 0 à 1.
    func fraction(at now: Date) -> Double {
        guard !courses.isEmpty else { return 0 }
        return courses.reduce(0) { $0 + $1.fraction(at: now) } / Double(courses.count)
    }

    var isFinished: Bool { !courses.isEmpty && courses.allSatisfy { $0.stage == .done } }

    /// Le temps restant estimé, en secondes ; `nil` tant que la mesure n'a pas
    /// de sens (premières secondes, ou presque rien de fait).
    func remainingSeconds(at now: Date) -> Double? {
        guard let startedAt, !isFinished else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        let fraction = self.fraction(at: now)
        guard elapsed >= 6, fraction >= 0.04 else { return nil }
        // Dès qu'un cours est fini, sa durée réelle fait référence : ce qui
        // reste vaut « la part restante de chaque cours × la durée d'un cours ».
        // L'extrapolation linéaire, elle, s'affolait dès qu'une étape traînait.
        let durations = courses.compactMap { course -> Double? in
            guard !course.failed, let start = course.startedAt, let end = course.finishedAt else { return nil }
            return end.timeIntervalSince(start)
        }
        if !durations.isEmpty {
            let perCourse = durations.reduce(0, +) / Double(durations.count)
            return max(0, courses.reduce(0) { $0 + (1 - $1.fraction(at: now)) * perCourse })
        }
        return max(0, elapsed / fraction * (1 - fraction))
    }

    /// « ~1 min 40 », « ~25 s », « encore un instant ».
    static func remainingLabel(_ seconds: Double?) -> String {
        guard let seconds else { return "estimation…" }
        if seconds < 8 { return String(localized: "encore un instant") }
        if seconds < 60 { return "~\(Int((seconds / 5).rounded()) * 5) s" }
        let minutes = Int(seconds) / 60
        let rest = (Int(seconds) % 60) / 10 * 10
        return rest == 0 ? "~\(minutes) min" : "~\(minutes) min \(rest)"
    }

    /// L'étape d'un message de la chaîne d'import (`CourseImportPipeline`).
    static func stage(forMessage message: String) -> Stage? {
        let text = message.lowercased()
        if text.contains("rangement") { return .analysis }
        if text.contains("mooc") || text.contains("courseware") || text.contains("plan du cours")
            || text.contains("mediaspace") || text.contains("explique")
            || text.contains("botafogo") || text.contains("outils") || text.contains("site du cours") {
            return .sources
        }
        return nil
    }
}
