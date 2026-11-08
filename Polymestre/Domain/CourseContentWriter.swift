import Foundation
import SwiftData

/// Ce qu'un import a changé, pour le dire en une phrase.
struct ContentImportResult: Equatable {
    var theoryAdded = 0
    var theoryUpdated = 0
    var seriesAdded = 0
    var seriesUpdated = 0
    var exercisesAdded = 0
    var deadlinesAdded = 0
    var pastExamsAdded = 0
    var documentsAdded = 0

    var isEmpty: Bool {
        theoryAdded + theoryUpdated + seriesAdded + seriesUpdated + deadlinesAdded + pastExamsAdded + documentsAdded == 0
    }

    var message: String {
        var parts: [String] = []
        if theoryAdded > 0 { parts.append(String(localized: "\(Plural.count(theoryAdded, "\(theoryAdded) élément", "\(theoryAdded) éléments")) de théorie")) }
        if seriesAdded > 0 { parts.append(Plural.count(seriesAdded, "\(seriesAdded) série", "\(seriesAdded) séries")) }
        if exercisesAdded > 0 { parts.append(Plural.count(exercisesAdded, "\(exercisesAdded) exercice", "\(exercisesAdded) exercices")) }
        if deadlinesAdded > 0 { parts.append(Plural.count(deadlinesAdded, "\(deadlinesAdded) échéance", "\(deadlinesAdded) échéances")) }
        if pastExamsAdded > 0 { parts.append(Plural.count(pastExamsAdded, "\(pastExamsAdded) ancien examen", "\(pastExamsAdded) anciens examens")) }
        if documentsAdded > 0 { parts.append(Plural.count(documentsAdded, "\(documentsAdded) document", "\(documentsAdded) documents")) }
        let updated = theoryUpdated + seriesUpdated
        if parts.isEmpty {
            return updated > 0 ? String(localized: "Déjà à jour · \(Plural.count(updated, "\(updated) élément rafraîchi", "\(updated) éléments rafraîchis")).") : String(localized: "Rien de nouveau.")
        }
        return String(localized: "Ajouté : ") + parts.joined(separator: " et ") + (updated > 0 ? String(localized: " · \(updated) mis à jour.") : ".")
    }
}

/// Écrit un brouillon relu dans un cours.
///
/// **Ne supprime jamais rien** : réimporter Moodle en semaine 8 doit ajouter la
/// série 8, pas effacer l'avancement des sept premières. Un élément déjà présent
/// — même adresse, ou même numéro — est mis à jour (titre, semaine, vidéos) et
/// garde ce qui a été coché.
enum ContentDraftWriter {

    /// Le thème, le corrigé et les exercices d'une série, quand la source les
    /// donne. Les exercices passent par `SeriesDraftWriter` en mode fusion :
    /// l'avancement (questions cochées, correction) est gardé par numéro.
    /// Ajoute un document à la liste du cours s'il n'y est pas ; rend 1 s'il est nouveau.
    private static func addDocument(_ item: ContentDraftItem, to course: Course) -> Int {
        guard !item.url.isEmpty else { return 0 }
        var documents = course.documents
        guard !documents.contains(where: { $0.url == item.url }) else { return 0 }
        documents.append(CourseDocument(title: item.title, url: item.url, group: item.group,
                                        kind: item.links.first?.kind ?? .page))
        course.documents = documents
        return 1
    }

    @discardableResult
    private static func writeDetails(of item: ContentDraftItem, into series: ExerciseSeries,
                                     course: Course, context: ModelContext, complete: Bool = false) -> Int {
        let topic = item.title.trimmingCharacters(in: .whitespaces)
        if !topic.isEmpty, topic != "Série \(series.seriesNumber)", topic != series.displayName,
           ContentDraftBuilder.seriesNumber(in: topic) == nil || topic.count > 12 {
            series.topic = topic
        }
        if let date = item.solutionsAt { series.solutionsAt = date }
        if !item.solutionURL.isEmpty { series.solutionURLString = item.solutionURL }
        guard !item.exercises.isEmpty else { return 0 }
        let before = series.exercises.count
        let draft = SeriesDraft(existingID: series.id, number: series.seriesNumber, label: series.label, title: "",
                                plannedWeek: series.plannedWeek,
                                exercises: item.exercises.map { spec in
                                    var exercise = ExerciseDraft(minor: spec.number.split(separator: ".").last.map(String.init) ?? spec.number,
                                                                 title: spec.title, isBonus: spec.isBonus,
                                                                 subQuestions: spec.questions)
                                    exercise.statement = spec.statement
                                    return exercise
                                })
        SeriesDraftWriter.write(draft, to: course, mode: .importMerge, context: context)
        for spec in item.exercises {
            guard let exercise = series.exercises.first(where: { $0.exerciseNumber == spec.number }) else { continue }
            if !spec.hint.isEmpty { exercise.hint = spec.hint }
            if !spec.solution.isEmpty { exercise.solution = spec.solution }
            if !spec.url.isEmpty { exercise.statementURLString = spec.url }
        }
        // Une source qui liste **toute** la série (le programme Botafogo) fait
        // foi : un exercice qu'elle ne cite plus, jamais commencé, s'en va —
        // les brouillons du site (6.11, 6.12 d'Analyse I) restaient sinon
        // sous la forme d'onglets à l'énoncé introuvable.
        if complete {
            let cited = Set(item.exercises.map(\.number))
            for exercise in series.exercises where !cited.contains(exercise.exerciseNumber)
                && !exercise.isDone && exercise.subQuestionDoneCount == 0 && exercise.score == nil
                && (exercise.correctionNote ?? "").isEmpty && exercise.hintLog.isEmpty && exercise.redoDueAt == nil {
                series.exercises.removeAll { $0.id == exercise.id }
                context.delete(exercise)
            }
        }
        return max(0, series.exercises.count - before)
    }

