import Foundation

/// Construit l'index de recherche à partir des modèles.
///
/// Toute la logique de correspondance est dans `SearchEngine`, qui est pur ; ici,
/// seulement la lecture des modèles et la mise en forme de ce qui s'affiche.
enum SearchIndexBuilder {

    /// Bornes d'indexation.
    ///
    /// Une année de chrono fait plusieurs milliers de lignes ; les indexer toutes
    /// ralentirait la première frappe pour un bénéfice nul — personne ne cherche
    /// une session de novembre dernier par mot-clé. On garde les plus récentes.
    static let sessionLimit = 400
    static let taskLimit = 300

    static func documents(courses: [Course],
                          sessions: [StudySession] = [],
                          tasks: [LinkedTask] = [],
                          milestones: [AcademicMilestone] = [],
                          groups: [StudyGroup] = []) -> [SearchDocument] {
        var documents: [SearchDocument] = []

        for course in courses {
            documents.append(courseDocument(course))
            for series in course.sortedSeries {
                documents.append(seriesDocument(series, course: course))
                for exercise in series.sortedExercises {
                    documents.append(exerciseDocument(exercise, series: series, course: course))
                }
            }
            for item in course.sortedTheoryItems {
                documents.append(theoryDocument(item, course: course))
            }
            for exam in course.sortedExams {
                documents.append(examDocument(exam, course: course))
            }
            for past in course.pastExams.sorted(by: { $0.year > $1.year }) {
                documents.append(pastExamDocument(past, course: course))
            }
        }

        for session in sessions.prefix(sessionLimit) {
            documents.append(sessionDocument(session))
        }
        for task in tasks.prefix(taskLimit) {
            documents.append(taskDocument(task))
        }
        for milestone in milestones {
            documents.append(milestoneDocument(milestone))
        }
        for group in groups {
            documents.append(groupDocument(group))
        }
        return documents
    }

    // MARK: Cours

    private static func courseDocument(_ course: Course) -> SearchDocument {
        // Le code est écrit de plusieurs façons selon les gens : « CS-250 »,
        // « CS250 », « cs 250 ». Les trois doivent tomber sur le cours.
        var detail = [course.name, course.shortName, course.code,
                      course.lecturer, course.notes, course.sectionCode].joined(separator: " ")
        detail += " " + course.code.replacingOccurrences(of: "-", with: "")
        return SearchDocument(id: "course.\(course.id)",
                              kind: .course,
                              title: course.name.isEmpty ? course.displayCode : course.name,
                              subtitle: [course.displayCode,
                                         "\(Int(course.credits)) crédits",
                                         course.term?.displayName ?? ""]
                                  .filter { !$0.isEmpty }
                                  .joined(separator: " · "),
                              detail: detail,
                              courseCode: course.displayCode)
    }

    private static func seriesDocument(_ series: ExerciseSeries, course: Course) -> SearchDocument {
        SearchDocument(id: "series.\(series.id)",
                       kind: .series,
                       title: series.title.isEmpty ? series.displayName : series.title,
                       subtitle: "\(course.displayCode) · semaine \(series.plannedWeek) · \(series.exercises.count) exercices",
                       detail: "serie \(series.seriesNumber) \(series.title) \(series.topic)",
                       courseCode: course.displayCode,
                       date: series.dueDate ?? series.publishedAt)
    }

    private static func exerciseDocument(_ exercise: Exercise,
                                         series: ExerciseSeries,
                                         course: Course) -> SearchDocument {
        var detail = "exercice \(exercise.exerciseNumber) \(exercise.title) serie \(series.seriesNumber)"
        if exercise.isBonus { detail += " bonus facultatif" }
        if let note = exercise.correctionNote { detail += " \(note)" }
        if exercise.redoRequired { detail += " a refaire" }
        // L'énoncé : « valeurs propres », « Cauchy » retrouvent l'exercice
        // même quand on a oublié son numéro.
        if !exercise.statement.isEmpty { detail += " " + String(MathMarkup.plain(exercise.statement).prefix(600)) }

        var parts = ["\(course.displayCode) · \(series.displayName)"]
        if exercise.isDone {
            parts.append(exercise.isCorrected ? "corrigé" : "fait")
        } else {
            parts.append("à faire")
        }
        if let confidence = exercise.confidence { parts.append(confidence.label) }

        return SearchDocument(id: "exercise.\(exercise.id)",
                              kind: .exercise,
                              title: "Exercice \(exercise.exerciseNumber)"
                                  + (exercise.title.isEmpty ? "" : " — \(exercise.title)"),
                              subtitle: parts.joined(separator: " · "),
                              detail: detail,
                              courseCode: course.displayCode,
                              date: exercise.doneAt)
    }

