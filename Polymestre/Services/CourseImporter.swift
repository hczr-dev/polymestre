import Foundation
import SwiftData

// MARK: - Spécifications décodées (JSON)

struct CourseImportPayload: Codable {
    var term: TermSpec?
    var courses: [CourseSpec]
    /// Sessions de travail — présentes dans une **sauvegarde** de l'app, jamais
    /// dans un import de structure. Restaurées telles quelles.
    var sessions: [SessionSpec]?

    init(term: TermSpec? = nil, courses: [CourseSpec], sessions: [SessionSpec]? = nil) {
        self.term = term
        self.courses = courses
        self.sessions = sessions
    }
}

/// Une session de travail dans une sauvegarde.
struct SessionSpec: Codable {
    var courseCode: String?
    var taskType: String
    var startedAt: String
    var durationSeconds: Int
    var isManual: Bool?
    var note: String?
    /// Cible précise, quand la session en avait une.
    var exerciseNumber: String?
    var theoryNumber: String?
}

struct TermSpec: Codable {
    var year: Int
    var season: String
    var startDate: String
    var endDate: String
    var totalWeeks: Int?
    var name: String?
}

struct CourseSpec: Codable {
    var code: String
    var name: String
    var shortName: String?
    var credits: Double?
    var weeklySelfStudyHours: Double?
    var isTracked: Bool?
    var weeklyLectureHours: Double?
    var weeklyExerciseHours: Double?
    var hasLectures: Bool?
    var sectionCode: String?
    var colorHex: String?
    var lecturer: String?
    var moodleURL: String?
    var videos: [VideoSpec]?
    var series: [SeriesSpec]?
    var exams: [ExamSpec]?
}

struct VideoSpec: Codable {
    var section: Int?
    var number: String
    var title: String?
    /// `video`, `reading`, `chapter` ou `slides` — vidéo par défaut.
    var kind: String?
    var durationSeconds: Int?
    var week: Int?
    var url: String?
    // Avancement — uniquement dans une sauvegarde.
    var watchedAt: String?
    var summarizedAt: String?
    var summaryText: String?
}

struct SeriesSpec: Codable {
    var number: Int
    var title: String?
    var week: Int?
    var url: String?
    var exercises: [ExerciseSpec]?
}

struct ExerciseSpec: Codable {
    var number: String
    var title: String?
    var isBonus: Bool?
    // Avancement — uniquement dans une sauvegarde.
    var doneAt: String?
    var confidence: String?
    var correctedAt: String?
    var correctness: String?
    var redoRequired: Bool?
    var correctionNote: String?
    var score: Double?
    var maxScore: Double?
}

struct ExamSpec: Codable {
    var kind: String?
    var title: String?
    var date: String
    var weightPercent: Double?
    var location: String?
}

/// Résultat d'un import.
struct ImportSummary: Equatable {
    var coursesCreated = 0
    var coursesUpdated = 0
    var videos = 0
    var series = 0
    var exercises = 0
    var exams = 0
    var sessions = 0

    var message: String {
        var parts: [String] = []
        if coursesCreated > 0 { parts.append("\(coursesCreated) cours créé(s)") }
        if coursesUpdated > 0 { parts.append("\(coursesUpdated) cours mis à jour") }
        if videos > 0 { parts.append("\(videos) éléments de théorie") }
        if series > 0 { parts.append("\(series) séries") }
        if exercises > 0 { parts.append("\(exercises) exercices") }
        if exams > 0 { parts.append("\(exams) évaluations") }
        if sessions > 0 { parts.append("\(sessions) sessions") }
        return parts.isEmpty ? "Aucune donnée importée." : parts.joined(separator: " · ")
    }
}

// MARK: - Import

/// Importe une structure de cours depuis un JSON ou un CSV.
///
/// L'import est **idempotent** : les cours sont retrouvés par leur code, les vidéos
/// par `numéro`, les séries par `numéro`, les exercices par `numéro`.
enum CourseImporter {

