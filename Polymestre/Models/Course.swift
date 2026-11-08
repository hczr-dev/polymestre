import Foundation
import SwiftData

/// Cours EPFL. Racine de la décomposition théorie / exercices.
@Model
final class Course {
    var id: UUID = UUID()
    /// Code officiel EPFL (« CS-250 »).
    var code: String = ""
    var name: String = ""
    /// Abréviation choisie par l'étudiant·e, affichée partout où la place manque
    /// (« ALGO », « Ana I »). Le code officiel reste `code`, et rien ne l'écrase.
    var shortName: String = ""
    var credits: Double = 0
    var colorHex: String = ""
    var iconName: String = ""
    var term: AcademicTerm?

    /// Heures de **cours magistral** (amphi) par semaine.
    var weeklyLectureHours: Double = 0
    /// Heures d'**exercices** (séances) par semaine.
    var weeklyExerciseHours: Double = 0

    /// Objectif de travail **personnel** hebdomadaire, en heures.
    ///
    /// `nil` = déduit de la charge ECTS : ce qui reste une fois les heures
    /// encadrées (amphi + exos) retirées. C'est ce champ qui rend l'attendu
    /// **hebdomadaire** — un total semestriel de 120 h ne se compare à rien.
    var weeklySelfStudyHours: Double?

    /// Le cours a-t-il réellement des heures de cours (amphi) ?
    ///
    /// C'est la question posée à l'étudiant·e à l'ajout d'une classe : certains
    /// cours n'ont que des séries d'exercices. Quand ce drapeau est faux, la charge
    /// attendue EPFL ne réserve aucune heure d'amphi, et le suivi de présence est masqué.
    var hasLectures: Bool = false
    /// Section EPFL du cours (« IN », « MA », …).
    var sectionCode: String = ""
    /// Cours suivi ce semestre (les autres sont archivés).
    var isTracked: Bool = false

    /// **Inutilisé** : doublon de `isTracked`, que tout l'app lit. Gardé dans
    /// le schéma (`SchemaV1`) pour ne pas imposer de migration ; à retirer avec
    /// la prochaine version du schéma.
    var isActive: Bool = false
    var lecturer: String = ""
    /// Le lien Moodle saisi à la main (formulaire du cours). Le lien d'un cours
    /// importé est dans `contentSources` ; `moodleLink` choisit.
    var moodleURLString: String = ""