    private static func theoryDocument(_ item: TheoryItem, course: Course) -> SearchDocument {
        var detail = "\(item.kind.label) \(item.number) \(item.title) \(item.summaryText ?? "")"
        if item.isWatched { detail += " vu" }
        if item.isSummarized { detail += " resume" }

        var parts = ["\(course.displayCode) · \(item.displayNumber)"]
        if item.durationSeconds > 0 {
            parts.append(DateUtils.durationLabel(seconds: item.durationSeconds))
        }
        parts.append(item.isWatched ? (item.isSummarized ? "vu et résumé" : "vu") : "à voir")

        return SearchDocument(id: "theory.\(item.id)",
                              kind: .theory,
                              title: item.title.isEmpty ? item.displayNumber : item.title,
                              subtitle: parts.joined(separator: " · "),
                              detail: detail,
                              courseCode: course.displayCode,
                              date: item.watchedAt)
    }

    /// Une annale : « midterm 2023 », « examen analyse corrigé ».
    private static func pastExamDocument(_ exam: PastExam, course: Course) -> SearchDocument {
        SearchDocument(id: "pastexam.\(exam.id)",
                       kind: .exam,
                       title: exam.title,
                       subtitle: "\(course.displayCode) · " + (exam.workedAt == nil ? "annale à faire" : "annale faite"),
                       detail: "annale \(exam.kind.label) \(exam.year) \(exam.solutionURLString.isEmpty ? "" : "corrige") \(exam.notes)",
                       courseCode: course.displayCode)
    }

    private static func examDocument(_ exam: Exam, course: Course) -> SearchDocument {
        SearchDocument(id: "exam.\(exam.id)",
                       kind: .exam,
                       title: exam.title,
                       subtitle: "\(course.displayCode) · \(DateUtils.shortDay.string(from: exam.date))"
                           + (exam.location.isEmpty ? "" : " · \(exam.location)"),
                       detail: "\(exam.kind.label) \(exam.title) \(exam.location) \(exam.notes)",
                       courseCode: course.displayCode,
                       date: exam.date)
    }

    // MARK: Hors cours

    private static func sessionDocument(_ session: StudySession) -> SearchDocument {
        var parts: [String] = []
        if let course = session.course { parts.append(course.displayCode) }
        parts.append(session.taskType.label)
        parts.append(DateUtils.shortDay.string(from: session.startedAt))
        if let target = session.targetLabel { parts.append(target) }

        return SearchDocument(id: "session.\(session.id)",
                              kind: .session,
                              title: session.note.isEmpty
                                  ? "\(DateUtils.hoursLabel(seconds: session.durationSeconds)) de travail"
                                  : session.note,
                              subtitle: parts.joined(separator: " · "),
                              detail: "\(session.note) \(session.taskType.label) \(session.targetLabel ?? "")",
                              courseCode: session.course?.displayCode,
                              date: session.startedAt)
    }

    private static func taskDocument(_ task: LinkedTask) -> SearchDocument {
        SearchDocument(id: "task.\(task.id)",
                       kind: .task,
                       title: task.title,
                       subtitle: [task.provider.label,
                                  task.dueDate.map { DateUtils.shortDay.string(from: $0) } ?? "",
                                  task.course?.displayCode ?? ""]
                                 .filter { !$0.isEmpty }
                                 .joined(separator: " · "),
                       detail: task.title,
                       courseCode: task.course?.displayCode,
                       date: task.dueDate)
    }

    private static func milestoneDocument(_ milestone: AcademicMilestone) -> SearchDocument {
        SearchDocument(id: "milestone.\(milestone.id)",
                       kind: .milestone,
                       title: milestone.title,
                       subtitle: [milestone.kind.label,
                                  DateUtils.shortDay.string(from: milestone.date),
                                  milestone.termLabel]
                                 .filter { !$0.isEmpty }
                                 .joined(separator: " · "),
                       detail: "\(milestone.title) \(milestone.notes) \(milestone.kind.label)",
                       date: milestone.date)
    }

    private static func groupDocument(_ group: StudyGroup) -> SearchDocument {
        SearchDocument(id: "group.\(group.id)",
                       kind: .group,
                       title: group.name,
                       subtitle: [group.subjectCodes.joined(separator: " · "),
                                  "\(group.members.count) membres"]
                                 .filter { !$0.isEmpty }
                                 .joined(separator: " · "),
                       detail: "\(group.name) \(group.details) \(group.subjectCodes.joined(separator: " "))",
                       courseCode: group.subjectCodes.first,
                       date: group.lastSyncedAt ?? group.createdAt)
    }
}
