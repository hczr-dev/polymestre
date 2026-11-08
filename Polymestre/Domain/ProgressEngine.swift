import Foundation

/// Agrégat des pourcentages d'un cours (théorie / exercices / corrections).
struct CourseProgress: Equatable {
    var videoCount: Int = 0
    var watchedCount: Int = 0
    var summarizedCount: Int = 0
    var exerciseCount: Int = 0
    var doneCount: Int = 0
    var correctedCount: Int = 0
    var bonusCount: Int = 0
    var bonusDoneCount: Int = 0
    var wrongOrRedoCount: Int = 0

    static func ratio(_ value: Int, _ total: Int) -> Double {
        total <= 0 ? 0 : Double(value) / Double(total)
    }

    /// Théorie : vidéos regardées / total.
    var theoryPercent: Double { Self.ratio(watchedCount, videoCount) }
    /// Exercices : exos (hors bonus) faits / total.
    var exercisePercent: Double { Self.ratio(doneCount, exerciseCount) }
    /// Corrections : exos corrigés / exos faits.
    var correctionPercent: Double { Self.ratio(correctedCount, doneCount) }

    /// Le chiffre d'un cours, en un nombre : la part faite de ce qui est à
    /// faire — théorie vue et exercices faits, pondérés par leur nombre. Les
    /// corrections n'y entrent pas : elles disent si c'est juste, pas si
    /// c'est fait. Un exercice à refaire n'est pas fait (`countsAsDone`).
    var completion: Double {
        Self.ratio(watchedCount + doneCount, videoCount + exerciseCount)
    }

    var remainingVideos: Int { max(0, videoCount - watchedCount) }
    var remainingExercises: Int { max(0, exerciseCount - doneCount) }
}

/// Progression d'une semaine donnée.
struct WeeklyProgress: Identifiable, Equatable {
    var week: Int
    var videoCount: Int = 0
    var watchedCount: Int = 0
    var exerciseCount: Int = 0
    var doneCount: Int = 0
    var correctedCount: Int = 0
    /// Durée totale des vidéos restantes pour cette semaine.
    var remainingVideoSeconds: Int = 0

    var id: Int { week }
    var theoryPercent: Double { CourseProgress.ratio(watchedCount, videoCount) }
    var exercisePercent: Double { CourseProgress.ratio(doneCount, exerciseCount) }
    var correctionPercent: Double { CourseProgress.ratio(correctedCount, doneCount) }
    var hasItems: Bool { videoCount > 0 || exerciseCount > 0 }

    /// Numéros des séries planifiées cette semaine (« Série 3 »).
    var seriesNumbers: [Int] = []

    /// Ce qui reste, tous axes confondus (théorie non vue + exercices non faits).
    var remainingCount: Int { (videoCount - watchedCount) + (exerciseCount - doneCount) }
    var isComplete: Bool { hasItems && remainingCount == 0 }
}

/// Moteur de calcul des pourcentages (fonctions pures, testables).
enum ProgressEngine {

    // MARK: Global

    static func progress(for course: Course) -> CourseProgress {
        var p = CourseProgress()
        let videos = course.theoryItems
        p.videoCount = videos.count
        p.watchedCount = videos.filter { $0.isWatched }.count
        p.summarizedCount = videos.filter { $0.isSummarized }.count

        let all = course.allExercises
        let required = all.filter { !$0.isBonus }
        p.bonusCount = all.filter(\.isBonus).count
        p.bonusDoneCount = all.filter { $0.isBonus && $0.isDone }.count
        p.exerciseCount = required.count
        // Fait et corrigé au sens de `ExerciseStage` : un exercice à refaire
        // n'est pas fait, et une correction ne compte que sur un exercice fait
        // (corrigés ⩽ faits, jamais plus de 100 %).
        p.doneCount = required.filter(\.countsAsDone).count
        p.correctedCount = required.filter { $0.countsAsDone && $0.isCorrected }.count
        p.wrongOrRedoCount = all.filter {
            $0.redoRequired || $0.correctness == .wrong
        }.count
        return p
    }

    // MARK: Rythme

    /// Ce qui aurait dû être fait **avant** cette semaine et ne l'est pas — à
    /// refaire, à corriger, exercices non faits, théorie non vue (`LateWork`).
    /// C'est le « 1 en retard » d'une carte de cours — la semaine en cours n'y
    /// compte pas, elle n'est pas finie.
    static func lateCount(for course: Course, currentWeek: Int? = nil, now: Date = Date()) -> Int {
        // Une seule définition du retard : celle de la page « À rattraper ».
        LateWork.of(course, currentWeek: currentWeek, now: now).total
    }

