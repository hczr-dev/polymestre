import Foundation

/// Ce qu'un cours a **en retard**, rangé par ce qu'il y a à faire.
///
/// Le « 12 en retard » d'une carte additionnait quatre choses différentes —
/// théorie non vue, exercices non faits des semaines passées, exercices faits
/// dont le corrigé est publié mais pas corrigés, exercices à refaire — et la
/// page qu'il ouvrait n'en listait que deux, avec un autre total : elle
/// affichait « À jour » pour un retard fait de corrections. Le badge, la carte
/// et la page lisent désormais **cette** liste ; `total` est le nombre affiché
/// partout.
///
/// Les quatre groupes sont disjoints (un exercice non fait **et** à refaire
/// était compté deux fois), dans l'ordre où les reprendre :
///   1. **à refaire** — une correction fausse, à reprendre tant qu'elle est fraîche ;
///   2. **à corriger** — fait, corrigé publié : quelques minutes pour fermer la boucle ;
///   3. **à faire** — les exercices des semaines passées, série par série ;
///   4. **à voir** — la théorie des semaines passées, semaine par semaine.
///
/// La semaine en cours n'y entre pas : elle n'est pas finie. Une série qui a
/// une échéance compte à son échéance, pas à sa semaine. Les bonus non plus :
/// facultatifs, ils ne sont pas dus.
struct LateWork {
    struct SeriesGroup: Identifiable {
        let series: ExerciseSeries
        /// Les exercices de la série qui restent à faire, dans l'ordre.
        let exercises: [Exercise]
        var id: UUID { series.id }
        /// Les exercices obligatoires de la série, pour « 4 sur 9 ».
        var requiredCount: Int { series.requiredExercises.count }
    }

    struct TheoryGroup: Identifiable {
        let week: Int
        let items: [TheoryItem]
        var id: Int { week }
    }

    /// La semaine en cours : tout ce qui était prévu **avant** est dû.
    var currentWeek: Int
    var redo: [Exercise] = []
    var toCorrect: [Exercise] = []
    var series: [SeriesGroup] = []
    var theory: [TheoryGroup] = []

    var exerciseCount: Int { series.reduce(0) { $0 + $1.exercises.count } }
    var theoryCount: Int { theory.reduce(0) { $0 + $1.items.count } }
    var total: Int { redo.count + toCorrect.count + exerciseCount + theoryCount }
    var isEmpty: Bool { total == 0 }

    /// « 2 à refaire, 3 à corriger, 5 exercices et 2 éléments de théorie ».
    var summary: String {
        var parts: [String] = []
        if !redo.isEmpty { parts.append(String(localized: "\(redo.count) à refaire")) }
        if !toCorrect.isEmpty { parts.append(String(localized: "\(toCorrect.count) à corriger")) }
        if exerciseCount > 0 { parts.append(Plural.count(exerciseCount, "\(exerciseCount) exercice à faire", "\(exerciseCount) exercices à faire")) }
        if theoryCount > 0 { parts.append(Plural.count(theoryCount, "\(theoryCount) élément de théorie", "\(theoryCount) éléments de théorie")) }
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + String(localized: " et ") + parts.last!
    }

    /// - Parameters:
    ///   - currentWeek: la semaine de référence (tests) ; par défaut la semaine
    ///     **non bornée** du semestre (`Course.dueWeek`) : passé la dernière
    ///     semaine, pendant la session, la dernière semaine aussi est échue.
    ///   - now: l'instant où l'on regarde — une échéance, un corrigé ou une
    ///     reprise ne deviennent dus qu'à leur heure.
    static func of(_ course: Course, currentWeek: Int? = nil, now: Date = Date()) -> LateWork {
        let week = currentWeek ?? course.dueWeek(at: now)
        var work = LateWork(currentWeek: currentWeek ?? course.currentWeek)
        let ordered = course.sortedSeries

        // À refaire : toutes les semaines — une correction fausse ne vieillit pas.
        // Une reprise **espacée** n'est due qu'à sa date : dans la file, elle
        // n'est pas en retard tant que son palier n'est pas arrivé. Elle reste
        // hors des autres groupes (elle n'est ni « à faire » ni « à corriger »).
        let flagged = ordered.flatMap(\.sortedExercises).filter { $0.redoRequired && (!$0.isBonus || $0.isDone) }
        work.redo = flagged.filter { $0.isRedoDue(at: now) }
        let redo = Set(flagged.map(\.id))

        for series in ordered where series.isDue(beforeWeek: week, at: now) {
            let published = series.solutionsAt.map { $0 <= now } ?? true
            let required = series.sortedExercises.filter { !$0.isBonus && !redo.contains($0.id) }
            if published {
                work.toCorrect += required.filter { $0.isDone && !$0.isCorrected }
            }
            let undone = required.filter { !$0.isDone }
            if !undone.isEmpty { work.series.append(SeriesGroup(series: series, exercises: undone)) }
        }

        let unseen = course.sortedTheoryItems.filter { $0.plannedWeek > 0 && $0.plannedWeek < week && !$0.isWatched }
        work.theory = Dictionary(grouping: unseen, by: \.plannedWeek)
            .map { TheoryGroup(week: $0.key, items: $0.value) }
            .sorted { $0.week < $1.week }
        return work
    }

    /// Les instants, d'ici `horizon`, où le retard peut changer **sans que rien
    /// ne soit touché** : le lundi suivant, une échéance de série, un corrigé
    /// publié, une reprise qui arrive à son palier. Le widget s'en sert pour
    /// passer au bon chiffre sans attendre l'app.
    static func changeDates(of course: Course, from now: Date = Date(), horizon: TimeInterval = 8 * 86_400) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var dates: [Date] = []
        var monday = DateUtils.addDays(7, to: DateUtils.startOfWeek(now))
        while monday <= end { dates.append(monday); monday = DateUtils.addDays(7, to: monday) }
        for series in course.series {
            if let due = series.dueDate { dates.append(due) }
            if let solutions = series.solutionsAt { dates.append(solutions) }
        }
        dates += course.allExercises.compactMap { $0.redoRequired ? $0.redoDueAt : nil }
        return Set(dates.filter { $0 > now && $0 <= end }).sorted()
    }
}

extension ExerciseSeries {
    /// La série est-elle échue ? Son échéance quand elle en a une (« à rendre
    /// jeudi » : pas en retard le lundi), sinon la fin de sa semaine prévue.
    func isDue(beforeWeek week: Int, at now: Date = Date()) -> Bool {
        if let dueDate { return dueDate <= now }
        return plannedWeek > 0 && plannedWeek < week
    }
}

extension Exercise {
    /// À refaire **maintenant** : marqué à refaire hors de la file de reprise,
    /// ou dans la file et arrivé à son palier. Le palier « pré-examen » sans
    /// date d'examen n'est pas dû.
    func isRedoDue(at now: Date = Date()) -> Bool {
        guard redoRequired else { return false }
        guard isQueuedForRedo else { return true }
        return redoDueAt.map { $0 <= now } ?? false
    }

    /// Fait **au sens de la progression** — comme `ExerciseStage.isDone` : un
    /// exercice à refaire n'est pas fait.
    var countsAsDone: Bool { isDone && !redoRequired }
}
