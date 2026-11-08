import Foundation

/// Produit un instantané de l'état d'étude, lisible par un **assistant**.
///
/// C'est la source du serveur MCP (`mcp/`). Le format est volontairement plat et
/// documenté : un assistant doit pouvoir le lire sans rien connaître de SwiftData,
/// et sans qu'on ait à maintenir un schéma binaire.
///
/// Ce que l'export contient — et ce qu'il ne contient **pas** est un choix : les
/// notes de correction et les résumés y sont (ils servent à réviser), mais aucune
/// donnée de compte, aucun jeton, aucune adhésion de groupe. Un fichier qu'on
/// partage ne doit pas transporter d'identités.
enum AssistantExport {

    static let fileName = "polymestre-assistant.json"
    /// v2 : identifiants partout (cours, séries, exercices, questions,
    /// théorie, sessions) et étape de chaque exercice — un assistant qui
    /// **agit** doit désigner exactement ce qu'il modifie.
    /// v3 : sur demande (`includeContent`), les notes, la fiche de révision, les
    /// corrigés rédigés, les adresses des séries et la liste des fichiers que
    /// l'app envoie. Sans demande, le format est celui de la v2 (plus `sharing`).
    static let formatVersion = 3

    /// Au-delà, un texte est tronqué : l'instantané voyage à chaque synchronisation.
    static let notesLimit = 60_000
    static let sheetLimit = 120_000
    static let solutionLimit = 6_000

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n\n[…tronqué]" : text
    }

    /// Construit l'instantané.
    ///
    /// - Parameters:
    ///   - includeContent: ajoute les notes, la fiche, les corrigés rédigés et les
    ///     adresses (réglage « Fichiers et notes »).
    ///   - files: l'index des fichiers que l'app enverra (`AssistantFiles`) ;
    ///     ignoré sans `includeContent`.
    static func make(courses: [Course],
                     sessions: [StudySession],
                     milestones: [AcademicMilestone],
                     groups: [StudyGroup],
                     hoursPerCredit: Double,
                     displayName: String,
                     includeContent: Bool = false,
                     files: [[String: Any]] = []) -> [String: Any] {
        let tracked = courses.filter(\.isTracked)

        var payload: [String: Any] = [
            "format": "polymestre.assistant",
            "version": formatVersion,
            "generatedAt": ISO8601DateFormatter().string(from: Date())
        ]

        payload["settings"] = [
            "hoursPerCredit": hoursPerCredit,
            "displayName": displayName
        ]

        payload["sharing"] = ["files": includeContent]
        if includeContent { payload["files"] = files }

        payload["courses"] = tracked.map { course in
            coursePayload(course, includeContent: includeContent)
        }

        payload["sessions"] = sessions.prefix(2000).map { session in
            var entry: [String: Any] = [
                "id": session.id.uuidString,
                "taskType": session.taskTypeRaw,
                "startedAt": ISO8601DateFormatter().string(from: session.startedAt),
                "durationSeconds": session.durationSeconds,
                "manual": session.isManual
            ]
            if let course = session.course { entry["course"] = course.displayCode }
            if let target = session.targetLabel { entry["target"] = target }
            if let exercise = session.exercise { entry["exerciseId"] = exercise.id.uuidString }
            if let item = session.theoryItem { entry["theoryId"] = item.id.uuidString }
            if !session.sourceRaw.isEmpty { entry["source"] = session.sourceRaw }
            if !session.note.isEmpty { entry["note"] = session.note }
            return entry
        }

        payload["calendar"] = milestones.map { milestone in
            [
                "title": milestone.title,
                "date": ISO8601DateFormatter().string(from: milestone.date),
                "kind": milestone.kindRaw,
                "approximate": milestone.isApproximate,
                "term": milestone.termLabel
            ]
        }

        payload["groups"] = groups.map { group in
            [
                "name": group.name,
                "subjects": group.subjectCodes,
                "members": group.members.count
            ]
        }

        return payload
    }

    /// L'instantané sérialisé, prêt à être partagé.
    static func data(courses: [Course],
                     sessions: [StudySession],
                     milestones: [AcademicMilestone],
                     groups: [StudyGroup],
                     hoursPerCredit: Double,
                     displayName: String) -> Data? {
        let payload = make(courses: courses,
                           sessions: sessions,
                           milestones: milestones,
                           groups: groups,
                           hoursPerCredit: hoursPerCredit,
                           displayName: displayName)
        return try? JSONSerialization.data(withJSONObject: payload,
                                           options: [.prettyPrinted, .sortedKeys])
    }

    private static func coursePayload(_ course: Course, includeContent: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "id": course.id.uuidString,
            "code": course.displayCode,
            "officialCode": course.code,
            "name": course.name,
            "credits": course.credits,
            "hasLectures": course.hasLectures,
            "weeklyLectureHours": course.weeklyLectureHours,
            "weeklyExerciseHours": course.weeklyExerciseHours,
            "currentWeek": course.currentWeek
        ]
        if let term = course.term {
            payload["term"] = term.displayName
            payload["termWeeks"] = term.totalWeeks
        }
        if !course.lecturer.isEmpty { payload["lecturer"] = course.lecturer }

        payload["series"] = course.sortedSeries.map { series in
            var seriesEntry: [String: Any] = [
                "id": series.id.uuidString,
                "number": series.seriesNumber,
                "title": series.title,
                "plannedWeek": series.plannedWeek,
                "complete": series.isComplete,
            ]
            if !series.label.isEmpty { seriesEntry["label"] = series.label }
            if includeContent {
                if !series.urlString.isEmpty { seriesEntry["url"] = series.urlString }
                if !series.solutionURLString.isEmpty { seriesEntry["solutionUrl"] = series.solutionURLString }
                if !series.topic.isEmpty { seriesEntry["topic"] = series.topic }
            }
            seriesEntry["exercises"] = series.sortedExercises.map { exercise in
                var entry: [String: Any] = [
                    "id": exercise.id.uuidString,
                    "number": exercise.exerciseNumber,
                    "title": exercise.title,
                    "stage": ExerciseStage(exercise).label,
                    "bonus": exercise.isBonus,
                    "done": exercise.isDone,
                    "corrected": exercise.isCorrected,
                    "redo": exercise.redoRequired
                ]
                if let correctness = exercise.correctness { entry["correctness"] = correctness.rawValue }
                if let note = exercise.correctionNote, !note.isEmpty { entry["correctionNote"] = note }
                if !exercise.statement.isEmpty { entry["statement"] = exercise.statement }
                if includeContent {
                    if !exercise.solution.isEmpty { entry["solution"] = clip(exercise.solution, solutionLimit) }
                    if !exercise.hint.isEmpty { entry["hint"] = exercise.hint }
                }
                if exercise.hasSubQuestions {
                    entry["questions"] = exercise.leafSubQuestions.map { question in
                        [
                            "path": question.path,
                            "label": question.parent.map { "\($0.displayLabel) \(question.displayLabel)" } ?? question.displayLabel,
                            "text": question.text,
                            "done": question.isDone
                        ] as [String: Any]
                    }
                }
                return entry
            }
            return seriesEntry
        }

        payload["theory"] = course.sortedTheoryItems.map { item in
            var entry: [String: Any] = [
                "id": item.id.uuidString,
                "number": item.number,
                "title": item.title,
                "kind": item.kindRaw,
                "watched": item.isWatched,
                "summarized": item.isSummarized,
                "plannedWeek": item.plannedWeek
            ]
            if item.durationSeconds > 0 { entry["durationSeconds"] = item.durationSeconds }
            if let summary = item.summaryText, !summary.isEmpty { entry["summary"] = summary }
            return entry
        }

        payload["exams"] = course.sortedExams.map { exam in
            var entry: [String: Any] = [
                "id": exam.id.uuidString,
                "title": exam.title,
                "kind": exam.kindRaw,
                "date": ISO8601DateFormatter().string(from: exam.date),
                "past": exam.isPast
            ]
            if let weight = exam.weightPercent { entry["weightPercent"] = weight }
            if !exam.location.isEmpty { entry["location"] = exam.location }
            return entry
        }

        if includeContent {
            if !course.notes.isEmpty { payload["notes"] = clip(course.notes, notesLimit) }
            if let sheet = course.revisionSheet {
                let text = NotebookExport.sheetText(courseName: course.name, sheet: sheet, map: course.studyMap)
                if !text.isEmpty { payload["revisionSheet"] = clip(text, sheetLimit) }
            }
            if !course.documents.isEmpty {
                payload["documents"] = course.documents.map { document in
                    ["title": document.title, "url": document.url, "group": document.group] as [String: Any]
                }
            }
            payload["pastExams"] = course.pastExams.map { exam in
                var entry: [String: Any] = [
                    "id": exam.id.uuidString,
                    "title": exam.title,
                    "year": exam.year,
                    "kind": exam.kindRaw
                ]
                if !exam.urlString.isEmpty { entry["url"] = exam.urlString }
                if !exam.solutionURLString.isEmpty { entry["solutionUrl"] = exam.solutionURLString }
                if !exam.notes.isEmpty { entry["notes"] = clip(exam.notes, notesLimit) }
                return entry
            }
            payload["resources"] = course.sortedResources.map { resource in
                var entry: [String: Any] = [
                    "id": resource.id.uuidString,
                    "title": resource.title,
                    "kind": resource.kindRaw
                ]
                if !resource.address.isEmpty { entry["address"] = resource.address }
                if !resource.fileName.isEmpty { entry["fileName"] = resource.fileName }
                return entry
            }
        }

        return payload
    }
}