    /// Les corrections à faire **hors du retard** : exercices faits, corrigé
    /// publié, d'une série pas encore échue — en pratique, la semaine en cours.
    ///
    /// Le retard (`LateWork`) compte déjà les corrections des séries échues et
    /// tout ce qui est à refaire ; la carte affichait les deux côte à côte, et
    /// le même exercice y comptait deux fois.
    struct CorrectionsDue: Equatable {
        var toCorrect = 0
        var isEmpty: Bool { toCorrect == 0 }
    }

    static func correctionsDue(for course: Course, currentWeek: Int? = nil, now: Date = Date()) -> CorrectionsDue {
        let week = currentWeek ?? course.dueWeek(at: now)
        var due = CorrectionsDue()
        for series in course.series where !series.isDue(beforeWeek: week, at: now) {
            guard series.solutionsAt.map({ $0 <= now }) ?? true else { continue }
            due.toCorrect += series.exercises.filter {
                (!$0.isBonus || $0.isDone) && !$0.redoRequired && $0.isDone && !$0.isCorrected
            }.count
        }
        return due
    }

    /// Ce qui est fait **en avance** : éléments des semaines à venir déjà faits.
    static func aheadCount(for course: Course, currentWeek: Int? = nil) -> Int {
        let week = currentWeek ?? course.currentWeek
        let theory = course.theoryItems.filter { $0.plannedWeek > week && $0.isWatched }.count
        let exercises = course.series
            .filter { $0.plannedWeek > week }
            .flatMap(\.exercises)
            .filter { !$0.isBonus && $0.countsAsDone }
            .count
        return theory + exercises
    }

    /// « À jour », « 3 en retard », « 2 d'avance » : l'état d'un cours en mots.
    static func standingLabel(late: Int, ahead: Int) -> String {
        if late > 0 { return String(localized: "\(late) en retard") }
        if ahead > 0 { return String(localized: "\(ahead) d'avance") }
        return String(localized: "À jour")
    }

    // MARK: Par semaine

    static func weekProgress(for course: Course, week: Int) -> WeeklyProgress {
        var w = WeeklyProgress(week: week)

        let videos = course.theoryItems.filter { $0.plannedWeek == week }
        w.videoCount = videos.count
        w.watchedCount = videos.filter(\.isWatched).count
        w.remainingVideoSeconds = videos.filter { !$0.isWatched }
            .reduce(0) { $0 + $1.durationSeconds }

        let exercises = course.series
            .filter { $0.plannedWeek == week }
            .flatMap(\.exercises)
            .filter { !$0.isBonus }
        w.exerciseCount = exercises.count
        w.doneCount = exercises.filter(\.countsAsDone).count
        w.correctedCount = exercises.filter { $0.countsAsDone && $0.isCorrected }.count
        w.seriesNumbers = course.series.filter { $0.plannedWeek == week }.map(\.seriesNumber).sorted()
        return w
    }

    /// Les semaines du semestre **toutes**, de 1 à la dernière — vides comprises.
    ///
    /// La progression se lit comme un calendrier : une semaine sans rien de prévu
    /// est une information (« rien à rattraper en S6 »), pas un trou à cacher. La
    /// borne est la durée du semestre, étendue si un élément est planifié plus loin.
    static func semesterWeeks(for course: Course) -> [WeeklyProgress] {
        let planned = course.theoryItems.map(\.plannedWeek) + course.series.map(\.plannedWeek)
        let last = max(course.term?.totalWeeks ?? 14, planned.max() ?? 0)
        guard last > 0 else { return [] }
        return (1...last).map { weekProgress(for: course, week: $0) }
    }

    /// Éléments de théorie sans semaine (importés sans calendrier).
    static func unplannedTheory(for course: Course) -> [TheoryItem] {
        course.sortedTheoryItems.filter { $0.plannedWeek <= 0 }
    }

    // MARK: Durées de vidéo

    /// Vidéos restantes pour une semaine, triées.
    static func remainingVideos(for course: Course, week: Int) -> [TheoryItem] {
        course.sortedTheoryItems.filter { $0.plannedWeek == week && !$0.isWatched }
    }

    /// Exercices restants pour une semaine donnée.
    static func remainingExercises(for course: Course, week: Int) -> [Exercise] {
        course.sortedSeries
            .filter { $0.plannedWeek == week }
            .flatMap(\.sortedExercises)
            .filter { !$0.countsAsDone }
    }
}

/// Ce qu'une ligne de cours affiche, calculé une fois par rendu d'« Aujourd'hui » (iPhone et Mac).
struct WeekCourseSummary {
    let course: Course
    let week: WeeklyProgress
    let late: Int
    let ahead: Int
    let corrections: ProgressEngine.CorrectionsDue

    init(course: Course, now: Date = Date()) {
        self.course = course
        week = ProgressEngine.weekProgress(for: course, week: course.currentWeek)
        late = ProgressEngine.lateCount(for: course, now: now)
        ahead = ProgressEngine.aheadCount(for: course)
        corrections = ProgressEngine.correctionsDue(for: course, now: now)
    }
}