    /// Le lien Moodle du cours : celui saisi à la main, sinon celui de l'import.
    var moodleLink: URL? {
        if !moodleURLString.isEmpty, let url = URL(string: moodleURLString) { return url }
        return contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .moodle }
    }
    var notes: String = ""

    /// Pages d'où le contenu du cours a été importé (Moodle, Courseware,
    /// Botafogo), une par ligne — pour « Mettre à jour depuis… » sans rechercher
    /// la page une seconde fois.
    var contentSourcesRaw: String = ""

    /// Les adresses d'éléments **écartés** à la relecture d'un import (un
    /// support qu'on ne veut pas suivre, une section décochée). La mise à jour
    /// automatique ne les réajoute pas. Une adresse par ligne.
    var contentIgnoredRaw: String = ""

    /// Les documents du cours qui ne se suivent pas — formulaire, aide-mémoire,
    /// organisation, forum — gardés comme liens (JSON de `CourseDocument`).
    var documentsRaw: String = ""

    var documents: [CourseDocument] {
        get { documentsRaw.isEmpty ? [] : CourseDocument.decodeList(documentsRaw) }
        set { documentsRaw = CourseDocument.encodeList(newValue) }
    }

    var contentIgnored: Set<String> {
        get { Set(contentIgnoredRaw.split(separator: "\n").map(String.init)) }
        set { contentIgnoredRaw = newValue.sorted().joined(separator: "\n") }
    }

    var contentSources: [String] {
        get { contentSourcesRaw.split(separator: "\n").map(String.init) }
        set { contentSourcesRaw = newValue.joined(separator: "\n") }
    }

    /// Ce qu'il faut faire chaque semaine, compris en lisant tout le cours
    /// (JSON `{"3": "Regarder…"}`) : la consigne en une phrase.
    var weekGuideRaw: String = ""

    var weekGuide: [Int: String] {
        get {
            // La plupart des cours n'en ont pas : ne pas lancer de décodeur pour rien.
            guard !weekGuideRaw.isEmpty, let data = weekGuideRaw.data(using: .utf8),
                  let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return Dictionary(raw.compactMap { key, value in Int(key).map { ($0, value) } }, uniquingKeysWith: { first, _ in first })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            weekGuideRaw = (try? JSONEncoder().encode(raw)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }

    /// La fiche de révision (JSON de `RevisionSheet`) : vide tant qu'elle
    /// n'est pas faite. Dans la base, pour suivre sur tous les appareils.
    var revisionSheetRaw: String = ""

    var revisionSheet: RevisionSheet? {
        get { RevisionSheet.decode(revisionSheetRaw) }
        set { revisionSheetRaw = newValue?.encoded() ?? "" }
    }

    /// Ce qui rend la fiche compréhensible, et à toi : liens entre les notions, où tu en es, phrases
    /// en clair, schémas, idées de ta carte mentale, ressources NotebookLM (JSON de `StudyMap`).
    /// Séparé de la fiche : une nouvelle fiche ne l'efface pas.
    var studyMapRaw: String = ""

    var studyMap: StudyMap {
        get { StudyMap.decode(studyMapRaw) ?? StudyMap() }
        set { studyMapRaw = newValue.isEmpty && newValue.enrichedAt == nil ? "" : newValue.encoded() }
    }

    @Relationship(deleteRule: .cascade, originalName: "theoryItems", inverse: \TheoryItem.course)
    var theoryItemsStore: [TheoryItem]? = []
    var theoryItems: [TheoryItem] {
        get { theoryItemsStore ?? [] }
        set { theoryItemsStore = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "series", inverse: \ExerciseSeries.course)
    var seriesStore: [ExerciseSeries]? = []
    var series: [ExerciseSeries] {
        get { seriesStore ?? [] }
        set { seriesStore = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "sessions", inverse: \StudySession.course)
    var sessionsStore: [StudySession]? = []
    var sessions: [StudySession] {
        get { sessionsStore ?? [] }
        set { sessionsStore = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "exams", inverse: \Exam.course)
    var examsStore: [Exam]? = []
    var exams: [Exam] {
        get { examsStore ?? [] }
        set { examsStore = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "pastExams", inverse: \PastExam.course)
    var pastExamsStore: [PastExam]? = []
    var pastExams: [PastExam] {
        get { pastExamsStore ?? [] }
        set { pastExamsStore = newValue }
    }

    /// Les ressources gardées sous la main (fiches-résumés, formulaires, liens).
    @Relationship(deleteRule: .cascade, inverse: \SavedResource.course)
    var savedResourcesStore: [SavedResource]? = []
    var savedResources: [SavedResource] {
        get { savedResourcesStore ?? [] }
        set { savedResourcesStore = newValue }
    }

    /// Épinglées d'abord, puis les plus récentes.
    var sortedResources: [SavedResource] {
        savedResources.sorted { ($0.isPinned ? 0 : 1, $1.addedAt) < ($1.isPinned ? 0 : 1, $0.addedAt) }
    }

    @Relationship(deleteRule: .cascade, originalName: "linkedTasks", inverse: \LinkedTask.course)
    var linkedTasksStore: [LinkedTask]? = []
    var linkedTasks: [LinkedTask] {
        get { linkedTasksStore ?? [] }
        set { linkedTasksStore = newValue }
    }

    /// Les sessions de groupe prévues pour ce cours. Inverse de
    /// `PlannedSession.course`, exigé par iCloud.
    @Relationship(deleteRule: .nullify, inverse: \PlannedSession.course)
    var plannedSessionsStore: [PlannedSession]? = []

    @Relationship(deleteRule: .cascade, originalName: "linkedEvents", inverse: \LinkedCalendarEvent.course)
    var linkedEventsStore: [LinkedCalendarEvent]? = []
    var linkedEvents: [LinkedCalendarEvent] {
        get { linkedEventsStore ?? [] }
        set { linkedEventsStore = newValue }
    }

    init(id: UUID = UUID(),
         code: String,
         name: String,
         shortName: String = "",
         credits: Double = 4,
         colorHex: String = "#4F46E5",
         iconName: String = "book.closed.fill",
         term: AcademicTerm? = nil,
         weeklyLectureHours: Double = 2,
         weeklyExerciseHours: Double = 1,
         weeklySelfStudyHours: Double? = nil,
         hasLectures: Bool = true,
         sectionCode: String = "",
         isTracked: Bool = true,
         lecturer: String = "",
         moodleURLString: String = "",
         notes: String = "") {
        self.id = id
        self.code = code
        self.name = name
        self.shortName = shortName
        self.credits = credits
        self.colorHex = colorHex
        self.iconName = iconName
        self.term = term
        self.weeklyLectureHours = weeklyLectureHours
        self.weeklyExerciseHours = weeklyExerciseHours
        self.weeklySelfStudyHours = weeklySelfStudyHours
        self.hasLectures = hasLectures
        self.sectionCode = sectionCode
        self.isTracked = isTracked
        self.lecturer = lecturer
        self.moodleURLString = moodleURLString
        self.notes = notes
    }

    // MARK: Convenience

    /// Ce qu'on affiche partout où la place manque : l'abréviation si l'étudiant·e
    /// en a défini une, sinon le code officiel. Le libellé complet reste `name`.
    var displayCode: String {
        let trimmed = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? code : trimmed
    }

    var sortedTheoryItems: [TheoryItem] {
        theoryItems.sorted { lhs, rhs in
            if lhs.sectionNumber != rhs.sectionNumber { return lhs.sectionNumber < rhs.sectionNumber }
            return lhs.number.localizedStandardCompare(rhs.number) == .orderedAscending
        }
    }

    var sortedSeries: [ExerciseSeries] {
        series.sorted { $0.key < $1.key }
    }

    /// La série de ce numéro et de cette étiquette.
    ///
    /// Sans série à cette étiquette exacte, une étiquette **apparue** (la série
    /// enregistrée sans, relue avec « mardi ») retrouve la série de même numéro
    /// qui n'en avait pas — pourvu que `soleOfNumber` dise que la source n'en a
    /// qu'une à ce numéro. Sans quoi chaque nouvelle lecture créerait un double.
    func series(number: Int, label: String = "", soleOfNumber: Bool = true) -> ExerciseSeries? {
        let key = SeriesIdentity.Key(number, label)
        if let exact = series.first(where: { $0.key == key }) { return exact }
        guard soleOfNumber else { return nil }
        let same = series.filter { $0.seriesNumber == number }
        if key.label.isEmpty { return same.count == 1 ? same[0] : nil }
        return same.first { $0.label.isEmpty }
    }

    /// Sections de théorie présentes.
    var theorySections: [Int] {
        Array(Set(theoryItems.map(\.sectionNumber))).sorted()
    }

    var allExercises: [Exercise] { series.flatMap(\.exercises) }

    var sortedExams: [Exam] { exams.sorted { $0.date < $1.date } }

    /// Annales, de la plus récente à la plus ancienne — l'ordre dans lequel on les
    /// travaille.
    var sortedPastExams: [PastExam] {
        pastExams.sorted { lhs, rhs in
            if lhs.year != rhs.year { return lhs.year > rhs.year }
            return lhs.addedAt > rhs.addedAt
        }
    }

    var nextExam: Exam? { sortedExams.first { $0.date >= Date() } }

    /// La prochaine **vraie** épreuve (midterm ou examen) : ni un quiz, ni un devoir,
    /// ni une échéance importée de Moodle. C'est elle qui déclenche la révision.
    var nextSitting: Exam? { sortedExams.first { $0.date >= Date() && $0.kind.isSitting } }

    /// Semaine courante, bornée à la durée du semestre.
    ///
    /// Bornée volontairement : un semestre importé dont la date de début est loin
    /// dans le passé ne doit pas produire une « semaine 47 » qui vide tous les écrans.
    ///
    /// Sans semestre rattaché, on retombe sur le calendrier académique réel plutôt
    /// que sur `1`. Renvoyer « semaine 1 » était faux et invisible : l'étudiant·e
    /// voyait « 1 / 14 » en pleine semaine 2, sans aucun moyen de comprendre
    /// pourquoi. Le rattachement est fait à l'import et réparé au lancement
    /// (`AcademicTerm.attachOrphanCourses`) ; ceci n'est qu'un dernier filet.
    var currentWeek: Int {
        guard let term else {
            let fallback = DateUtils.currentAutumnOrSpringStart()
            let week = DateUtils.weekNumber(from: fallback.start)
            return min(max(week, 1), max(fallback.weeks, 1))
        }
        return DateUtils.clampedWeek(for: Date(), term: term)
    }

    /// La semaine qui décide de ce qui est **dû**, non bornée.
    ///
    /// `currentWeek` s'arrête à la dernière semaine pour l'affichage ; pour le
    /// retard, cette borne gardait la dernière semaine « en cours » toute la
    /// session d'examens, et rien de ce qu'elle prévoyait ne devenait dû.
    func dueWeek(at date: Date = Date()) -> Int {
        guard let term else { return currentWeek }
        return max(1, DateUtils.weekNumber(for: date, term: term))
    }

    /// Le semestre de ce cours est-il en cours ?
    var isTermRunning: Bool {
        guard let term else { return true }
        return term.isRunning
    }

}