    enum ImportError: LocalizedError {
        case invalidJSON(String)
        case emptyCourses
        case invalidCSV(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let detail): return "JSON invalide : \(detail)"
            case .emptyCourses: return "Le fichier ne contient aucun cours."
            case .invalidCSV(let detail): return "CSV invalide : \(detail)"
            }
        }
    }

    // MARK: JSON

    @discardableResult
    static func importJSON(_ text: String, into context: ModelContext,
                           sectionCode: String = "") throws -> ImportSummary {
        guard let data = text.data(using: .utf8) else {
            throw ImportError.invalidJSON("encodage UTF-8 impossible")
        }
        let payload: CourseImportPayload
        do {
            payload = try JSONDecoder().decode(CourseImportPayload.self, from: data)
        } catch {
            throw ImportError.invalidJSON(error.localizedDescription)
        }
        return try importPayload(payload, into: context, sectionCode: sectionCode)
    }

    // MARK: CSV

    /// CSV attendu (une ligne par élément, en-tête obligatoire) :
    ///
    /// ```
    /// course_code,course_name,credits,kind,number,title,duration_seconds,week,is_bonus,date,weight,location
    /// CS-250,Algorithms I,6,video,1.1,Introduction,2700,1,,,,,
    /// CS-250,Algorithms I,6,exercise,1.1,,,1,false,,,,
    /// CS-250,Algorithms I,6,exam,midterm,Midterm,,,2025-03-28T08:00:00Z,30,SG1
    /// ```
    ///
    /// `kind` vaut `video`, `exercise` ou `exam`. Pour un exercice, la série est
    /// déduite du préfixe du numéro (`2.3` → série 2).
    ///
    /// Chaque ligne doit contenir **toutes** les colonnes de l'en-tête : une colonne
    /// vide s'écrit par deux virgules consécutives. Une ligne plus courte décale les
    /// valeurs suivantes.
    @discardableResult
    static func importCSV(_ text: String, into context: ModelContext,
                          sectionCode: String = "") throws -> ImportSummary {
        let rows = try parseCSV(text)
        guard let header = rows.first else { throw ImportError.invalidCSV("fichier vide") }

        let columns = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func index(_ name: String) -> Int? { columns.firstIndex(of: name) }

        guard let codeIndex = index("course_code") else {
            throw ImportError.invalidCSV("colonne « course_code » manquante")
        }
        guard let kindIndex = index("kind") else {
            throw ImportError.invalidCSV("colonne « kind » manquante")
        }

        let nameIndex = index("course_name")
        let creditsIndex = index("credits")
        let numberIndex = index("number")
        let titleIndex = index("title")
        let durationIndex = index("duration_seconds")
        let weekIndex = index("week")
        let bonusIndex = index("is_bonus")
        let dateIndex = index("date")
        let weightIndex = index("weight")
        let locationIndex = index("location")
        let lectureHoursIndex = index("weekly_lecture_hours")
        let exerciseHoursIndex = index("weekly_exercise_hours")

        struct CourseAccumulator {
            var name: String
            var credits: Double
            var lectureHours: Double
            var exerciseHours: Double
            var videos: [VideoSpec] = []
            var series: [Int: SeriesSpec] = [:]
            var exams: [ExamSpec] = []
        }

        var order: [String] = []
        var accumulators: [String: CourseAccumulator] = [:]

        for row in rows.dropFirst() {
            guard row.count > max(codeIndex, kindIndex) else { continue }
            let code = row[codeIndex].trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else { continue }

            func value(_ idx: Int?) -> String {
                guard let idx, idx < row.count else { return "" }
                return row[idx].trimmingCharacters(in: .whitespaces)
            }

            if accumulators[code] == nil {
                order.append(code)
                accumulators[code] = CourseAccumulator(
                    name: value(nameIndex).isEmpty ? code : value(nameIndex),
                    credits: Double(value(creditsIndex)) ?? 4,
                    lectureHours: Double(value(lectureHoursIndex)) ?? 2,
                    exerciseHours: Double(value(exerciseHoursIndex)) ?? 1
                )
            }

            let kind = row[kindIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let number = value(numberIndex)

            switch kind {
            case "video":
                guard !number.isEmpty else { continue }
                let section = Int(number.split(separator: ".").first ?? "1") ?? 1
                accumulators[code]?.videos.append(VideoSpec(
                    section: section,
                    number: number,
                    title: value(titleIndex).isEmpty ? nil : value(titleIndex),
                    durationSeconds: Int(value(durationIndex)),
                    week: Int(value(weekIndex)),
                    url: nil))

            case "exercise":
                guard !number.isEmpty else { continue }
                let seriesNumber = Int(number.split(separator: ".").first ?? "1") ?? 1
                var series = accumulators[code]?.series[seriesNumber]
                    ?? SeriesSpec(number: seriesNumber,
                                  title: "Série \(seriesNumber)",
                                  week: Int(value(weekIndex)) ?? seriesNumber,
                                  url: nil,
                                  exercises: [])
                var exercises = series.exercises ?? []
                exercises.append(ExerciseSpec(number: number,
                                              title: value(titleIndex).isEmpty ? nil : value(titleIndex),
                                              isBonus: ["true", "1", "yes", "oui", "vrai"].contains(value(bonusIndex).lowercased())))
                series.exercises = exercises
                accumulators[code]?.series[seriesNumber] = series

            case "exam", "evaluation", "évaluation":
                let dateString = value(dateIndex)
                guard !dateString.isEmpty else { continue }
                accumulators[code]?.exams.append(ExamSpec(
                    kind: number.isEmpty ? "exam" : number,
                    title: value(titleIndex).isEmpty ? nil : value(titleIndex),
                    date: dateString,
                    weightPercent: Double(value(weightIndex)),
                    location: value(locationIndex).isEmpty ? nil : value(locationIndex)))

            default:
                continue
            }
        }

        guard !order.isEmpty else { throw ImportError.emptyCourses }

        let specs = order.compactMap { code -> CourseSpec? in
            guard let accumulator = accumulators[code] else { return nil }
            return CourseSpec(code: code,
                              name: accumulator.name,
                              shortName: nil,
                              credits: accumulator.credits,
                              weeklySelfStudyHours: nil,
                              isTracked: nil,
                              weeklyLectureHours: accumulator.lectureHours,
                              weeklyExerciseHours: accumulator.exerciseHours,
                              hasLectures: nil,
                              sectionCode: nil,
                              colorHex: nil,
                              lecturer: nil,
                              moodleURL: nil,
                              videos: accumulator.videos.isEmpty ? nil : accumulator.videos,
                              series: accumulator.series.isEmpty ? nil : accumulator.series.keys.sorted().compactMap { accumulator.series[$0] },
                              exams: accumulator.exams.isEmpty ? nil : accumulator.exams)
        }

        return try importPayload(CourseImportPayload(term: nil, courses: specs),
                                 into: context,
                                 sectionCode: sectionCode)
    }

    // MARK: - Cœur

    @discardableResult
    static func importPayload(_ payload: CourseImportPayload,
                              into context: ModelContext,
                              sectionCode: String = "") throws -> ImportSummary {
        guard !payload.courses.isEmpty else { throw ImportError.emptyCourses }

        var summary = ImportSummary()
        let term = resolveTerm(payload.term, context: context)

        for spec in payload.courses {
            let existing = try? context.fetch(
                FetchDescriptor<Course>(predicate: #Predicate { $0.code == spec.code })
            ).first

            let course: Course
            if let existing {
                course = existing
                summary.coursesUpdated += 1
            } else {
                course = Course(code: spec.code,
                                name: spec.name,
                                credits: spec.credits ?? 4,
                                colorHex: spec.colorHex ?? Theme.coursePalette[abs(spec.code.hashValue) % Theme.coursePalette.count],
                                term: term,
                                weeklyLectureHours: spec.weeklyLectureHours ?? 2,
                                weeklyExerciseHours: spec.weeklyExerciseHours ?? 1,
                                hasLectures: spec.hasLectures ?? true,
                                sectionCode: spec.sectionCode ?? sectionCode)
                context.insert(course)
                summary.coursesCreated += 1
            }

            course.name = spec.name
            if let shortName = spec.shortName { course.shortName = shortName }
            if let credits = spec.credits { course.credits = credits }
            if let selfStudy = spec.weeklySelfStudyHours { course.weeklySelfStudyHours = selfStudy }
            if let tracked = spec.isTracked { course.isTracked = tracked }
            if let lecture = spec.weeklyLectureHours { course.weeklyLectureHours = lecture }
            if let exercise = spec.weeklyExerciseHours { course.weeklyExerciseHours = exercise }
            if let hasLectures = spec.hasLectures { course.hasLectures = hasLectures }
            if let specSection = spec.sectionCode, !specSection.isEmpty { course.sectionCode = specSection }
            else if !sectionCode.isEmpty, course.sectionCode.isEmpty { course.sectionCode = sectionCode }
            if let color = spec.colorHex { course.colorHex = color }
            if let lecturer = spec.lecturer { course.lecturer = lecturer }
            if let link = spec.moodleURL { course.moodleURLString = link }
            if course.term == nil { course.term = term }

            summary.videos += upsertVideos(spec.videos ?? [], into: course, context: context)
            let seriesResult = upsertSeries(spec.series ?? [], into: course, context: context)
            summary.series += seriesResult.series
            summary.exercises += seriesResult.exercises
            summary.exams += upsertExams(spec.exams ?? [], into: course, context: context)
        }

        summary.sessions = restoreSessions(payload.sessions ?? [], context: context)

        try? context.save()
        return summary
    }

    /// Restaure les sessions d'une sauvegarde, sans doublon.
    ///
    /// Une session est identifiée par (début, durée, cours) : réimporter deux fois
    /// la même sauvegarde ne double pas le temps de travail.
    private static func restoreSessions(_ specs: [SessionSpec], context: ModelContext) -> Int {
        guard !specs.isEmpty else { return 0 }
        let courses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
        let existing = (try? context.fetch(FetchDescriptor<StudySession>())) ?? []
        var known = Set(existing.map { sessionKey($0.startedAt, $0.durationSeconds, $0.course?.code) })
        var count = 0
        for spec in specs {
            guard let start = DateUtils.parse(spec.startedAt), spec.durationSeconds > 0 else { continue }
            let key = sessionKey(start, spec.durationSeconds, spec.courseCode)
            guard known.insert(key).inserted else { continue }
            let course = spec.courseCode.flatMap { code in courses.first { $0.code == code } }
            let exercise = spec.exerciseNumber.flatMap { number in
                course?.allExercises.first { $0.exerciseNumber == number }
            }
            let theory = spec.theoryNumber.flatMap { number in
                course?.theoryItems.first { $0.number == number }
            }
            let session = StudySession(course: course,
                                       taskType: TaskType(rawValue: spec.taskType) ?? .other,
                                       startedAt: start,
                                       durationSeconds: spec.durationSeconds,
                                       isManual: spec.isManual ?? true,
                                       note: spec.note ?? "",
                                       exercise: exercise,
                                       theoryItem: theory)
            context.insert(session)
            count += 1
        }
        return count
    }

    private static func sessionKey(_ start: Date, _ seconds: Int, _ code: String?) -> String {
        "\(Int(start.timeIntervalSince1970))|\(seconds)|\(code ?? "-")"
    }

    // MARK: - Analyse CSV

    /// Analyseur CSV minimal gérant les champs entre guillemets et les virgules internes.
    static func parseCSV(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if inQuotes {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n":
                    row.append(field)
                    field = ""
                    if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        rows.append(row)
                    }
                    row = []
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }
            index = text.index(after: index)
        }

        row.append(field)
        if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            rows.append(row)
        }
        return rows
    }

    // MARK: - Helpers

    private static func resolveTerm(_ spec: TermSpec?, context: ModelContext) -> AcademicTerm {
        let year = spec?.year ?? Calendar.current.component(.year, from: Date())
        let seasonRaw = spec?.season ?? "spring"
        let season = TermSeason(rawValue: seasonRaw) ?? .spring

        if let existing = try? context.fetch(FetchDescriptor<AcademicTerm>()).first(where: {
            $0.year == year && $0.seasonRaw == season.rawValue
        }) {
            return existing
        }

        let start = spec.flatMap { DateUtils.parse($0.startDate) }
            // Le semestre commence **cette semaine** par défaut. Le régler à
            // « il y a deux semaines » affichait « Semaine 3 » à quelqu'un dont
            // le semestre venait de commencer : le numéro en découle directement.
            ?? DateUtils.currentAutumnOrSpringStart().start
        let end = spec.flatMap { DateUtils.parse($0.endDate) }
            ?? DateUtils.addWeeks(14, to: start)
        let term = AcademicTerm(year: year,
                                season: season,
                                startDate: start,
                                endDate: end,
                                totalWeeks: spec?.totalWeeks ?? 14,
                                name: spec?.name ?? "")
        context.insert(term)
        return term
    }

    private static func upsertVideos(_ specs: [VideoSpec],
                                     into course: Course,
                                     context: ModelContext) -> Int {
        var count = 0
        var order = course.theoryItems.count
        for spec in specs {
            let kind = spec.kind.flatMap(TheoryKind.init(rawValue:))
            if let existing = course.theoryItems.first(where: { $0.number == spec.number }) {
                existing.title = spec.title ?? existing.title
                if let kind { existing.kind = kind }
                if let duration = spec.durationSeconds { existing.durationSeconds = duration }
                if let week = spec.week { existing.plannedWeek = week }
                if let url = spec.url { existing.urlString = url }
                applyProgress(spec, to: existing)
                continue
            }
            let section = spec.section ?? Int(spec.number.split(separator: ".").first ?? "1") ?? 1
            let video = TheoryItem(course: course,
                                    sectionNumber: section,
                                    number: spec.number,
                                    title: spec.title ?? "",
                                    kind: kind ?? .video,
                                    durationSeconds: spec.durationSeconds ?? 0,
                                    plannedWeek: spec.week ?? 0,  // sans semaine : 0, pas la semaine 1 (en retard dès la 2)
                                    sortOrder: order,
                                    urlString: spec.url ?? "")
            context.insert(video)
            applyProgress(spec, to: video)
            order += 1
            count += 1
        }
        return count
    }

    private static func upsertSeries(_ specs: [SeriesSpec],
                                     into course: Course,
                                     context: ModelContext) -> (series: Int, exercises: Int) {
        var seriesCount = 0
        var exerciseCount = 0
        for spec in specs {
            let series: ExerciseSeries
            if let existing = course.series.first(where: { $0.seriesNumber == spec.number }) {
                series = existing
                if let title = spec.title { series.title = title }
                if let week = spec.week { series.plannedWeek = week }
                if let url = spec.url { series.urlString = url }
            } else {
                series = ExerciseSeries(course: course,
                                        seriesNumber: spec.number,
                                        title: spec.title ?? "Série \(spec.number)",
                                        plannedWeek: spec.week ?? 0,  // sans semaine : 0, pas la semaine 1 (en retard dès la 2)
                                        urlString: spec.url ?? "")
                context.insert(series)
                seriesCount += 1
            }

            for (index, exerciseSpec) in (spec.exercises ?? []).enumerated() {
                if let existing = series.exercises.first(where: { $0.exerciseNumber == exerciseSpec.number }) {
                    if let title = exerciseSpec.title { existing.title = title }
                    if let bonus = exerciseSpec.isBonus { existing.isBonus = bonus }
                    applyProgress(exerciseSpec, to: existing)
                    continue
                }
                let exercise = Exercise(series: series,
                                        exerciseNumber: exerciseSpec.number,
                                        title: exerciseSpec.title ?? "",
                                        isBonus: exerciseSpec.isBonus ?? false,
                                        sortOrder: index)
                context.insert(exercise)
                applyProgress(exerciseSpec, to: exercise)
                exerciseCount += 1
            }
        }
        return (seriesCount, exerciseCount)
    }

    /// L'avancement d'une sauvegarde. Un import de structure n'en porte pas : rien
    /// n'est touché, et un import ne remet jamais un élément à « non fait ».
    private static func applyProgress(_ spec: VideoSpec, to item: TheoryItem) {
        if let raw = spec.watchedAt, let date = DateUtils.parse(raw) { item.watchedAt = date }
        if let raw = spec.summarizedAt, let date = DateUtils.parse(raw) { item.summarizedAt = date }
        if let text = spec.summaryText, !text.isEmpty { item.summaryText = text }
    }

    private static func applyProgress(_ spec: ExerciseSpec, to exercise: Exercise) {
        if let raw = spec.doneAt, let date = DateUtils.parse(raw) { exercise.doneAt = date }
        if let raw = spec.confidence, let level = ConfidenceLevel(rawValue: raw) { exercise.confidence = level }
        if let raw = spec.correctedAt, let date = DateUtils.parse(raw) { exercise.correctedAt = date }
        if let raw = spec.correctness, let value = Correctness(rawValue: raw) { exercise.correctness = value }
        if let redo = spec.redoRequired { exercise.redoRequired = redo }
        if let note = spec.correctionNote, !note.isEmpty { exercise.correctionNote = note }
        if let score = spec.score { exercise.score = score }
        if let maxScore = spec.maxScore { exercise.maxScore = maxScore }
    }

    private static func upsertExams(_ specs: [ExamSpec],
                                    into course: Course,
                                    context: ModelContext) -> Int {
        var count = 0
        for spec in specs {
            guard let date = DateUtils.parse(spec.date) else { continue }
            let kind = ExamKind(rawValue: spec.kind ?? "exam") ?? .exam
            if course.exams.contains(where: { $0.kind == kind && abs($0.date.timeIntervalSince(date)) < 3600 }) {
                continue
            }
            let exam = Exam(course: course,
                            kind: kind,
                            title: spec.title ?? kind.label,
                            date: date,
                            weightPercent: spec.weightPercent,
                            location: spec.location ?? "")
            context.insert(exam)
            count += 1
        }
        return count
    }
}
