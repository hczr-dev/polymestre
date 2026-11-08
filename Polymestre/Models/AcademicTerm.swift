import Foundation
import SwiftData

/// Semestre académique EPFL (automne / printemps).
@Model
final class AcademicTerm {
    var id: UUID = UUID()
    var year: Int = 0
    var seasonRaw: String = ""
    /// Lundi de la semaine 1.
    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var totalWeeks: Int = 0
    var name: String = ""

    var season: TermSeason {
        get { TermSeason(rawValue: seasonRaw) ?? .spring }
        set { seasonRaw = newValue.rawValue }
    }

    /// Libellé court : « Printemps 2025 ».
    var displayName: String {
        name.isEmpty ? "\(season.label) \(year)" : name
    }

    /// Les cours du semestre. Inverse de `Course.term` : iCloud exige que
    /// chaque relation ait son inverse.
    @Relationship(deleteRule: .nullify, inverse: \Course.term)
    var courses: [Course]? = []

    init(id: UUID = UUID(),
         year: Int,
         season: TermSeason,
         startDate: Date,
         endDate: Date,
         totalWeeks: Int = 14,
         name: String = "") {
        self.id = id
        self.year = year
        self.seasonRaw = season.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.totalWeeks = totalWeeks
        self.name = name
    }

    // MARK: État temporel

    var hasStarted: Bool { Date() >= startDate }
    var hasEnded: Bool { Date() > endDate }
    /// Le semestre est en cours aujourd'hui.
    var isRunning: Bool { hasStarted && !hasEnded }
    var hasNotStarted: Bool { Date() < startDate }

    /// Progression temporelle du semestre, 0…1.
    var timeProgress: Double {
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(startDate)
        return min(1, max(0, elapsed / total))
    }

    /// Semaine courante bornée à `1...totalWeeks`.
    var currentWeek: Int { DateUtils.clampedWeek(for: Date(), term: self) }

    /// État lisible pour l'interface.
    var statusLabel: String {
        if hasEnded { return String(localized: "Terminé") }
        if hasNotStarted { return String(localized: "À venir") }
        return String(localized: "Semaine \(currentWeek) / \(totalWeeks)")
    }

    // MARK: Résolution

    /// Choisit le semestre à afficher : celui qui contient la date du jour,
    /// sinon le plus proche (le prochain à venir, ou le dernier terminé).
    static func resolve(from terms: [AcademicTerm], reference: Date = Date()) -> AcademicTerm? {
        guard !terms.isEmpty else { return nil }
        if let running = terms.first(where: { $0.isRunning }) { return running }

        let upcoming = terms.filter { $0.startDate > reference }.min { $0.startDate < $1.startDate }
        if let upcoming { return upcoming }

        return terms.max { $0.endDate < $1.endDate }
    }

    /// Semestres triés du plus récent au plus ancien.
    static func sorted(_ terms: [AcademicTerm]) -> [AcademicTerm] {
        terms.sorted { $0.startDate > $1.startDate }
    }

    // MARK: Rattachement des cours

    /// Le semestre auquel rattacher un cours qui n'en a pas.
    ///
    /// Ordre de préférence : celui qui est en cours, sinon le plus récent, sinon
    /// celui qu'on crée d'après le calendrier EPFL. Un cours sans semestre affiche
    /// « semaine 1 » sur tous les écrans — c'est faux, et rien ne le signalait.
    static func current(in context: ModelContext, reference: Date = Date()) -> AcademicTerm {
        let terms = (try? context.fetch(FetchDescriptor<AcademicTerm>())) ?? []
        if let running = terms.first(where: { $0.isRunning }) { return running }
        if let latest = terms.max(by: { $0.startDate < $1.startDate }) { return latest }

        let start = DateUtils.currentAutumnOrSpringStart(reference: reference)
        let monday = DateUtils.startOfWeek(start.start)
        let term = AcademicTerm(year: Calendar.current.component(.year, from: monday),
                                season: start.season,
                                startDate: monday,
                                endDate: DateUtils.addTeachingWeeks(start.weeks, to: monday),
                                totalWeeks: start.weeks)
        context.insert(term)
        return term
    }

    /// Rattache au semestre courant les cours qui n'en ont aucun, et remet
    /// d'aplomb la semaine de leurs séries.
    ///
    /// Réparation, pas fonctionnalité : les cours créés par l'import d'horaire
    /// étaient enregistrés avec `term: nil`, donc affichés en « semaine 1 » quel que
    /// soit le jour. L'import PDF d'une série, lui, prend `course.currentWeek` comme
    /// semaine planifiée — il écrivait donc « Semaine 1 » pour toutes les séries,
    /// y compris la Série 2 importée en semaine 2.
    ///
    /// La correction des séries reste **bornée** : uniquement les cours réparés
    /// ici, uniquement une série encore à la semaine 1, et uniquement si son
    /// numéro désigne une autre semaine. Aucune donnée choisie par l'étudiant·e
    /// n'est touchée. Idempotent.
    @discardableResult
    static func attachOrphanCourses(in context: ModelContext, reference: Date = Date()) -> Int {
        let orphans = ((try? context.fetch(FetchDescriptor<Course>())) ?? [])
            .filter { $0.term == nil }
        guard !orphans.isEmpty else { return 0 }
        let term = current(in: context, reference: reference)
        for course in orphans {
            course.term = term
            for series in course.series where series.plannedWeek == 1 && series.seriesNumber > 1 {
                series.plannedWeek = series.seriesNumber
            }
        }
        try? context.save()
        return orphans.count
    }
}