    /// - Parameter updateWeeks: réécrire la semaine des éléments déjà là. Vrai
    ///   pour un import **relu** (la relecture fait foi) ; faux pour une mise à
    ///   jour automatique, qui ne doit jamais défaire une semaine corrigée à la
    ///   main.
    @discardableResult
    static func apply(_ draft: ContentDraft, to course: Course, context: ModelContext,
                      updateWeeks: Bool = true) -> ContentImportResult {
        var result = ContentImportResult()
        var nextSort = (course.theoryItems.map(\.sortOrder).max() ?? -1) + 1
        // Les vidéos déjà vues : un chapitre réparti autrement (leçon par leçon,
        // sur deux semaines) reste vu là où ses vidéos l'étaient.
        let watchedVideos = Set(course.theoryItems.filter(\.isWatched).flatMap { $0.links.filter { $0.kind == .video }.map(\.url) })

        // Ce qui a été écarté à une relecture reste écarté : une relecture le
        // décide (et peut le reprendre), une mise à jour automatique jamais.
        var ignored = course.contentIgnored
        if updateWeeks {
            for section in draft.sections {
                for item in section.items where !item.url.isEmpty {
                    if section.isIncluded && item.kind != .ignore {
                        ignored.remove(item.url)
                    } else {
                        ignored.insert(item.url)
                    }
                }
            }
            if ignored != course.contentIgnored { course.contentIgnored = ignored }
        }

        for (sectionIndex, section) in draft.sections.enumerated() where section.isIncluded {
            let chapter = ContentDraftBuilder.leadingNumber(in: section.title).flatMap { Int($0.number) }
            for item in section.items {
                if !updateWeeks, !item.url.isEmpty, ignored.contains(item.url) { continue }
                switch item.kind {
                case .ignore:
                    continue
                case .deadline:
                    // Une échéance est une évaluation du cours : rendu noté,
                    // projet, examen. Retrouvée par son titre, jamais doublée.
                    let title = item.title.trimmingCharacters(in: .whitespaces)
                    if let existing = course.exams.first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                        if let date = item.date, existing.date != date { existing.date = date }
                        if existing.urlString.isEmpty { existing.urlString = item.url }
                    } else if let date = item.date {
                        let exam = Exam(course: course, kind: item.examKind, title: title, date: date)
                        exam.urlString = item.url
                        context.insert(exam)
                        result.deadlinesAdded += 1
                    } else {
                        // Sans date, c'est un document : on garde le lien.
                        result.documentsAdded += addDocument(item, to: course)
                    }
                case .pastExam:
                    let year = Int(item.number) ?? Calendar.current.component(.year, from: Date())
                    if let existing = course.pastExams.first(where: { $0.urlString == item.url || $0.title == item.title }) {
                        if existing.solutionURLString.isEmpty { existing.solutionURLString = item.solutionURL }
                    } else {
                        let past = PastExam(course: course, title: item.title, year: year, kind: .exam,
                                            urlString: item.url, solutionURLString: item.solutionURL)
                        context.insert(past)
                        result.pastExamsAdded += 1
                    }
                case .resource:
                    result.documentsAdded += addDocument(item, to: course)
                case .theory:
                    let existing = course.theoryItems.first { existing in
                        (!item.url.isEmpty && existing.urlString == item.url) || existing.number == item.number
                    }
                    let sectionNumber = Int(item.number.split(separator: ".").first ?? "") ?? chapter ?? (sectionIndex + 1)
                    defer {
                        // L'élément d'une semaine (numéro « 4 ») absorbe les
                        // éléments qu'un import précédent avait créés pour chacun de
                        // ses cours (« 4.1 », « 4.2 ») : leurs liens sont désormais
                        // les siens. La semaine reste vue si tout l'était.
                        if !item.number.isEmpty, item.number.allSatisfy(\.isNumber),
                           let target = course.theoryItems.first(where: { $0.number == item.number || (!item.url.isEmpty && $0.urlString == item.url) }) {
                            target.number = item.number
                            let urls = Set(item.links.map(\.url) + [item.url])
                            let absorbed = course.theoryItems.filter { other in
                                other !== target && other.plannedWeek == target.plannedWeek
                                    && !other.urlString.isEmpty && urls.contains(other.urlString)
                            }
                            if !absorbed.isEmpty {
                                let all = [target] + absorbed
                                target.watchedAt = all.allSatisfy(\.isWatched) ? all.compactMap(\.watchedAt).max() : nil
                                for other in absorbed { context.delete(other) }
                                result.theoryUpdated += absorbed.count
                            }
                        }
                    }
                    if let existing {
                        existing.title = item.title
                        // La semaine d'un chapitre de MOOC vient du plan du cours :
                        // elle suit chaque mise à jour (une semaine fausse se corrige).
                        let derived = item.title.hasPrefix("MOOC · ")
                        if updateWeeks || existing.plannedWeek == 0 || derived { existing.plannedWeek = item.plannedWeek(in: section) }
                        if derived { existing.number = item.number }
                        existing.videoCount = item.videoCount
                        existing.sectionTitle = section.title
                        existing.kind = item.theoryKind
                        if existing.urlString.isEmpty { existing.urlString = item.url }
                        if !item.links.isEmpty { existing.links = item.links }
                        existing.sourceRaw = draft.source.rawValue
                        result.theoryUpdated += 1
                    } else {
                        let theory = TheoryItem(course: course,
                                                sectionNumber: sectionNumber,
                                                number: item.number,
                                                title: item.title,
                                                kind: item.theoryKind,
                                                plannedWeek: item.plannedWeek(in: section),
                                                sortOrder: nextSort,
                                                urlString: item.url)
                        theory.videoCount = item.videoCount
                        theory.sectionTitle = section.title
                        theory.sourceRaw = draft.source.rawValue
                        theory.links = item.links
                        let videos = item.links.filter { $0.kind == .video }.map(\.url)
                        if item.title.hasPrefix("MOOC · "), !videos.isEmpty, videos.allSatisfy(watchedVideos.contains) {
                            theory.watchedAt = Date()
                        }
                        context.insert(theory)
                        nextSort += 1
                        result.theoryAdded += 1
                    }
                case .series:
                    guard let number = item.seriesNumber ?? Int(item.number) else { continue }
                    let series: ExerciseSeries
                    let siblings = draft.sections.flatMap(\.items)
                        .filter { $0.kind == .series && ($0.seriesNumber ?? Int($0.number)) == number }
                    // Seule à ce numéro, ou la première de ses sœurs (« 5a » avant
                    // « 5b ») : elle reprend la série enregistrée sans étiquette,
                    // et son avancement, au lieu d'en créer une à côté.
                    let firstLabel = siblings.map { SeriesIdentity.normalized($0.seriesLabel) }
                        .sorted(by: SeriesIdentity.labelPrecedes).first
                    let soleOfNumber = siblings.count <= 1 || SeriesIdentity.normalized(item.seriesLabel) == firstLabel
                    if let existing = course.series(number: number, label: item.seriesLabel, soleOfNumber: soleOfNumber) {
                        // Une étiquette apparue (« mardi ») se pose sur la série d'avant.
                        if existing.label.isEmpty, !item.seriesLabel.isEmpty {
                            if existing.title == existing.displayName { existing.title = SeriesIdentity.displayName(number: number, label: item.seriesLabel) }
                            existing.label = SeriesIdentity.normalized(item.seriesLabel)
                        }
                        // Un corrigé seul (sans énoncé) ne déplace jamais sa série :
                        // la semaine est celle de l'énoncé, pas celle du corrigé.
                        let carriesStatement = !item.url.isEmpty || !item.pdfURL.isEmpty
                        if (updateWeeks && carriesStatement) || existing.plannedWeek == 0 {
                            existing.plannedWeek = item.plannedWeek(in: section)
                        }
                        // L'adresse de l'énoncé est remplacée quand l'ancienne n'a rien
                        // donné (aucun exercice lu) : une série de CS-107 créée par un
                        // ancien import du MOOC gardait sa page Courseware, et la
                        // vraie page de la série (proginsc) n'était jamais retenue.
                        // Une adresse sur Courseware (le MOOC) est aussi remplacée par
                        // celle du cours : les séries de CS-107 sont sur proginsc, et
                        // le MOOC n'en a que d'autres exercices, pas à faire.
                        let fresh = item.pdfURL.isEmpty ? item.url : item.pdfURL
                        let staleMOOC = URL(string: existing.urlString)?.host?.contains("courseware") == true
                            && URL(string: fresh)?.host?.contains("courseware") != true
                        if existing.urlString.isEmpty
                            || (!fresh.isEmpty && fresh != existing.urlString && (existing.exercises.isEmpty || staleMOOC)) {
                            existing.urlString = fresh
                            if staleMOOC {
                                // Les exercices pointaient eux aussi vers le MOOC.
                                for exercise in existing.exercises
                                where URL(string: exercise.statementURLString)?.host?.contains("courseware") == true {
                                    exercise.statementURLString = ""
                                }
                                existing.needsReread = true
                            }
                        }
                        if existing.solutionURLString.isEmpty, !item.solutionURL.isEmpty {
                            existing.solutionURLString = item.solutionURL
                        }
                        series = existing
                        result.seriesUpdated += 1
                    } else {
                        series = ExerciseSeries(course: course,
                                                seriesNumber: number,
                                                label: item.seriesLabel,
                                                plannedWeek: item.plannedWeek(in: section),
                                                urlString: item.pdfURL.isEmpty ? item.url : item.pdfURL)
                        context.insert(series)
                        result.seriesAdded += 1
                    }
                    result.exercisesAdded += writeDetails(of: item, into: series, course: course, context: context,
                                                          complete: BotafogoLinks.isPage(item.url) && !item.exercises.isEmpty)
                }
            }
        }

        if draft.source == .moodle { cleanUpMOOC(course: course, draft: draft, context: context) }
        if !draft.weekGuide.isEmpty { course.weekGuide = draft.weekGuide }

        var sources = course.contentSources
        if !draft.url.isEmpty, !sources.contains(draft.url) {
            sources.append(draft.url)
            course.contentSources = sources
        }
        return result
    }

    /// Ce que d'anciens imports du MOOC ont laissé, une fois le cours rangé par
    /// Moodle (et son plan) :
    ///   • les « séries » qui ne sont que des chapitres d'exercices du MOOC
    ///     (Courseware), pas commencées — elles ne sont pas à faire ;
    ///   • les leçons du MOOC sans semaine : elles rejoignent leur chapitre
    ///     (vu si toutes ses vidéos l'étaient), puis disparaissent.
    static func cleanUpMOOC(course: Course, draft: ContentDraft, context: ModelContext) {
        func isMOOC(_ address: String) -> Bool { address.contains("courseware.epfl.ch") }

        for series in course.series where isMOOC(series.urlString) {
            let started = series.exercises.contains { $0.isDone || $0.subQuestionDoneCount > 0 }
            if !started { context.delete(series) }
        }

        // Les éléments « MOOC · » que le brouillon ne contient plus (un chapitre
        // désormais réparti leçon par leçon, un chapitre plus demandé) disparaissent.
        let draftedMOOC = Set(draft.sections.flatMap(\.items).filter { $0.title.hasPrefix("MOOC · ") }.map(\.number))
        if !draftedMOOC.isEmpty {
            for stale in course.theoryItems where stale.title.hasPrefix("MOOC · ") && !draftedMOOC.contains(stale.number) {
                context.delete(stale)
            }
        }

        let chapters = course.theoryItems.filter { $0.title.hasPrefix("MOOC · ") && $0.plannedWeek > 0 && draftedMOOC.contains($0.number) }
        guard !chapters.isEmpty else { return }
        let drafted = Set(draft.sections.flatMap(\.items).map(\.url))
        let leftovers = course.theoryItems.filter { item in
            // Une leçon sans semaine, ou un bloc d'un ancien import fait
            // seulement de liens vers le MOOC (« Bienvenue — Regardez » en
            // semaine 8) : les chapitres « MOOC · » les remplacent.
            let onlyMOOC = isMOOC(item.urlString) && item.links.allSatisfy { isMOOC($0.url) }
            return (item.plannedWeek == 0 || onlyMOOC) && isMOOC(item.urlString) && !drafted.contains(item.urlString)
                && !item.title.hasPrefix("MOOC · ")
        }
        guard !leftovers.isEmpty else { return }
        for chapter in chapters where !chapter.isWatched {
            // Les leçons d'un chapitre : leur titre commence ses liens (« Variables — Vidéo 1 »).
            let lessonTitles = Set(chapter.links.map { $0.title.components(separatedBy: " — ").first ?? $0.title })
            let lessons = leftovers.filter { lessonTitles.contains($0.title) && $0.videoCount > 0 }
            if !lessons.isEmpty, lessons.allSatisfy(\.isWatched) {
                chapter.watchedAt = lessons.compactMap(\.watchedAt).max()
            }
        }
        for item in leftovers { context.delete(item) }
    }
}
