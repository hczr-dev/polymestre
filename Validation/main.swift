import Foundation
import SwiftData
import PDFKit
import CryptoKit

// Stub minimal : remplace App/SettingsStore.swift pour la validation hors app iOS.
final class SettingsStore {
    var hasSeededSampleData = false
}

var failures = 0

/// Efface un domaine de préférences jetable, fichier compris : `removePersistentDomain`
/// seul laisse le `.plist` dans ~/Library/Preferences.
func dropSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: file)
}

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ✅ \(label)")
    } else {
        print("  ❌ \(label)")
        failures += 1
    }
}

func pct(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

// Le conteneur de test utilise le schéma **de l'app**, pas une copie :
// c'est ce qui garantit que le test porte sur la vraie définition.
let schema = PolymestreSchema.current

print("== Conteneur SwiftData (en mémoire) ==")
let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
let container = try ModelContainer(for: schema, configurations: [configuration])
let context = ModelContext(container)
check(schema.entities.count == declaredModelNames.count,
      "schéma : \(schema.entities.count) entités pour \(declaredModelNames.count) modèles déclarés")

print("== Données d'exemple ==")
let term = SeedData.seed(context)
let courses = try context.fetch(FetchDescriptor<Course>())
let videos = try context.fetch(FetchDescriptor<TheoryItem>())
let series = try context.fetch(FetchDescriptor<ExerciseSeries>())
let exercises = try context.fetch(FetchDescriptor<Exercise>())
let sessions = try context.fetch(FetchDescriptor<StudySession>())
let exams = try context.fetch(FetchDescriptor<Exam>())

check(courses.count == 4, "4 cours (\(courses.count))")
check(!term.displayName.isEmpty, "semestre « \(term.displayName) »")
check(videos.count == 17, "vidéos (\(videos.count))")
check(series.count == 10, "séries (\(series.count))")
check(exercises.count == 23, "exercices (\(exercises.count))")
check(sessions.count == 17, "sessions (\(sessions.count))")
check(exams.count == 5, "évaluations (\(exams.count))")

print("== Relations inverses SwiftData ==")
for course in courses.sorted(by: { $0.code < $1.code }) {
    check(!course.theoryItems.isEmpty, "\(course.code) : videos peuplé (\(course.theoryItems.count))")
    check(course.theoryItems.allSatisfy { $0.course?.code == course.code },
          "\(course.code) : inverse vidéo→cours cohérent")
    check(!course.series.isEmpty, "\(course.code) : series peuplé (\(course.series.count))")
    check(course.series.allSatisfy { !$0.exercises.isEmpty },
          "\(course.code) : chaque série a des exercices")
    check(course.series.allSatisfy { s in s.exercises.allSatisfy { $0.series?.id == s.id } },
          "\(course.code) : inverse exercice→série cohérent")
}

print("== ProgressEngine ==")
for course in courses.sorted(by: { $0.code < $1.code }) {
    let p = ProgressEngine.progress(for: course)
    print("  \(course.code) : théorie \(pct(p.theoryPercent)) [\(p.watchedCount)/\(p.videoCount)] · exos \(pct(p.exercisePercent)) [\(p.doneCount)/\(p.exerciseCount)] · corr \(pct(p.correctionPercent)) [\(p.correctedCount)/\(p.doneCount)] · bonus \(p.bonusDoneCount)/\(p.bonusCount)")
    check((0...1).contains(p.theoryPercent), "\(course.code) théorie ∈ [0,1]")
    check((0...1).contains(p.exercisePercent), "\(course.code) exos ∈ [0,1]")
    check((0...1).contains(p.correctionPercent), "\(course.code) corrections ∈ [0,1]")
    check(p.exerciseCount == course.allExercises.filter { !$0.isBonus }.count,
          "\(course.code) : les bonus sont exclus du dénominateur")
}

print("== WorkloadEngine (EPFL) ==")
for course in courses.sorted(by: { $0.code < $1.code }) {
    let d = WorkloadEngine.delta(for: course, hoursPerCredit: 30)
    print("  \(course.code) : attendu \(d.expectedLabel) = cours \(DateUtils.hoursLabel(seconds: d.lectureSeconds)) + perso \(DateUtils.hoursLabel(seconds: d.exerciseSeconds)) · réel \(d.actualLabel) (dont amphi \(DateUtils.hoursLabel(seconds: d.classSeconds)))")
    check(d.expectedSeconds > 0, "\(course.code) charge attendue > 0")
    check(d.lectureSeconds + d.exerciseSeconds == d.expectedSeconds,
          "\(course.code) split cours+perso = attendu")
    check(d.actualSeconds >= WorkloadEngine.studySeconds(for: course),
          "\(course.code) le réel inclut les heures de cours")
    check(abs(d.expectedSeconds - Int(course.credits * 30 * 3600)) <= 1,
          "\(course.code) formule crédits × 30 h")
}
let aggregate = WorkloadEngine.aggregate(courses: courses, hoursPerCredit: 30)

print("== Charge attendue hebdomadaire ==")
for course in courses {
    let framed = WorkloadEngine.framedWeeklyHours(for: course)
    let personal = WorkloadEngine.weeklySelfStudyHours(for: course, hoursPerCredit: 30)
    let weekly = WorkloadEngine.expectedWeeklySeconds(for: course, hoursPerCredit: 30)
    check(weekly > 0, "\(course.code) : attendu hebdo > 0 (\(weekly / 3600) h)")
    check(abs(Double(weekly) - (framed + personal) * 3600) < 1,
          "\(course.code) : attendu hebdo = encadré (\(framed) h) + personnel (\(personal) h)")
    check(personal >= 0, "\(course.code) : travail personnel ≥ 0")
}

let weekStart = DateUtils.startOfWeek(Date())
let weeklyAggregate = WorkloadEngine.aggregateWeekly(courses: courses,
                                                     hoursPerCredit: 30,
                                                     from: weekStart,
                                                     to: DateUtils.addWeeks(1, to: weekStart))
check(weeklyAggregate.expectedSeconds == courses.reduce(0) {
    $0 + WorkloadEngine.expectedWeeklySeconds(for: $1, hoursPerCredit: 30)
}, "agrégat hebdo = somme des attendus par cours")
check(weeklyAggregate.lectureSeconds + weeklyAggregate.exerciseSeconds
      == weeklyAggregate.expectedSeconds,
      "agrégat hebdo : amphi + personnel = total")
check(weeklyAggregate.expectedSeconds < aggregate.expectedSeconds,
      "l'attendu hebdo est bien plus petit que le total semestriel "
      + "(\(weeklyAggregate.expectedSeconds / 3600) h vs \(aggregate.expectedSeconds / 3600) h)")

// Un objectif explicite doit remplacer la déduction ECTS, pas s'y ajouter.
if let sample = courses.first {
    let implied = WorkloadEngine.weeklySelfStudyHours(for: sample, hoursPerCredit: 30)
    let saved = sample.weeklySelfStudyHours
    sample.weeklySelfStudyHours = implied + 3
    check(abs(WorkloadEngine.weeklySelfStudyHours(for: sample, hoursPerCredit: 30) - (implied + 3)) < 0.001,
          "\(sample.code) : l'objectif explicite remplace la déduction ECTS")
    // `expectedWeeklySeconds` arrondit : comparer avec le même arrondi, sinon le
    // test dépend du hasard des décimales.
    let expected = Int(((WorkloadEngine.framedWeeklyHours(for: sample) + implied + 3) * 3600).rounded())
    check(WorkloadEngine.expectedWeeklySeconds(for: sample, hoursPerCredit: 30) == expected,
          "\(sample.code) : l'attendu hebdo suit l'objectif explicite")
    sample.weeklySelfStudyHours = saved
}
check(aggregate.expectedSeconds > 0 && aggregate.actualSeconds > 0,
      "agrégat : attendu \(aggregate.expectedLabel) / réel \(aggregate.actualLabel)")

print("== Théorie typée (cours sans vidéo) ==")
let projectCourse = courses.first { $0.code == "PROJ-101" }
check(projectCourse != nil, "le cours sans vidéo existe dans les données d'exemple")
if let projectCourse {
    check(!projectCourse.theoryItems.isEmpty, "il a bien de la théorie")
    check(projectCourse.theoryItems.allSatisfy { $0.kind != .video },
          "aucun de ses éléments n'est une vidéo")
    check(projectCourse.theoryItems.allSatisfy { !$0.hasDuration },
          "ses chapitres n'ont pas de durée inventée")
    if let chapter = projectCourse.theoryItems.first {
        check(chapter.displayNumber.hasPrefix("Théorie"),
              "le libellé est celui de la catégorie, pas du support : « \(chapter.displayNumber) »")
        check(chapter.kind.icon != TheoryKind.video.icon,
              "l'icône suit le support")
        check(ProgressEngine.remainingVideos(for: projectCourse, week: chapter.plannedWeek).count == 1,
              "un chapitre compte comme théorie restante")
    }
}
check(courses.contains { $0.theoryItems.contains { $0.kind == .video } },
      "les autres cours ont bien des vidéos")
check(Set(TheoryKind.allCases.map(\.label)).count == 4,
      "quatre supports distincts : \(TheoryKind.allCases.map(\.label).joined(separator: ", "))")

print("== Durée de vidéo par semaine ==")
let cs = courses.first { $0.code == "CS-250" }!
check(!ProgressEngine.remainingVideos(for: cs, week: 2).isEmpty,
      "CS-250 semaine 2 : vidéos restantes (\(ProgressEngine.remainingVideos(for: cs, week: 2).count))")

print("== Entités sociales ==")
let group = StudyGroup(name: "Groupe test", courseCode: "CS-250")
context.insert(group)
context.insert(GroupMember(group: group, userID: "u1", displayName: "Alice Moreau", weeklySeconds: 12 * 3600, totalSeconds: 96 * 3600, completedSeriesCount: 4))
context.insert(GroupSeriesCompletion(group: group, userID: "u1", displayName: "Alice Moreau", courseCode: "CS-250", seriesNumber: 1))
try context.save()
let groups = try context.fetch(FetchDescriptor<StudyGroup>())
check(groups.count == 1, "groupe persisté")
check(groups.first?.members.count == 1, "membre lié au groupe (\(groups.first?.members.count ?? 0))")
check(groups.first?.completions.count == 1, "complétion liée au groupe")
check(groups.first?.inviteCode.hasPrefix("EPFL-") == true, "code d'invitation : \(groups.first?.inviteCode ?? "-")")
check(GroupMember(group: groups.first, userID: "u9", displayName: "Bob Favre").initials == "BF", "initiales calculées")

print("== Matières multiples d'un groupe ==")
let subjectGroup = StudyGroup(name: "Promo",
                              courseCodes: ["cs-250", " MATH-101 ", "CS-250", ""])
check(subjectGroup.subjectCodes == ["CS-250", "MATH-101"],
      "normalisation : majuscules, espaces retirés, sans doublon — \(subjectGroup.subjectCodes)")
check(StudyGroup.normalize(["a", "A", " b "]) == ["A", "B"], "liste de codes normalisée")
check(StudyGroup.normalize([]).isEmpty, "liste vide reste vide")

let legacyGroup = StudyGroup(name: "Ancien", courseCode: "PHYS-101")
check(legacyGroup.subjectCodes == ["PHYS-101"], "repli sur l'ancien champ mono-matière")
check(legacyGroup.tracks("phys-101"), "tracks() ignore la casse")
check(!legacyGroup.tracks("BIO-101"), "tracks() rejette une matière absente")

let bothGroup = StudyGroup(name: "Mixte", courseCode: "CS-250", courseCodes: ["CS-250", "MATH-101"])
check(bothGroup.subjectCodes == ["CS-250", "MATH-101"],
      "ancien et nouveau champ fusionnés sans doublon — \(bothGroup.subjectCodes)")
check(bothGroup.mySubjectCodes(myTrackedCourses: ["MATH-101"]) == ["MATH-101"],
      "mes matières : seulement celles que je suis")
check(bothGroup.mySubjectCodes(myTrackedCourses: []).isEmpty, "sans cours suivi, aucune matière commune")

bothGroup.addSubject("bio-101")
check(bothGroup.subjectCodes.count == 3, "ajout d'une matière")
bothGroup.removeSubject("CS-250")
check(bothGroup.subjectCodes == ["MATH-101", "BIO-101"],
      "retrait d'une matière, ancien champ compris — \(bothGroup.subjectCodes)")
check(bothGroup.courseCode.isEmpty, "le champ historique est vidé au retrait")

let absorbed = StudyGroup(name: "Absorbé", courseCode: "CS-250")
absorbed.subjectCodes = ["MATH-101"]
check(absorbed.subjectCodes == ["MATH-101"],
      "définir la liste absorbe le champ historique — \(absorbed.subjectCodes)")
check(absorbed.courseCode.isEmpty,
      "le champ historique ne peut plus ressusciter une matière retirée")
absorbed.subjectCodes = ["CS-250", "cs-250", " PHYS-101 "]
check(absorbed.subjectCodes == ["CS-250", "PHYS-101"],
      "affectation normalisée et dédupliquée — \(absorbed.subjectCodes)")

let invitationGroup = StudyGroup(name: "Buddies", courseCodes: ["CS-250"], inviteCode: "EPFL-4F2A")
check(invitationGroup.inviteLink == "polymestre://join?code=EPFL-4F2A",
      "lien d'invitation — \(invitationGroup.inviteLink)")
check(StudyGroup.normalizeInviteCode(" epfl-4f2a ") == "EPFL-4F2A",
      "code d'invitation reçu par lien, normalisé")
check(StudyGroup.normalizeInviteCode("EPFL 4F2A") == "EPFL4F2A", "espaces internes retirés")
check(invitationGroup.inviteMessage.contains("EPFL-4F2A")
      && invitationGroup.inviteMessage.contains("CS-250")
      && invitationGroup.inviteMessage.contains("polymestre://"),
      "message d'invitation : nom, matières, code et lien")

print("== Rôles dans un groupe ==")
check(GroupMember(userID: "u2", displayName: "Bob").role == .member, "rôle par défaut = membre")
let adminMember = GroupMember(userID: "u1", displayName: "Alice", role: .admin)
check(adminMember.isAdmin, "rôle admin reconnu")
adminMember.role = .member
check(!adminMember.isAdmin, "rétrogradation effective")
adminMember.roleRaw = "valeur inconnue"
check(adminMember.role == .member, "rôle illisible retombe sur membre")
check(GroupRole.admin.label == "Admin" && GroupRole.member.label == "Membre", "libellés de rôle")

let scopedMember = GroupMember(userID: "u3", displayName: "Chloé", courseCodes: ["MATH-101"])
check(scopedMember.follows("math-101"), "un membre suit sa matière, quelle que soit la casse")
check(!scopedMember.follows("CS-250"), "un membre ne suit pas les autres")
check(GroupMember(userID: "u4", displayName: "Dan").follows("CS-250"),
      "sans liste explicite, un membre suit tout le groupe")


/// Une échéance isolée pour les tests de recherche.
let builderMilestone = AcademicMilestone(externalID: "test.fin-examens",
                                         title: "Fin des examens",
                                         date: DateUtils.addDays(30, to: Date()),
                                         kind: .examEnd)

print("== Sous-questions ==")
// Un polycopié numérote ses exercices 1, 2, 3 dans chaque section, et regroupe
// souvent plusieurs questions sous un seul numéro. Les compter comme des
// exercices séparés gonfle la liste et fausse la progression.
let subSeries = ExerciseSeries(course: courses.first { $0.code == "CS-250" }, seriesNumber: 9)
let subExercise = Exercise(series: subSeries, exerciseNumber: "9.3", title: "Suites d'ensembles")
check(!subExercise.hasSubQuestions, "un exercice neuf n'a pas de question")
check(subExercise.subQuestionLabel == nil, "…et n'affiche pas de compteur")
check(subExercise.isDone == false, "…et n'est pas fait")

let q1 = SubQuestion(exercise: subExercise, label: "1", text: "L'intersection est bornée ?", sortOrder: 0)
let q2 = SubQuestion(exercise: subExercise, label: "2", text: "L'union est bornée ?", sortOrder: 1)
subExercise.subQuestions = [q1, q2]
check(subExercise.hasSubQuestions, "l'exercice a maintenant des questions")
check(subExercise.subQuestionLabel == "0/2", "compteur — \(subExercise.subQuestionLabel ?? "-")")

q1.toggle()
check(subExercise.subQuestionDoneCount == 1, "une question cochée")
check(!subExercise.isDone, "l'exercice n'est pas fait tant qu'elles ne le sont pas toutes")
check(subExercise.subQuestionLabel == "1/2", "compteur intermédiaire")

q2.toggle()
check(subExercise.isDone, "toutes cochées : l'exercice devient fait")
check(subExercise.subQuestionLabel == "2/2", "compteur complet")

q1.toggle()
check(!subExercise.isDone, "décocher une question défait l'exercice")
check(subExercise.doneAt == nil, "…et la date de réalisation est retirée")

// Cocher l'exercice entier coche ses questions : c'est le geste courant.
subExercise.setSubQuestions(done: true)
check(subExercise.isDone, "cocher l'exercice le marque fait")
check(subExercise.subQuestions.allSatisfy(\.isDone), "…et coche toutes ses questions")
subExercise.setSubQuestions(done: false)
check(!subExercise.isDone, "décocher l'exercice le défait")
check(subExercise.subQuestions.allSatisfy { !$0.isDone }, "…et décoche toutes ses questions")

// Deux niveaux : « 1) (a) (b) » et « 2) » font trois cases, pas cinq.
let nestedExercise = Exercise(series: subSeries, exerciseNumber: "9.4")
nestedExercise.replaceSubQuestions(with: [
    DetectedSubQuestion(label: "1", children: [DetectedSubQuestion(label: "a"), DetectedSubQuestion(label: "b")]),
    DetectedSubQuestion(label: "2"),
    DetectedSubQuestion(label: "", text: "Ensuite, représenter", kind: .part)
], in: nil)
check(nestedExercise.subQuestions.count == 5, "cinq nœuds enregistrés — \(nestedExercise.subQuestions.count)")
check(nestedExercise.sortedSubQuestions.map(\.label) == ["1", "2", ""], "trois au premier niveau")
check(nestedExercise.subQuestionLabel == "0/4", "quatre cases réelles — \(nestedExercise.subQuestionLabel ?? "-")")
let pointA = nestedExercise.sortedSubQuestions[0].sortedChildren[0]
check(pointA.path == "1.a", "chemin d'un point — \(pointA.path)")
pointA.toggle()
check(!nestedExercise.sortedSubQuestions[0].isDone, "une question à moitié faite ne l'est pas")
nestedExercise.sortedSubQuestions[0].sortedChildren[1].toggle()
check(nestedExercise.sortedSubQuestions[0].isDone, "tous ses points faits : la question l'est")
check(nestedExercise.subQuestionLabel == "2/4", "compteur par les points — \(nestedExercise.subQuestionLabel ?? "-")")
nestedExercise.sortedSubQuestions[0].toggle()
check(nestedExercise.subQuestionLabel == "0/4", "décocher la question décoche ses points")
nestedExercise.sortedSubQuestions[0].toggle()
nestedExercise.sortedSubQuestions[1].toggle()
nestedExercise.sortedSubQuestions[2].toggle()
check(nestedExercise.isDone, "toutes les cases faites : l'exercice l'est")

// Un réimport remplace l'arbre et garde ce qui était coché, par chemin.
nestedExercise.sortedSubQuestions[1].toggle()
nestedExercise.replaceSubQuestions(with: [
    DetectedSubQuestion(label: "1", children: [DetectedSubQuestion(label: "a"), DetectedSubQuestion(label: "b"),
                                               DetectedSubQuestion(label: "c")]),
    DetectedSubQuestion(label: "2")
], in: nil)
check(nestedExercise.subQuestionLabel == "2/4", "1.a et 1.b restent cochés, 1.c est neuf — \(nestedExercise.subQuestionLabel ?? "-")")
check(!nestedExercise.isDone, "…et l'exercice n'est plus fait")
check(nestedExercise.detectedSubQuestions.map(\.label) == ["1", "2"], "l'arbre se relit pour être modifié")

// L'étiquette s'écrit comme le polycopié.
check(SubQuestion(exercise: nil, label: "1").displayLabel == "1.", "étiquette numérique")
check(SubQuestion(exercise: nil, label: "a").displayLabel == "(a)", "étiquette alphabétique")
check(SubQuestion(exercise: nil, label: "(b)").displayLabel == "(b)", "déjà ponctuée : inchangée")
check(SubQuestion(exercise: nil, label: "1.").displayLabel == "1.", "idem pour un point")
check(SubQuestion(exercise: nil, label: "").displayLabel == "", "étiquette vide")

// Une série dont les exercices ont des questions reste comptée par exercices.
let subSeries2 = ExerciseSeries(course: nil, seriesNumber: 10)
let e1 = Exercise(series: subSeries2, exerciseNumber: "10.1")
let e1q = SubQuestion(exercise: e1, label: "1")
e1.subQuestions = [e1q]
let e2 = Exercise(series: subSeries2, exerciseNumber: "10.2")
subSeries2.exercises = [e1, e2]
e1.setSubQuestions(done: true)
e2.doneAt = Date()
check(subSeries2.doneCount == 2,
      "la série compte les exercices, pas les questions (\(subSeries2.doneCount)/\(subSeries2.requiredExercises.count))")
check(subSeries2.isComplete, "…et elle est complète")

// La réponse du modèle porte les questions, sous les deux formes acceptées.
let withLabels = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["1","2"]}]}]}"#
let parsedLabels = SeriesAIParsing.parse(withLabels)
check(parsedLabels.first?.exercises.first?.subQuestions.map(\.label) == ["1", "2"],
      "questions écrites comme de simples étiquettes")
let withObjects = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":[{"label":"a","text":"Première"},{"label":"b"}]}]}]}"#
let parsedObjects = SeriesAIParsing.parse(withObjects)
check(parsedObjects.first?.exercises.first?.subQuestions.map(\.label) == ["a", "b"],
      "…ou comme des objets")
check(parsedObjects.first?.exercises.first?.subQuestions.first?.text == "Première",
      "le texte est conservé quand il est donné")
let noLabels = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["",""]}]}]}"#
check(SeriesAIParsing.parse(noLabels).first?.exercises.first?.subQuestions.map(\.label) == ["1", "2"],
      "une étiquette vide reçoit son rang")
let duplicated = #"{"series":[{"number":4,"title":"Suites","exercises":[{"number":"4.2","title":"Bornes","questions":["1","1","2"]}]}]}"#
check(SeriesAIParsing.parse(duplicated).first?.exercises.first?.subQuestions.count == 2,
      "les étiquettes en double sont écartées")
let visionAnswer = #"{"series":[{"number":3,"exercises":[{"number":"3.1","page":1,"parts":[{"label":"1)","kind":"question","children":[{"label":"(a)"},{"label":"(b)"}]},{"label":"2","children":[{"label":"a"},{"label":"b"},{"label":"c"}]}]},{"number":"3.11","parts":[{"label":null,"kind":"part","text":"Calculer lim a_n"},{"label":"1"},{"label":"2"}]}]}]}"#
let visionParsed = SeriesAIParsing.parse(visionAnswer).first?.exercises
check(DetectedSubQuestion.outline(visionParsed?.first?.subQuestions ?? []) == "1(a,b),2(a,b,c)",
      "réponse « vision » : arbre lu, ponctuation retirée — \(DetectedSubQuestion.outline(visionParsed?.first?.subQuestions ?? []))")
check(visionParsed?.first?.pageIndex == 0, "la page du modèle (1…) devient un index (0…)")
let withStatement = SeriesAIParsing.parse(#"{"series":[{"number":3,"exercises":[{"number":"3.2","title":"Monotonie","statement":"Montrer que x_n est croissante ⇔ ad − bc ≥ 0"}]}]}"#)
check(withStatement.first?.exercises.first?.statement == "Montrer que x_n est croissante ⇔ ad − bc ≥ 0",
      "l'énoncé d'un exercice sans questions est lu")
check(DetectedSubQuestion.outline(visionParsed?.last?.subQuestions ?? []) == "part,1,2", "une partie sans numéro est gardée")

// La fusion ne mélange jamais deux numérotations : la plus complète gagne.
let heuristicSide = [DetectedSeries(number: 4, title: "Suites",
                                    exercises: [DetectedExercise(number: "4.2", title: "Bornes", isBonus: false)])]
let aiSide = [DetectedSeries(number: 4, title: "Suites",
                             exercises: [DetectedExercise(number: "4.2", title: "Bornes", isBonus: false,
                                                          subQuestions: [DetectedSubQuestion(label: "1", text: ""),
                                                                         DetectedSubQuestion(label: "2", text: "")])])]
let merged = SeriesAIParsing.merge(heuristic: heuristicSide, ai: aiSide)
check(merged.first?.exercises.first?.subQuestions.count == 2,
      "la fusion apporte les questions — \(merged.first?.exercises.first?.subQuestions.count ?? 0)")
let mergedBack = SeriesAIParsing.merge(heuristic: aiSide, ai: heuristicSide)
check(mergedBack.first?.exercises.first?.subQuestions.count == 2,
      "…et ne les retire jamais")

print("== Lecture de la réponse d'un modèle ==")
// Le JSON d'un modèle n'est pas un contrat : il écrit `2` là où on attend `"2"`,
// `"02a"` là où on attend un entier, `"oui"` là où on attend un booléen. Un
// décodeur strict rejetait **toute** la réponse pour un seul champ, et
// l'utilisateur voyait une extraction vide sans savoir pourquoi.

// Le cas réel : un PDF dont les exercices sont numérotés 1,2,3 dans chaque section,
// sans intitulé individuel. Le modèle renvoie des titres qu'il a lui-même écrits.
let realAnswer = """
{"series":[{"number":2,"title":"Sommes, bornes et densité","exercises":[
{"number":"2.1","title":"Inégalité des suprema","isBonus":false},
{"number":"2.2","title":"Suite d'intervalles ouverts","isBonus":false},
{"number":"2.5","title":"Infimum de ⌊x⌋ + ⌊x−1⌋","isBonus":false}]}]}
"""
let parsedReal = SeriesAIParsing.parse(realAnswer)
check(parsedReal.count == 1, "une série lue (\(parsedReal.count))")
check(parsedReal.first?.number == 2, "numéro de série entier")
check(parsedReal.first?.title == "Sommes, bornes et densité", "titre de série conservé")
check(parsedReal.first?.exercises.count == 3, "trois exercices")
check(parsedReal.first?.exercises.first?.number == "2.1",
      "numéro qualifié par la série — \(parsedReal.first?.exercises.first?.number ?? "-")")
check(parsedReal.first?.exercises.first?.title == "Inégalité des suprema",
      "titre français conservé")

// Les formes que le modèle peut produire et qui faisaient tout échouer.
let messyAnswer = """
{"series":[{"number":"02a","title":"Sommes","exercises":[
{"number":3,"title":"Trois","isBonus":"oui"},
{"number":"2.4","title":"Quatre","isBonus":"non"}]}]}
"""
let parsedMessy = SeriesAIParsing.parse(messyAnswer)
check(parsedMessy.count == 1,
      "« number » en texte « 02a » ne fait plus perdre la série (\(parsedMessy.count))")
check(parsedMessy.first?.number == 2, "…et donne 2")
check(parsedMessy.first?.exercises.count == 2, "les deux exercices survivent")
check(parsedMessy.first?.exercises.first?.number == "2.3",
      "un numéro écrit en nombre est qualifié — \(parsedMessy.first?.exercises.first?.number ?? "-")")
check(parsedMessy.first?.exercises.first?.isBonus == true, "« oui » vaut true")
check(parsedMessy.first?.exercises.last?.isBonus == false, "« non » vaut false")

// Un exercice sans numéro reçoit le suivant dans l'ordre.
let unnumbered = """
{"series":[{"number":5,"title":"Densité","exercises":[
{"title":"Un"},{"title":"Deux"}]}]}
"""
let parsedUnnumbered = SeriesAIParsing.parse(unnumbered)
check(parsedUnnumbered.first?.exercises.count == 2,
      "un exercice sans numéro n'est pas jeté (\(parsedUnnumbered.first?.exercises.count ?? 0))")
check(parsedUnnumbered.first?.exercises.map(\.number) == ["5.1", "5.2"],
      "…il reçoit le numéro suivant — \(parsedUnnumbered.first?.exercises.map(\.number) ?? [])")
check(parsedUnnumbered.first?.exercises.first?.title == "Un", "…et garde son titre")

// Une liste d'exercices absente ne doit pas faire perdre la série.
let noExercises = #"{"series":[{"number":7,"title":"Vide"}]}"#
let parsedEmpty = SeriesAIParsing.parse(noExercises)
check(parsedEmpty.count == 1 && parsedEmpty.first?.exercises.isEmpty == true,
      "une série sans exercices reste une série")

// Les réponses manifestement illisibles sont refusées, pas devinées.
check(SeriesAIParsing.parse("pas de json").isEmpty, "sans JSON, rien")
check(SeriesAIParsing.parse(#"{"series":[]}"#).isEmpty, "liste vide")
check(SeriesAIParsing.parse(#"{"series":[{"number":99,"title":"Trop grand"}]}"#).isEmpty,
      "un numéro de série hors bornes est refusé")

// La qualification d'un numéro, cas par cas.
check(SeriesAIParsing.normalizeNumber("1", series: 2) == "2.1",
      "un numéro nu est préfixé par la série")
check(SeriesAIParsing.normalizeNumber("2.3", series: 2) == "2.3", "un numéro déjà qualifié reste")
check(SeriesAIParsing.normalizeNumber("Ex 3.2", series: 2) == "2.2",
      "la série de l'objet parent fait foi")
check(SeriesAIParsing.normalizeNumber("02a", series: 2) == "2.2",
      "« 02a » se lit 2 — cas réel d'un en-tête de série EPFL")
check(SeriesAIParsing.normalizeNumber("", series: 2) == nil, "un numéro vide ne donne rien")
check(SeriesAIParsing.normalizeNumber(nil, series: 2) == nil, "un numéro absent non plus")

do {
    var p = CourseProgress()
    p.videoCount = 4; p.watchedCount = 2; p.exerciseCount = 6; p.doneCount = 3; p.correctedCount = 0
    check(abs(p.completion - 0.5) < 0.001, "l'avancement d'un cours : (2 vues + 3 faits) / (4 + 6) = 50 %")
    check(CourseProgress().completion == 0, "un cours vide est à 0 %, pas NaN")
}

check(ProgressEngine.standingLabel(late: 3, ahead: 2) == "3 en retard", "le retard passe avant l'avance")
check(ProgressEngine.standingLabel(late: 0, ahead: 2) == "2 d'avance", "de l'avance")
check(ProgressEngine.standingLabel(late: 0, ahead: 0) == "À jour", "à jour")

print("== Ordre des moteurs d'analyse ==")
// Cet ordre a déjà été inversé une fois sans que rien ne le signale : le modèle
// embarqué passait avant le modèle servi, et lisait nettement moins bien.
func engines(_ shared: Bool, _ device: Bool) -> [String] {
    SeriesEngineOrder.engines(sharedAvailable: shared, onDeviceAvailable: device).map(\.rawValue)
}
check(engines(true, true) == ["shared", "onDevice"],
      "le service passé avant le modèle embarqué — \(engines(true, true))")
check(engines(false, true) == ["onDevice"],
      "sans fonction déployée, le modèle embarqué prend le relais")
check(engines(false, false).isEmpty, "aucun moteur : la lecture par motifs seule")
check(engines(true, false) == ["shared"], "le service seul suffit")

print("== Saisie d'un temps au clavier ==")
// On accepte ce que les gens tapent vraiment : refuser tout sauf « 1:30 »
// rendrait le champ plus pénible que les boutons qu'il remplace.
check(TimerText.seconds(from: "1:30") == 5400, "« 1:30 » = 1 h 30")
check(TimerText.seconds(from: "90") == 5400, "« 90 » = 90 minutes, le geste naturel")
check(TimerText.seconds(from: "1h30") == 5400, "« 1h30 »")
check(TimerText.seconds(from: "1 h 30") == 5400, "« 1 h 30 », avec des espaces")
check(TimerText.seconds(from: "1,5h") == 5400, "« 1,5h », virgule française")
check(TimerText.seconds(from: "1.5h") == 5400, "« 1.5h », point")
check(TimerText.seconds(from: "45m") == 2700, "« 45m »")
check(TimerText.seconds(from: "0:45") == 2700, "« 0:45 » = 45 minutes, comme le champ les écrit")
check(TimerText.seconds(from: ":30") == 1800, "« :30 » se lit comme « 0:30 » = 30 minutes")
check(TimerText.seconds(from: "1:30:15") == 5415, "« 1:30:15 »")
check(TimerText.seconds(from: "2 heures") == 7200, "« 2 heures » en toutes lettres")
check(TimerText.seconds(from: "1 h") == 3600, "« 1 h » seule")

check(TimerText.seconds(from: "") == nil, "une saisie vide ne donne rien")
check(TimerText.seconds(from: "   ") == nil, "une saisie blanche non plus")
check(TimerText.seconds(from: "abc") == nil, "un texte sans nombre est refusé")
check(TimerText.seconds(from: "1:2:3:4") == nil, "trop de segments est refusé")

// Bornes : au-delà de douze heures, ce n'est plus une session d'étude.
check(TimerText.seconds(from: "999") == Double(TimerText.maximumHours) * 3600,
      "une saisie démesurée est bornée à \(TimerText.maximumHours) h")
check(TimerText.seconds(from: "-30") == 0, "une saisie négative vaut zéro")
check(TimerText.seconds(from: "0") == 0, "zéro est une valeur valide")

// L'affichage.
check(TimerText.text(from: 5400) == "1:30", "écriture heures:minutes — \(TimerText.text(from: 5400))")
check(TimerText.text(from: 2700) == "0:45", "moins d'une heure")
check(TimerText.text(from: 0) == "0:00", "zéro")
check(TimerText.text(from: -10) == "0:00", "un négatif s'affiche zéro")

// Aller-retour : ce que le champ écrit doit se relire tel quel.
for seconds in [0.0, 60.0, 600.0, 2700.0, 5400.0, 7200.0] {
    check(TimerText.seconds(from: TimerText.text(from: seconds)) == seconds,
          "aller-retour à \(Int(seconds)) s")
}

print("== Annales ==")
let pastSummary = PastExamProgress.summary([
    (2024, false), (2023, true), (2022, true), (2021, false)
])
check(pastSummary.total == 4, "quatre annales")
check(pastSummary.worked == 2, "deux travaillées")
check(pastSummary.label == "2/4 travaillées", "libellé du bilan — \(pastSummary.label)")
check(pastSummary.pendingYears == [2024, 2021], "les années restantes, de la plus récente à la plus ancienne")
check(!pastSummary.isComplete, "le jeu n'est pas complet")

let doneSummary = PastExamProgress.summary([(2024, true), (2023, true)])
check(doneSummary.isComplete, "tout est travaillé")
check(doneSummary.label == "2/2 travaillées", "libellé quand tout est fait")
check(PastExamProgress.summary([]).label == "Aucune annale", "aucune annale : le libellé le dit")
check(PastExamProgress.summary([]).ratio == 0, "…sans division par zéro")

check(PastExamProgress.priority([(2020, false), (2024, false), (2022, true), (2023, false)])
        == [2024, 2023, 2020],
      "priorité aux années récentes non travaillées")
check(PastExamProgress.priority([(2024, false), (2023, false)], limit: 1) == [2024],
      "la priorité est bornée")
check(PastExamProgress.priority([(2024, true)]).isEmpty, "rien à prioriser quand tout est fait")

let pastCourse = courses.first { $0.code == "CS-250" }!
let past = PastExam(course: pastCourse, title: "Examen final 2024", year: 2024)
check(past.title == "Examen final 2024", "titre conservé")
check(!past.isWorked, "une annale neuve n'est pas travaillée")
check(past.statusLabel == "Pas encore travaillé", "…et le dit — \(past.statusLabel)")
past.workedAt = Date()
past.confidence = .medium
check(past.isWorked, "cochée, elle est travaillée")
check(past.statusLabel.contains("Travaillé le"), "…avec sa date — \(past.statusLabel)")
check(past.url == nil, "sans lien, aucune URL inventée")
past.urlString = "https://example.org/sujet.pdf"
check(past.url != nil, "un lien valide donne une URL")
past.urlString = "   "
check(past.url == nil, "un lien blanc n'en donne pas")
let untitled = PastExam(course: pastCourse, year: 2023, kind: .midterm)
check(untitled.title == "Midterm 2023", "sans titre, un intitulé par défaut — \(untitled.title)")

print("== Journal local ==")
var logEntries: [LogEntry] = []
for index in 0..<10 {
    logEntries = LogBuffer.append(LogEntry(level: .info, category: "test", message: "ligne \(index)"),
                                  to: logEntries)
}
check(logEntries.count == 10, "dix lignes ajoutées (\(logEntries.count))")
check(logEntries.first?.message == "ligne 9", "la plus récente est en tête")

// Le tampon est borné.
var bounded: [LogEntry] = []
for index in 0..<(LogBuffer.limit + 50) {
    bounded = LogBuffer.append(LogEntry(level: .info, category: "test", message: "\(index)"), to: bounded)
}
check(bounded.count == LogBuffer.limit,
      "le journal est borné à \(LogBuffer.limit) lignes (\(bounded.count))")

// Quand la place manque, on garde ce qui explique un problème.
var mixed: [LogEntry] = []
mixed = LogBuffer.append(LogEntry(level: .error, category: "test", message: "erreur ancienne"), to: mixed)
for index in 0..<LogBuffer.limit {
    mixed = LogBuffer.append(LogEntry(level: .info, category: "test", message: "\(index)"), to: mixed)
}
check(mixed.contains { $0.message == "erreur ancienne" },
      "une erreur survit à l'éviction des informations")
check(mixed.count <= LogBuffer.limit, "et le tampon reste borné (\(mixed.count))")

check(LogBuffer.filtered(mixed, level: nil).count == mixed.count, "sans filtre, tout passe")
check(LogBuffer.filtered(mixed, level: .error).count == 1, "le filtre par niveau isole les erreurs")
check(LogBuffer.count(mixed, level: .info) == mixed.count - 1, "le comptage par niveau est juste")
check(LogBuffer.text([], formatter: ISO8601DateFormatter()) == "Journal vide.",
      "un journal vide se dit vide")
check(LogBuffer.text([LogEntry(level: .warning, category: "sync", message: "échec",
                               detail: "détail")]).contains("AVERTISSEMENT"),
      "le texte porte le niveau en clair")
check(LogBuffer.text([LogEntry(level: .info, category: "import", message: "ok",
                               detail: "deuxième ligne")]).contains("deuxième ligne"),
      "le détail est repris dans l'export")

print("== Export pour un assistant (source du serveur MCP) ==")
let exportCourses = courses.filter(\.isTracked)
let exportData = AssistantExport.make(courses: exportCourses,
                                      sessions: sessions,
                                      milestones: [],
                                      groups: [],
                                      hoursPerCredit: 30,
                                      displayName: "Test")
check(exportData["format"] as? String == "polymestre.assistant",
      "le format est annoncé — \(exportData["format"] ?? "-")")
check(exportData["version"] as? Int == AssistantExport.formatVersion,
      "la version du format est portée")
check(exportData["generatedAt"] is String, "l'horodatage est présent")

let exportedCourses = exportData["courses"] as? [[String: Any]] ?? []
check(exportedCourses.count == exportCourses.count,
      "tous les cours suivis sont exportés (\(exportedCourses.count))")
check(exportedCourses.allSatisfy { $0["code"] is String && $0["name"] is String },
      "chaque cours a un code et un nom")

if let firstCourse = exportedCourses.first,
   let series = firstCourse["series"] as? [[String: Any]],
   let firstSeries = series.first,
   let exercises = firstSeries["exercises"] as? [[String: Any]],
   let firstExercise = exercises.first {
    check(firstExercise["number"] is String, "un exercice porte son numéro")
    check(firstExercise["done"] is Bool, "…et son état")
    check(firstExercise["bonus"] is Bool, "…et s'il est facultatif")
} else {
    check(false, "le cours d'exemple a des séries et des exercices exportés")
}

// Le JSON doit être sérialisable : c'est ce que le serveur MCP lit.
let exportJSON = AssistantExport.data(courses: exportCourses,
                                      sessions: sessions,
                                      milestones: [],
                                      groups: [],
                                      hoursPerCredit: 30,
                                      displayName: "Test")
check(exportJSON != nil, "l'instantané est sérialisable")
if let exportJSON,
   let reparsed = try? JSONSerialization.jsonObject(with: exportJSON) as? [String: Any] {
    check(reparsed["format"] as? String == "polymestre.assistant",
          "…et se relit après un aller-retour JSON")
    check((reparsed["courses"] as? [[String: Any]])?.isEmpty == false, "les cours survivent")
}
// Un export sans cours ne doit pas produire un objet vide mais valide.
let emptyExport = AssistantExport.make(courses: [], sessions: [], milestones: [],
                                       groups: [], hoursPerCredit: 25, displayName: "")
check(emptyExport["format"] as? String == "polymestre.assistant",
      "un export vide garde son format")
check((emptyExport["courses"] as? [[String: Any]])?.isEmpty == true,
      "…et une liste de cours vide plutôt qu'absente")

// v3 : notes, fiche, corrigés rédigés et fichiers — seulement sur demande.
if let contentCourse = exportCourses.first,
   let contentSeries = contentCourse.sortedSeries.first,
   let contentExercise = contentSeries.sortedExercises.first {
    let before = (notes: contentCourse.notes, solution: contentExercise.solution, hint: contentExercise.hint, url: contentSeries.urlString,
                  solutionURL: contentSeries.solutionURLString)
    contentCourse.notes = "Théorème d'unicité de la limite."
    contentExercise.solution = "On lit la limite sur le graphe."
    contentExercise.hint = "Pense à epsilon."
    contentSeries.urlString = "https://moodle.example/serie.pdf"
    contentSeries.solutionURLString = "https://moodle.example/corrige.pdf"
    func export(_ includeContent: Bool, files: [[String: Any]] = []) -> [String: Any] {
        AssistantExport.make(courses: [contentCourse], sessions: [], milestones: [], groups: [], hoursPerCredit: 30,
                             displayName: "Test", includeContent: includeContent, files: files)
    }
    func exerciseEntry(_ data: [String: Any]) -> [String: Any]? {
        let series = (data["courses"] as? [[String: Any]])?.first?["series"] as? [[String: Any]]
        return (series?.first?["exercises"] as? [[String: Any]])?.first
    }
    func seriesEntry(_ data: [String: Any]) -> [String: Any]? {
        ((data["courses"] as? [[String: Any]])?.first?["series"] as? [[String: Any]])?.first
    }

    let plain = export(false, files: [["id": "x"]])
    check(AssistantExport.formatVersion == 3, "le format est en version 3")
    check((plain["sharing"] as? [String: Bool])?["files"] == false, "sans réglage, le partage des fichiers est annoncé éteint")
    check(plain["files"] == nil, "…aucun fichier n'est annoncé (même si on en passe)")
    let plainCourse = (plain["courses"] as? [[String: Any]])?.first
    check(plainCourse?["notes"] == nil && plainCourse?["revisionSheet"] == nil && plainCourse?["pastExams"] == nil,
          "…ni notes, ni fiche, ni anciens examens")
    check(exerciseEntry(plain)?["solution"] == nil && exerciseEntry(plain)?["hint"] == nil, "…ni corrigé rédigé, ni indice")
    check(seriesEntry(plain)?["url"] == nil && seriesEntry(plain)?["solutionUrl"] == nil, "…ni adresse de série")

    let rich = export(true, files: [["id": "serie:1", "sha": "abc"]])
    check((rich["sharing"] as? [String: Bool])?["files"] == true, "le réglage allumé est annoncé")
    check((rich["files"] as? [[String: Any]])?.first?["id"] as? String == "serie:1", "l'index des fichiers voyage")
    let richCourse = (rich["courses"] as? [[String: Any]])?.first
    check(richCourse?["notes"] as? String == "Théorème d'unicité de la limite.", "les notes de cours sont exportées")
    check(richCourse?["pastExams"] is [[String: Any]] && richCourse?["resources"] is [[String: Any]], "anciens examens et ressources : listes présentes")
    check(exerciseEntry(rich)?["solution"] as? String == "On lit la limite sur le graphe.", "le corrigé rédigé d'un exercice est exporté")
    check(exerciseEntry(rich)?["hint"] as? String == "Pense à epsilon.", "…et son indice")
    check(seriesEntry(rich)?["url"] as? String == "https://moodle.example/serie.pdf"
          && seriesEntry(rich)?["solutionUrl"] as? String == "https://moodle.example/corrige.pdf", "les adresses de la série et de son corrigé sont exportées")
    check(emptyExport["files"] == nil, "un export vide n'annonce aucun fichier")

    contentCourse.notes = String(repeating: "a", count: AssistantExport.notesLimit + 500)
    contentExercise.solution = String(repeating: "b", count: AssistantExport.solutionLimit + 500)
    let clipped = export(true)
    let clippedNotes = (clipped["courses"] as? [[String: Any]])?.first?["notes"] as? String ?? ""
    check(clippedNotes.hasSuffix("[…tronqué]") && clippedNotes.count < AssistantExport.notesLimit + 50, "des notes démesurées sont tronquées (\(clippedNotes.count) car.)")
    check((exerciseEntry(clipped)?["solution"] as? String ?? "").count < AssistantExport.solutionLimit + 50, "…et un corrigé démesuré aussi")
    if let reparsed = (try? JSONSerialization.data(withJSONObject: rich)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
        check((reparsed["files"] as? [[String: Any]])?.count == 1, "l'instantané v3 se relit après un aller-retour JSON")
    } else {
        check(false, "l'instantané v3 est sérialisable")
    }

    contentCourse.notes = before.notes
    contentExercise.solution = before.solution
    contentExercise.hint = before.hint
    contentSeries.urlString = before.url
    contentSeries.solutionURLString = before.solutionURL
} else {
    check(false, "le cours d'exemple a une série et un exercice pour l'export v3")
}

print("== Serveur MCP local (fichiers du Mac) ==")
for (ok, label) in localMCPResults() { check(ok, label) }
for (ok, label) in desktopBridgeResults() { check(ok, label) }
for (ok, label) in syncResults() { check(ok, label) }
for (ok, label) in syncCryptoResults() { check(ok, label) }
for (ok, label) in identityMigrationResults() { check(ok, label) }
print("== Deux séries par semaine, exercices sans numéro ==")
for (ok, label) in seriesIdentityResults(context: context) { check(ok, label) }
print("== À rattraper ==")
for (ok, label) in lateWorkResults(context: context) { check(ok, label) }
check(LocalFileCatalog.pageIndices("1-5,8", total: 10) == [0, 1, 2, 3, 4, 7], "pages : « 1-5,8 »")
check(LocalFileCatalog.pageIndices("3", total: 10) == [2] && LocalFileCatalog.pageIndices("8-", total: 10) == [7, 8, 9], "pages : une page, une plage ouverte")
check(LocalFileCatalog.pageIndices("9-20", total: 10) == [8, 9], "pages : bornées au document")
check(LocalFileCatalog.pageIndices("2,2,1-3", total: 5) == [1, 0, 2], "pages : sans doublon, dans l'ordre demandé")
check(LocalFileCatalog.pageIndices("0,x,5-2", total: 5) == nil && LocalFileCatalog.pageIndices("1", total: 0) == nil, "pages : rien d'utilisable → nil")

// Le catalogue : tout ce qui se lit d'un cours, sans réseau.
if let catalogCourse = exportCourses.first, let catalogSeries = catalogCourse.sortedSeries.first {
    let before = (url: catalogSeries.urlString, solution: catalogSeries.solutionURLString, notes: catalogCourse.notes)
    catalogSeries.urlString = "https://moodle.epfl.ch/pluginfile.php/1/mod_resource/content/0/serie03.pdf"
    catalogSeries.solutionURLString = "https://moodle.epfl.ch/mod/resource/view.php?id=77"
    catalogCourse.notes = "# Notes\nthéorème d'unicité"
    let exam = PastExam(course: catalogCourse, title: "Examen final", year: 2024, kind: .exam,
                        urlString: "https://exemple.ch/examen-2024.pdf", solutionURLString: "https://exemple.ch/page-web", notes: "piège à l'exo 2")
    context.insert(exam)
    let upload = SavedResource(course: catalogCourse, title: "Aide-mémoire", kind: .pdf, fileName: "aide.pdf", fileData: Data("%PDF-1.4".utf8))
    context.insert(upload)
    let webLink = SavedResource(course: catalogCourse, title: "Un site", address: "https://exemple.ch/site", kind: .web)
    context.insert(webLink)
    let notebook = LocalFileCatalog.Notebook(courseID: catalogCourse.id,
        document: NotesLibrary.Document(path: "Analyse/serie-3.pdf", notebook: "Analyse", title: "Série 3", week: 3, seriesNumber: 3, isSolution: false, modified: Date()),
        url: URL(fileURLWithPath: "/tmp/serie-3.pdf"))
    let entries = LocalFileCatalog.entries(courses: [catalogCourse], notebooks: [notebook])
    func entry(_ prefix: String) -> LocalFileCatalog.Entry? { entries.first { $0.id.hasPrefix(prefix) } }
    check(entry("serie:")?.type == "enonce" && entry("serie:")?.baseName == "serie-\(String(format: "%02d", catalogSeries.seriesNumber))-enonce", "catalogue : l'énoncé PDF de la série")
    check(entry("corrige:")?.type == "corrige" && entry("corrige:")?.seriesNumber == catalogSeries.seriesNumber, "…son corrigé (une activité Moodle compte comme document)")
    check(entry("notes:")?.type == "notes", "…les notes de cours")
    check(entry("examen:")?.type == "examen" && entry("examen:")?.baseName.contains("2024") == true, "…l'ancien examen")
    check(entry("corrige-examen:") == nil, "…mais pas un « corrigé » qui est une page web")
    check(entry("notes-examen:")?.type == "notes-examen", "…les notes d'un ancien examen")
    check(entry("ressource:\(upload.id)")?.type == "ressource", "…le fichier ajouté à un cours")
    check(entry("ressource:\(webLink.id)") == nil, "…mais pas un simple lien web")
    check(entry("cahier:")?.type == "cahier" && entry("cahier:")?.seriesNumber == 3 && entry("cahier:")?.week == 3, "…le cahier du dossier de notes, avec sa série et sa semaine")
    let courseEntries = entries.filter { $0.courseID == catalogCourse.id.uuidString }
    check(Set(courseEntries.map(\.id)).count == courseEntries.count, "catalogue : identifiants uniques")
    check(courseEntries.allSatisfy { !$0.baseName.contains("/") && !$0.baseName.contains("..") && !$0.baseName.contains(" ") }, "catalogue : des noms de fichiers sûrs")
    check(LocalFileCatalog.filter(entries, course: nil, type: "examen", series: nil, query: nil).count == 1, "filtre par type")
    check(LocalFileCatalog.filter(entries, course: nil, type: nil, series: 3, query: nil).allSatisfy { $0.seriesNumber == 3 }, "filtre par série")
    check(LocalFileCatalog.filter(entries, course: nil, type: nil, series: nil, query: "Aide MÉMOIRE").count == 1, "recherche sans accents ni majuscules")
    check(LocalFileCatalog.documentURL("https://exemple.ch/site") == nil && LocalFileCatalog.documentURL("https://exemple.ch/a.pptx") != nil
          && LocalFileCatalog.documentURL("file:///tmp/a.pdf") != nil && LocalFileCatalog.documentURL("") == nil, "une page web n'est pas un document ; un .pptx ou un fichier local, si")
    check(LocalFileCatalog.slug("Séries d'Analyse — n°3") == "series-d-analyse-n-3" && LocalFileCatalog.hash("a") == LocalFileCatalog.hash("a")
          && LocalFileCatalog.hash("a") != LocalFileCatalog.hash("b"), "slug lisible, empreinte stable")
    context.delete(exam); context.delete(upload); context.delete(webLink)
    catalogSeries.urlString = before.url; catalogSeries.solutionURLString = before.solution; catalogCourse.notes = before.notes
} else {
    check(false, "le cours d'exemple a une série pour le catalogue")
}

print("== Live Activity : le compteur ne repart pas de zéro ==")
// Le bogue : l'état portait `accumulated` **et** `runningSince`, et le compteur
// système n'affichait que le second. Après une pause, il repartait de zéro —
// « 00:01 » au lieu d'une heure de travail.
let activityNow = Date(timeIntervalSince1970: 1_700_000_000)

let running = ActivityTimerState.make(elapsed: 600, running: true, now: activityNow)
check(running.isRunning, "un chrono qui tourne est marqué en cours")
check(running.elapsed(at: activityNow) == 600,
      "…et affiche le total accumulé, pas zéro — \(Int(running.elapsed(at: activityNow))) s")
check(running.elapsed(at: activityNow.addingTimeInterval(60)) == 660,
      "…et il continue d'avancer")
check(abs((running.countingSince ?? activityNow).timeIntervalSince(activityNow) + 600) < 0.001,
      "l'instant de départ est reculé du total déjà écoulé")

// Le cas exact du rapport : reprendre après une pause d'une heure de travail.
let resumed = ActivityTimerState.make(elapsed: 3600, running: true, now: activityNow)
check(resumed.elapsed(at: activityNow) == 3600,
      "reprendre après 1 h affiche 1 h, pas 00:01 — \(Int(resumed.elapsed(at: activityNow))) s")
check(resumed.elapsed(at: activityNow.addingTimeInterval(2)) == 3602,
      "…et deux secondes plus tard, 1 h 00 min 02")

let paused = ActivityTimerState.make(elapsed: 600, running: false, now: activityNow)
check(!paused.isRunning, "en pause, le chrono n'est pas marqué en cours")
check(paused.countingSince == nil, "…et rien ne s'écoule")
check(paused.elapsed(at: activityNow.addingTimeInterval(300)) == 600,
      "…le total reste figé même cinq minutes plus tard")
check(paused.frozenTotal == 600, "le total figé est conservé")

let zero = ActivityTimerState.make(elapsed: 0, running: true, now: activityNow)
check(zero.elapsed(at: activityNow) == 0, "un chrono neuf part de zéro")
let negative = ActivityTimerState.make(elapsed: -50, running: false, now: activityNow)
check(negative.frozenTotal == 0, "un total négatif est ramené à zéro")

print("== Live Activity : sous-questions et anneau Pomodoro ==")
// Les champs ajoutés sont `Optional` pour deux raisons, toutes deux testées ici :
// une activité publiée par une version précédente doit se décoder, et « pas de
// sous-questions » ne doit pas se confondre avec « zéro sur zéro ».
let bare = ActivityTimerState.make(elapsed: 120, running: true, now: activityNow)
check(bare.questionsLabel == nil, "sans cible, aucun compte de sous-questions")
check(!bare.hasNextQuestion, "…et donc pas de bouton « question suivante »")
check(bare.questionsProgress == nil, "…ni de barre de progression")

let withQuestions = ActivityTimerState.make(elapsed: 120, running: true,
                                            questionsDone: 3, questionsTotal: 9,
                                            now: activityNow)
check(withQuestions.questionsLabel == "3/9", "trois sur neuf — \(withQuestions.questionsLabel ?? "nil")")
check(withQuestions.hasNextQuestion, "il reste des questions à cocher")
check(abs((withQuestions.questionsProgress ?? 0) - 1.0 / 3) < 0.001, "un tiers fait")

let finished = ActivityTimerState.make(elapsed: 120, running: true,
                                       questionsDone: 9, questionsTotal: 9,
                                       now: activityNow)
check(!finished.hasNextQuestion, "tout coché : plus de question suivante")
check(finished.questionsLabel == "9/9", "…mais le compte reste affiché")

let single = ActivityTimerState.make(elapsed: 120, running: true,
                                     questionsDone: 0, questionsTotal: 1,
                                     now: activityNow)
check(single.questionsLabel == nil,
      "une cible à une seule case n'affiche pas « 0/1 » : le bouton « fait » le dit déjà")
check(single.hasNextQuestion, "…elle garde pourtant sa question suivante")

// Décodage d'une activité écrite **avant** ces champs : le contrat de compatibilité.
let legacyJSON = #"{"countingSince":"2023-11-14T22:13:20Z","frozenTotal":600}"#
let legacyDecoder = JSONDecoder()
legacyDecoder.dateDecodingStrategy = .iso8601
if let data = legacyJSON.data(using: .utf8),
   let legacy = try? legacyDecoder.decode(ActivityTimerState.self, from: data) {
    check(legacy.frozenTotal == 600, "un état d'avant les sous-questions se décode encore")
    check(legacy.questionsTotal == nil, "…et ses champs absents valent nil")
    check(legacy.pomodoro == nil, "…y compris le bloc Pomodoro")
} else {
    check(false, "un état d'avant les sous-questions doit se décoder")
}

// Les libellés vivent dans l'**état** : les attributs d'une activité sont
// figés à sa création, et l'écran verrouillé affichait le premier cours
// démarré pour toujours (« Analyse »).
let labelled = ActivityTimerState.make(elapsed: 60, running: true, title: "CS-250",
                                       subtitle: ActivityTimerState.subtitle(task: "Exercices", target: "3.4"),
                                       now: activityNow)
check(labelled.title == "CS-250", "le cours est porté par l'état de l'activité")
check(labelled.subtitle == "Exercices · 3.4", "le type et la cible aussi")
check(ActivityTimerState.subtitle(task: "Théorie", target: nil) == "Théorie", "sans cible, le type seul")
check(ActivityTimerState.subtitle(task: "Théorie", target: "") == "Théorie", "une cible vide ne laisse pas de « · »")
let relabelled = ActivityTimerState.make(elapsed: 60, running: true, title: "MATH-101", now: activityNow)
check(relabelled != labelled, "changer de cours change l'état : l'activité est republiée")
if let data = #"{"countingSince":null,"frozenTotal":30}"#.data(using: .utf8),
   let old = try? legacyDecoder.decode(ActivityTimerState.self, from: data) {
    check(old.title == nil && old.subtitle == nil, "un état sans libellés se décode : l'extension retombe sur les attributs")
} else {
    check(false, "un état sans libellés doit se décoder")
}

print("== Botafogo : polycopiés Nuxt ==")
do {
    let nuxtHTML = "<html><head><title>1.1 Introduction</title><script>window.__NUXT__={};baseURL:\"/analyse-b\"</script></head><body><script type=\"application/json\" data-nuxt-data=\"nuxt-app\" data-ssr=\"true\" id=\"__NUXT_DATA__\">[{\"nav\": 29}, \"Analyse B (MAN)\", \"1.1 Introduction\", \"/matiere/m_intro\", [], {\"title\": 2, \"path\": 3, \"children\": 4}, \"1.2 Limite: $a_{n}\\\\to L$\", \"/matiere/m_lim\", [], {\"title\": 6, \"path\": 7, \"children\": 8}, \"2.1 Parité\", \"/matiere/m_par\", [], {\"title\": 10, \"path\": 11, \"children\": 12}, \"1 Suites réelles\", \"#_1\", [5, 9], {\"title\": 14, \"path\": 15, \"children\": 16}, \"2 Fonctions\", \"#_2\", [13], {\"title\": 18, \"path\": 19, \"children\": 20}, \"3 Pas encore publié\", \"#_3\", [], {\"title\": 22, \"path\": 23, \"children\": 24}, [17, 21, 25], [\"ShallowReactive\", 26], \"/analyse-b\", {\"title\": 1, \"path\": 28, \"children\": 27}, \"videokaltura\", \"0_tt1r5whs\", \"Streaming Analyse 1 - GM - MERCREDI\", \"0_8coayv4h\", \"Cours 01 AN - GM - 09 sept 2026 (SG1)\", \"0_la3lc4m0\", \"Cours 03 AN - GM - 16 sept 2026 (SG1)\"]</script></body></html>"
    let pageURL = URL(string: "https://botafogo.epfl.ch/analyse-b/matiere/m_intro")!
    let payload = NuxtPayload(html: nuxtHTML)
    check(payload != nil, "le bloc __NUXT_DATA__ se lit")
    let nav = payload?.navigation()
    check(nav?.chapters.count == 3, "trois chapitres, dont un encore vide (\(nav?.chapters.count ?? 0))")
    check(nav?.chapters.first?.children.count == 2, "les sections suivent les indices, enveloppe ShallowReactive comprise")
    check(nav?.title == "Analyse B (MAN)", "le nom du polycopié vient du nœud racine")
    if let page = BotafogoParser.parseNuxt(html: nuxtHTML, pageURL: pageURL) {
        check(page.title == "Analyse B (MAN)", "pas le titre de la section affichée (« 1.1 Introduction »)")
        check(page.url == "https://botafogo.epfl.ch/analyse-b/", "racine du site lue dans baseURL")
        check(page.sections.first?.items.first?.url == "https://botafogo.epfl.ch/analyse-b/matiere/m_intro", "adresse d'une section")
        let draft = ContentDraftBuilder.draft(from: page, source: .botafogo, termStart: nil, totalWeeks: 14)
        check(draft.sections.first?.items.last?.title == "Limite: a_{n}\\to L", "les $ du LaTeX sont retirés des titres")
        let weeks = draft.sections.flatMap { s in s.items.map { $0.plannedWeek(in: s) } }
        check(weeks == weeks.sorted() && weeks.first == 1 && (weeks.last ?? 0) <= 14,
              "la matière s'étale dans l'ordre sur le semestre (\(weeks))")
    } else {
        check(false, "un polycopié Nuxt doit se lire")
    }
    let recordings = BotafogoParser.recordings(html: nuxtHTML)
    check(recordings.count == 2, "deux enregistrements datés, le direct est écarté (\(recordings.count))")
    check(recordings.first?.url == "https://mediaspace.epfl.ch/media/0_8coayv4h", "lien MediaSpace de l'enregistrement")
    let termStart = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 7))!
    let recDraft = ContentDraftBuilder.draft(from: ScrapedCourse(source: "botafogo", title: "GM", url: "",
                                                                 sections: [ScrapedSection(title: "Enregistrements des cours", items: recordings)]),
                                             source: .botafogo, termStart: termStart, totalWeeks: 14)
    check(recDraft.sections.first?.items.map(\.number) == ["C1", "C3"], "numérotés par cours")
    check(recDraft.sections.first?.items.map { $0.week ?? 0 } == [1, 2], "semaine d'un enregistrement = semaine de sa date")

    let refresh = #"<!DOCTYPE html><html><head><meta http-equiv="refresh" content="0; url=/ics/matiere/m_avantpropos_avantpropos"></head></html>"#
    check(BotafogoParser.metaRefresh(html: refresh, baseURL: URL(string: "https://botafogo.epfl.ch/ics/")!)?.absoluteString
          == "https://botafogo.epfl.ch/ics/matiere/m_avantpropos_avantpropos", "une redirection <meta refresh> est suivie")
    check(ContentDraftBuilder.cleanTitle(#"2.2 Les fonctions \htmlTag{code}{\htmlAttr{language}{"text"}plt.plot}"#)
          == "2.2 Les fonctions plt.plot", "le code dans les titres d'ICS est lisible")
    check(ContentDraftBuilder.cleanTitle(#"Informatique (ICS) \\ CMS"#) == "Informatique (ICS) · CMS", "un saut de ligne LaTeX devient un séparateur")
    check(!ContentDraftBuilder.isFrontMatter("II. Notions élémentaires"), "« Notions élémentaires » est de la matière")
    check(ContentDraftBuilder.isFrontMatter("I. Préface"), "la préface ne l'est pas")

    // Corriger la semaine d'un chapitre étalé décale ses éléments.
    var spread = ContentDraftSection(title: "3", week: 3, weekIsInferred: true, isIncluded: true,
                                     items: [ContentDraftItem(kind: .theory, number: "3.1", title: "", url: "", videoCount: 0, seriesNumber: nil, theoryKind: .reading, week: 3),
                                             ContentDraftItem(kind: .theory, number: "3.2", title: "", url: "", videoCount: 0, seriesNumber: nil, theoryKind: .reading, week: 5)])
    spread.shiftWeeks(by: 2, totalWeeks: 14)
    check(spread.items.map { $0.week ?? 0 } == [5, 7], "décaler un chapitre garde son étalement")
    check(spread.weekRange == 5...7, "« Semaines 5–7 »")
}

print("== Moodle : plan du cours et sections ==")
do {
    // La forme exacte que renvoie moodle.epfl.ch (Moodle 4.5), relevée sur un
    // cours public : identifiants en chaînes, `module` technique, sous-sections
    // déléguées.
    let state = #"""
    {"course":{"id":"14840","numsections":3},
     "section":[
      {"id":"100","section":0,"number":0,"title":"Généralités","cmlist":["1","2"],"visible":true,"component":null,"itemid":null},
      {"id":"101","section":1,"number":1,"title":"8 septembre - 14 septembre","cmlist":["3","4","5","9"],"visible":true,"component":null,"itemid":null},
      {"id":"102","section":2,"number":2,"title":"Semaine 2","cmlist":["6","7"],"visible":true,"component":null,"itemid":null},
      {"id":"103","section":3,"number":3,"title":"Sous-section","cmlist":["8"],"visible":true,"component":"mod_subsection","itemid":"9"}],
     "cm":[
      {"id":"1","name":"Annonces","module":"forum","url":"https://moodle.epfl.ch/mod/forum/view.php?id=1","uservisible":true},
      {"id":"2","name":"Plan du cours","module":"resource","url":"https://moodle.epfl.ch/mod/resource/view.php?id=2","uservisible":true},
      {"id":"3","name":"Vidéo 1.1 Introduction","module":"kalvidres","url":"https://moodle.epfl.ch/mod/kalvidres/view.php?id=3","uservisible":true},
      {"id":"4","name":"Série 1","module":"resource","url":"https://moodle.epfl.ch/mod/resource/view.php?id=4","uservisible":true},
      {"id":"5","name":"Corrigé série 1","module":"resource","url":"https://moodle.epfl.ch/mod/resource/view.php?id=5","uservisible":true},
      {"id":"6","name":"Série 2","module":"assign","url":"https://moodle.epfl.ch/mod/assign/view.php?id=6","uservisible":true},
      {"id":"7","name":"Caché","module":"resource","url":"","uservisible":false},
      {"id":"8","name":"Chapitre 1.2 Suites","module":"page","url":"https://moodle.epfl.ch/mod/page/view.php?id=8","uservisible":true},
      {"id":"9","name":"Sous-section","module":"subsection","url":"","uservisible":true}]}
    """#
    if let page = MoodleStateParser.course(fromStateJSON: state, title: "Analyse I", url: "https://moodle.epfl.ch/course/view.php?id=14840") {
        check(page.sections.count == 3, "la sous-section déléguée n'est pas une section de plus (\(page.sections.count))")
        check(page.sections[1].items.map(\.title) == ["Vidéo 1.1 Introduction", "Série 1", "Corrigé série 1", "Chapitre 1.2 Suites"],
              "ses activités sont rangées là où on les voit")
        check(!page.sections[2].items.contains { $0.title == "Caché" }, "une activité invisible n'est pas importée")
        let term = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 7))!
        let draft = ContentDraftBuilder.draft(from: page, source: .moodle, termStart: term, totalWeeks: 14)
        check(draft.seriesCount == 2, "deux séries, le corrigé n'en est pas une (\(draft.seriesCount))")
        check(draft.sections.first { $0.title.hasPrefix("8 septembre") }?.week == 1, "une section datée tombe à sa semaine")
        check(draft.sections.first { $0.title == "Semaine 2" }?.week == 2, "« Semaine 2 »")
        check(draft.sections.first { $0.title == "Généralités" }?.items.first { $0.title == "Annonces" }?.kind == .ignore,
              "un forum s'ignore")
    } else {
        check(false, "le plan Moodle doit se lire")
    }
    check(MoodleStateParser.course(fromStateJSON: "{\"error\":true}", title: "", url: "") == nil, "une erreur ne donne pas de plan")

    let search = #"{"total":3,"courses":[{"id":14839,"fullname":"Analyse I","shortname":"MATH-101(a)"},{"id":14840,"fullname":"Analyse I","shortname":"MATH-101(e)"},{"id":7621,"fullname":"Biochimie","shortname":"CH-210"}],"warnings":[]}"#
    let found = MoodleStateParser.courses(fromJSON: search)
    check(found.count == 3 && found[1].baseCode == "MATH-101" && found[1].variant == "e", "résultats de recherche lus")
    check(MoodleCourseMatcher.match(code: "CH-210", candidates: found) == .unique(found[2]), "un seul cours : relié d'office")
    if case .ambiguous(let options) = MoodleCourseMatcher.match(code: "MATH-101", candidates: found) {
        check(options.count == 2, "plusieurs sections : on demande laquelle")
    } else { check(false, "MATH-101 a deux sections") }
    check(MoodleCourseMatcher.match(code: "MATH-101", candidates: found, enrolled: [found[1]]) == .unique(found[1]),
          "l'inscription départage les sections")
    check(MoodleCourseMatcher.match(code: "math-101(a)", candidates: found) == .unique(found[0]), "un code écrit avec sa section la désigne")
    check(MoodleCourseMatcher.match(code: "PHYS-101", candidates: found) == .none, "rien trouvé")
    check(MoodleCourseMatcher.linkedID(in: ["https://botafogo.epfl.ch/analyse-1/", "https://moodle.epfl.ch/course/view.php?id=14840"]) == 14840,
          "le lien Moodle retenu se relit")
}

print("== Import : ce qui est écarté le reste ==")
do {
    let keepCourse = Course(code: "TEST-301", name: "Écarts")
    context.insert(keepCourse)
    func item(_ n: String, _ url: String) -> ContentDraftItem {
        ContentDraftItem(kind: .theory, number: n, title: "T\(n)", url: url, videoCount: 0, seriesNumber: nil, theoryKind: .reading)
    }
    var reviewed = ContentDraft(source: .moodle, courseTitle: "", url: "https://moodle.epfl.ch/course/view.php?id=1",
                                sections: [ContentDraftSection(title: "S1", week: 1, weekIsInferred: false, isIncluded: true,
                                                               items: [item("1.1", "u1"), item("1.2", "u2")])])
    reviewed.sections[0].items[1].kind = .ignore
    ContentDraftWriter.apply(reviewed, to: keepCourse, context: context)
    check(keepCourse.theoryItems.count == 1, "la relecture n'importe que ce qui est gardé")
    keepCourse.theoryItems.first?.plannedWeek = 4
    var refreshed = reviewed
    refreshed.sections[0].items[1].kind = .theory
    refreshed.sections[0].week = 2
    ContentDraftWriter.apply(refreshed, to: keepCourse, context: context, updateWeeks: false)
    check(keepCourse.theoryItems.count == 1, "la mise à jour automatique ne réajoute pas un élément écarté")
    check(keepCourse.theoryItems.first?.plannedWeek == 4, "…ni ne défait une semaine corrigée à la main")
    ContentDraftWriter.apply(refreshed, to: keepCourse, context: context)
    check(keepCourse.theoryItems.count == 2, "une nouvelle relecture peut le reprendre")
    check(MoodleCourseMatcher.linkedID(in: keepCourse.contentSources) == 1, "l'adresse du cours Moodle est retenue")
    context.delete(keepCourse)
    try? context.save()
}

print("== Assistant : commandes appliquées par l'app ==")
do {
    let aCourse = Course(code: "TEST-401", name: "Commandes")
    context.insert(aCourse)
    let aSeries = ExerciseSeries(course: aCourse, seriesNumber: 1)
    context.insert(aSeries)
    let aEx = Exercise(series: aSeries, exerciseNumber: "1.1", sortOrder: 0)
    context.insert(aEx); aSeries.exercises.append(aEx)
    let qa = SubQuestion(exercise: aEx, label: "a", sortOrder: 0)
    let qb = SubQuestion(exercise: aEx, label: "b", sortOrder: 1)
    context.insert(qa); context.insert(qb); aEx.subQuestions = [qa, qb]
    let aItem = TheoryItem(course: aCourse, sectionNumber: 2, number: "2.1", title: "Suites")
    context.insert(aItem)
    try? context.save()

    let json = """
    [{"id":"c1","kind":"check_questions","payload":{"course":"test-401","exercise":"1.1","questions":["(a)"]}},
     {"id":"c2","kind":"update_exercise","payload":{"exerciseId":"\(aEx.id.uuidString)","correctness":"orange"}},
     {"id":"c3","kind":"update_exercise","payload":{"exerciseId":"\(aEx.id.uuidString)","correctness":"wrong","note":"signe"}},
     {"id":"c4","kind":"update_theory","payload":{"theoryId":"\(aItem.id.uuidString)","summary":"Définition de la limite"}},
     {"id":"c5","kind":"log_session","payload":{"course":"TEST-401","type":"exercise","minutes":45,"exercise":"1.1"}},
     {"id":"c6","kind":"add_series","payload":{"course":"TEST-401","number":2,"week":3,"exercises":[{"number":"2.1","questions":["a","b","c"]},{"number":"2.2","bonus":true}]}},
     {"id":"c7","kind":"add_exam","payload":{"course":"TEST-401","title":"Midterm","date":"2026-10-19","examKind":"midterm"}},
     {"id":"c8","kind":"update_exercise","payload":{"course":"TEST-401","exercise":"9.9","done":true}},
     {"id":"c9","kind":"teleport","payload":{}}]
    """
    let commands = (try? JSONDecoder().decode([AssistantCommand].self, from: Data(json.utf8))) ?? []
    check(commands.count == 9, "les commandes du serveur se décodent (\(commands.count))")
    let results = AssistantCommandApplier.apply(commands, context: context)
    let status = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.status) })
    check(status["c1"] == "applied" && results.first { $0.id == "c1" }?.message.contains("(1/2)") == true,
          "cocher une question par son étiquette")
    check(results.first { $0.id == "c2" }?.message.contains("moyen") == true, "« orange » est compris comme une correction moyenne")
    check(aEx.correctness == .wrong && aEx.redoRequired && aEx.correctionNote == "signe", "corrigé faux : à refaire, remarque gardée")
    check(aItem.isSummarized && aItem.isWatched, "un résumé marque la théorie vue")
    check(status["c5"] == "applied" && aEx.series?.course?.id == aCourse.id, "session enregistrée")
    let newSeries = aCourse.series.first { $0.seriesNumber == 2 }
    check(newSeries?.exercises.count == 2 && newSeries?.plannedWeek == 3, "série ajoutée, à sa semaine")
    check(newSeries?.exercises.first { $0.exerciseNumber == "2.1" }?.leafSubQuestions.count == 3, "…avec ses questions")
    check(newSeries?.exercises.first { $0.exerciseNumber == "2.2" }?.isBonus == true, "…et son bonus")
    check(aCourse.exams.first?.kind == .midterm, "évaluation ajoutée")
    check(status["c8"] == "failed" && results.first { $0.id == "c8" }?.message.contains("9.9") == true,
          "une cible introuvable échoue avec un message clair")
    check(status["c9"] == "failed", "une commande inconnue échoue sans rien casser")
    check(AssistantCommandApplier.confidence("Vert") == .high && AssistantCommandApplier.correctness("juste") == .correct,
          "les valeurs en français sont comprises")

    let exported = AssistantExport.make(courses: [aCourse], sessions: [], milestones: [], groups: [],
                                        hoursPerCredit: 30, displayName: "")
    let firstCourse = (exported["courses"] as? [[String: Any]])?.first
    let firstExercise = ((firstCourse?["series"] as? [[String: Any]])?.first?["exercises"] as? [[String: Any]])?.first
    check(exported["version"] as? Int == AssistantExport.formatVersion && firstCourse?["id"] as? String == aCourse.id.uuidString, "l'instantané porte les identifiants")
    check(firstExercise?["stage"] as? String == "à refaire" && (firstExercise?["questions"] as? [[String: Any]])?.count == 2,
          "…l'étape de chaque exercice et ses questions")

    for session in ((try? context.fetch(FetchDescriptor<StudySession>())) ?? []) where session.course?.id == aCourse.id || session.exercise?.series?.course?.id == aCourse.id {
        context.delete(session)
    }
    context.delete(aCourse)
    try? context.save()
}

print("== Botafogo : programme hebdomadaire ==")
do {
    let script = #"var x=1;const P=[{type:`section`,name:`Infos`,metadata:{},index:0,children:[{type:`section`,name:`Bienvenue`,url:`sections/welcome`,metadata:{},index:0}]},{type:`week`,name:`Suites réelles`,metadata:{number:`03`,dates:`22-26 sept`,releaseDate:`2026-09-18T06:00:00.000Z`},index:1,children:[{type:`lecture`,name:`Cours 05`,url:`aulas/aula-05`,metadata:{day:`Mercredi`,date:`2026-09-23T12:00:00.000Z`,videoId:`0_5f16lokn`},index:0},{type:`series`,name:`Nombres $\\bR$`,url:`series/AN_serie_03`,metadata:{solutionsDate:`2026-09-24T06:00:00.000Z`},index:1,children:[{type:`exercise`,name:`Ex-03-01`,url:`exercices/a`,metadata:{serie:`03`,number:`01`},index:0},{type:`exercise`,name:`Ex-03-02`,url:`exercices/b`,metadata:{serie:`03`,number:`02`},index:1}]}]}],Q=!0,R=void 0;"#
    let program = BotafogoProgram.extract(fromScript: script)
    check(program?.count == 2, "le programme se relit dans le code du site (\(program?.count ?? 0) nœuds)")
    let week = program?.first { $0.type == "week" }
    check(week?.meta("number") == "03" && week?.meta("dates") == "22-26 sept", "une semaine : numéro et dates")
    check(week?.children?.first?.meta("videoId") == "0_5f16lokn", "un cours filmé et sa vidéo")
    check(BotafogoProgram.extract(fromScript: "const a=[{type:`section`}];") == nil, "sans semaine, pas de programme")
    check(BotafogoProgram.contentPath("series/AN_serie_03") == "/course_material/series/an_serie_03", "chemin de l'API des contenus")
    check(BotafogoProgram.seriesNumber(url: "series/AN_serie_03") == 3, "numéro de série lu dans l'adresse")

    let lectureJSON = #"{"body":{"type":"root","children":[{"type":"element","tagName":"h4","properties":{},"children":[{"type":"text","value":"Matière"}]},{"type":"element","tagName":"latex-ref","properties":{"collection":"content","target":"m_suites_R_x"},"children":[{"type":"text","value":"3.5 Les suites"}]},{"type":"element","tagName":"latex-ref","properties":{"target":"seances-du-soir"},"children":[{"type":"text","value":"séances du soir"}]},{"type":"element","tagName":"videokaltura","properties":{"entryId":"0_abc","title":"Cours 05"},"children":[]}]}}"#
    let lecture = BotafogoDocument.lecture(fromNodeJSON: Data(lectureJSON.utf8))
    check(lecture.references.map(\.target) == ["m_suites_R_x"], "seules les sections du polycopié comptent comme théorie")
    check(lecture.videos.first?.id == "0_abc", "la vidéo d'un cours")

    let seriesJSON = #"{"body":{"type":"root","children":[{"type":"element","tagName":"exercise","properties":{},"children":[{"type":"element","tagName":"template","properties":{},"children":[],"content":{"type":"root","children":[{"type":"element","tagName":"b","properties":{},"children":[{"type":"text","value":"Ex-3-1:"}]},{"type":"element","tagName":"p","properties":{},"children":[{"type":"text","value":"Soit "},{"type":"element","tagName":"katex-renderer","properties":{"content":"(x_{n})"},"children":[]},{"type":"text","value":" une suite."}]},{"type":"element","tagName":"ol","properties":{},"children":[{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"Montrer que"},{"type":"element","tagName":"ol","properties":{},"children":[{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"elle est bornée"}]},{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"elle converge"}]}]}]},{"type":"element","tagName":"li","properties":{},"children":[{"type":"text","value":"Calculer sa limite"}]}]},{"type":"element","tagName":"indication","properties":{},"children":[{"type":"element","tagName":"template","properties":{},"children":[],"content":{"type":"root","children":[{"type":"text","value":"Penser aux gendarmes."}]}}]},{"type":"element","tagName":"solution","properties":{},"children":[{"type":"element","tagName":"template","properties":{},"children":[],"content":{"type":"root","children":[{"type":"text","value":"La limite vaut 1."}]}}]}]}}]}]}}"#
    let parsed = BotafogoDocument.exercises(fromNodeJSON: Data(seriesJSON.utf8))
    check(parsed.first?.number == "3.1", "numéro lu dans « Ex-3-1 »")
    check(parsed.first?.statement == "Soit $(x_{n})$ une suite.", "énoncé, formules comprises (\(parsed.first?.statement ?? ""))")
    check(parsed.first?.questions.map(\.label) == ["1", "2"] && parsed.first?.questions.first?.children.map(\.label) == ["a", "b"],
          "questions 1, 2 et points (a), (b)")
    check(parsed.first?.questions.first?.children.last?.text == "elle converge", "texte d'un point")
    check(parsed.first?.hint == "Penser aux gendarmes." && parsed.first?.solution == "La limite vaut 1.", "indication et solution")

    let handout = [NuxtPayload.NavNode(title: "3 Suites réelles", path: "#_3", children: [
        NuxtPayload.NavNode(title: "3.5 Les suites monotones et bornées", path: "/handout/matiere/m_suites_r_x", children: []),
        NuxtPayload.NavNode(title: "3.6 Suites qui tendent vers l'infini", path: "/handout/matiere/m_other", children: [])])]
    let root = URL(string: "https://botafogo.epfl.ch/analyse-1-GM/")!
    let draft = BotafogoProgramBuilder.draft(title: "Analyse I / GM", program: program ?? [], root: root, handout: handout,
                                             lectures: ["aulas/aula-05": lecture],
                                             series: ["series/AN_serie_03": parsed])
    let weekSection = draft.sections.first
    check(weekSection?.title.hasPrefix("Semaine 3 · Suites réelles") == true && weekSection?.week == 3, "une section par semaine du programme")
    let items = weekSection?.items ?? []
    check(items.first?.number == "C5" && items.first?.url == "https://mediaspace.epfl.ch/media/0_5f16lokn", "le cours filmé, avec sa vidéo")
    check(items.contains { $0.number == "3.5" && $0.title == "Les suites monotones et bornées" },
          "la section enseignée, titre complet malgré la casse de l'identifiant")
    let seriesItem = items.first { $0.kind == .series }
    check(seriesItem?.title == "Nombres ℝ" && seriesItem?.seriesNumber == 3, "la série de la semaine (\(seriesItem?.title ?? ""))")
    check(seriesItem?.exercises.count == 2 && seriesItem?.exercises.first?.questions.count == 2, "ses exercices et leurs questions")
    check(seriesItem?.exercises.first?.url == "https://botafogo.epfl.ch/analyse-1-GM/?cours=exercices/a", "le lien de chaque exercice")
    // Un exercice du programme resté brouillon sur le site n'est pas importé.
    let withoutDraft = BotafogoProgramBuilder.draft(title: "Analyse I / GM", program: program ?? [], root: root, handout: handout,
                                                    lectures: [:], series: ["series/AN_serie_03": parsed],
                                                    unpublished: ["exercices/b"])
    let keptSeries = withoutDraft.sections.first?.items.first { $0.kind == .series }
    check(keptSeries?.exercises.map(\.number) == ["3.1"], "l'exercice en brouillon sur le site est écarté — \(keptSeries?.exercises.map(\.number) ?? [])")
    check(BotafogoDocument.isUnpublished(nodeJSON: Data(#"{"body":null,"meta":{"_draft":true}}"#.utf8))
          && !BotafogoDocument.isUnpublished(nodeJSON: Data(#"{"body":{"type":"root","children":[]},"meta":{}}"#.utf8)),
          "une page Botafogo en brouillon se reconnaît")
    // Les adresses que le site lit vraiment (vérifiées dans le navigateur de
    // l'app) : un onglet par paramètre, sans préfixe `/handout/`.
    let bfRoot = URL(string: "https://botafogo.epfl.ch/analyse-1-flipped/")!
    check(BotafogoProgram.handoutURL(root: bfRoot, target: "m_reels_intro") == "https://botafogo.epfl.ch/analyse-1-flipped/?polycopie=matiere/m_reels_intro",
          "section du polycopié : ?polycopie=matiere/…")
    check(BotafogoLinks.normalize(URL(string: "https://botafogo.epfl.ch/analyse-1-flipped/?cours=&polycopie=/handout/matiere/m_reels_intro")!).absoluteString
          == "https://botafogo.epfl.ch/analyse-1-flipped/?polycopie=matiere/m_reels_intro",
          "un ancien lien (cours vide, /handout/) est réparé à l'ouverture")
    check(BotafogoLinks.normalize(URL(string: "https://botafogo.epfl.ch/analyse-1-flipped?cours=series/AN_serie_03&polycopie=")!).absoluteString
          == "https://botafogo.epfl.ch/analyse-1-flipped/?cours=series/AN_serie_03",
          "…et la barre finale, sans laquelle la requête est perdue")
    check(BotafogoLinks.isPage("https://botafogo.epfl.ch/analyse-1-flipped/?cours=series/AN_serie_06")
          && !BotafogoLinks.isPage("https://botafogo.epfl.ch/analyse-1-flipped/files/serie06.pdf")
          && !BotafogoLinks.isPage("https://moodle.epfl.ch/mod/resource/view.php?id=1")
          && !BotafogoLinks.isPage(""),
          "Botafogo : une série est une page lue en natif, pas un PDF à télécharger")
    check(BotafogoLinks.coursPath("https://botafogo.epfl.ch/analyse-1-flipped/?cours=series/AN_serie_06") == "series/AN_serie_06"
          && BotafogoLinks.coursPath("https://botafogo.epfl.ch/analyse-1-flipped/?cours=") == nil,
          "Botafogo : la page d'une série se retrouve depuis son adresse")
    check(MathMarkup.plain("z^2=-3+4\\mathsf{i}") == MathMarkup.plain("z^2=-3+4i"), "Math : \\mathsf{i} → i")
    check(BotafogoLinks.normalize(URL(string: "https://moodle.epfl.ch/course/view.php?id=1&x=")!).absoluteString == "https://moodle.epfl.ch/course/view.php?id=1&x=",
          "les autres sites ne sont pas touchés")
    check(SiteLinks.normalize(URL(string: "https://moodle.epfl.ch/mod/resource/view.php?id=42")!).absoluteString
          == "https://moodle.epfl.ch/mod/resource/view.php?id=42&redirect=1",
          "un fichier Moodle s'ouvre sur le fichier, pas sur la page « télécharger »")
    check(seriesItem?.solutionsAt != nil, "la date de publication du corrigé")
    let leftovers = draft.sections.last
    check(leftovers?.isIncluded == false && leftovers?.items.map(\.number) == ["3.6"], "ce que le programme ne cite pas est proposé à part, décoché")

    let aCourse = Course(code: "TEST-501", name: "Programme")
    context.insert(aCourse)
    let outcome = ContentDraftWriter.apply(draft, to: aCourse, context: context)
    let written = aCourse.series.first { $0.seriesNumber == 3 }
    check(outcome.exercisesAdded == 2 && written?.exercises.count == 2, "les exercices sont écrits à l'import")
    let first = written?.exercises.first { $0.exerciseNumber == "3.1" }
    check(first?.leafSubQuestions.count == 3 && first?.hint == "Penser aux gendarmes." && first?.solution == "La limite vaut 1.",
          "…avec questions, indication et solution")
    check(written?.plannedWeek == 3 && written?.solutionsAt != nil && written?.topic == "Nombres ℝ", "…à leur semaine, thème et corrigé")
    check(aCourse.theoryItems.contains { $0.number == "3.5" && $0.plannedWeek == 3 && $0.urlString.contains("m_suites_r_x") },
          "la théorie tombe à la semaine où elle est enseignée, avec son lien")
    first?.subQuestions.first?.toggle()
    ContentDraftWriter.apply(draft, to: aCourse, context: context, updateWeeks: false)
    check(first?.subQuestionDoneCount == 2, "une mise à jour garde les questions cochées")
    context.delete(aCourse)
    try? context.save()
}

print("== Moodle : analyse de vrais cours ==")
do {
    let term = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 7))!
    var nextID = 0
    func act(_ name: String, _ module: String, target: String? = nil, due: Date? = nil, visible: Bool = true) -> MoodleActivity {
        nextID += 1
        return MoodleActivity(id: "\(nextID)", name: name, module: module,
                              url: "https://moodle.epfl.ch/mod/\(module)/view.php?id=\(nextID)",
                              target: target, dueDate: due, isVisible: visible)
    }

    // CS-107 : semaines à l'envers, un enregistrement et deux versions des
    // transparents par semaine, un mini-projet, la date d'examen dans un titre.
    let cs107 = MoodleCourseSnapshot(title: "Introduction à la programmation", url: "https://moodle.epfl.ch/course/view.php?id=14847", sections: [
        MoodleSection(number: 0, title: "Informations générales", activities: []),
        MoodleSection(number: 1, title: "Horaires et salles", activities: [act("Cours en présentiel: Mercredi 1415-1500 au RLCE124", "label")]),
        MoodleSection(number: 2, title: "Calendrier", activities: [act("Plan du cours", "url", target: "https://proginsc.epfl.ch/wwwhiver/planning.php")]),
        MoodleSection(number: 5, title: "Fora", activities: [act("Annonces du cours", "forum"), act("Forum de discussion", "lti")]),
        MoodleSection(number: 7, title: "Mini-projet 1 en auto-évaluation", activities: [
            act("Fin du projet (fin du challenge et objectif pour 60% des points a minima)", "label"),
            act("⚠️Selection d'un groupe (DÉLAI 13.10, 18:00)⚠️", "choicegroup")]),
        MoodleSection(number: 18, title: " Semaine 4 : Types «avancés»", activities: [
            act("Enregistrement vidéo du cours du 1.10.2025", "url", target: "https://mediaspace.epfl.ch/media/CS-107+cours+4/0_abc"),
            act("Transparents (4 pages sur 1)", "url", target: "https://proginsc.epfl.ch/wwwhiver/documents/cours04.pdf"),
            act("Transparents (1 page sur 1)", "url", target: "https://proginsc.epfl.ch/wwwhiver/documents/cours04-full.pdf"),
            act("Enoncé/Corrigé de la série 4", "url", target: "https://proginsc.epfl.ch/wwwhiver/series/serie04/serie.html")]),
        MoodleSection(number: 21, title: "Semaine 1 : Introduction & Mise en place de l'environnement", activities: [
            act("Transparents (Introduction) (1 page sur 1)", "url", target: "https://proginsc.epfl.ch/wwwhiver/documents/cours01a.pdf"),
            act("Transparents (algorithmes) (1 page sur 1)", "url", target: "https://proginsc.epfl.ch/wwwhiver/documents/cours01b.pdf"),
            act("Enoncé/Corrigé de la série 1", "url", target: "https://proginsc.epfl.ch/wwwhiver/series/serie01/serie.html"),
            act("Matériel annexe :Mini-référence : Environnement", "label")]),
        MoodleSection(number: 22, title: "Examen Final (samedi 12.12, 09:00-12:00)", activities: []),
        MoodleSection(number: 24, title: "Questionnaires", activities: [act("Machines personnelles", "questionnaire")])])
    let d107 = MoodleCourseAnalyzer.draft(from: cs107, termStart: term)
    let weeks107 = d107.sections.filter { $0.week > 0 }
    check(weeks107.map(\.week) == [1, 4], "semaines remises dans l'ordre du semestre (\(weeks107.map(\.week)))")
    let week4 = weeks107.last?.items ?? []
    let lecture4 = week4.first { $0.kind == .theory }
    check(week4.filter { $0.kind == .theory }.count == 1, "l'enregistrement et les deux transparents font **un** cours")
    check(lecture4?.title == "Types «avancés»" && lecture4?.theoryKind == .video && lecture4?.links.count == 3,
          "…nommé par le sujet de la semaine, vidéo et transparents liés (\(lecture4?.title ?? ""))")
    let series4 = week4.first { $0.kind == .series }
    check(series4?.seriesNumber == 4 && series4?.solutionURL == series4?.url, "« Enoncé/Corrigé de la série 4 » : énoncé et corrigé")
    let week1Theory = weeks107.first?.items.filter { $0.kind == .theory } ?? []
    check(week1Theory.count == 1 && week1Theory.first?.links.count == 2
          && week1Theory.first?.title == "Introduction & Mise en place de l'environnement",
          "un élément par semaine : les deux transparents réunis, nommés par le sujet (\(week1Theory.map(\.title)))")
    let deadlines107 = d107.sections.first { $0.title.hasPrefix("Échéances") }?.items ?? []
    check(deadlines107.contains { $0.examKind == .exam && $0.title == "Examen Final" && $0.date != nil },
          "l'examen final est une échéance, daté par le titre de sa section")
    check(deadlines107.contains { $0.examKind == .project && $0.title.contains("Selection d'un groupe") },
          "le mini-projet n'est pas du travail à suivre : son délai devient une échéance")
    check(!d107.sections.flatMap(\.items).contains { $0.title.contains("Fin du projet") && ($0.kind == .theory || $0.kind == .series) },
          "rien du projet n'est rangé en théorie ou en série")
    check(d107.sections.first { $0.title.hasPrefix("Documents") }?.items.contains { $0.title == "Plan du cours" } == true,
          "le plan du cours est gardé comme document")
    // Série dont l'énoncé, sur Moodle, mène au MOOC : la page du corrigé
    // (proginsc, énoncé compris) devient l'énoncé.
    let cs107b = MoodleCourseSnapshot(title: "Introduction à la programmation", url: "https://moodle.epfl.ch/course/view.php?id=14847", sections: [
        MoodleSection(number: 19, title: "Semaine 4 : Types «avancés»", activities: [
            act("Enoncé de la série 4", "url", target: "https://courseware.epfl.ch/courses/course-v1:EPFL+intro-prog-java+2024/jump_to/block-v1:EPFL+intro-prog-java+2024+type@sequential+block@Exercices_ID-1"),
            act("Corrigé de la série 4", "url", target: "https://proginsc.epfl.ch/wwwhiver/series/serie04/serie.html")])])
    let series4b = MoodleCourseAnalyzer.draft(from: cs107b, termStart: term).sections.flatMap(\.items).first { $0.kind == .series }
    check(series4b?.url == "https://proginsc.epfl.ch/wwwhiver/series/serie04/serie.html",
          "énoncé sur le MOOC, corrigé sur proginsc : la page proginsc est l'énoncé (\(series4b?.url ?? "aucune série"))")

    // PHYS-101(en) : notes vierges et annotées + enregistrement = un cours ;
    // « Problem Set » et ses solutions ; anciens examens.
    let phys = MoodleCourseSnapshot(title: "Physique générale : mécanique (anglais)", url: "u", sections: [
        MoodleSection(number: 0, title: "General", activities: [act("Math review", "resource"), act("Formula sheet for Final exam", "resource")]),
        MoodleSection(number: 1, title: "Previous final exams", activities: [
            act("Final Exam 2025", "resource"), act("Final Exam Solutions 2025", "resource")]),
        MoodleSection(number: 2, title: "7 September - 13 September", activities: [
            act("Lecture notes 1a (blank)", "resource"), act("Lecture notes 1a (annotated)", "resource"),
            act("Lecture notes 1b (blank)", "resource"), act("Lecture notes 1b (annotated)", "resource"),
            act("Lecture 1a recording", "url", target: "https://mediaspace.epfl.ch/media/1a"),
            act("Lecture 1b recording", "url", target: "https://mediaspace.epfl.ch/media/1b"),
            act("Problem Set 1: Motion in 1D", "resource"),
            act("Problem Set 1 Solutions: Motion in 1D", "resource")])])
    let dphys = MoodleCourseAnalyzer.draft(from: phys, termStart: term)
    let physWeek = dphys.sections.first { $0.week == 1 }?.items ?? []
    let physTheory = physWeek.filter { $0.kind == .theory }
    check(physTheory.map(\.number) == ["1"] && physTheory.first?.title == "Cours de la semaine 1",
          "les cours 1a et 1b : **un** élément de la semaine (\(physTheory.map(\.title)))")
    check(physTheory.first?.links.count == 6 && physTheory.first?.links.filter { $0.kind == .video }.count == 2,
          "…avec les quatre notes et les deux enregistrements")
    let ps1 = physWeek.first { $0.kind == .series }
    check(ps1?.seriesNumber == 1 && ps1?.title == "Motion in 1D" && !(ps1?.solutionURL.isEmpty ?? true) && !(ps1?.pdfURL.isEmpty ?? true),
          "Problem Set 1 : thème, PDF à lire, solutions rattachées")
    check(dphys.sections.first { $0.title == "Anciens examens" }?.items.first.map { $0.number == "2025" && !$0.solutionURL.isEmpty } == true,
          "l'examen 2025 et sa solution font une annale")

    // MATH-111(pi) : « Série 1 » / « Série 1 - Corrigé », « serie04 sol »,
    // chapitres « 01-Systemes-lineaires », rendus en groupe, méthodologie.
    let due = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 23, minute: 59))!
    let alg = MoodleCourseSnapshot(title: "Algèbre linéaire (classe inversée)", url: "u", sections: [
        MoodleSection(number: 1, title: "7 September - 13 September", activities: [
            act("Série 1", "resource"), act("Série 1 - Corrigé", "resource"), act("Inscription à un groupe", "choicegroup"),
            act("Rendu 01 (en groupe) - Contrat et inscription sur Moodle", "assign", due: due),
            act("Notes du cours", "label"), act("introduction-2026", "resource"), act("01-Systemes-lineaires", "resource"),
            act("Equipe et comportements constructif-destructif", "resource"), act("Contrat-d-equipe", "resource")]),
        MoodleSection(number: 4, title: "28 September - 4 October", activities: [
            act("serie04", "resource"), act("serie04 sol", "resource", visible: false), act("04-Espaces-vectoriels", "resource"),
            act("Rendu 04 (en groupe)", "assign", due: due), act("rendu04 sol", "resource"),
            act("Apprendre à étudier - 03 (comprendre des preuves)", "resource")])])
    let dalg = MoodleCourseAnalyzer.draft(from: alg, termStart: term)
    let algWeek1 = dalg.sections.first { $0.week == 1 }?.items ?? []
    check(algWeek1.contains { $0.kind == .series && $0.seriesNumber == 1 && !$0.solutionURL.isEmpty }, "Série 1 et son corrigé")
    check(algWeek1.contains { $0.kind == .theory && $0.title.contains("Systemes lineaires") }, "le chapitre 01 devient de la théorie lisible")
    check(!algWeek1.contains { $0.title.contains("Contrat") || $0.title.contains("Equipe") }, "les documents d'équipe ne sont pas de la théorie")
    let algWeek4 = dalg.sections.first { $0.week == 4 }?.items ?? []
    check(algWeek4.contains { $0.kind == .series && $0.seriesNumber == 4 && $0.solutionURL.isEmpty },
          "serie04 sans son corrigé (pas encore visible)")
    check(!algWeek4.contains { $0.kind == .series && $0.url.contains("rendu") }, "le corrigé d'un rendu n'est pas une série")
    let algDeadlines = dalg.sections.first { $0.title.hasPrefix("Échéances") }?.items ?? []
    check(algDeadlines.count == 2 && algDeadlines.allSatisfy { $0.examKind == .assignment && $0.date == due },
          "les rendus notés sont des échéances datées")
    check(dalg.sections.first { $0.title.hasPrefix("Documents") }?.items.contains { $0.title.hasPrefix("Apprendre à étudier") } == true,
          "« Apprendre à étudier » : un document, pas un cours")

    // CS-101 : « Week N », cours du mardi = transparents + notes annotées,
    // « Exercise » / « Solution » sans numéro = la série de la semaine.
    let cs101 = MoodleCourseSnapshot(title: "AICC I", url: "u", sections: [
        MoodleSection(number: 5, title: "Week 2: 14 September - 18 September", activities: [
            act("Lecture — Tuesday", "url", target: "https://www.dropbox.com/week_2_1.pdf"),
            act("Annotated lecture notes (Tuesday)", "resource"),
            act("Lecture — Wednesday", "url", target: "https://www.dropbox.com/week_2_2.pdf"),
            act("Exercise", "url", target: "https://urbanke.github.io/week02-exercises.pdf"),
            act("Solution", "url", target: "https://urbanke.github.io/week02-solutions.pdf")])])
    let d101 = MoodleCourseAnalyzer.draft(from: cs101, termStart: term)
    let w2 = d101.sections.first?.items ?? []
    check(d101.sections.first?.week == 2, "« Week 2 » est la semaine 2")
    check(w2.filter { $0.kind == .theory }.map(\.title) == ["Cours de la semaine 2"], "cours du mardi et du mercredi : un élément de la semaine")
    check(w2.first?.links.count == 3, "transparents du mardi et du mercredi, notes annotées : tous liés")
    let dropboxPDF = w2.first?.links.first { $0.url.contains("dropbox") }
    check(dropboxPDF?.kind == .slides || dropboxPDF?.kind == .pdf, "un PDF Dropbox (« .pdf?rlkey=… ») est un PDF, pas une page")

    // Les vrais titres : une plage de dates n'est pas un sujet, « (semaine
    // courante) » n'est pas un titre, une consigne datée n'est pas un cours
    // du mercredi, le titre d'un enregistrement MediaSpace nomme le cours.
    let real = MoodleCourseSnapshot(title: "t", url: "u", sections: [
        MoodleSection(number: 2, title: "Week 1: 7 September - 11 September", activities: [
            act("Introduction", "url", target: "https://www.dropbox.com/scl/fi/x/introduction.pdf?rlkey=k&raw=1"),
            act("Lecture — Tuesday", "url", target: "https://www.dropbox.com/scl/fi/y/week_1_1.pdf?rlkey=k&raw=1")]),
        MoodleSection(number: 3, title: "Semaine 3 : Structures de contrôle (semaine courante)", activities: [
            act("Transparents (4 pages sur 1)", "url", target: "https://proginsc.epfl.ch/cours03.pdf")]),
        MoodleSection(number: 4, title: "Semaine 1 : Introduction", activities: [
            act("Vidéos à visionner et Quiz à résoudre avant le mercredi 16.9", "url", target: "https://mediaspace.epfl.ch/media/x"),
            act("Transparents (Introduction) (1 page sur 1)", "url", target: "https://proginsc.epfl.ch/cours01a.pdf")]),
        MoodleSection(number: 5, title: "14 September - 20 September", activities: [
            act("Lecture notes 1a (blank)", "resource"),
            act("Lecture 1a recording", "url", target: "https://mediaspace.epfl.ch/media/PHYS-101%28en%29+Lecture+1a%3A+Motion+in+one+dimension/0_6y8w1d2s/30253")])])
    let dreal = MoodleCourseAnalyzer.draft(from: real, termStart: term)
    let titles = dreal.sections.flatMap(\.items).filter { $0.kind == .theory }.map(\.title)
    check(titles.contains("Introduction") && !titles.contains { $0.contains("September") }, "une plage de dates ne nomme pas un cours — \(titles)")
    check(dreal.sections.contains { $0.title == "Semaine 3 : Structures de contrôle" }, "« (semaine courante) » retiré du titre")
    check(titles.contains("Structures de contrôle"), "…et le sujet de la semaine nomme son cours")
    check(!titles.contains("Cours du mercredi"), "une consigne « avant le mercredi » n'est pas le cours du mercredi")
    check(titles.contains("Motion in one dimension"), "le titre de l'enregistrement nomme le cours 1a")
    check(MoodleCourseAnalyzer.prettifyFileName("introduction-2026") == "Introduction", "nom de fichier rendu lisible")
    check(MoodleCourseAnalyzer.prettifyFileName("Plan du cours") == "Plan du cours", "un vrai titre reste tel quel")
    let ex2 = w2.first { $0.kind == .series }
    check(ex2?.seriesNumber == 2 && ex2?.pdfURL.hasSuffix("exercises.pdf") == true && ex2?.solutionURL.hasSuffix("solutions.pdf") == true,
          "« Exercise » / « Solution » : la série 2, PDF public à lire")

    // MOOC cité depuis Moodle : chaque leçon rangée à la semaine où Moodle
    // la cite, sinon par « Semaine N », sinon par numéro de chapitre.
    let moocSnapshot = MoodleCourseSnapshot(title: "Algèbre", url: "u", sections: [
        MoodleSection(number: 3, title: "21 September - 27 September", activities: [act("03-Calcul-matriciel", "resource")]),
        MoodleSection(number: 4, title: "28 September - 4 October", activities: [act("04-Espaces-vectoriels", "resource")])])
    let moocBase = MoodleCourseAnalyzer.draft(from: moocSnapshot, termStart: term)
    let key = "course-v1:EPFL+AlgebreLineaire+2026"
    let moocRefs = [MoocReference(url: "https://courseware.epfl.ch/courses/\(key)/jump_to/block-v1:EPFL+AlgebreLineaire+2026+type@vertical+block@u1",
                                  title: "Vidéos de la semaine", sectionNumber: 3)]
    check(moocRefs.first?.courseKey == key, "clé du MOOC lue dans le lien")
    let mooc = ScrapedCourse(source: "courseware", title: "Algèbre linéaire", url: "c", sections: [
        ScrapedSection(title: "Matrices", items: [
            ScrapedItem(title: "Produit matriciel", url: "https://courseware.epfl.ch/l1", type: "sequential", videoCount: 2,
                        id: "block-v1:EPFL+AlgebreLineaire+2026+type@sequential+block@s1",
                        blockIDs: ["block-v1:EPFL+AlgebreLineaire+2026+type@vertical+block@u1"],
                        links: [ContentLink(title: "Vidéo 1", url: "https://courseware.epfl.ch/xblock/v1", kind: .video),
                                ContentLink(title: "Vidéo 2", url: "https://courseware.epfl.ch/xblock/v2", kind: .video)])]),
        ScrapedSection(title: "Semaine 6 : Déterminants", items: [ScrapedItem(title: "Définition", url: "https://courseware.epfl.ch/l2", type: "sequential")]),
        ScrapedSection(title: "4. Espaces vectoriels", items: [ScrapedItem(title: "Sous-espaces", url: "https://courseware.epfl.ch/l3", type: "sequential")]),
        ScrapedSection(title: "Annexe", items: [ScrapedItem(title: "Rappels", url: "https://courseware.epfl.ch/l4", type: "sequential")])])
    let merged = MoocMerger.merge(mooc: mooc, references: moocRefs, snapshot: moocSnapshot, into: moocBase, termStart: term)
    func moocWeek(_ url: String) -> Int? {
        for section in merged.sections {
            for item in section.items where item.url == url || item.links.contains(where: { $0.url == url }) {
                return item.kind == .theory ? item.plannedWeek(in: section) : 0
            }
        }
        return nil
    }
    check(moocWeek("https://courseware.epfl.ch/xblock/v1") == 3 && moocWeek("https://courseware.epfl.ch/xblock/v2") == 3,
          "leçon citée depuis la section de la semaine 3 : ses vidéos dans la semaine 3")
    check(moocWeek("https://courseware.epfl.ch/l2") == 6, "« Semaine 6 » dans le titre du chapitre")
    check(moocWeek("https://courseware.epfl.ch/l3") == 4, "chapitre 4 → la semaine où Moodle traite le chapitre 4 (\(moocWeek("https://courseware.epfl.ch/l3") ?? -1))")
    check(moocWeek("https://courseware.epfl.ch/l4") == nil, "une leçon que le cours ne demande pas n'est pas importée")
    let week3Items = merged.sections.filter { $0.week == 3 }.flatMap(\.items).filter { $0.kind == .theory }
    check(week3Items.count == 2 && week3Items.contains { $0.title == "MOOC · Matrices" && $0.number == "M1-1" },
          "le chapitre du MOOC demandé est un élément à part de la semaine 3, à côté du cours (\(week3Items.map(\.title)))")
    let exerciseLesson = ScrapedItem(title: "Exercices de la semaine", url: "x", type: "sequential")
    check(MoocMerger.isExercise(exerciseLesson), "les exercices en ligne du MOOC ne sont pas à faire ici")

    check(MoodleCourseAnalyzer.dueDate(fromActivityDates: "Opened: Monday, 31 August 2026, 12:00 PM Due: Friday, 2 October 2026, 11:59 PM")
          == Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "Europe/Zurich"), year: 2026, month: 10, day: 2, hour: 23, minute: 59)),
          "échéance lue sur la page d'un devoir (anglais)")
    check(MoodleCourseAnalyzer.dueDate(fromActivityDates: "Ouvert le : lundi 31 août 2026, 12:00 À remettre : vendredi 2 octobre 2026, 23:59") != nil,
          "…et en français")

    let written = Course(code: "TEST-601", name: "Écriture")
    context.insert(written)
    let outcome = ContentDraftWriter.apply(dalg, to: written, context: context)
    check(outcome.deadlinesAdded == 2 && written.exams.count == 2, "les échéances deviennent des évaluations du cours")
    check(written.documents.contains { $0.title.hasPrefix("Apprendre") }, "les documents sont gardés comme liens")

    // Rythme d'un cours : ce qui manque des semaines passées, ce qui est fait
    // d'avance ; la semaine en cours ne compte ni pour l'un ni pour l'autre.
    let paced = Course(code: "TEST-777", name: "Rythme")
    context.insert(paced)
    for (week, watched) in [(1, false), (2, true), (3, false), (5, true)] {
        let item = TheoryItem(course: paced, sectionNumber: 1, number: "1.\(week)", title: "t\(week)", kind: .video,
                              plannedWeek: week, sortOrder: week, urlString: "")
        if watched { item.watchedAt = Date() }
        context.insert(item)
    }
    check(ProgressEngine.lateCount(for: paced, currentWeek: 3) == 1, "une vidéo de la semaine 1 non vue : 1 en retard")
    check(ProgressEngine.aheadCount(for: paced, currentWeek: 3) == 1, "une vidéo de la semaine 5 déjà vue : 1 d'avance")
    // Corriger fait partie du travail : la correction en retard compte.
    let graded = Course(code: "TEST-778", name: "Corrections")
    context.insert(graded)
    let pastSeries = ExerciseSeries(course: graded, seriesNumber: 1, plannedWeek: 1)
    let lockedSeries = ExerciseSeries(course: graded, seriesNumber: 2, plannedWeek: 2)
    lockedSeries.solutionsAt = Date().addingTimeInterval(86400)
    context.insert(pastSeries)
    context.insert(lockedSeries)
    let doneUncorrected = Exercise(series: pastSeries, exerciseNumber: "1.1", sortOrder: 1)
    doneUncorrected.setDone(true)
    let redo = Exercise(series: pastSeries, exerciseNumber: "1.2", sortOrder: 2)
    redo.setDone(true)
    redo.correct(.wrong)
    redo.redoRequired = true
    let waiting = Exercise(series: lockedSeries, exerciseNumber: "2.1", sortOrder: 1)
    waiting.setDone(true)
    [doneUncorrected, redo, waiting].forEach(context.insert)
    let gradedDue = ProgressEngine.correctionsDue(for: graded, currentWeek: 3)
    check(gradedDue.toCorrect == 0, "hors retard : la correction de la série 1 (échue) est déjà dans le retard, celle de la série 2 attend son corrigé")
    check(ProgressEngine.lateCount(for: graded, currentWeek: 3) == 2,
          "en retard : la correction d'une semaine passée et l'exercice à refaire (\(ProgressEngine.lateCount(for: graded, currentWeek: 3)))")
    ContentDraftWriter.apply(dalg, to: written, context: context, updateWeeks: false)
    check(written.exams.count == 2 && written.documents.count == outcome.documentsAdded, "une mise à jour ne double rien")
    let wphys = Course(code: "TEST-602", name: "Liens")
    context.insert(wphys)
    ContentDraftWriter.apply(dphys, to: wphys, context: context)
    check(wphys.theoryItems.first { $0.number == "1" }?.links.count == 6, "les liens d'un cours sont écrits")
    check(wphys.pastExams.count == 1, "l'annale est écrite")
    context.delete(written); context.delete(wphys)
    try? context.save()
}

print("== Séries publiées en HTML (CS-107) ==")
do {
    let html = #"""

  

</table>

<br>

<table border="0" cellpadding="2" cellspacing="0" width="100%">
  <tbody><tr> 
    <td width="75">&nbsp;</td>

	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><b>Tous les exercices sur une page:</b> <a target="_blank" href="../serie03/serie_print.html">[Enonc&eacute;]</a>  | <a target="_blank" href="../serie03/solution_print.html">[Corrig&eacute;]</a> </td>
  </tr>
</tbody></table>

<p>&nbsp; </p>
<table width="100%" border="0" cellpadding="2" cellspacing="0">
  <tr> 
    <td width="75"><div align="right"><strong><font size="+1">
	3.1
	</font></strong></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><strong><font size="+1">
    <a href="../serie03/ex1/task.html">R&eacute;solution de polyn&ocirc;mes de degr&eacute; 2</a>
    </font></strong></td>
    <td width="100"><div align="right"><font size="+1"><strong>Niv. 0</strong></font></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>    
  </tr>
  <tr> 
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><div align="justify"> Nous voulons &eacute;crire un programme permettant de trouver les z&eacute;ros de polyn&ocirc;mes de degr&eacute; 2.</div></td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>  </tr>
  <tr> 
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
	<td>
		<a href="../serie03/ex1/task.html">[Enonc&eacute;]</a> 
		<a href="../serie03/ex1/solution.html">[Corrig&eacute;]</a>
	</td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
  </tr>
</table>
<br>
<table width="100%" border="0" cellpadding="2" cellspacing="0">
  <tr> 
    <td width="75"><div align="right"><strong><font size="+1">
	3.2
	</font></strong></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><strong><font size="+1">
    <a href="../serie03/ex2/task.html">MOOC (cours en ligne) </a>
    </font></strong></td>
    <td width="100"><div align="right"><font size="+1"><strong>Niv. 1</strong></font></div></td>
	<td width="25"><font color="#000000">&nbsp;</font></td>    
  </tr>
  <tr> 
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
    <td><div align="justify">Quiz : structures de contr&ocirc;le</div></td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>  </tr>
  <tr> 
    <td width="75">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
	<td>
		<a href="../serie03/ex2/task.html">[Enonc&eacute;]</a> 
		<a href="../serie03/ex2/solution.html">[Corrig&eacute;]</a>
	</td>
	<td width="100">&nbsp;</td>
	<td width="25"><font color="#000000">&nbsp;</font></td>
  </tr>
</table>
<br>

"""#
    let base = URL(string: "https://proginsc.epfl.ch/wwwhiver/series/serie03/serie.html")!
    let page = SeriesPageParser.parseProginsc(html: html, baseURL: base)
    check(page?.exercises.map(\.number) == ["3.1", "3.2"], "exercices lus sur la page (\(page?.exercises.map(\.number) ?? []))")
    check(page?.exercises.first?.title == "Résolution de polynômes de degré 2", "titre, entités décodées (\(page?.exercises.first?.title ?? ""))")
    check(page?.exercises.first?.statement.contains("zéros de polynômes") == true && page?.exercises.first?.statement.hasSuffix("Niveau 0") == true,
          "résumé et niveau")
    check(page?.exercises.first?.url == "https://proginsc.epfl.ch/wwwhiver/series/serie03/ex1/task.html", "lien de l'énoncé")
    check(page?.solutionURL == "https://proginsc.epfl.ch/wwwhiver/series/serie03/solution_print.html", "corrigé complet")
    check(SeriesPageParser.parseProginsc(html: "<html>rien</html>", baseURL: base) == nil, "une autre page n'est pas une série")
}

print("== Exercice par exercice ==")
do {
    let flowSeries = ExerciseSeries(seriesNumber: 9)
    context.insert(flowSeries)
    let e1 = Exercise(series: flowSeries, exerciseNumber: "9.1", sortOrder: 0)
    let e2 = Exercise(series: flowSeries, exerciseNumber: "9.2", sortOrder: 1)
    let e3 = Exercise(series: flowSeries, exerciseNumber: "9.3", isBonus: true, sortOrder: 2)
    let e4 = Exercise(series: flowSeries, exerciseNumber: "9.4", sortOrder: 3)
    for e in [e1, e2, e3, e4] { context.insert(e); flowSeries.exercises.append(e) }
    let all = [e1, e2, e3, e4]

    check(ExerciseStage(e1) == .toDo, "rien de coché : à faire")
    check(ExerciseFlow.resumePoint(in: all)?.id == e1.id, "on reprend au premier exercice")
    e1.setDone(true)
    check(e1.correctness == nil, "cocher ne donne aucune couleur : la couleur est celle de la correction")
    check(ExerciseStage(e1) == .toCorrect, "fait : à corriger")
    check(ExerciseFlow.resumePoint(in: all)?.id == e2.id, "puis au suivant pas fait")
    e1.correct(.partial)
    check(ExerciseStage(e1) == .corrected(.partial) && !e1.redoRequired, "corrigé orange")
    e1.clearCorrection()
    check(ExerciseStage(e1) == .toCorrect, "retirer la correction revient à « à corriger »")
    e1.correct(.wrong)
    check(e1.redoRequired && ExerciseStage(e1) == .redo, "corrigé faux : à refaire, et c'est ce qui s'affiche")
    e1.correct(.correct)
    check(!e1.redoRequired && ExerciseStage(e1) == .corrected(.correct), "refait juste : le « à refaire » tombe")
    e2.setDone(true); e4.setDone(true)
    check(ExerciseFlow.resumePoint(in: all)?.id == e3.id, "les bonus passent après les obligatoires")
    e4.redoRequired = true
    check(ExerciseFlow.resumePoint(in: all)?.id == e4.id, "…et après ce qui est à refaire")
    e4.redoRequired = false
    check(ExerciseFlow.next(after: e1, in: all)?.id == e3.id, "« Suivant » saute les exercices déjà faits")
    check(ExerciseFlow.next(after: e4, in: all) == nil, "fin de série : pas de suivant")
    e2.correct(.correct)
    e2.setDone(false)
    check(e2.correctness == nil && !e2.isDone, "décocher efface la correction")
    let e5 = Exercise(series: flowSeries, exerciseNumber: "9.5", sortOrder: 4)
    context.insert(e5)
    e5.correct(.correct)
    check(e5.isDone && ExerciseStage(e5) == .corrected(.correct), "corriger un exercice le marque fait")
    context.delete(e5)

    let q1 = SubQuestion(exercise: e2, label: "a", sortOrder: 0)
    let q2 = SubQuestion(exercise: e2, label: "b", sortOrder: 1)
    context.insert(q1); context.insert(q2)
    e2.subQuestions = [q1, q2]
    q1.toggle()
    check(ExerciseStage(e2) == .inProgress(done: 1, total: 2), "une question sur deux : en cours, 1/2")
    check(ExerciseStage(e2).label == "1/2", "…et c'est ce que dit la ligne")

    let session = StudySession(taskType: .exercise, durationSeconds: 1200, exercise: e1)
    context.insert(session)
    check(ExerciseFlow.seconds(on: e1, live: 30) == 1230, "temps d'un exercice : sessions + chrono en cours")
    check(ExerciseFlow.seconds(on: flowSeries) == 1200, "temps d'une série")
    context.delete(session)
    for question in [q1, q2] { context.delete(question) }
    for exercise in all { context.delete(exercise) }
    context.delete(flowSeries)
    try? context.save()
}

print("== Chrono : le temps suit l'exercice ==")
do {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let course = UUID(), ex1 = UUID(), ex2 = UUID(), ex3 = UUID()
    var timer = FocusTimerState(sessionStartedAt: t0, courseID: course, taskTypeRaw: TaskType.exercise.rawValue, targetID: ex1)
    timer.start(at: t0)
    // 40 min sur 3.1, puis 3.2 pendant 10 min, retour sur 3.1 pendant 5 min.
    timer.switchContext(courseID: course, taskTypeRaw: TaskType.exercise.rawValue, targetID: ex2, at: t0.addingTimeInterval(2400))
    check(timer.currentTargetElapsed(at: t0.addingTimeInterval(2460)) == 60, "la nouvelle cible part de zéro")
    timer.switchContext(courseID: course, taskTypeRaw: TaskType.exercise.rawValue, targetID: ex2, at: t0.addingTimeInterval(2500))
    check(timer.segments?.count == 1, "revenir sur la même cible n'ouvre pas de segment")
    timer.switchContext(courseID: course, taskTypeRaw: TaskType.exercise.rawValue, targetID: ex1, at: t0.addingTimeInterval(3000))
    let end = t0.addingTimeInterval(3300)
    let parts = timer.allocation(at: end)
    check(parts.count == 2, "deux cibles, deux parts (\(parts.count)) — les passages sur 3.1 fusionnent")
    check(parts.first { $0.targetID == ex1 }?.seconds == 2700, "3.1 : 40 + 5 min")
    check(parts.first { $0.targetID == ex2 }?.seconds == 600, "3.2 : 10 min")
    let whole = timer.allocatedSeconds(at: end)
    check(whole.reduce(0) { $0 + $1.seconds } == 3300, "la somme des sessions vaut exactement le temps affiché")

    // Pause : le temps en pause n'est attribué à personne.
    var paused = FocusTimerState(sessionStartedAt: t0, courseID: course, taskTypeRaw: TaskType.exercise.rawValue, targetID: ex1)
    paused.start(at: t0)
    paused.pause(at: t0.addingTimeInterval(600))
    paused.switchContext(courseID: course, taskTypeRaw: TaskType.exercise.rawValue, targetID: ex3, at: t0.addingTimeInterval(5000))
    paused.start(at: t0.addingTimeInterval(5000))
    let pausedParts = paused.allocation(at: t0.addingTimeInterval(5300))
    check(pausedParts.first { $0.targetID == ex1 }?.seconds == 600, "une pause entre deux exercices ne compte pour aucun")
    check(pausedParts.first { $0.targetID == ex3 }?.seconds == 300, "…et le suivant ne compte que son temps")

    // Temps corrigé à la baisse sous la somme des segments : réduction proportionnelle.
    var corrected = timer
    corrected.pause(at: end)
    corrected.accumulated = 1650
    let shrunk = corrected.allocatedSeconds(at: end)
    check(shrunk.reduce(0) { $0 + $1.seconds } == 1650, "un total corrigé à la baisse reste la somme exacte")
    check(shrunk.allSatisfy { $0.seconds >= 1 }, "aucune session vide")

    // Un état écrit avant les segments se relit.
    let oldTimer = #"{"accumulated":120,"sessionStartedAt":"2026-09-20T10:00:00Z","taskTypeRaw":"exercise","note":"","contextLabel":"","pomodoro":false}"#
    let timerDecoder = JSONDecoder(); timerDecoder.dateDecodingStrategy = .iso8601
    if let decoded = try? timerDecoder.decode(FocusTimerState.self, from: Data(oldTimer.utf8)) {
        check(decoded.segments == nil, "un chrono d'avant les segments se relit")
        check(decoded.allocatedSeconds(at: t0).map(\.seconds) == [120], "…et s'enregistre en une seule session")
    } else {
        check(false, "un chrono d'avant les segments doit se relire")
    }
}

// L'anneau : les bornes en horloge murale sont ce que le système sait animer.
let ring = ActivityPomodoro.make(blockNumber: 1, elapsedInBlock: 600, remaining: 900,
                                 completedBlocks: 0, running: true, now: activityNow)
check(ring.startedAt == activityNow.addingTimeInterval(-600),
      "le bloc a commencé il y a dix minutes de travail")
check(ring.endsAt == activityNow.addingTimeInterval(900), "…et se termine dans quinze")
check(ring.interval != nil, "l'anneau a un intervalle à animer")
check(abs(ring.frozenProgress - 0.4) < 0.001, "40 % du bloc")
check(ring.label == "Bloc 1", "libellé du bloc")

let pausedRing = ActivityPomodoro.make(blockNumber: 2, elapsedInBlock: 300, remaining: 1200,
                                       completedBlocks: 1, running: false, now: activityNow)
check(pausedRing.interval == nil,
      "en pause, aucun intervalle : un anneau qui continue de se remplir mentirait")
check(abs(pausedRing.frozenProgress - 0.2) < 0.001, "…mais la part faite reste connue")
check(pausedRing.completedBlocks == 1, "un bloc déjà terminé")

let completeRing = ActivityPomodoro.make(blockNumber: 1, elapsedInBlock: 1500, remaining: 0,
                                         completedBlocks: 1, running: true, now: activityNow)
check(completeRing.isBlockComplete, "un bloc à terme est marqué terminé")
check(completeRing.interval == nil, "…et n'anime plus rien : l'intervalle serait vide")

// Le pont entre le moteur et l'anneau : ce que l'app fera réellement.
let engineStatus = PomodoroEngine.status(elapsed: 1500 * 2 + 600, focusMinutes: 25)
let fromEngine = ActivityPomodoro.make(blockNumber: engineStatus.blockNumber,
                                       elapsedInBlock: engineStatus.elapsedInBlock,
                                       remaining: engineStatus.remaining,
                                       completedBlocks: engineStatus.completedBlocks,
                                       running: true, now: activityNow)
check(fromEngine.blockNumber == 3, "le moteur donne le bloc 3, l'anneau le reprend")
check(fromEngine.completedBlocks == 2, "…et ses deux blocs terminés")
check(abs(fromEngine.frozenProgress - engineStatus.progress) < 0.001,
      "…sans changer la fraction que le moteur a calculée")

print("== Live Activity : le jour d'examen ==")
// L'activité d'examen n'est déclenchée par aucun geste : elle s'ouvre et se ferme
// **par le temps**. C'est donc la seule chose qui puisse se tromper, et elle est
// ici entièrement testable.
let examAt = Date(timeIntervalSince1970: 1_700_000_000)

check(ExamActivityState.phase(examDate: examAt, now: examAt.addingTimeInterval(-3600)) == .upcoming,
      "une heure avant, l'épreuve est à venir")
check(ExamActivityState.phase(examDate: examAt, now: examAt) == .running,
      "à l'heure pile, l'épreuve est en cours")
check(ExamActivityState.phase(examDate: examAt, now: examAt.addingTimeInterval(3600)) == .running,
      "une heure après le début, toujours en cours")
check(ExamActivityState.phase(examDate: examAt,
                              now: examAt.addingTimeInterval(ExamActivityState.assumedDuration + 1)) == .over,
      "passé la durée supposée, l'épreuve est terminée")

// La fenêtre d'affichage : ni trop tôt — un compte à rebours de trois jours est
// une pression, pas une information — ni après coup.
check(!ExamActivityState.isRelevant(examDate: examAt, now: examAt.addingTimeInterval(-3 * 86400)),
      "trois jours avant, aucune activité")
check(!ExamActivityState.isRelevant(examDate: examAt,
                                    now: examAt.addingTimeInterval(-ExamActivityState.lead - 60)),
      "juste avant la fenêtre, toujours rien")
check(ExamActivityState.isRelevant(examDate: examAt,
                                   now: examAt.addingTimeInterval(-ExamActivityState.lead + 60)),
      "dans les douze heures, l'activité s'affiche")
check(ExamActivityState.isRelevant(examDate: examAt, now: examAt.addingTimeInterval(-1800)),
      "une demi-heure avant, elle est là")
check(ExamActivityState.isRelevant(examDate: examAt, now: examAt.addingTimeInterval(1800)),
      "pendant l'épreuve, elle reste")
check(!ExamActivityState.isRelevant(examDate: examAt,
                                    now: examAt.addingTimeInterval(ExamActivityState.assumedDuration + 60)),
      "après l'épreuve, elle disparaît — c'est ce qui laissait un îlot mort à l'écran")

check(ExamActivityState.make(examDate: examAt, now: examAt.addingTimeInterval(-600)).phase == .upcoming,
      "l'état publié reprend la phase déduite")

print("== Pomodoro : le cycle travail / pause ==")
do {
    let cfg = PomodoroSettings(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15,
                               longBreakEvery: 4, autoStartFocus: false)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var s = FocusTimerState(runningSince: t0, sessionStartedAt: t0, pomodoro: true)

    check(s.advance(settings: cfg, to: t0.addingTimeInterval(600)).isEmpty,
          "à 10 min, rien ne se passe")
    check(s.phase(settings: cfg, at: t0.addingTimeInterval(600)) == .working, "on travaille")
    check(s.blockEndDate(settings: cfg) == t0.addingTimeInterval(1500), "le bloc finira à 25 min")

    // L'app revient 28 min après le départ : le bloc a fini à 25 min, pas à 28.
    let back = t0.addingTimeInterval(28 * 60)
    let events = s.advance(settings: cfg, to: back)
    check(events == [.blockEnded(block: 1, kind: .short)], "le bloc 1 est annoncé fini — \(events)")
    check(s.accumulated == 1500, "le travail est coupé **au terme** : 25 min, pas 28")
    check(!s.isRunning, "le chrono de travail est arrêté pendant la pause")
    check(s.breakStartedAt == t0.addingTimeInterval(1500), "la pause a commencé à la fin du bloc")
    check(s.breakEndsAt == t0.addingTimeInterval(1500 + 300), "…et dure 5 min")
    if case .onBreak(.short, _, _) = s.phase(settings: cfg, at: back) {
        check(true, "la phase affichée est la pause")
    } else { check(false, "la phase affichée est la pause") }
    check(s.isRestorable(at: back), "une session en pause Pomodoro reste une session vivante")

    // Fin de pause sans démarrage automatique : on attend un geste.
    let afterBreak = t0.addingTimeInterval(1500 + 360)
    check(s.advance(settings: cfg, to: afterBreak) == [.breakEnded(nextBlock: 2)], "la pause s'achève")
    check(s.phase(settings: cfg, at: afterBreak) == .readyForBlock(2), "le bloc 2 attend un geste")
    check(s.accumulated == 1500, "la pause n'a rien ajouté au travail")

    // Passer la pause relance le travail tout de suite.
    var skip = FocusTimerState(runningSince: t0, sessionStartedAt: t0, pomodoro: true)
    skip.advance(settings: cfg, to: t0.addingTimeInterval(1510))
    skip.skipBreak(at: t0.addingTimeInterval(1520))
    check(skip.isRunning && skip.currentBreak == nil, "passer la pause relance le travail")
    check(skip.elapsed(at: t0.addingTimeInterval(1580)) == 1560, "…à partir des 25 min comptées")

    // Allonger la pause.
    var longer = FocusTimerState(runningSince: t0, sessionStartedAt: t0, pomodoro: true)
    longer.advance(settings: cfg, to: t0.addingTimeInterval(1500))
    longer.extendBreak(by: 300)
    check(longer.breakEndsAt == t0.addingTimeInterval(1500 + 600), "+5 min allonge la pause")

    // Démarrage automatique : plusieurs cycles rattrapés d'un coup.
    var auto = cfg
    auto.autoStartFocus = true
    var chain = FocusTimerState(runningSince: t0, sessionStartedAt: t0, pomodoro: true)
    // 4 blocs de 25 + 3 pauses de 5 = 115 min ; on revient à 116 min.
    let chained = chain.advance(settings: auto, to: t0.addingTimeInterval(116 * 60))
    check(chained.filter { if case .blockEnded = $0 { return true } else { return false } }.count == 4,
          "quatre blocs rattrapés — \(chained.count) événements")
    check(chained.last == .blockEnded(block: 4, kind: .long), "le quatrième bloc ouvre la pause longue")
    check(chain.accumulated == 4 * 1500, "exactement 100 min de travail comptées")
    check(chain.breakEndsAt == t0.addingTimeInterval(115 * 60 + 900), "la pause longue dure 15 min")

    // Hors Pomodoro : aucune pause, jamais.
    var plain = FocusTimerState(runningSince: t0, sessionStartedAt: t0, pomodoro: false)
    check(plain.advance(settings: cfg, to: t0.addingTimeInterval(4000)).isEmpty, "hors Pomodoro, rien")
    check(plain.isRunning, "…et le chrono continue")

    // Un état écrit avant l'ajout des pauses se relit.
    let legacyJSON = #"{"accumulated":60,"sessionStartedAt":"2027-01-15T08:00:00Z","taskTypeRaw":"exercise","note":"","contextLabel":"","pomodoro":true}"#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacyState = try? decoder.decode(FocusTimerState.self, from: Data(legacyJSON.utf8))
    check(legacyState?.currentBreak == nil && legacyState?.accumulated == 60,
          "un chrono enregistré par l'ancienne version se relit")

    check(cfg.breakKind(afterBlock: 3) == .short && cfg.breakKind(afterBlock: 8) == .long,
          "pause longue tous les quatre blocs")
}

print("== Pomodoro ==")
check(PomodoroEngine.blockDuration(minutes: 25) == 1500, "25 min = 1500 s")
check(PomodoroEngine.blockDuration(minutes: 0) == 60,
      "un bloc nul est borné à une minute — sinon la boucle d'alerte ne s'arrête jamais")
check(PomodoroEngine.blockDuration(minutes: -10) == 60, "un bloc négatif est borné aussi")

let start = PomodoroEngine.status(elapsed: 0, focusMinutes: 25)
check(start.blockNumber == 1, "au départ, bloc 1")
check(start.elapsedInBlock == 0, "rien d'écoulé dans le bloc")
check(start.remaining == 1500, "25 min restantes")
check(start.progress == 0, "anneau à zéro")
check(!start.isBlockComplete, "bloc non terminé")

let midway = PomodoroEngine.status(elapsed: 600, focusMinutes: 25)
check(midway.blockNumber == 1, "10 min plus tard, toujours bloc 1")
check(midway.remaining == 900, "15 min restantes — \(Int(midway.remaining)) s")
check(abs(midway.progress - 0.4) < 0.001, "anneau à 40 % — \(String(format: "%.2f", midway.progress))")

// L'instant exact où la pause est due : c'est le cas qui compte.
let exactly = PomodoroEngine.status(elapsed: 1500, focusMinutes: 25)
check(exactly.isBlockComplete, "à 25 min pile, le bloc est terminé")
check(exactly.blockNumber == 1, "…et on est encore sur le bloc 1, pas déjà le 2")
check(exactly.completedBlocks == 1, "un bloc terminé")
check(exactly.progress == 1, "anneau plein")

let second = PomodoroEngine.status(elapsed: 1501, focusMinutes: 25)
check(second.blockNumber == 2, "une seconde plus tard, bloc 2")
check(second.completedBlocks == 1, "toujours un bloc terminé")
check(second.remaining == 1499, "le nouveau bloc vient de commencer")

let third = PomodoroEngine.status(elapsed: 1500 * 2 + 60, focusMinutes: 25)
check(third.blockNumber == 3, "après deux blocs et une minute, bloc 3")
check(third.completedBlocks == 2, "deux blocs terminés")
check(third.remaining == 1440, "24 min restantes")
check(third.label == "Bloc 3", "libellé du bloc")

check(PomodoroEngine.status(elapsed: -5, focusMinutes: 25).blockNumber == 1,
      "un temps négatif ne produit pas un bloc négatif")

print("== Raccourcis du chrono ==")
let defaultShortcuts = FocusShortcutDefaults.make(from: ["CS-250", "MATH-101"])
check(defaultShortcuts.count == 4, "deux cours × deux natures = quatre raccourcis (\(defaultShortcuts.count))")
check(defaultShortcuts.first?.courseCode == "CS-250", "l'ordre des cours est conservé")
check(defaultShortcuts.first?.taskType == .video, "la vidéo vient en premier")
check(defaultShortcuts[1].taskType == .exercise, "puis les exercices")

let manyCourses = (1...10).map { "C-\($0)" }
check(FocusShortcutDefaults.make(from: manyCourses).count == FocusShortcutDefaults.maxDefaults,
      "la proposition est plafonnée à \(FocusShortcutDefaults.maxDefaults)")

// Un cours supprimé ne doit pas laisser une tuile morte.
let prunedShortcuts = FocusShortcutDefaults.sanitize(
    [FocusShortcut(courseCode: "CS-250", taskType: .video),
     FocusShortcut(courseCode: "DISPARU-1", taskType: .video),
     FocusShortcut(courseCode: "CS-250", taskType: .video),
     FocusShortcut(courseCode: "CS-250", taskType: .exercise)],
    knownCourses: ["CS-250"])
check(prunedShortcuts.count == 2, "cours disparu retiré et doublon supprimé (\(prunedShortcuts.count))")
check(prunedShortcuts.map(\.taskType) == [.video, .exercise], "l'ordre est préservé")
check(FocusShortcutDefaults.sanitize([], knownCourses: []).isEmpty, "une liste vide reste vide")

// Aller-retour JSON : c'est ainsi que les raccourcis sont conservés.
let encoded = FocusShortcut.encode(defaultShortcuts)
check(FocusShortcut.decode(encoded) == defaultShortcuts, "les raccourcis survivent à l'encodage")
check(FocusShortcut.decode("pas du json").isEmpty, "un contenu illisible ne plante pas")
check(FocusShortcut.decode("").isEmpty, "un contenu vide ne plante pas")
check(FocusShortcut(courseCode: "CS-250", taskType: .video).id == "CS-250|video",
      "l'identifiant est stable — \(FocusShortcut(courseCode: "CS-250", taskType: .video).id)")

print("== Schéma versionné ==")
// Le schéma de l'app doit contenir **exactement** les modèles déclarés dans les
// sources. C'est l'oubli qui avait laissé `GroupItemCompletion` hors du conteneur.
let schemaModelNames = Set(SchemaV1.models.map { String(describing: $0) })
let declared = Set(declaredModelNames)
let missingFromSchema = declared.subtracting(schemaModelNames)
let unknownInSchema = schemaModelNames.subtracting(declared)
check(missingFromSchema.isEmpty,
      "aucun @Model oublié dans SchemaV1 — manquants : \(missingFromSchema.sorted())")
check(unknownInSchema.isEmpty,
      "aucun modèle fantôme dans SchemaV1 — en trop : \(unknownInSchema.sorted())")
check(schemaModelNames.count == declared.count,
      "\(declared.count) modèles déclarés, \(schemaModelNames.count) dans le schéma")
check(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0), "version 1.0.0")
check(PolymestreSchema.currentVersion == 1, "version courante cohérente")
check(PolymestreMigrationPlan.schemas.count == 1,
      "le plan connaît la version en cours (\(PolymestreMigrationPlan.schemas.count))")
check(PolymestreMigrationPlan.stages.isEmpty || !PolymestreMigrationPlan.stages.isEmpty,
      "le plan de migration est interrogeable")

// La liste des modèles déclarés n'est pas vide : un garde-fou qui ne compare rien
// ne garde rien.
check(!declared.isEmpty, "la liste générée depuis les sources n'est pas vide")
check(declared.contains("Course") && declared.contains("AcademicMilestone"),
      "elle contient bien les modèles attendus")

print("== Recherche globale ==")
// La recherche doit trouver ce que l'utilisateur **tape**, pas ce qu'il a écrit.
check(SearchEngine.normalize("Algèbre linéaire") == "algebre lineaire",
      "accents et casse neutralisés — « \(SearchEngine.normalize("Algèbre linéaire")) »")
check(SearchEngine.normalize("CS-250") == "cs 250", "ponctuation réduite à un espace")
check(SearchEngine.normalize("  trop   d'espaces  ") == "trop d espaces", "espaces normalisés")
check(SearchEngine.tokens("algo exo") == ["algo", "exo"], "mots séparés")
check(SearchEngine.search("", in: []).isEmpty, "requête vide : aucun résultat")
check(SearchEngine.search("   ", in: []).isEmpty, "requête blanche : aucun résultat")

let catalogue: [SearchDocument] = [
    SearchDocument(id: "course.1", kind: .course, title: "Algorithms I",
                   subtitle: "CS-250 · 6 crédits", detail: "algorithms i cs 250 cs250",
                   courseCode: "CS-250"),
    SearchDocument(id: "course.2", kind: .course, title: "Analyse I",
                   subtitle: "MATH-101 · 7 crédits", detail: "analyse i math 101 math101",
                   courseCode: "MATH-101"),
    SearchDocument(id: "exercise.1", kind: .exercise, title: "Exercice 3.2 — Tri fusion",
                   subtitle: "CS-250 · Série 3", detail: "exercice 3 2 tri fusion algo recursif",
                   courseCode: "CS-250", date: Date()),
    SearchDocument(id: "theory.1", kind: .theory, title: "Analyse asymptotique",
                   subtitle: "CS-250 · Vidéo 1.2", detail: "video 1 2 complexite grand o",
                   courseCode: "CS-250"),
    SearchDocument(id: "session.1", kind: .session, title: "Révision récurrences",
                   subtitle: "CS-250 · Exercices", detail: "revision recurrences exercices",
                   courseCode: "CS-250", date: Date()),
    SearchDocument(id: "milestone.1", kind: .milestone, title: "Fin des examens",
                   subtitle: "Fin des examens · 30 janv.", detail: "fin des examens")
]

// Trouver par intitulé.
let algoHits = SearchEngine.search("algorithms", in: catalogue)
check(algoHits.first?.document.id == "course.1", "le cours sort en premier")
check(algoHits.first?.match == .title, "…et la correspondance est annoncée comme un intitulé")

// Sans accent ni casse.
check(SearchEngine.search("ANALYSE", in: catalogue).contains { $0.document.id == "course.2" },
      "recherche insensible aux accents et à la casse")
check(SearchEngine.search("asymptotique", in: catalogue).first?.document.id == "theory.1",
      "un titre de théorie se trouve")

// Par code de cours, sous ses trois écritures.
for written in ["CS-250", "cs250", "cs 250"] {
    let found = SearchEngine.search(written, in: catalogue)
    check(found.contains { $0.document.id == "exercise.1" },
          "« \(written) » trouve les exercices du cours")
}
check(SearchEngine.search("cs250", in: catalogue).contains { $0.document.id == "theory.1" },
      "…et la théorie du même cours")

// Tous les mots doivent correspondre : c'est ce qui rend la recherche utile.
let bothWords = SearchEngine.search("tri fusion", in: catalogue)
check(bothWords.count == 1 && bothWords.first?.document.id == "exercise.1",
      "deux mots : seul le document qui contient les deux sort (\(bothWords.count))")
check(SearchEngine.search("tri banane", in: catalogue).isEmpty,
      "un mot absent disqualifie le document")
check(SearchEngine.search("algo cours", in: catalogue).isEmpty,
      "« algo » ne suffit pas si le second mot n'existe nulle part")

// Un mot du détail suffit, mais l'intitulé passe devant.
let detailHit = SearchEngine.search("recursif", in: catalogue)
check(detailHit.first?.document.id == "exercise.1", "un mot du détail trouve le document")
check(detailHit.first?.match == .detail, "…et la correspondance est annoncée comme un détail")

// Le code de cours est un cas intermédiaire, annoncé comme tel.
let codeOnly = SearchEngine.search("math101", in: catalogue)
check(codeOnly.first?.match == .course, "correspondance par code annoncée comme telle")

// À score égal, l'ordre des natures est stable : cours, puis exercice.
let broad = SearchEngine.search("cs", in: catalogue)
check(broad.first?.kind == .course, "à pertinence comparable, un cours passe avant un exercice")
check(broad == broad.sorted { lhs, rhs in
    lhs.score != rhs.score ? lhs.score > rhs.score : lhs.kind <= rhs.kind
} || broad.count < 2, "le tri est déterministe")

// Groupement et résumé.
let grouped = SearchEngine.grouped(algoHits)
check(grouped.count == 1 && grouped.first?.kind == .course, "regroupement par nature")
check(SearchEngine.summary([], query: "").contains("Tape un code"),
      "sans requête, l'écran explique quoi taper")
check(SearchEngine.summary([], query: "zzz").contains("zzz"), "sans résultat, la requête est citée")
check(SearchEngine.summary(algoHits, query: "algorithms").contains("1 résultat"),
      "avec résultats, le compte est annoncé")

// Le plafond : au-delà, la liste cesse d'aider.
let many = (0..<200).map { index in
    SearchDocument(id: "x.\(index)", kind: .exercise, title: "Exercice \(index) trigonométrie",
                   detail: "trigonometrie")
}
check(SearchEngine.search("trigonometrie", in: many).count == SearchEngine.limit,
      "les résultats sont plafonnés à \(SearchEngine.limit)")

// ── Index construit depuis les modèles ──────────────────────────────────────
if let indexCourse = courses.first(where: { $0.code == "CS-250" }) {
    let documents = SearchIndexBuilder.documents(courses: [indexCourse])
    check(documents.contains { $0.kind == .course }, "le cours est indexé")
    check(documents.contains { $0.kind == .series }, "ses séries sont indexées")
    check(documents.contains { $0.kind == .exercise }, "ses exercices sont indexés")
    check(documents.contains { $0.kind == .theory }, "sa théorie est indexée")
    check(documents.contains { $0.kind == .exam }, "ses évaluations sont indexées")
    check(documents.count > 10, "l'index est fourni (\(documents.count) documents pour un cours)")

    // Le code du cours se retrouve sous ses deux écritures.
    let codeHit = SearchEngine.search("cs250", in: documents)
    check(!codeHit.isEmpty, "« cs250 » trouve le cours et son contenu (\(codeHit.count) résultats)")

    // Chercher un titre réel du cours d'exemple.
    if let series = indexCourse.sortedSeries.first {
        let found = SearchEngine.search("serie \(series.seriesNumber)", in: documents)
        check(found.contains { $0.kind == .series || $0.kind == .exercise },
              "une série se retrouve par son numéro")
    }
    check(SearchEngine.search("zzzzintrouvable", in: documents).isEmpty,
          "un mot absent ne ramène rien")
}

// Groupes et échéances sont indexables aussi.
let nonCourseDocuments = SearchIndexBuilder.documents(courses: [],
                                                     milestones: [builderMilestone],
                                                     groups: [])
check(nonCourseDocuments.contains { $0.kind == .milestone },
      "les échéances de l'EPFL sont cherchables")
check(SearchEngine.search("examen", in: nonCourseDocuments).contains { $0.kind == .milestone },
      "…et se trouvent par leur intitulé")

print("== Calendrier académique de l'EPFL : lecture de la vraie page ==")
// Le HTML est un extrait **authentique** de la page publique : c'est ce qui rend
// ce test utile. Un parseur testé sur une structure inventée ne prouve rien.
let epflHTML = """
<p><strong>Semestre automne 26-27</strong></p>
<table><tbody>
<tr><td>Fin juillet 2026</td><td><a href="x">Publication de l&#8217;horaire du semestre</a></td></tr>
<tr><td>1 ao&#251;t 2026</td><td>F&#234;te nationale (jour f&#233;ri&#233;)</td></tr>
<tr><td><strong>7 septembre 2026</strong></td><td><strong>D&#233;but des enseignements</strong></td></tr>
<tr><td>21 septembre 2026</td><td>Lundi du Je&#251;ne f&#233;d&#233;ral (jour f&#233;ri&#233;)</td></tr>
<tr><td>16 octobre 2026</td><td>Interruption des enseignements (fin de journ&#233;e)</td></tr>
<tr><td>26 octobre 2026</td><td>Reprise des enseignements</td></tr>
<tr><td>Mi-novembre 2026</td><td>Publication de l&#8217;horaire des examens</td></tr>
<tr><td>20 novembre 2026</td><td><a href="y">D&#233;lai pour le&nbsp;retrait des examens</a></td></tr>
<tr><td>18 d&#233;cembre 2026</td><td>Fin des enseignements</td></tr>
<tr><td>11 janvier 2027</td><td>D&#233;but des examens</td></tr>
<tr><td>30 janvier 2027</td><td>Fin des examens</td></tr>
</tbody></table>
<p><strong>Semestre printemps 25-26</strong></p>
<table><tbody>
<tr><td><strong>16 f&#233;vrier 2026</strong></td><td><strong>D&#233;but des enseignements (sauf mise &#224; niveau)</strong></td></tr>
<tr><td>3 avril 2026</td><td>Vendredi saint (jour f&#233;ri&#233;)</td></tr>
<tr><td><strong>4 juillet 2026</strong></td><td><strong>Fin des examens</strong></td></tr>
</tbody></table>
"""
let parsedCalendar = AcademicCalendarParser.parse(html: epflHTML)
check(parsedCalendar.count == 14, "14 lignes lues sur la page (\(parsedCalendar.count))")
check(parsedCalendar.allSatisfy { $0.date >= Date(timeIntervalSince1970: 0) },
      "chaque échéance porte une date")

/// Les deux semestres contiennent un « Début des enseignements » : on cible
/// celui d'automne, comme le ferait l'écran pour le semestre en cours.
func milestone(_ title: String, in term: String = "automne") -> AcademicMilestoneValue? {
    parsedCalendar.first { $0.title.contains(title) && $0.termLabel.contains(term) }
}
check(milestone("Début des enseignements")?.title.contains("mise à niveau") == false,
      "« Début des enseignements » de l'automne est lu — \(milestone("Début des enseignements")?.title ?? "-")")
check(milestone("Début des enseignements")?.termLabel == "Semestre automne 26-27",
      "…rattaché à son semestre — \(milestone("Début des enseignements")?.termLabel ?? "-")")
check(milestone("Début des enseignements")?.kind == .teachingStart, "…classé comme début des cours")
check(milestone("Début des enseignements")?.isImportant == true,
      "…et marqué important, comme l'EPFL le fait")

// La date qui commande toute l'app.
let epflAutumn2026 = AcademicCalendarParser.parseDate("7 septembre 2026")
let epflCalendar = Calendar(identifier: .gregorian)
check(epflAutumn2026 != nil, "« 7 septembre 2026 » est lue")
if let epflAutumn2026 {
    let parts = epflCalendar.dateComponents([.year, .month, .day, .weekday], from: epflAutumn2026.date)
    check(parts.year == 2026 && parts.month == 9 && parts.day == 7,
          "…au 7 septembre 2026 (\(parts.day ?? -1)/\(parts.month ?? -1)/\(parts.year ?? -1))")
    check(parts.weekday == 2, "…qui est bien un lundi")
    check(epflAutumn2026.approximate == false, "…comme date exacte")
}
check(DateUtils.autumnStart(forYear: 2026) == epflAutumn2026?.date,
      "la règle de rentrée et la page de l'EPFL donnent la même date")

// Les dates approximatives : l'EPFL ne donne pas de jour, on le dit.
let midNovember = AcademicCalendarParser.parseDate("Mi-novembre 2026")
check(midNovember?.approximate == true, "« Mi-novembre » est marquée approximative")
check(epflCalendar.component(.day, from: midNovember?.date ?? Date()) == 15,
      "…au 15 du mois — \(midNovember.map { epflCalendar.component(.day, from: $0.date) } ?? -1)")
let endDecember = AcademicCalendarParser.parseDate("Fin décembre 2025")
check(epflCalendar.component(.day, from: endDecember?.date ?? Date()) == 31,
      "« Fin décembre » au dernier jour du mois — \(endDecember.map { epflCalendar.component(.day, from: $0.date) } ?? -1)")
let earlyMarch = AcademicCalendarParser.parseDate("Début mars 2026")
check(epflCalendar.component(.day, from: earlyMarch?.date ?? Date()) == 1, "« Début mars » au 1er")
check(AcademicCalendarParser.parseDate("Fin février 2027").map {
    epflCalendar.component(.day, from: $0.date)
} == 28, "février 2027 n'est pas bissextile : 28")
check(AcademicCalendarParser.parseDate("Fin février 2028").map {
    epflCalendar.component(.day, from: $0.date)
} == 29, "février 2028 est bissextile : 29")
check(AcademicCalendarParser.parseDate("pas une date") == nil, "un texte sans date ne produit rien")
check(AcademicCalendarParser.parseDate("") == nil, "une cellule vide ne produit rien")

// Classification.
check(AcademicCalendarParser.kind(for: "Vendredi saint (jour férié)") == .holiday, "jour férié reconnu")
check(AcademicCalendarParser.kind(for: "Interruption des enseignements (fin de journée)") == .break,
      "interruption reconnue")
check(AcademicCalendarParser.kind(for: "Délai pour le retrait des examens") == .deadline, "délai reconnu")
check(AcademicCalendarParser.kind(for: "Ouverture des inscriptions anticipées") == .opening,
      "ouverture reconnue")
check(AcademicCalendarParser.kind(for: "Fin des examens") == .examEnd, "fin des examens reconnue")
check(AcademicCalendarParser.kind(for: "Envoi des bulletins de notes") == .publication,
      "envoi de bulletins classé en publication")
check(AcademicCalendarParser.kind(for: "Autre chose") == .other, "l'inconnu ne force pas une nature")

// HTML : sans les balises ni les entités.
check(AcademicCalendarParser.plainText("<td>D&#233;lai pour le&nbsp;retrait</td>")
        == "Délai pour le retrait",
      "balises et entités retirées — « \(AcademicCalendarParser.plainText("<td>D&#233;lai pour le&nbsp;retrait</td>")) »")
check(AcademicCalendarParser.plainText("<a href=\"x\">Deux <strong>mots</strong></a>") == "Deux mots",
      "balises imbriquées retirées")
check(AcademicCalendarParser.plainText("<td>   espaces   multiples  </td>") == "espaces multiples",
      "espaces normalisés")

// Clé stable : deux lectures de la même page ne doivent pas dupliquer.
let idsFirst = Set(AcademicCalendarParser.parse(html: epflHTML).map(\.id))
let idsAgain = Set(AcademicCalendarParser.parse(html: epflHTML).map(\.id))
check(idsFirst == idsAgain && idsFirst.count == 14,
      "les identifiants sont stables d'une lecture à l'autre (\(idsFirst.count))")

// ── Instantané embarqué ─────────────────────────────────────────────────────
let snapshot = EPFLCalendarSnapshot.milestones()
check(snapshot.count == 71, "instantané embarqué : 71 échéances (\(snapshot.count))")
check(snapshot.allSatisfy { $0.id.hasPrefix("epfl.") }, "chaque échéance porte une clé EPFL")
check(snapshot == snapshot.sorted { $0.date < $1.date }, "l'instantané est chronologique")
check(!snapshot.isEmpty, "l'instantané n'est pas vide")

// Les quatre bornes du semestre d'automne 2026-2027, vérifiables à la main.
func snapshotDate(_ title: String, in term: String? = nil) -> Date? {
    snapshot.first { value in
        value.title == title && (term == nil || value.termLabel.contains(term!))
    }?.date
}
func day(_ date: Date?) -> String {
    guard let date else { return "—" }
    return DateUtils.shortDay.string(from: date)
}
check(day(snapshotDate("Début des enseignements", in: "automne 26-27")) == "lun. 7 sept.",
      "automne 2026 : début des cours le 7 septembre — \(day(snapshotDate("Début des enseignements")))")
check(day(snapshotDate("Fin des enseignements", in: "automne 26-27")) == "ven. 18 déc.",
      "…fin des cours le 18 décembre — \(day(snapshotDate("Fin des enseignements")))")
check(day(snapshotDate("Début des examens", in: "automne 26-27")) == "lun. 11 janv.",
      "…début des examens le 11 janvier — \(day(snapshotDate("Début des examens")))")
check(day(snapshotDate("Fin des examens", in: "automne 26-27")) == "sam. 30 janv.",
      "…fin des examens le 30 janvier — \(day(snapshotDate("Fin des examens")))")

check(EPFLCalendarSnapshot.autumnTeachingStart(year: 2026) == epflAutumn2026?.date,
      "le début d'automne est extractible de l'instantané")
check(EPFLCalendarSnapshot.autumnTeachingStart(year: 2025) == nil,
      "une année non publiée ne rend pas de date inventée")

check(snapshot.contains { $0.kind == .holiday }, "l'instantané contient les jours fériés")
check(snapshot.contains { $0.kind == .deadline }, "…et les délais")
check(snapshot.filter(\.isApproximate).count == 13,
      "13 échéances approximatives, signalées comme telles (\(snapshot.filter(\.isApproximate).count))")

print("== Diagnostic des erreurs Supabase ==")
// Ce traducteur a menti deux fois : « politiques RLS » sans dire quelle table, et
// un message qui laissait croire qu'un simple réexécutable suffisait. On le teste
// donc sur les réponses **réelles** de PostgREST.
let rlsBody = #"{"code":"42501","message":"new row violates row-level security policy for table \"presence\"","details":null,"hint":null}"#
let rlsRaw = "Erreur serveur (403) : \(rlsBody)"
let rls = GroupErrorExplainer.explain(raw: rlsRaw)
check(rls.contains("membre du groupe"), "un 42501 oriente vers l'adhésion manquante")
check(rls.contains("presence"), "…et nomme la table refusée — \(rls.suffix(60))")
check(rls.contains("42501"), "…et conserve le code serveur")

let denied = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (403) : {"code":"42501","message":"permission denied for table presence"}"#)
check(denied.contains("droits manquants"),
      "un « permission denied » est distingué d'une politique RLS — \(denied.prefix(50))")

let missing = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (404) : {"code":"PGRST205","message":"Could not find the table 'public.presence' in the schema cache"}"#)
check(missing.contains("supabase-schema.sql"), "une table absente renvoie au fichier SQL")

let ambiguous = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (300) : {"code":"PGRST201","message":"Could not embed because more than one relationship was found"}"#)
check(ambiguous.contains("deux chemins"), "une imbrication ambiguë est expliquée")

let fk = GroupErrorExplainer.explain(
    raw: #"Erreur serveur (409) : {"code":"23503","message":"insert or update on table violates foreign key constraint"}"#)
check(fk.contains("profil"), "une violation de clé étrangère renvoie au profil")

let unknownRaw = "Erreur serveur (500) : panne inconnue"
check(GroupErrorExplainer.explain(raw: unknownRaw) == unknownRaw,
      "une erreur non reconnue est rendue telle quelle, sans invention")

check(GroupErrorExplainer.serverDetail("pas de json ici").isEmpty,
      "sans JSON, aucun détail inventé")
check(GroupErrorExplainer.serverDetail(#"{"code":"X"}"#).contains("code X"),
      "un code seul est tout de même repris")
check(GroupErrorExplainer.serverDetail(#"{"message":""}"#).isEmpty,
      "un message vide ne produit pas de « Serveur : » orphelin")
check(GroupErrorExplainer.serverDetail(#"{"message":"boom","hint":"essaie ceci"}"#)
        .contains("essaie ceci"),
      "l'indication du serveur est conservée")

print("== Rôle : le créateur reste administrateur après migration ==")
// `roleRaw` est arrivé après `StudyGroup.isAdmin`. Pour un groupe créé avant,
// SwiftData a migré le nouvel attribut à sa valeur par défaut — « member » —
// y compris pour la personne qui avait créé le groupe. Elle se retrouvait sans
// droits sur son propre groupe.
let migratedGroup = StudyGroup(name: "Créé avant les rôles", isAdmin: true)
let migratedOwner = GroupMember(group: migratedGroup, userID: "me", displayName: "Moi",
                                isMe: true, role: .member)
check(migratedOwner.role == .member, "le rôle a bien migré à « member »")
check(migratedOwner.isAdmin, "…et le créateur reste administrateur malgré tout")

let joinedGroup = StudyGroup(name: "Rejoint", isAdmin: false)
let joiner = GroupMember(group: joinedGroup, userID: "me", displayName: "Moi",
                         isMe: true, role: .member)
check(!joiner.isAdmin, "celui qui a rejoint n'est pas administrateur")
joiner.role = .admin
check(joiner.isAdmin, "une promotion explicite prime sur le drapeau local")
joiner.role = .member
check(!joiner.isAdmin, "une rétrogradation aussi")

let otherGroup = StudyGroup(name: "Autre", isAdmin: true)
let someoneElse = GroupMember(group: otherGroup, userID: "u9", displayName: "Alice", role: .member)
check(!someoneElse.isAdmin, "le drapeau « admin » du groupe ne profite qu'à moi")

print("== Comparaison d'avancement entre membres ==")
let subjectReference = SubjectReference(seriesNumbers: [1, 2, 3],
                                        exerciseNumbers: ["1.1", "1.2", "1.3", "1.4"],
                                        theoryNumbers: ["1.1", "1.2"])
check(subjectReference.seriesTotal == 3
      && subjectReference.exerciseTotal == 4
      && subjectReference.theoryTotal == 2,
      "référentiel compté : 3 séries, 4 exercices, 2 théorie")
check(!subjectReference.isEmpty, "référentiel non vide")
check(SubjectReference().isEmpty, "référentiel vide détecté")

let subjectComparison = GroupProgressEngine.compare(
    subject: "cs-250",
    reference: subjectReference,
    contributions: [
        SubjectContribution(userID: "me",
                            seriesNumbers: [1, 2],
                            exerciseNumbers: ["1.1"],
                            theoryNumbers: ["1.1"]),
        SubjectContribution(userID: "u-alice",
                            seriesNumbers: [1],
                            exerciseNumbers: ["1.1", "1.2", "1.3", "1.4", "9.9"],
                            theoryNumbers: ["1.1", "1.2"])
    ],
    members: [("me", "Moi", true), ("u-alice", "Alice Moreau", false)],
    meID: "me")
check(subjectComparison.rows.count == 2, "deux membres comparés")
check(subjectComparison.subject == "CS-250", "matière normalisée en majuscules")
check(subjectComparison.rows.first?.userID == "u-alice", "le plus avancé en tête")
check(subjectComparison.me?.userID == "me", "moi identifié dans le classement")
check(subjectComparison.me?.exercisesDone == 1, "mes exercices comptés (1)")
check(subjectComparison.rows.first?.exercisesDone == 4,
      "un numéro hors référentiel ne compte pas (4, pas 5)")
check(subjectComparison.rows.first?.gapExercises == 3, "écart d'exercices (+3)")
check(subjectComparison.rows.first?.gapSeries == -1, "écart de séries (−1)")
check(subjectComparison.rows.first?.gapTheory == 1, "écart de théorie (+1)")
check(subjectComparison.rows.first?.gapLabel == "3 éléments d'avance",
      "libellé d'écart — \(subjectComparison.rows.first?.gapLabel ?? "-")")
check(subjectComparison.me?.gapLabel == nil, "aucun écart affiché pour moi")
check(subjectComparison.notStarted == 0, "personne n'est à zéro")
check(subjectComparison.isComparable, "comparaison possible à deux")
check(subjectComparison.rows.first?.detailLabel == "4/4 exercices · 2/2 théorie · 1/3 séries",
      "détail par axe — \(subjectComparison.rows.first?.detailLabel ?? "-")")

let emptyReference = GroupProgressEngine.compare(
    subject: "X",
    reference: SubjectReference(),
    contributions: [SubjectContribution(userID: "me", seriesNumbers: [1])],
    members: [("me", "Moi", true), ("u1", "Bob", false)],
    meID: "me")
check(emptyReference.rows.allSatisfy { $0.overallPercent == 0 },
      "référentiel vide : aucun pourcentage inventé")
check(!emptyReference.isComparable, "référentiel vide : comparaison signalée comme impossible")

let orphanComparison = GroupProgressEngine.compare(
    subject: "CS-250",
    reference: subjectReference,
    contributions: [SubjectContribution(userID: "me", exerciseNumbers: ["1.1"]),
                    SubjectContribution(userID: "u-ghost", exerciseNumbers: ["1.2"])],
    members: [("me", "Moi", true)],
    meID: "me")
check(orphanComparison.rows.contains { $0.userID == "u-ghost" && !$0.isPresent },
      "une contribution sans membre reste visible, marquée hors groupe")
check(orphanComparison.rows.first?.userID == "me",
      "un membre présent passe devant une contribution orpheline")

let anonymousComparison = GroupProgressEngine.compare(
    subject: "CS-250",
    reference: subjectReference,
    contributions: [SubjectContribution(userID: "u1", exerciseNumbers: ["1.1"]),
                    SubjectContribution(userID: "u2", exerciseNumbers: ["1.2"])],
    members: [("u1", "Bob", false), ("u2", "Chloé", false)],
    meID: nil)
check(anonymousComparison.me == nil, "sans identifiant, aucun « moi »")
check(anonymousComparison.rows.allSatisfy { $0.gapLabel == nil },
      "sans « moi », aucun écart n'est affiché — on ne compare personne à personne")
check(anonymousComparison.rows.allSatisfy { !$0.isMe },
      "sans identifiant, personne n'est marqué comme moi")

let flaggedComparison = GroupProgressEngine.compare(
    subject: "CS-250",
    reference: subjectReference,
    contributions: [SubjectContribution(userID: "me", exerciseNumbers: ["1.1"])],
    members: [("me", "Moi", true), ("u1", "Bob", false)],
    meID: nil)
check(flaggedComparison.me?.userID == "me",
      "le drapeau isMe du membre suffit, même sans identifiant distant")

print("== Avancement par matière, lu depuis les modèles ==")
let builderTerm = AcademicTerm(year: 2025,
                               season: .autumn,
                               startDate: DateUtils.autumnStart(forYear: 2025),
                               endDate: DateUtils.addWeeks(14, to: DateUtils.autumnStart(forYear: 2025)))
context.insert(builderTerm)
let builderCourse = Course(code: "GRP-100", name: "Groupes et réseaux", term: builderTerm)
context.insert(builderCourse)
let builderSeries = ExerciseSeries(course: builderCourse, seriesNumber: 1)
context.insert(builderSeries)
for number in ["1.1", "1.2"] {
    context.insert(Exercise(series: builderSeries, exerciseNumber: number))
}
context.insert(TheoryItem(course: builderCourse, sectionNumber: 1, number: "1.1"))
context.insert(TheoryItem(course: builderCourse, sectionNumber: 1, number: "1.2"))

let builtReference = GroupProgressBuilder.reference(for: builderCourse)
check(builtReference.seriesTotal == 1 && builtReference.exerciseTotal == 2 && builtReference.theoryTotal == 2,
      "référentiel lu depuis le cours (\(builtReference.seriesTotal) série, \(builtReference.exerciseTotal) ex., \(builtReference.theoryTotal) théo.)")
check(GroupProgressBuilder.reference(for: nil).isEmpty, "sans cours, aucun référentiel à comparer")

let builderGroup = StudyGroup(name: "Promo BA4", courseCodes: ["GRP-100"])
context.insert(builderGroup)
context.insert(GroupMember(group: builderGroup, userID: "me", displayName: "Moi",
                           isMe: true, role: .admin, courseCodes: ["GRP-100"]))
context.insert(GroupMember(group: builderGroup, userID: "u-alice", displayName: "Alice",
                           role: .member, courseCodes: ["GRP-100"]))
context.insert(GroupSeriesCompletion(group: builderGroup, userID: "u-alice",
                                     displayName: "Alice", courseCode: "grp-100", seriesNumber: 1))
context.insert(GroupItemCompletion(group: builderGroup, userID: "u-alice", displayName: "Alice",
                                   courseCode: "grp-100", kind: .exercise, itemNumber: "1.1"))
context.insert(GroupItemCompletion(group: builderGroup, userID: "u-alice", displayName: "Alice",
                                   courseCode: "GRP-100", kind: .exercise, itemNumber: "1.2"))
context.insert(GroupItemCompletion(group: builderGroup, userID: "me", displayName: "Moi",
                                   courseCode: "GRP-100", kind: .exercise, itemNumber: "1.1"))
try context.save()

let builtComparison = GroupProgressBuilder.comparison(subject: "grp-100",
                                                      group: builderGroup,
                                                      course: builderCourse,
                                                      meID: "me")
check(builtComparison.rows.count == 2, "deux membres lus depuis le groupe")
check(builtComparison.me?.exercisesDone == 1, "mes exercices lus depuis les modèles (1)")
check(builtComparison.rows.first?.exercisesDone == 2,
      "les numéros sont comparés sans tenir compte de la casse du code")
check(builtComparison.rows.first?.seriesDone == 1, "série lue depuis les modèles")
check(GroupProgressBuilder.contributions(subject: "GRP-100", group: builderGroup).count == 2,
      "contributions regroupées par membre")
check(GroupProgressBuilder.contributions(subject: "INEXISTANT", group: builderGroup).isEmpty,
      "une matière sans donnée ne produit aucune contribution")

let builtHeadline = GroupProgressBuilder.headline(subject: "GRP-100",
                                                  group: builderGroup,
                                                  course: builderCourse,
                                                  meID: "me")
check(builtHeadline.followerCount == 2, "les deux membres suivent GRP-100")
check(builtHeadline.leadLabel == "Alice a 2 éléments d'avance",
      "écart annoncé depuis la carte — \(builtHeadline.leadLabel ?? "aucun")")

let onlyMeHeadline = GroupProgressBuilder.headline(subject: "GRP-100",
                                                   group: builderGroup,
                                                   course: builderCourse,
                                                   meID: "u-alice")
check(onlyMeHeadline.leadLabel == nil || onlyMeHeadline.leadLabel?.contains("Moi") == true,
      "quand je suis devant, aucun retard n'est annoncé")

print("== Session Supabase conservée entre deux lancements ==")
// Le client ne gardait la session qu'en mémoire : **chaque relance déconnectait**.
// Les groupes cessaient de se synchroniser et la présence ne se publiait plus,
// sans qu'aucune erreur ne soit visible.
let sessionNow = Date()
let freshSession = StoredSession(accessToken: "jeton", refreshToken: "rafraîchir",
                                 userID: "u1", email: "a@b.ch",
                                 expiresAt: sessionNow.addingTimeInterval(3600))
check(!freshSession.isExpired(at: sessionNow), "un jeton d'une heure n'est pas expiré")
check(freshSession.isUsable, "un jeton non vide est utilisable")
check(freshSession.userID == "u1", "l'identifiant survit au stockage")

let staleSession = StoredSession(accessToken: "jeton",
                                 expiresAt: sessionNow.addingTimeInterval(-1))
check(staleSession.isExpired(at: sessionNow), "un jeton dépassé est expiré")
check(staleSession.refreshToken == nil, "sans jeton de rafraîchissement, il faudra se reconnecter")

// La marge : un jeton qui expire dans 30 s est traité comme expiré, sinon la
// requête part avec un jeton mort et revient en 401.
let nearly = StoredSession(accessToken: "jeton",
                           expiresAt: sessionNow.addingTimeInterval(30))
check(nearly.isExpired(at: sessionNow),
      "un jeton expirant dans 30 s est renouvelé d'avance (marge \(Int(StoredSession.leeway)) s)")
let comfortable = StoredSession(accessToken: "jeton",
                                expiresAt: sessionNow.addingTimeInterval(StoredSession.leeway + 30))
check(!comfortable.isExpired(at: sessionNow), "au-delà de la marge, on garde le jeton")

// Le trousseau est indexé par hôte : changer de projet ne réutilise pas la session.
check(StoredSession(accessToken: "x", expiresAt: sessionNow)
        == StoredSession(accessToken: "x", expiresAt: sessionNow),
      "deux sessions identiques se comparent")

print("== Diagnostic du direct ==")
check(PresenceAvailability.evaluate(isConfigured: false, isSignedIn: true,
                                    hasRemoteGroup: true, lastError: nil) == .notConfigured,
      "sans Supabase configuré, le direct le dit")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: false,
                                    hasRemoteGroup: true, lastError: nil) == .notSignedIn,
      "sans connexion, le direct le dit")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: true,
                                    hasRemoteGroup: false, lastError: nil) == .groupNotSynced,
      "sans groupe distant, le direct le dit")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: true,
                                    hasRemoteGroup: true, lastError: nil) == .ready,
      "tout en place : le direct est prêt")
check(PresenceAvailability.evaluate(isConfigured: true, isSignedIn: true,
                                    hasRemoteGroup: true,
                                    lastError: "table absente") == .failing("table absente"),
      "un refus du serveur remonte tel quel")
check(!PresenceAvailability.notConfigured.isReady, "un état dégradé n'est pas « prêt »")
check(PresenceAvailability.ready.message == nil, "aucun message quand tout va bien")
for state in [PresenceAvailability.notConfigured, .notSignedIn, .groupNotSynced, .failing("x")] {
    check(state.message?.isEmpty == false, "chaque état dégradé porte un message actionnable")
}

print("== Présence en direct ==")
let presenceNow = Date()
let liveAlice = PresenceEntry(userID: "u-alice",
                              displayName: "Alice Moreau",
                              courseCode: "CS-250",
                              taskLabel: "Exercices",
                              target: "Exercice 3.2",
                              startedAt: presenceNow.addingTimeInterval(-3600),
                              updatedAt: presenceNow,
                              isMe: false)
check(liveAlice.isLive(at: presenceNow), "un battement récent = en ligne")
check(!liveAlice.isLive(at: presenceNow.addingTimeInterval(PresenceEntry.heartbeat * 3)),
      "trois battements manqués = hors ligne")
check(liveAlice.elapsedLabel(at: presenceNow) == DateUtils.hoursLabel(seconds: 3600),
      "durée écoulée affichée — \(liveAlice.elapsedLabel(at: presenceNow))")
check(liveAlice.activityLabel == "CS-250 · Exercices · Exercice 3.2",
      "libellé d'activité — \(liveAlice.activityLabel)")

let deadBob = PresenceEntry(userID: "u-bob",
                            displayName: "Bob",
                            courseCode: "CS-250",
                            taskLabel: "Théorie",
                            target: "",
                            startedAt: presenceNow.addingTimeInterval(-7200),
                            updatedAt: presenceNow.addingTimeInterval(-7200),
                            isMe: false)
let liveMe = PresenceEntry(userID: "me",
                           displayName: "Moi",
                           courseCode: "CS-250",
                           taskLabel: "Exercices",
                           target: "",
                           startedAt: presenceNow.addingTimeInterval(-600),
                           updatedAt: presenceNow,
                           isMe: true)
let liveBoard = PresenceBoard.live([deadBob, liveAlice, liveMe], at: presenceNow)
check(liveBoard.count == 2, "le membre périmé est écarté (\(liveBoard.count) en ligne)")
check(liveBoard.first?.isMe == true, "moi en tête quand je travaille")
check(liveBoard.last?.userID == "u-alice", "les autres suivent, du plus ancien au plus récent")
check(PresenceBoard.summary(liveBoard) == "Alice Moreau travaille en ce moment",
      "résumé à une personne — \(PresenceBoard.summary(liveBoard))")
check(PresenceBoard.summary([liveMe]) == "Tu travailles en ce moment", "résumé quand je suis seul")
check(PresenceBoard.summary([]) == "Personne ne travaille", "résumé à vide")
check(PresenceBoard.summary([liveMe, liveAlice]) == "Alice Moreau travaille en ce moment",
      "mon propre état n'est pas compté comme « quelqu'un d'autre »")
check(PresenceEntry(userID: "u", displayName: "U", courseCode: "", taskLabel: "",
                    target: "", startedAt: presenceNow, updatedAt: presenceNow, isMe: false)
        .activityLabel == "Travail en cours",
      "sans matière ni type, un libellé de repli plutôt qu'une ligne vide")


print("== Catégorisation fine du temps ==")
if let cs = courses.first(where: { $0.code == "CS-250" }),
   let exercise = cs.allExercises.first,
   let item = cs.theoryItems.first {
    let precise = StudySession(course: cs,
                               taskType: .exercise,
                               startedAt: Date(),
                               durationSeconds: 1800,
                               exercise: exercise)
    check(precise.targetLabel == exercise.displayNumber,
          "session liée à un exercice : « \(precise.targetLabel ?? "—") »")
    let reading = StudySession(course: cs,
                               taskType: .theory,
                               startedAt: Date(),
                               durationSeconds: 900,
                               theoryItem: item)
    check(reading.targetLabel == item.displayNumber,
          "session liée à la théorie : « \(reading.targetLabel ?? "—") »")
    let loose = StudySession(course: cs, taskType: .exercise, durationSeconds: 600)
    check(loose.targetLabel == nil,
          "une session non précisée reste valide et sans cible")
    check(precise.durationSeconds + reading.durationSeconds == 2700,
          "le temps reste compté pareil, cible ou pas")
}

print("== Notice de chaque intégration de tâches ==")
check(TaskProvider.allCases.count == 7,
      "sept fournisseurs de tâches (\(TaskProvider.allCases.count))")
for provider in [TaskProvider.googleTasks, .tickTick] {
    check(provider.supportsReading, "\(provider.label) : lecture annoncée")
    check(provider.credentialLabel != nil, "\(provider.label) : identifiant nommé")
    check(provider.icon != TaskProvider.reminders.icon,
          "\(provider.label) : icône propre")
}
for provider in TaskProvider.allCases {
    check(!provider.setupSummary.isEmpty, "\(provider.label) : résumé présent")
    check(provider.setupSteps.count >= 3,
          "\(provider.label) : \(provider.setupSteps.count) étapes de configuration")
    check(provider.setupSteps.allSatisfy { !$0.isEmpty && $0.count > 12 },
          "\(provider.label) : aucune étape vide ni trop courte")
    check(!provider.capabilityLabel.isEmpty, "\(provider.label) : capacité annoncée")
    check(!provider.helpText.isEmpty, "\(provider.label) : aide en ligne présente")
    check(provider.setupCaveat != nil, "\(provider.label) : limite annoncée")
}
check(TaskProvider.allCases.filter { $0.setupURLString != nil }.count >= 2,
      "au moins deux fournisseurs renvoient vers leur page d'identifiants")
check(TaskProvider.allCases.contains { $0.setupURLString == nil },
      "les fournisseurs sans page d'identifiants n'en inventent pas")

print("== Détection des exercices dans un PDF de série ==")

// Polycopié EPFL typique : en-tête de série, exercices numérotés, un bonus.
let typical = """
Série 3 – Intégrales généralisées
Exercice 3.1
Calculer l'intégrale suivante sur R.
Exercice 3.2 (bonus)
Exercice 3.3 – Théorème de Fubini
"""
let typicalSeries = SeriesPDFParser.parse(typical)
check(typicalSeries.count == 1, "un polycopié type donne une série (\(typicalSeries.count))")
if let three = typicalSeries.first {
    check(three.number == 3, "série 3 détectée (\(three.number))")
    check(three.title == "Intégrales généralisées", "intitulé de série : « \(three.title) »")
    check(three.exercises.map(\.number) == ["3.1", "3.2", "3.3"],
          "trois exercices dans l'ordre : \(three.exercises.map(\.number).joined(separator: ", "))")
    check(three.exercises.first(where: { $0.number == "3.2" })?.isBonus == true,
          "« (bonus) » reconnu sur la ligne")
    check(three.exercises.first(where: { $0.number == "3.3" })?.title == "Théorème de Fubini",
          "intitulé d'exercice conservé")
    check(three.exercises.first(where: { $0.number == "3.1" })?.isBonus == false,
          "un exercice normal n'est pas marqué bonus")
}

let multi = """
Série 1
1.1
1.2
Série 2
Exercice 2.1
"""
let multiSeries = SeriesPDFParser.parse(multi)
check(multiSeries.count == 2, "deux séries regroupées (\(multiSeries.count))")
check(multiSeries.map(\.number) == [1, 2], "séries dans l'ordre")
check(multiSeries.first?.exercises.count == 2, "la première série a deux exercices")

let wrapped = "Exercice 4.1\n(bonus)\nExercice 4.2\n"
let wrappedSeries = SeriesPDFParser.parse(wrapped)
check(wrappedSeries.first?.exercises.first(where: { $0.number == "4.1" })?.isBonus == true,
      "« bonus » reconnu sur la ligne suivante")
check(wrappedSeries.first?.exercises.first(where: { $0.number == "4.2" })?.isBonus == false,
      "le bonus ne déborde pas sur l'exercice suivant")

let bareSeries = SeriesPDFParser.parse("Exercice 1\nExercice 2\n")
check(bareSeries.count == 1 && bareSeries[0].exercises.map(\.number) == ["1.1", "1.2"],
      "« Exercice 1 / Exercice 2 » hors série : numérotés dans la série 1 — \(bareSeries.first?.exercises.map(\.number).joined(separator: ", ") ?? "-")")

check(SeriesPDFParser.parse("Exercice 1.1\nExercice 1.1\n").first?.exercises.count == 1,
      "un doublon ne crée pas deux exercices")
check(SeriesPDFParser.parse("Exercice\u{00A0}5.1\n").first?.exercises.first?.number == "5.1",
      "espace insécable toléré")

// Un PDF scanné ne contient aucun texte : le parseur ne doit rien inventer.
check(SeriesPDFParser.parse("").isEmpty, "texte vide : aucune série inventée")
check(SeriesPDFParser.parse("Cours d'analyse\nProfesseur Untel\n").isEmpty,
      "texte sans numéro : aucune série inventée")
check(SeriesPDFParser.majorComponent(of: "12.4") == 12, "série à deux chiffres")
check(SeriesPDFParser.majorComponent(of: "n/a") == nil, "numéro illisible → rien")

print("== Formats réels de polycopiés EPFL ==")

// Analyse 1 inversée : « Ex-02-01: », en-tête « Série 02 (Nombres R) », et deux
// exercices collés sur une même ligne par l'extraction du PDF.
let analyse = """
Série 02 (Nombres R)
Ex-02-01: Montrer que dans R,
1) Si x y alors x + x y + y.
Ex-02-08: Ex-02-09: Montrer que si n est un entier tel que n2 est pair.
Ex-02-11: (Cet exercice est facultatif.)
Soit C := {x ∈ R+ : x3 < 1}.
Ex-02-12: Montrer que l’ensemble C est ouvert.
"""
let analyseSeries = SeriesPDFParser.parse(analyse)
check(analyseSeries.count == 1, "Analyse 1 : une seule série (\(analyseSeries.count))")
if let s = analyseSeries.first {
    check(s.number == 2, "Analyse 1 : série 2 (\(s.number))")
    check(s.title == "Nombres R", "Analyse 1 : titre sans parenthèses « \(s.title) »")
    check(s.exercises.map(\.number) == ["2.1", "2.8", "2.9", "2.11", "2.12"],
          "Analyse 1 : numéros lus — \(s.exercises.map(\.number).joined(separator: ", "))")
    check(s.exercises.contains { $0.number == "2.9" },
          "Analyse 1 : « Ex-02-09 » collé sur la ligne du 08 est bien détecté")
    check(s.exercises.first { $0.number == "2.8" }?.title.isEmpty == true,
          "Analyse 1 : le 08 ne vole pas le titre du 09")
    check(s.exercises.first { $0.number == "2.11" }?.isBonus == true,
          "Analyse 1 : « facultatif » vaut bonus")
    check(s.exercises.first { $0.number == "2.12" }?.isBonus == false,
          "Analyse 1 : un exercice normal n'est pas bonus")
}

// Algèbre linéaire inversée : « Exercice N » suivi de la **première phrase de
// l'énoncé**, pollué par les métadonnées de mise en page « Type : … Défi : ⋆⋆ ».
//
// Le texte qui suit le numéro n'est pas un intitulé : c'est l'énoncé. L'afficher
// comme titre sous l'exercice invente une information (constaté sur un vrai PDF :
// « solution générale. » sous l'exercice 1, « tions change. » sous le 3).
let algebre = """
Série 2
Exercice 1 solution générale.
Type : Technique Défi : ⋆⋆
Exercice 2 Type : Concept Défi : ⋆⋆
Exercice 3
"""
let algebreSeries = SeriesPDFParser.parse(algebre)
check(algebreSeries.count == 1, "Algèbre : une seule série (\(algebreSeries.count))")
if let s = algebreSeries.first {
    check(s.number == 2, "Algèbre : série 2 lue depuis l'en-tête (\(s.number))")
    check(s.exercises.map(\.number) == ["2.1", "2.2", "2.3"],
          "Algèbre : trois exercices, numérotés par leur série — \(s.exercises.map(\.number).joined(separator: ", "))")
    check(s.exercises.first?.title.isEmpty == true,
          "Algèbre : « solution générale. » n'est pas retenu comme titre — « \(s.exercises.first?.title ?? "") »")
    check(s.exercises.first { $0.number == "2.2" }?.title.isEmpty == true,
          "Algèbre : les métadonnées « Type : … Défi : … » ne polluent pas le titre")
    check(s.exercises.first { $0.number == "2.3" }?.title.isEmpty == true,
          "Algèbre : « Exercice 3 » seul n'invente pas de titre")
}

// Le tri entre intitulé et énoncé, cas par cas.
print("== Intitulé ou énoncé ? ==")
check(!SeriesPDFParser.looksLikeTitle("solution générale."), "une phrase terminée par un point est un énoncé")
check(!SeriesPDFParser.looksLikeTitle("tions change."), "un fragment de mot est rejeté")
check(!SeriesPDFParser.looksLikeTitle("ou contre-exemple."), "une suite d'énoncé en minuscule est rejetée")
check(!SeriesPDFParser.looksLikeTitle("Montrer que l'ensemble C est ouvert."),
      "une consigne complète est rejetée")
check(!SeriesPDFParser.looksLikeTitle("1) Si x y alors x + x y + y."), "une énumération est rejetée")
check(!SeriesPDFParser.looksLikeTitle("Montrer que ;"), "un point-virgule final est rejeté")
check(SeriesPDFParser.looksLikeTitle("Diagonalisation ; applications"),
      "un point-virgule interne ne suffit pas à rejeter — limite assumée de la règle")
check(!SeriesPDFParser.looksLikeTitle(String(repeating: "Mot ", count: 30)),
      "un texte trop long est rejeté")
check(!SeriesPDFParser.looksLikeTitle("   "), "un texte vide est rejeté")
check(SeriesPDFParser.looksLikeTitle("Diagonalisation"), "un intitulé court est conservé")
check(SeriesPDFParser.looksLikeTitle("Espaces vectoriels"), "un intitulé de deux mots est conservé")
check(SeriesPDFParser.looksLikeTitle("Nombres R"), "un intitulé sans ponctuation est conservé")

// Et sur un document complet : le titre explicite après deux-points survit.
let titré = """
Série 3
Exercice 1 : Diagonalisation
Exercice 2 : Espaces vectoriels
"""
let titréSeries = SeriesPDFParser.parse(titré)
check(titréSeries.first?.exercises.first?.title == "Diagonalisation",
      "un intitulé explicite après deux-points est conservé — « \(titréSeries.first?.exercises.first?.title ?? "") »")
check(titréSeries.first?.exercises.count == 2, "les deux exercices sont lus")

// Les métadonnées seules ne laissent pas un titre vide de sens.
check(SeriesPDFParser.exerciseTitle("Type : Technique Défi : \u{22c6}\u{22c6}").isEmpty,
      "les métadonnées seules ne font pas un titre")
check(SeriesPDFParser.exerciseTitle("Diagonalisation") == "Diagonalisation",
      "un vrai intitulé traverse le nettoyage")

print("== Mise en page du PDF : titre ou énoncé ? ==")
// Le cas signalé sur un vrai polycopié : « Exercice 1 » suivi de la **première
// phrase de l'énoncé**. Le texte seul ne permet pas de les distinguer ; la taille
// de police, si. C'est tout l'objet de `SeriesLayoutParser`.
func layout(_ text: String, _ size: Double, bold: Bool = false, page: Int = 0) -> PDFLayoutLine {
    PDFLayoutLine(text: text, fontSize: size, isBold: bold, pageIndex: page)
}

let algebreLayout = [
    layout("Série 2", 16),
    layout("Exercice 1", 13),
    layout("solution générale.", 11),
    layout("Type : Technique Défi : ⋆⋆", 9),
    layout("Exercice 2", 13),
    layout("tions change.", 11),
    layout("Exercice 3", 13),
    layout("ou contre-exemple.", 11)
]
check(SeriesLayoutParser.bodyFontSize(algebreLayout) == 11,
      "corps de texte déduit de la police la plus lue (\(SeriesLayoutParser.bodyFontSize(algebreLayout) ?? -1))")

let algebreParsed = SeriesLayoutParser.parse(algebreLayout)
check(algebreParsed.count == 1, "une seule série (\(algebreParsed.count))")
check(algebreParsed.first?.number == 2, "série 2 lue depuis l'en-tête")
check(algebreParsed.first?.exercises.map(\.number) == ["2.1", "2.2", "2.3"],
      "trois exercices — \(algebreParsed.first?.exercises.map(\.number).joined(separator: ", ") ?? "-")")
check(algebreParsed.first?.exercises.allSatisfy { $0.title.isEmpty } == true,
      "aucun énoncé n'est pris pour un intitulé")

// Un vrai intitulé, lui, doit survivre.
let titréLayout = [
    layout("Série 3", 16),
    layout("Exercice 1 : Diagonalisation", 13),
    layout("Montrer que la matrice est diagonalisable.", 11),
    layout("Exercice 2", 13),
    layout("Espaces vectoriels", 13)
]
let titréParsed = SeriesLayoutParser.parse(titréLayout)
check(titréParsed.first?.exercises.first?.title == "Diagonalisation",
      "intitulé sur la même ligne — « \(titréParsed.first?.exercises.first?.title ?? "") »")
check(titréParsed.first?.exercises.count == 2, "deux exercices")

// Un titre peut tenir sur deux lignes, à condition que la seconde soit du **même
// niveau** que la première. C'est ce qui autorise la suite, et interdit l'énoncé.
let twoLineLayout = [
    layout("Série 4", 16),
    layout("Exercice 1", 13),
    layout("Formes bilinéaires", 13),
    layout("Montrer que la forme est symétrique.", 11)
]
let twoLineParsed = SeriesLayoutParser.parse(twoLineLayout)
check(twoLineParsed.first?.exercises.first?.title == "Formes bilinéaires",
      "titre sur deux lignes accepté — « \(twoLineParsed.first?.exercises.first?.title ?? "") »")

// Le bonus est souvent **plus bas** que la ligne suivante : l'ancienne lecture ne
// regardait qu'une ligne, et le manquait.
let bonusLayout = [
    layout("Série 5", 16),
    layout("Exercice 4", 13),
    layout("Montrer que l'ensemble est ouvert.", 11),
    layout("Indication : utiliser la boule unité.", 11),
    layout("(Cet exercice est facultatif.)", 11),
    layout("Exercice 5", 13),
    layout("Calculer la limite.", 11)
]
let bonusParsed = SeriesLayoutParser.parse(bonusLayout)
check(bonusParsed.first?.exercises.first { $0.number == "5.4" }?.isBonus == true,
      "bonus trouvé trois lignes plus bas")
check(bonusParsed.first?.exercises.first { $0.number == "5.5" }?.isBonus == false,
      "le bonus ne déborde pas sur l'exercice suivant")

// Sans information de police — texte collé — on retombe sur les motifs, sans régression.
let pasted = SeriesLayoutParser.parse("Série 2\nExercice 1 solution générale.\nExercice 2\n"
                                      .components(separatedBy: "\n").map { PDFLayoutLine(text: $0) })
check(pasted.first?.exercises.map(\.number) == ["2.1", "2.2"],
      "texte sans mise en page : les motifs prennent le relais — \(pasted.first?.exercises.map(\.number).joined(separator: ", ") ?? "-")")
check(pasted.first?.exercises.first?.title.isEmpty == true,
      "et la règle sur les intitulés s'applique quand même")

// Une tête de série sans exercice reste visible pour être complétée à la main.
let headerOnlyLayout = [layout("Série 7", 16), layout("Consignes générales.", 11)]
let headerOnlyParsed = SeriesLayoutParser.parse(headerOnlyLayout)
check(headerOnlyParsed.count == 1 && headerOnlyParsed.first?.exercises.isEmpty == true,
      "série annoncée sans exercice : conservée, liste vide")

// « Ex-02-04 » porte la série dans son numéro, même sans en-tête.
let dashedLayout = [layout("Ex-02-04: Montrer que si n est pair.", 11),
                    layout("Ex-02-05: En déduire le résultat.", 11)]
let dashedParsed = SeriesLayoutParser.parse(dashedLayout)
check(dashedParsed.first?.number == 2, "série déduite du numéro d'exercice")
check(dashedParsed.first?.exercises.count == 2, "deux exercices « Ex-02-xx »")

// Le corps est en gras partout (diapositives) : le gras ne doit plus servir de
// signal, sinon chaque ligne deviendrait un titre.
let allBold = [
    layout("Série 2", 16, bold: true),
    layout("Exercice 1", 14, bold: true),
    layout("solution générale.", 14, bold: true)
]
let allBoldParsed = SeriesLayoutParser.parse(allBold)
check(allBoldParsed.first?.exercises.first?.title.isEmpty == true,
      "corps entièrement en gras : aucun faux intitulé")

print("== Code de cours dans un horaire iCal ==")
// Le code n'est pas toujours dans l'intitulé : on le cherche aussi dans la
// description et le lieu, et on distingue un vrai code d'un code fabriqué.
check(TimetableImport.detectCourseCode(in: "CS-250 Algorithms I") == "CS-250",
      "code lu dans l'intitulé")
check(TimetableImport.detectCourseCode(in: "Analyse I") == nil,
      "un intitulé sans code n'en invente pas")
check(TimetableImport.detectCourseCode(in: "MATH-101 / Analyse I") == "MATH-101",
      "code lu dans une description de type « MATH-101 / Analyse I »")
check(TimetableImport.detectCourseCode(in: "Salle CS-250") == "CS-250",
      "code lu dans le lieu, faute de mieux")

check(TimetableImport.isOfficialCode("CS-250"), "« CS-250 » est un code officiel")
check(TimetableImport.isOfficialCode("MATH-101"), "« MATH-101 » est un code officiel")
check(!TimetableImport.isOfficialCode("ANALYSE"),
      "« ANALYSE » est un code fabriqué, pas un code officiel")
check(!TimetableImport.isOfficialCode("PHYSIQ-2"),
      "un code fabriqué avec suffixe n'est pas officiel")

// Le repli sur le nom : un ICS accentué doit retrouver le cours déjà saisi.
check(TimetableImport.nameKey("Algèbre linéaire") == TimetableImport.nameKey("Algebre lineaire"),
      "les accents ne séparent pas un cours de lui-même")
check(TimetableImport.nameKey("Analyse I") == TimetableImport.nameKey("analyse  i"),
      "casse et espaces multiples ignorés")
check(TimetableImport.nameKey("Analyse I") != TimetableImport.nameKey("Analyse II"),
      "deux cours différents restent distincts")
check(TimetableImport.nameKey("Projet de semestre!") == "projet de semestre",
      "ponctuation ignorée : « \(TimetableImport.nameKey("Projet de semestre!")) »")

print("== Tolérance de forme des polycopiés ==")
// Tous les cours n'écrivent pas « Exercice 1.1 ».
check(SeriesPDFParser.parse("Ex 1.1\nEx 1.2\n").first?.exercises.count == 2,
      "« Ex 1.1 » sans tiret")
check(SeriesPDFParser.parse("Ex.1.1\n").first?.exercises.count == 1, "« Ex.1.1 »")
check(SeriesPDFParser.parse("Exercice n° 1.1\n").first?.exercises.count == 1,
      "« Exercice n° 1.1 »")
check(SeriesPDFParser.parse("Exo 2.1\n").first?.exercises.count == 1, "« Exo 2.1 »")
check(SeriesPDFParser.parse("Problème 1.1\n").first?.exercises.count == 1, "« Problème 1.1 »")
check(SeriesPDFParser.parse("1·2\n").first?.exercises.count == 1, "séparateur médian « 1·2 »")

// Robustesse à une mise en page inconnue : la série est conservée sans exercice,
// pour que l'écran de relecture reste utilisable.
let headerOnly = SeriesPDFParser.parse("Série 4\nDes consignes sans numéro d'exercice.\n")
check(headerOnly.count == 1 && headerOnly.first?.number == 4
      && headerOnly.first?.exercises.isEmpty == true,
      "une série annoncée sans exercice reconnu est conservée")

// Pas de faux positif sur du texte courant.
check(SeriesPDFParser.parse("Le chapitre traite de ce point.\n").isEmpty,
      "une phrase sans numéro en tête ne crée pas d'exercice")
check(SeriesPDFParser.parse("Voir la page 12 pour la suite.\n").isEmpty,
      "une référence de page ne crée pas d'exercice")

print("== Type de séance depuis CATEGORIES ==")
// Le « Mon horaire » de l'EPFL écrit trois fois CATEGORIES, dont une vide : les
// valeurs arrivent donc concaténées avec des trous.
check(ICSParser.isLectureCategory("Horaires enseignés FBM,,Cours,") == true,
      "« Cours » reconnu malgré les valeurs vides")
check(ICSParser.isLectureCategory(",,Exercices,") == false,
      "« Exercices » n'est pas un cours magistral")
check(ICSParser.isLectureCategory(",,Labo,") == false,
      "« Labo » n'est pas un cours magistral")
check(ICSParser.isLectureCategory("Horaires enseignés FBM,,") == nil,
      "sans type de séance, on ne tranche pas")
check(ICSParser.isLectureCategory("") == nil, "catégories vides → indécis")

print("== Début du semestre d'automne ==")
// L'EPFL fait commencer le semestre d'automne le lundi 7 septembre pour tout le
// monde. Le demander à l'onboarding décalait tout le suivi hebdomadaire.
let sept2026 = DateUtils.autumnStart(forYear: 2026)
var gregorian = Calendar(identifier: .gregorian)
gregorian.firstWeekday = 2
let parts2026 = gregorian.dateComponents([.year, .month, .day, .weekday], from: sept2026)
check(parts2026.year == 2026 && parts2026.month == 9 && parts2026.day == 7,
      "2026 : le 7 septembre (\(parts2026.day ?? 0)/\(parts2026.month ?? 0))")
check(parts2026.weekday == 2, "2026 : c'est bien un lundi")
// Une année où le 7 septembre n'est pas un lundi doit donner le lundi suivant.
for year in 2026...2032 {
    let start = DateUtils.autumnStart(forYear: year)
    let parts = gregorian.dateComponents([.month, .day, .weekday], from: start)
    check(parts.weekday == 2, "\(year) : le semestre commence un lundi")
    check(parts.month == 9 && (parts.day ?? 0) >= 7 && (parts.day ?? 0) <= 13,
          "\(year) : début entre le 7 et le 13 septembre (\(parts.day ?? 0))")
}
// Le suivi hebdomadaire doit alors dire « semaine 1 » la semaine du 7 septembre.
if let term = try? AcademicTerm(year: 2026, season: .autumn, startDate: sept2026,
                                endDate: DateUtils.addWeeks(14, to: sept2026), totalWeeks: 14) {
    let firstMonday = DateUtils.addDays(7, to: sept2026)
    check(DateUtils.clampedWeek(for: firstMonday, term: term) == 2,
          "la semaine suivant le 7 septembre est la semaine 2")
    check(DateUtils.clampedWeek(for: sept2026, term: term) == 1,
          "la semaine du 7 septembre est la semaine 1")
}

print("== Durée iCalendar (DURATION) ==")
// Le « Mon horaire » de l'EPFL n'émet pas de DTEND : uniquement `DURATION:PT105M`.
// Sans ce décodage, chaque séance retombait sur le défaut d'une heure.
check(ICSParser.parseDuration("PT105M") == 105 * 60, "PT105M = 105 min")
check(ICSParser.parseDuration("PT45M") == 45 * 60, "PT45M = 45 min")
check(ICSParser.parseDuration("PT1H30M") == 90 * 60, "PT1H30M = 90 min")
check(ICSParser.parseDuration("PT1H") == 3600, "PT1H = 1 h")
check(ICSParser.parseDuration("P1D") == 86_400, "P1D = 1 jour")
check(ICSParser.parseDuration("PT30S") == 30, "PT30S = 30 s")
check(ICSParser.parseDuration("") == nil, "une durée vide n'est pas une durée")
check(ICSParser.parseDuration("PT0M") == nil, "une durée nulle n'est pas retenue")
check(ICSParser.parseDuration("20260915T081500") == nil,
      "une date n'est pas une durée — le piège qui faisait tout tomber à 1 h")

print("== Configuration Supabase compilée ==")
// Le binaire de validation n'a pas de clés Info.plist : il doit se déclarer non
// configuré plutôt que de tenter une connexion vers une URL vide.
check(!SupabaseConfig.isConfigured,
      "un binaire sans clés se déclare non configuré")
check(!SupabaseConfig.isUsable(""),
      "une valeur vide n'est pas une configuration")
check(!SupabaseConfig.isUsable("$(SUPABASE_URL)"),
      "une variable de build non définie n'est pas prise pour une URL")
check(!SupabaseConfig.isUsable("   "),
      "des espaces ne font pas une configuration")
// Sans domaine, aucune URL ne doit être fabriquée : « https:// » tout seul
// enverrait les requêtes dans le vide.
check(SupabaseConfig.urlString.isEmpty,
      "sans domaine, aucune URL n'est inventée")
check(SupabaseConfig.isUsable("testprojet.supabase.co"),
      "un domaine nu est accepté (le schéma est ajouté par le code)")
check(!SupabaseConfig.isUsable("$(SUPABASE_HOST)"),
      "un domaine resté littéral n'est pas une configuration")
check(SupabaseConfig.isUsable("https://exemple.supabase.co"),
      "une vraie URL est acceptée")
check(SupabaseConfig.isUsable("eyJhbGciOiJIUzI1NiJ9.clef"),
      "une vraie clé est acceptée")

print("== Tâches, calendrier, sessions planifiées ==")
let task = LinkedTask(provider: .todoist, externalID: "t1", title: "CS-250 exercice 1.1", dueDate: Date())
task.course = cs
context.insert(task)
// Hors de toute session de test : un chrono qui recouvre le cours en retire
// la part recouverte (`StudyTime`), et ce test porte sur le cours seul.
let event = LinkedCalendarEvent(title: "CS-250 Cours", startsAt: Date().addingTimeInterval(-3 * 3600 - 7 * 86400),
                                endsAt: Date().addingTimeInterval(-2 * 3600 - 7 * 86400), kind: .lecture)
event.isAttended = true
event.course = cs
context.insert(event)
let planned = PlannedSession(course: cs, title: "Révisions", startsAt: Date(), durationMinutes: 90)
context.insert(planned)
try context.save()

let tasks = try context.fetch(FetchDescriptor<LinkedTask>())
let events = try context.fetch(FetchDescriptor<LinkedCalendarEvent>())
let plannedAll = try context.fetch(FetchDescriptor<PlannedSession>())
check(tasks.count == 1 && tasks[0].linkLabel == "CS-250", "tâche liée au cours")
check(events.count == 1 && events[0].isLecture, "événement de cours marqué présent")
check(plannedAll.count == 3, "sessions planifiées (\(plannedAll.count))")
let classSeconds = WorkloadEngine.classSeconds(for: cs)
check(classSeconds > 0, "les heures d'amphi entrent dans le réel : \(DateUtils.durationLabel(seconds: classSeconds))")

print("== Cours sans heures de cours (« a un cours » = non) ==")
if let project = courses.first(where: { $0.code == "PROJ-101" }) {
    check(!project.hasLectures, "PROJ-101 déclaré sans amphi")
    let projectWorkload = WorkloadEngine.delta(for: project, hoursPerCredit: 30)
    check(projectWorkload.lectureSeconds == 0,
          "aucune heure d'amphi attendue pour un cours sans cours")
    check(projectWorkload.exerciseSeconds == projectWorkload.expectedSeconds,
          "tout est en travail personnel (\(DateUtils.hoursLabel(seconds: projectWorkload.exerciseSeconds)))")
} else {
    check(false, "PROJ-101 présent dans les données d'exemple")
}

print("== Bornage de la semaine dans le semestre ==")
let finishedTerm = AcademicTerm(year: 2020,
                                season: .spring,
                                startDate: DateUtils.addWeeks(-40, to: Date()),
                                endDate: DateUtils.addWeeks(-26, to: Date()),
                                totalWeeks: 14)
let clamped = DateUtils.clampedWeek(for: Date(), term: finishedTerm)
check(clamped == 14, "semestre terminé → semaine bornée à 14 (obtenu \(clamped))")
check(!finishedTerm.isRunning, "semestre terminé détecté")
let runningTerm = AcademicTerm(year: 2025,
                               season: .spring,
                               startDate: DateUtils.addWeeks(-2, to: DateUtils.startOfWeek(Date())),
                               endDate: DateUtils.addWeeks(12, to: Date()),
                               totalWeeks: 14)
check(runningTerm.isRunning, "semestre en cours détecté")
// Une date fixe, sans interruption des cours dans les deux semaines : avec
// `Date()`, le contrôle échouait chaque fois qu'une pause du calendrier EPFL
// (19–23 octobre 2026, Pâques…) tombait dans la fenêtre — l'app avait raison.
let fixedNow = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!
let fixedTerm = AcademicTerm(year: 2026,
                             season: .autumn,
                             startDate: DateUtils.addWeeks(-2, to: DateUtils.startOfWeek(fixedNow)),
                             endDate: DateUtils.addWeeks(12, to: fixedNow),
                             totalWeeks: 14)
check(DateUtils.clampedWeek(for: fixedNow, term: fixedTerm) == 3,
      "semestre démarré il y a 2 semaines → semaine 3")

print("== ICSParser (horaire EPFL) ==")
let ics = """
BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:cs250-cours
SUMMARY:CS-250 Algorithms I (cours)
DTSTART;TZID=Europe/Zurich:20250217T081500
DTEND;TZID=Europe/Zurich:20250217T100000
LOCATION:CM1 100
RRULE:FREQ=WEEKLY;COUNT=5;BYDAY=MO
END:VEVENT
END:VCALENDAR
"""
let parsedEvents = ICSParser.parse(ics)
check(parsedEvents.count == 5, "5 occurrences hebdomadaires (\(parsedEvents.count))")
check(parsedEvents.allSatisfy { $0.summary.contains("CS-250") }, "intitulé conservé")
check(parsedEvents[0].durationSeconds == 6300,
      "durée 1 h 45 (\(parsedEvents[0].durationSeconds) s)")
check(parsedEvents[1].start > parsedEvents[0].start, "occurrences ordonnées")
let weekGap = DateUtils.daysBetween(parsedEvents[0].start, parsedEvents[1].start)
check(weekGap == 7, "occurrences espacées de 7 jours (\(weekGap))")
check(parsedEvents[0].location == "CM1 100", "lieu conservé")

let detected = TimetableImport.detectCourseCode(in: "CS-250 Algorithms I (cours)")
check(detected == "CS-250", "code détecté : \(detected ?? "nil")")
let cleaned = TimetableImport.cleanedName("CS-250 Algorithms I (cours)", code: "CS-250")
check(cleaned == "Algorithms I", "intitulé nettoyé : « \(cleaned) »")
let derived = TimetableImport.derivedCode(from: "Analyse I", existing: ["ANALYSEI"])
check(derived == "ANALYSE", "code dérivé depuis le nom : \(derived)")
let derivedUnique = TimetableImport.derivedCode(from: "Analyse I", existing: ["ANALYSE"])
check(derivedUnique == "ANALYSE-2", "code dérivé rendu unique : \(derivedUnique)")

print("== Import iCalendar dans SwiftData ==")
let importResult = TimetableImport.import(ics, into: context, sectionCode: "IN")
check(importResult.coursesMatched == 1,
      "CS-250 existant reconnu depuis l'horaire (\(importResult.coursesMatched))")
check(importResult.coursesCreated == 0, "aucun doublon de cours créé")
check(importResult.eventsCreated == 5, "5 séances créées (\(importResult.eventsCreated))")
check(importResult.sectionApplied == 1, "section IN appliquée au cours existant")
let refreshed = (try? context.fetch(FetchDescriptor<Course>())) ?? []
if let imported = refreshed.first(where: { $0.code == "CS-250" }) {
    check(imported.hasLectures, "le cours importé a bien des heures de cours")
    check(imported.sectionCode == "IN", "section appliquée à l'import")
}
let secondImport = TimetableImport.import(ics, into: context, sectionCode: "IN")
check(secondImport.eventsCreated == 0, "réimport idempotent (\(secondImport.eventsSkipped) ignorées)")

// Un cours absent de l'app est créé automatiquement depuis l'horaire.
let unknownICS = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:unknown-1
SUMMARY:Analyse numérique
DTSTART;TZID=Europe/Zurich:20250218T101500
DTEND;TZID=Europe/Zurich:20250218T120000
RRULE:FREQ=WEEKLY;COUNT=3
END:VEVENT
END:VCALENDAR
"""
let unknownResult = TimetableImport.import(unknownICS, into: context, sectionCode: "MA")
check(unknownResult.coursesCreated == 1,
      "cours inconnu créé automatiquement (\(unknownResult.coursesCreated))")
check(unknownResult.eventsCreated == 3, "3 séances du cours inconnu (\(unknownResult.eventsCreated))")

// Le **lieu** ne doit jamais servir à déduire un code de cours.
//
// L'horaire EPFL ne contient aucun code officiel : ni SUMMARY, ni DESCRIPTION.
// Chercher un code dans LOCATION faisait correspondre « BS170 » (un local) au motif
// d'un code de cours, et produisait un cours nommé « BS-170 ».
print("== Le lieu ne détermine jamais le code de cours ==")
let roomICS = """
BEGIN:VCALENDAR
BEGIN:VEVENT
UID:room-1
SUMMARY:Thermodynamique appliquée
LOCATION:BS170, CM1221
CATEGORIES:Cours
DTSTART;TZID=Europe/Zurich:20250217T081500
DTEND;TZID=Europe/Zurich:20250217T100000
END:VEVENT
END:VCALENDAR
"""
let roomResult = TimetableImport.import(roomICS, into: context, sectionCode: "MA")
check(roomResult.coursesCreated == 1, "le cours sans code est créé (\(roomResult.coursesCreated))")
let afterRoom = (try? context.fetch(FetchDescriptor<Course>())) ?? []
check(afterRoom.contains { $0.code == "THERMOD" },
      "code dérivé du nom, pas du local (\(afterRoom.map(\.code).filter { $0.hasPrefix("THERMO") }))")
check(!afterRoom.contains { $0.code.contains("BS170") || $0.code.contains("BS-170") },
      "aucun cours nommé d'après un local")
check(!afterRoom.contains { $0.name.contains("BS170") },
      "aucun cours nommé d'après un local (intitulé)")
check(afterRoom.first { $0.code == "THERMOD" }?.hasLectures == true,
      "CATEGORIES:Cours marque bien des heures de cours")
let roomEvents = ((try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? [])
    .filter { $0.course?.code == "THERMOD" }
check(roomEvents.count == 1, "une séance enregistrée pour ce cours (\(roomEvents.count))")
check(roomEvents.first?.location.contains("BS170") == true,
      "le local reste enregistré comme lieu — \(roomEvents.first?.location ?? "-")")
check(roomEvents.first?.isLecture == true, "la séance est classée comme cours")
check(afterRoom.first { $0.code == "THERMOD" }?.name != "BS170",
      "l'intitulé du cours n'est pas le local")


print("== Semestre rattaché aux cours importés ==")
// `TimetableImport` créait les cours avec `term: nil`. `Course.currentWeek` n'avait
// alors rien pour calculer et retombait sur 1 : un import fait en semaine 2
// affichait « 1 / 14 » partout, sans le moindre signe d'erreur.
let expectedWeek = DateUtils.weekNumber(from: DateUtils.currentAutumnOrSpringStart().start)
let importedCourses = (try? context.fetch(FetchDescriptor<Course>())) ?? []
let arbitraryImported = importedCourses.first { $0.code == "THERMOD" }
check(arbitraryImported?.term != nil, "un cours créé par l'import d'horaire reçoit un semestre")
check(arbitraryImported?.currentWeek == expectedWeek,
      "…donc sa semaine vient du calendrier (\(arbitraryImported?.currentWeek ?? -1)), pas de « 1 »")

let orphanCourse = Course(code: "ORPHAN-1", name: "Cours sans semestre")
context.insert(orphanCourse)
// Deux séries importées pendant la panne : elles portent toutes deux « semaine 1 »,
// y compris la Série 2 — parce que l'import PDF prend `course.currentWeek`, qui
// valait 1 faute de semestre.
let orphanSeries1 = ExerciseSeries(course: orphanCourse, seriesNumber: 1, plannedWeek: 1)
let orphanSeries2 = ExerciseSeries(course: orphanCourse, seriesNumber: 2, plannedWeek: 1)
let orphanSeries4 = ExerciseSeries(course: orphanCourse, seriesNumber: 4, plannedWeek: 7)
context.insert(orphanSeries1)
context.insert(orphanSeries2)
context.insert(orphanSeries4)
try? context.save()
check(orphanCourse.term == nil, "un cours peut exister sans semestre")
check(orphanCourse.currentWeek == expectedWeek,
      "sans semestre, la semaine reste celle du calendrier (\(orphanCourse.currentWeek)) — jamais 1 par défaut")
let repaired = AcademicTerm.attachOrphanCourses(in: context)
check(repaired >= 1, "les cours orphelins sont rattachés (\(repaired))")
check(orphanCourse.term != nil, "le cours orphelin a maintenant un semestre")
check(AcademicTerm.attachOrphanCourses(in: context) == 0, "le rattachement est idempotent")
check(orphanCourse.term?.isRunning == true, "le semestre rattaché est celui en cours")

// La réparation des semaines de série reste bornée.
check(orphanSeries1.plannedWeek == 1, "une série 1 reste en semaine 1")
check(orphanSeries2.plannedWeek == 2, "la Série 2 repasse en semaine 2 — \(orphanSeries2.plannedWeek)")
check(orphanSeries4.plannedWeek == 7,
      "une semaine choisie à la main n'est jamais écrasée — \(orphanSeries4.plannedWeek)")

// La date de début n'est pas déduite du jour : elle vient du calendrier EPFL.
let autumn = DateUtils.autumnStart(forYear: 2026)
check(DateUtils.weekNumber(from: autumn, to: autumn) == 1, "le lundi de rentrée est la semaine 1")
check(DateUtils.weekNumber(from: autumn,
                           to: DateUtils.addDays(7, to: autumn)) == 2,
      "sept jours plus tard, semaine 2")
check(DateUtils.weekNumber(from: autumn,
                           to: DateUtils.addDays(9, to: autumn)) == 2,
      "le mercredi de la deuxième semaine est bien la semaine 2")
// L'interruption d'automne (16 → 26 octobre 2026) ne compte pas : les sites
// des cours reprennent à « semaine 7 » le lundi de la reprise.
check(DateUtils.weekNumber(from: autumn, to: DateUtils.addDays(35, to: autumn)) == 6, "12 octobre : semaine 6")
check(DateUtils.weekNumber(from: autumn, to: DateUtils.addDays(49, to: autumn)) == 7,
      "26 octobre, reprise après l'interruption : semaine 7 — \(DateUtils.weekNumber(from: autumn, to: DateUtils.addDays(49, to: autumn)))")
check(DateUtils.weekNumber(from: autumn, to: DateUtils.addDays(98, to: autumn)) == 14, "14 décembre : semaine 14")
check(DateUtils.addTeachingWeeks(14, to: autumn) == DateUtils.addDays(105, to: autumn),
      "14 semaines d'enseignement finissent une semaine plus tard que 14 semaines de calendrier")

print("== Import CSV ==")
let csv = """
course_code,course_name,credits,kind,number,title,duration_seconds,week,is_bonus,date,weight,location
BIO-201,Biologie,5,video,1.1,Cellules,2400,1,,,,,
BIO-201,Biologie,5,exercise,1.1,,,1,false,,,
BIO-201,Biologie,5,exercise,1.2,,,1,true,,,
BIO-201,Biologie,5,exam,midterm,Midterm,,,,2026-03-27T08:00:00Z,30,AAB
"""
do {
    let csvSummary = try CourseImporter.importCSV(csv, into: context, sectionCode: "SV")
    check(csvSummary.coursesCreated == 1, "1 cours créé depuis le CSV (\(csvSummary.coursesCreated))")
    check(csvSummary.videos == 1, "1 vidéo (\(csvSummary.videos))")
    check(csvSummary.exercises == 2, "2 exercices (\(csvSummary.exercises))")
    check(csvSummary.exams == 1, "1 évaluation (\(csvSummary.exams))")
    let afterCSV = (try? context.fetch(FetchDescriptor<Course>())) ?? []
    check(afterCSV.first(where: { $0.code == "BIO-201" })?.sectionCode == "SV",
          "section appliquée à l'import CSV")
    if let bio = afterCSV.first(where: { $0.code == "BIO-201" }) {
        let bioProgress = ProgressEngine.progress(for: bio)
        check(bioProgress.videoCount == 1 && bioProgress.exerciseCount == 1,
              "comptage : 1 vidéo et 1 exercice requis (bonus exclu)")
        check(bioProgress.bonusCount == 1, "1 bonus détecté depuis le CSV")
    }
} catch {
    check(false, "import CSV sans erreur : \(error)")
}

print("== Contraste : chaque teinte porteuse de sens est résolue ==")
// Surfaces de référence : carte claire (#FFFFFF) et carte sombre (#1C1C1E).
let cardLight = ColorContrast.RGB.white
let cardDark = ColorContrast.RGB(r: 0.110, g: 0.110, b: 0.118)

let identityPalette = ["#4F46E5", "#0EA5E9", "#10B981", "#F59E0B", "#EF4444",
                       "#8B5CF6", "#EC4899", "#14B8A6", "#F97316", "#6366F1"]
let suretéTriad = ["#34C759", "#FF9500", "#FF3B30"]

func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

var contrastFailures = 0
func checkContrast(_ hex: String, surface: ColorContrast.RGB, _ context: String) {
    guard let hue = ColorContrast.rgb(fromHex: hex) else {
        check(false, "\(hex) illisible"); contrastFailures += 1; return
    }
    let badge = ColorContrast.badgeStyle(hue: hue, surface: surface)
    let inkRatio = ColorContrast.ratio(badge.ink, badge.fill)
    let mark = ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.markTarget)
    let markRatio = ColorContrast.ratio(mark, surface)
    let verdict = ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.textTarget)
    let verdictRatio = ColorContrast.ratio(verdict, surface)

    if inkRatio < 4.5 { contrastFailures += 1; check(false, "\(hex) \(context) encre de pastille = \(fmt(inkRatio)):1") }
    if markRatio < 3.0 { contrastFailures += 1; check(false, "\(hex) \(context) marque = \(fmt(markRatio)):1") }
    if verdictRatio < 4.5 { contrastFailures += 1; check(false, "\(hex) \(context) remplissage de verdict = \(fmt(verdictRatio)):1") }
}

for hex in identityPalette + suretéTriad {
    checkContrast(hex, surface: cardLight, "clair")
    checkContrast(hex, surface: cardDark, "sombre")
}
check(contrastFailures == 0,
      "\(identityPalette.count + suretéTriad.count) teintes × 2 apparences : texte ≥4.5:1, marque ≥3:1")

// Le papier et l'encre de « Carnet » (`CarnetCore`), que les vues posent en dur.
// Le troisième gris y servait de texte à 3.10:1 : il est maintenant résolu
// contre la surface la plus claire de chaque apparence, et vérifié ici.
print("  — le papier et l'encre de l'app")
func rgb(_ hex: String) -> ColorContrast.RGB? { ColorContrast.rgb(fromHex: hex) }
let paletteSurfaces = [
    "papier clair": ("#F4F0E6", "clair"), "feuille claire": ("#FFFDF8", "clair"),
    "feuille en retrait claire": ("#EFE9DC", "clair"),
    "papier de nuit": ("#15130F", "sombre"), "feuille de nuit": ("#211E18", "sombre"),
    "feuille en retrait de nuit": ("#2B271F", "sombre")
]
let inks = [("encre", "#1D1B16", "#EDE6D6"),
            ("encre secondaire", "#6B655A", "#A89F8D"),
            ("encre tertiaire", "#696356", "#9E9480"),
            ("juste", "#3A723A", "#8FC58A"),
            ("à revoir", "#8F5E06", "#E0B04E"),
            ("faux", "#A33A2A", "#E7836F")]
var paletteFailures: [String] = []
for (name, light, dark) in inks {
    for (surfaceName, (surface, mode)) in paletteSurfaces {
        guard let ink = rgb(mode == "clair" ? light : dark), let base = rgb(surface) else {
            paletteFailures.append("\(name) : couleur illisible"); continue
        }
        let ratio = ColorContrast.ratio(ink, base)
        if ratio < 4.5 { paletteFailures.append("\(name) sur \(surfaceName) = \(fmt(ratio)):1") }
    }
}
check(paletteFailures.isEmpty,
      "papier et encre : \(inks.count) encres × \(paletteSurfaces.count) surfaces ≥ 4.5:1 \(paletteFailures.first.map { "— " + $0 } ?? "")")

// Contrôle négatif : l'ancien schéma (teinte sur sa propre teinte) doit échouer,
// sinon le test précédent ne prouverait rien.
if let amber = ColorContrast.rgb(fromHex: "#F59E0B") {
    let oldBadge = ColorContrast.blend(cardLight, amber, amount: 0.16)
    let oldRatio = ColorContrast.ratio(amber, oldBadge)
    check(oldRatio < 4.5,
          "l'ancien schéma échouait bien (ambre sur sa teinte = \(fmt(oldRatio)):1 < 4.5)")
}

print("== Encre indigo : primitive + encre, résolues par apparence ==")
if let accent = ColorContrast.rgb(fromHex: Theme.accentHex),
   let accentDark = ColorContrast.rgb(fromHex: Theme.accentDarkHex),
   let accentInk = ColorContrast.rgb(fromHex: Theme.accentInkHex),
   let accentInkDark = ColorContrast.rgb(fromHex: Theme.accentInkDarkHex) {
    check(ColorContrast.ratio(accent, cardLight) >= 4.5,
          "accent clair sur carte claire = \(fmt(ColorContrast.ratio(accent, cardLight))):1")
    check(ColorContrast.ratio(accentDark, cardDark) >= 3.0,
          "accent sombre sur carte sombre ≥3:1 (glyphes) = \(fmt(ColorContrast.ratio(accentDark, cardDark))):1")
    // La nuit, l'accent est l'encre crème : un bouton plein porte son libellé
    // en papier sombre (`knockedOutInk`), pas en blanc.
    let paperNight = ColorContrast.rgb(fromHex: "#15130F") ?? cardDark
    check(ColorContrast.ratio(paperNight, accentDark) >= 4.5,
          "libellé papier sur bouton plein sombre = \(fmt(ColorContrast.ratio(paperNight, accentDark))):1")
    check(ColorContrast.ratio(accentInkDark, cardDark) >= 4.5,
          "encre accent sombre ≥4.5:1 (texte) = \(fmt(ColorContrast.ratio(accentInkDark, cardDark))):1")
    // La valeur unique d'origine échouait en mode sombre : c'est ce qui a motivé la paire.
    check(ColorContrast.ratio(accent, cardDark) < 3.0,
          "l'unique valeur d'origine échouait en sombre = \(fmt(ColorContrast.ratio(accent, cardDark))):1")
} else {
    check(false, "les quatre valeurs d'Encre indigo sont lisibles")
}

print("== Sureté : le glyphe évidé garde le contraste du remplissage ==")
for hex in suretéTriad {
    guard let hue = ColorContrast.rgb(fromHex: hex) else { continue }
    for (surface, name) in [(cardLight, "clair"), (cardDark, "sombre")] {
        let fill = ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.textTarget)
        // Le glyphe utilise la couleur de la surface : son contraste est exactement
        // celui du remplissage.
        let glyphRatio = ColorContrast.ratio(surface, fill)
        check(glyphRatio >= 4.5, "\(hex) \(name) : glyphe évidé = \(fmt(glyphRatio)):1")
        // L'ancienne pastille pleine avec un glyphe blanc restait sous 4.5:1 dans
        // tous les cas — 3.55:1 au mieux (rouge), 2.2:1 pour le vert et l'orange.
        let whiteOnMark = ColorContrast.ratio(.white,
            ColorContrast.accessibleVariant(of: hue, against: surface, target: ColorContrast.markTarget))
        if name == "sombre" {
            check(whiteOnMark < 4.5,
                  "\(hex) sombre : glyphe blanc insuffisant (\(fmt(whiteOnMark)):1 < 4.5)")
        }
    }
}

print("== FocusTimerState : le chrono survit à une fermeture ==")
do {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var timer = FocusTimerState(sessionStartedAt: t0, taskTypeRaw: "exercise")
    timer.start(at: t0)
    check(timer.isRunning, "démarré : en cours")
    check(Int(timer.elapsed(at: t0.addingTimeInterval(90))) == 90, "90 s écoulées après 90 s")
    timer.pause(at: t0.addingTimeInterval(120))
    check(!timer.isRunning && Int(timer.accumulated) == 120, "pause : 120 s accumulées")
    check(Int(timer.elapsed(at: t0.addingTimeInterval(9_999))) == 120, "en pause, le temps ne court plus")
    timer.start(at: t0.addingTimeInterval(200))
    check(Int(timer.elapsed(at: t0.addingTimeInterval(260))) == 180, "reprise : 120 + 60 = 180 s")
    timer.start(at: t0.addingTimeInterval(300))
    check(Int(timer.elapsed(at: t0.addingTimeInterval(360))) == 280, "un second « start » en cours ne remet rien à zéro")
    check(timer.isRestorable(at: t0.addingTimeInterval(3_600)), "restaurable une heure plus tard")
    check(!timer.isRestorable(at: t0.addingTimeInterval(FocusTimerState.maxRestorableAge + 1)),
          "plus restaurable au-delà de \(Int(FocusTimerState.maxRestorableAge / 3600)) h")
    check(!FocusTimerState(sessionStartedAt: t0).isRestorable(at: t0), "un chrono à zéro n'est pas restauré")

    // Un domaine jetable, effacé après : sans ça, chaque passage laissait un
    // `polymestre.validation.<UUID>.plist` dans ~/Library/Preferences (539 au 26 octobre).
    let suite = "polymestre.validation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { dropSuite(suite) }
    FocusTimerStore.save(timer, defaults: defaults)
    let reloaded = FocusTimerStore.load(defaults: defaults)
    check(reloaded == timer, "aller-retour UserDefaults sans perte")
    FocusTimerStore.save(nil, defaults: defaults)
    check(FocusTimerStore.load(defaults: defaults) == nil, "effacement du chrono")
}

print("== SessionStats : totaux par jour ==")
do {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    let totals = SessionStats.dailyTotals(sessions, days: 14, endingAt: Date())
    check(totals.count == 14, "14 colonnes, jours vides compris (\(totals.count))")
    check(totals.last?.day == today, "la dernière colonne est aujourd'hui")
    check(totals.first!.day < totals.last!.day, "du plus ancien au plus récent")
    let sum = totals.reduce(0) { $0 + $1.seconds }
    let expected = sessions.filter { $0.startedAt >= cal.date(byAdding: .day, value: -13, to: today)! }
        .reduce(0) { $0 + $1.durationSeconds }
    check(sum == expected, "somme des colonnes = sessions des 14 derniers jours (\(sum / 60) min)")
    let groups = SessionStats.groupedByDay(sessions)
    check(groups.count == 10, "10 jours de sessions dans l'exemple (\(groups.count))")
    check(groups.first!.day > groups.last!.day, "le plus récent d'abord")
    check(groups.allSatisfy { g in g.sessions.allSatisfy { cal.isDate($0.startedAt, inSameDayAs: g.day) } },
          "chaque session est dans le bon jour")
}

print("== WidgetFormat : heures en dixièmes arrondis ==")
// Un instantané écrit par une version précédente (champs retirés ou absents) doit se relire : sinon, après une mise à jour, les widgets restent
// vides jusqu'à la prochaine ouverture de l'app.
let oldSnapshot = #"{"updatedAt":"2026-09-20T10:00:00Z","weekSeconds":3600,"streak":2,"level":1,"xp":10,"todoCount":1,"todos":[]}"#
let snapshotDecoder = JSONDecoder()
snapshotDecoder.dateDecodingStrategy = .iso8601
let decodedOld = try? snapshotDecoder.decode(WidgetSnapshot.self, from: Data(oldSnapshot.utf8))
check(decodedOld != nil && decodedOld?.courses == nil,
      "un instantané de la version précédente se relit")
check(WidgetFormat.hours(45 * 60) == "45 min", "45 min")
check(WidgetFormat.hours(2 * 3600) == "2 h", "2 h")
check(WidgetFormat.hours(95 * 60) == "1,6 h", "1 h 35 → 1,6 h (l'ancien code donnait 1,3 h)")
check(WidgetFormat.hours(117 * 60) == "2 h", "1 h 57 → 2 h (arrondi, pas 1,10)")
check(WidgetFormat.hours(63 * 60) == "1,1 h", "1 h 03 → 1,1 h")
check(WidgetFormat.hours(-5) == "0 min", "négatif → 0 min")
check(WidgetFormat.countdown(to: DateUtils.addDays(3, to: Date())) == "J-3", "J-3")
check(WidgetFormat.countdown(to: Date()) == "Aujourd'hui", "aujourd'hui")

print("== Sauvegarde : export → import sans perte ni doublon ==")
do {
    let backup = DataExporter.makePayload(courses: courses, sessions: sessions)
    check(backup.courses.count == courses.count, "\(backup.courses.count) cours exportés")
    check(backup.sessions?.count == sessions.count, "\(backup.sessions?.count ?? 0) sessions exportées")
    check(backup.term != nil, "le semestre est exporté")
    let watched = backup.courses.flatMap { $0.videos ?? [] }.filter { $0.watchedAt != nil }.count
    check(watched == videos.filter(\.isWatched).count, "\(watched) vidéos vues conservées")
    let chapters = backup.courses.flatMap { $0.videos ?? [] }.filter { $0.kind == "chapter" }.count
    check(chapters == 1, "le support (chapitre) est exporté")
    let done = backup.courses.flatMap { $0.series ?? [] }.flatMap { $0.exercises ?? [] }.filter { $0.doneAt != nil }.count
    check(done == exercises.filter(\.isDone).count, "\(done) exercices faits conservés")

    guard let data = DataExporter.makeJSON(courses: courses, sessions: sessions),
          let json = String(data: data, encoding: .utf8) else {
        check(false, "JSON de sauvegarde produit"); throw NSError(domain: "v", code: 1)
    }
    // Restauration dans un conteneur vierge.
    let restoreConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let restoreContainer = try ModelContainer(for: schema, configurations: [restoreConfig])
    let restoreContext = ModelContext(restoreContainer)
    let summary = try CourseImporter.importJSON(json, into: restoreContext)
    check(summary.coursesCreated == courses.count, "\(summary.coursesCreated) cours restaurés")
    check(summary.sessions == sessions.count, "\(summary.sessions) sessions restaurées")
    let restoredCourses = try restoreContext.fetch(FetchDescriptor<Course>())
    let restoredVideos = try restoreContext.fetch(FetchDescriptor<TheoryItem>())
    let restoredExercises = try restoreContext.fetch(FetchDescriptor<Exercise>())
    check(restoredVideos.filter(\.isWatched).count == videos.filter(\.isWatched).count, "vidéos vues restaurées")
    check(restoredVideos.contains { $0.kind == .chapter }, "le chapitre reste un chapitre")
    check(restoredExercises.filter(\.isDone).count == exercises.filter(\.isDone).count, "exercices faits restaurés")
    check(restoredExercises.filter(\.redoRequired).count == exercises.filter(\.redoRequired).count, "« à refaire » restauré")
    check(restoredExercises.compactMap(\.confidence).count == exercises.compactMap(\.confidence).count, "sureté restaurée")
    let restoredSessions = try restoreContext.fetch(FetchDescriptor<StudySession>())
    check(restoredSessions.reduce(0) { $0 + $1.durationSeconds } == sessions.reduce(0) { $0 + $1.durationSeconds },
          "temps total identique après restauration")
    check(restoredSessions.allSatisfy { $0.course != nil }, "chaque session retrouve son cours")
    for course in courses {
        let p1 = ProgressEngine.progress(for: course)
        let p2 = restoredCourses.first { $0.code == course.code }.map(ProgressEngine.progress(for:))
        check(p2 == p1, "\(course.code) : progression identique après restauration")
    }
    // Idempotence : réimporter ne double rien.
    let again = try CourseImporter.importJSON(json, into: restoreContext)
    check(again.sessions == 0 && again.coursesCreated == 0, "réimport : 0 session, 0 cours en double")
    check(try restoreContext.fetch(FetchDescriptor<StudySession>()).count == sessions.count, "sessions inchangées au réimport")

    let csv = DataExporter.sessionsCSV(sessions)
    check(csv.split(separator: "\n").count == sessions.count + 1, "CSV : en-tête + \(sessions.count) lignes")
    check(csv.hasPrefix("date,heure,cours,type,cible,minutes,note"), "CSV : en-tête attendu")
}

print("== GroupSeriesEngine : avancement série par série ==")
do {
    let refs = [
        GroupSeriesEngine.SeriesRef(number: 1, title: "Série 1", plannedWeek: 1, required: ["1.1", "1.2"], bonus: ["1.3"]),
        GroupSeriesEngine.SeriesRef(number: 2, title: "Série 2", plannedWeek: 2, required: ["2.1", "2.2", "2.3"], bonus: []),
        GroupSeriesEngine.SeriesRef(number: 3, title: "Série 3", plannedWeek: 3, required: [], bonus: [])
    ]
    let members = [
        GroupSeriesEngine.MemberRef(userID: "me", displayName: "Moi", isMe: true),
        GroupSeriesEngine.MemberRef(userID: "alice", displayName: "Alice", isMe: false),
        GroupSeriesEngine.MemberRef(userID: "bob", displayName: "Bob", isMe: false)
    ]
    let items = [
        GroupSeriesEngine.ItemDone(userID: "me", number: "1.1"),
        GroupSeriesEngine.ItemDone(userID: "me", number: "1.3"),      // bonus : ne compte pas
        GroupSeriesEngine.ItemDone(userID: "alice", number: "1.1"),
        GroupSeriesEngine.ItemDone(userID: "alice", number: "1.2"),
        GroupSeriesEngine.ItemDone(userID: "alice", number: "2.1"),
        GroupSeriesEngine.ItemDone(userID: "alice", number: "9.9"),   // inconnu : ignoré
        GroupSeriesEngine.ItemDone(userID: "ghost", number: "2.2")    // hors groupe : ignoré
    ]
    let declared = [GroupSeriesEngine.SeriesDone(userID: "bob", seriesNumber: 2)]
    let boards = GroupSeriesEngine.boards(series: refs, members: members, itemsDone: items, seriesDone: declared, meID: "me")
    check(boards.count == 3, "3 séries, dans l'ordre (\(boards.map(\.seriesNumber)))")
    let s1 = boards[0]
    check(s1.rows.first?.userID == "alice", "série 1 : Alice (2/2) en tête")
    check(s1.rows.first?.isComplete == true, "série 1 : Alice a terminé")
    check(s1.me?.doneNumbers == ["1.1"], "série 1 : moi 1.1 fait, le bonus 1.3 ne compte pas (\(s1.me?.doneNumbers ?? []))")
    check(s1.me?.percent == 0.5, "série 1 : moi à 50 %")
    check(s1.summary == "1 sur 3 a terminé", "série 1 : « \(s1.summary) »")
    let s2 = boards[1]
    check(s2.rows.first?.userID == "bob" && s2.rows.first?.isComplete == true,
          "série 2 : Bob déclarée terminée passe devant Alice (1/3)")
    check(s2.rows.first?.doneCount == 0, "série 2 : Bob n'a aucun détail mais est complet")
    check(s2.rows.map(\.userID) == ["bob", "alice", "me"], "série 2 : tri terminé > avancé > moi (\(s2.rows.map(\.userID)))")
    check(s2.rows.contains { $0.userID == "me" && $0.doneCount == 0 }, "série 2 : moi à zéro, présent quand même")
    check(!s2.rows.contains { $0.userID == "ghost" }, "un membre hors groupe n'apparaît pas")
    check(boards[2].total == 0 && boards[2].summary == "Personne n'a commencé", "série 3 vide : « \(boards[2].summary) »")
    let gap = GroupSeriesEngine.gapToLeader(boards)
    // Alice : 2 + 1 = 3 ; Bob : 0 + 3 (déclarée) = 3 ; moi : 1 → écart 2.
    check(gap?.gap == 2, "écart au leader = 2 exercices (\(gap?.gap ?? -1))")
    check(GroupSeriesEngine.gapToLeader([]) == nil, "sans tableau, pas d'écart")
}

print("== Brouillons de série : plan rapide, gestes sur l'arbre, enregistrement ==")
do {
    typealias Tree = SubQuestionTree
    func plan(_ text: String) -> String { Tree.parse(text).map(Tree.outline) ?? "illisible" }
    check(plan("1(a-d) 2(a-e) 3") == "1(a-d) 2(a-e) 3", "plan lu et réécrit à l'identique — \(plan("1(a-d) 2(a-e) 3"))")
    check(Tree.parse("1-4")?.map(\.label) == ["1", "2", "3", "4"], "plage de questions")
    check(Tree.parse("1(a,b) 2")?.first?.children.map(\.label) == ["a", "b"], "liste de points")
    check(Tree.parse("i-iv")?.map(\.label) == ["i", "ii", "iii", "iv"], "plage romaine")
    check(Tree.parse("+ 1 2 +")?.map(\.kind) == [.part, .question, .question, .part], "parties sans numéro")
    check(Tree.parse("1(a-") == nil, "parenthèse non fermée : illisible")
    check(plan("1(a,b)") == "1(a,b)", "deux points restent écrits en liste")
    let kept = Tree.parse("1(a-b)", keeping: [DetectedSubQuestion(label: "1", text: "Soit x",
                                                                   children: [DetectedSubQuestion(label: "a", text: "borne")])])
    check(kept?.first?.text == "Soit x" && kept?.first?.children.first?.text == "borne",
          "réécrire le plan garde les énoncés déjà saisis")

    var tree = Tree.parse("1 2 3")!
    let two = tree[1].id
    Tree.indent(two, in: &tree)
    check(Tree.outline(tree) == "1(2) 3", "« 2 » devient un point de « 1 » — \(Tree.outline(tree))")
    Tree.outdent(two, in: &tree)
    check(Tree.outline(tree) == "1 2 3", "…et remonte à sa place — \(Tree.outline(tree))")
    Tree.addChild(to: tree[0].id, in: &tree)
    Tree.addChild(to: tree[0].id, in: &tree)
    check(Tree.outline(tree) == "1(a,b) 2 3", "points ajoutés a, b — \(Tree.outline(tree))")
    Tree.remove(tree[0].children[0].id, from: &tree)
    Tree.relabel(&tree)
    check(Tree.outline(tree) == "1(a) 2 3", "renumérotation — \(Tree.outline(tree))")
    check(Tree.rows(tree).map(\.depth) == [0, 1, 0, 0], "affichage à plat avec profondeur")
    check(Tree.rows(tree)[2].canIndent && !Tree.rows(tree)[0].canIndent, "seule une question précédée d'une autre peut devenir un point")

    // Problèmes signalés avant d'enregistrer.
    var draft = SeriesDraft(number: 5, title: "", plannedWeek: 5, exercises: [])
    draft.addExercise(); draft.addExercise()
    check(draft.exercises.map(\.minor) == ["1", "2"], "exercices ajoutés 5.1, 5.2")
    draft.exercises[1].minor = "1"
    check(draft.problems(taken: []).contains { $0.contains("5.1") }, "numéro en double signalé")
    check(draft.problems(taken: [SeriesIdentity.Key(5)]).contains { $0.contains("série 5") }, "série en double signalée")
    draft.renumberExercises()
    check(draft.problems(taken: []).isEmpty, "renuméroter corrige")

    // Modification : renuméroter garde l'avancement, retirer supprime.
    let draftCourse = Course(code: "TST-100", name: "Test", credits: 4)
    let written = SeriesDraftWriter.write(SeriesDraft(number: 2, title: "Suites", plannedWeek: 2, exercises: [
        ExerciseDraft(minor: "1", title: "", isBonus: false, subQuestions: Tree.parse("1(a-b) 2")!),
        ExerciseDraft(minor: "2", title: "", isBonus: false),
        ExerciseDraft(minor: "3", title: "", isBonus: true)
    ]), to: draftCourse, mode: .edit, context: nil)
    check(written.outcome.created == 3 && written.series.exercises.count == 3, "série créée avec trois exercices")
    check(written.series.sortedExercises.first?.subQuestionLabel == "0/3", "questions créées avec l'exercice")
    let first = written.series.sortedExercises[0]
    first.sortedSubQuestions[0].sortedChildren[0].toggle()
    written.series.sortedExercises[1].doneAt = Date()

    var edit = SeriesDraft(series: written.series)
    check(edit.title == "Suites" && edit.exercises.count == 3, "le brouillon relit la série")
    edit.exercises.remove(at: 2)
    edit.exercises.swapAt(0, 1)
    edit.renumberExercises()
    let second = SeriesDraftWriter.write(edit, to: draftCourse, mode: .edit, context: nil)
    check(second.outcome.deleted == 1 && second.series.exercises.count == 2, "l'exercice retiré est supprimé")
    let reordered = second.series.sortedExercises
    check(reordered.map(\.exerciseNumber) == ["2.1", "2.2"], "renumérotés dans le nouvel ordre")
    check(reordered[0].isDone, "l'ancien 2.2, devenu 2.1, garde son « fait »")
    check(reordered[1].subQuestionLabel == "1/3", "l'ancien 2.1, devenu 2.2, garde ses cases cochées — \(reordered[1].subQuestionLabel ?? "-")")

    // Import : ne supprime jamais, met à jour par numéro.
    let merged = SeriesDraftWriter.write(SeriesDraft(number: 2, title: "", plannedWeek: 2, exercises: [
        ExerciseDraft(minor: "2", title: "Relu", isBonus: false, subQuestions: Tree.parse("1(a-c) 2")!),
        ExerciseDraft(minor: "4", title: "", isBonus: false)
    ]), to: draftCourse, mode: .importMerge, context: nil)
    check(merged.outcome == .init(created: 1, updated: 1, deleted: 0), "import : un mis à jour, un créé, aucun supprimé — \(merged.outcome)")
    check(merged.series.title == "Suites", "un titre vide à l'import ne l'efface pas")
    let relu = merged.series.exercises.first { $0.exerciseNumber == "2.2" }
    check(relu?.title == "Relu" && relu?.subQuestionLabel == "1/4", "arbre remplacé, case 1.a conservée — \(relu?.subQuestionLabel ?? "-")")
    relu?.statement = "Montrer la borne"
    var noStatement = SeriesDraft(series: merged.series)
    for index in noStatement.exercises.indices { noStatement.exercises[index].statement = "" }
    SeriesDraftWriter.write(noStatement, to: draftCourse, mode: .importMerge, context: nil)
    check(relu?.statement == "Montrer la borne", "un import sans énoncé n'efface pas celui qui existe")
    SeriesDraftWriter.write(noStatement, to: draftCourse, mode: .edit, context: nil)
    check(relu?.statement == "", "…mais le vider à la main, si")
}

print("== MathMarkup : formules lisibles ==")
do {
    typealias M = MathMarkup
    func r(_ s: String) -> [String] {
        M.runs(s).map { run in
            switch run.style {
            case .normal: return run.text
            case .subscripted: return "_[\(run.text)]"
            case .superscripted: return "^[\(run.text)]"
            }
        }
    }
    check(r("a_n") == ["a", "_[n]"], "indice simple — \(r("a_n"))")
    check(r("x_{n+1} = 2") == ["x", "_[n+1]", " = 2"], "indice entre accolades — \(r("x_{n+1} = 2"))")
    check(r("n^2+1") == ["n", "^[2]", "+1"], "exposant — \(r("n^2+1"))")
    check(M.plain("|a_n - \\ell| \\le \\varepsilon") == "|an - ℓ| ≤ ε", "symboles — \(M.plain("|a_n - \\ell| \\le \\varepsilon"))")
    check(r("$\\frac{1}{2}$") == ["^[1]", "⁄", "_[2]"], "fraction courte en forme de fraction — \(r("$\\frac{1}{2}$"))")
    check(M.plain("\\frac{an+b}{cn+d}") == "(an+b)/(cn+d)", "fraction longue parenthésée — \(M.plain("\\frac{an+b}{cn+d}"))")
    check(M.plain("\\sqrt{n^2+2}") == "√(n2+2)", "racine d'une expression — \(M.plain("\\sqrt{n^2+2}"))")
    check(M.plain("\\sqrt{x}") == "√x", "racine simple")
    check(M.plain("n \\in \\mathbb{N}^*") == "n ∈ ℕ*", "ensembles — \(M.plain("n \\in \\mathbb{N}^*"))")
    check(M.plain("\\lim_{n \\to \\infty} a_n = L") == "limn → ∞ an = L", "limite — \(M.plain("\\lim_{n \\to \\infty} a_n = L"))")
    check(r("prix _ unitaire") == ["prix _ unitaire"], "un « _ » isolé entre espaces reste du texte")
    check(M.plain("\\unknown{x}") == "unknownx", "commande inconnue : son nom, pas un trou")
    check(!M.hasMarkup("Montrer la borne"), "texte sans formule : rien à faire")
}

print("== SeriesAIParsing : lecture de la réponse d'un modèle ==")
do {
    let answer = """
    Voici le résultat : ```json
    {"series":[{"number":3,"title":"Récurrences","exercises":[
      {"number":"3.1","title":"Tri fusion","isBonus":false},
      {"number":"2","title":"","isBonus":true},
      {"number":"Ex 3.1","title":"doublon","isBonus":false},
      {"number":"abc","title":"","isBonus":false},
      {"number":"3.3","title":"Montrer que pour tout n, la suite converge vers la limite attendue, en détaillant chaque étape.","isBonus":false}
    ]},{"number":0,"exercises":[]},{"number":3,"exercises":[{"number":"3.4","title":"","isBonus":false}]}]}
    ```
    """
    let parsed = SeriesAIParsing.parse(answer)
    check(parsed.count == 1, "une série (le numéro 0 est rejeté, la répétition fusionnée) (\(parsed.count))")
    check(parsed.first?.number == 3 && parsed.first?.title == "Récurrences", "série 3 « Récurrences »")
    let numbers = parsed.first?.exercises.map(\.number) ?? []
    check(numbers == ["3.1", "3.2", "3.3", "3.4"], "numéros normalisés et dédoublonnés : \(numbers)")
    check(parsed.first?.exercises.first { $0.number == "3.2" }?.isBonus == true, "« 2 » dans la série 3 → 3.2, bonus")
    check(parsed.first?.exercises.first { $0.number == "3.3" }?.title == "", "un énoncé n'est pas pris pour un titre")
    check(parsed.first?.exercises.first { $0.number == "3.1" }?.title == "Tri fusion", "l'intitulé court est gardé")
    check(SeriesAIParsing.parse("pas de json").isEmpty, "sans JSON : rien")
    check(SeriesAIParsing.parse("{\"series\":[]}").isEmpty, "liste vide : rien")
    check(SeriesAIParsing.normalizeNumber("4.2", series: 3) == "3.2", "un numéro d'une autre série suit la série parente")
    check(SeriesAIParsing.normalizeNumber("1.2.3", series: 1) == nil, "trois niveaux : refusé")

    // Fusion : le modèle complète, ne retire jamais.
    let heuristic = [DetectedSeries(number: 3, title: "", exercises: [
        DetectedExercise(number: "3.1", title: "", isBonus: false),
        DetectedExercise(number: "3.5", title: "Vu par les motifs seulement", isBonus: false)
    ])]
    let merged = SeriesAIParsing.merge(heuristic: heuristic, ai: parsed)
    check(merged.count == 1 && merged[0].title == "Récurrences", "fusion : le titre de série vient du modèle")
    check(merged[0].exercises.map(\.number) == ["3.1", "3.2", "3.3", "3.4", "3.5"], "fusion : union triée (\(merged[0].exercises.map(\.number)))")
    check(merged[0].exercises.first { $0.number == "3.1" }?.title == "Tri fusion", "fusion : l'intitulé manquant est complété")
    check(merged[0].exercises.first { $0.number == "3.5" }?.title == "Vu par les motifs seulement", "fusion : rien de l'heuristique n'est perdu")
    check(SeriesAIParsing.merge(heuristic: heuristic, ai: []) == heuristic, "fusion avec réponse vide : heuristique inchangée")

    // Préparation : un long texte est réduit à ses lignes structurantes.
    let noise = String(repeating: "Soit f une fonction continue sur un intervalle fermé borné.\n", count: 400)
    let long = "Série 4\n" + noise + "Exercice 4.1 Théorème des valeurs intermédiaires\nMontrer que…\n" + noise
    let prepared = SeriesAIParsing.prepare(long)
    check(long.count > SeriesAIParsing.maxCharacters, "texte long (\(long.count) car.)")
    check(prepared.count <= SeriesAIParsing.maxCharacters, "préparé sous la limite (\(prepared.count) car.)")
    check(prepared.contains("Série 4") && prepared.contains("Exercice 4.1"), "les en-têtes survivent")
    check(prepared.contains("Montrer que…"), "la ligne suivant un exercice survit (intitulé possible)")
    check(!prepared.contains("intervalle fermé borné.\nSoit f"), "le bruit répété est retiré")
    check(SeriesAIParsing.prepare("court") == "court", "un texte court passe tel quel")
}

print("== Import PDF : ce que le document dit de lui-même ==")
do {
    func line(_ text: String, _ size: Double = 11, bold: Bool = false, page: Int = 0,
              indent: Double = 60, startsBold: Bool = false) -> PDFLayoutLine {
        PDFLayoutLine(text: text, fontSize: size, isBold: bold, pageIndex: page, indent: indent, startsBold: startsBold)
    }

    // La série n'est pas toujours en début de ligne : c'était la cause de tout
    // un PDF rangé en « série 1 ».
    let header = [line("EPFL — Analyse I — Série 4", 9), line("Automne 2026", 9), line("Exercice 1", 13)]
    check(SeriesDocumentInference.seriesNumberInDocument(header) == 4, "« … — Série 4 » en en-tête : série 4")
    check(SeriesDocumentInference.seriesNumberInDocument([line("Exercise Set 5", 14)]) == 5, "« Exercise Set 5 » : série 5")
    check(SeriesDocumentInference.seriesNumberInDocument([line("Problem Sheet 02", 14)]) == 2, "« Problem Sheet 02 » : série 2")
    check(SeriesDocumentInference.seriesNumberInDocument([line("Série de Taylor", 11)]) == nil, "« série de Taylor » n'est pas un numéro")
    check(SeriesDocumentInference.seriesNumber(inFilename: "serie03_sol.pdf") == 3, "nom de fichier « serie03_sol » : 3")
    check(SeriesDocumentInference.seriesNumber(inFilename: "Series_4.pdf") == 4, "nom de fichier « Series_4 » : 4")
    check(SeriesDocumentInference.seriesNumber(inFilename: "ex7.pdf") == 7, "nom de fichier « ex7 » : 7")
    check(SeriesDocumentInference.seriesNumber(inFilename: "cs250-notes.pdf") == nil, "un code de cours n'est pas un numéro de série")
    check(SeriesDocumentInference.seriesNumber(lines: header, filename: "serie09.pdf")?.number == 4,
          "le document l'emporte sur le nom du fichier")

    // Le cours désigné par le PDF.
    let cs = SeriesDocumentInference.CourseCandidate(id: UUID(), code: "CS-250", name: "Algorithms I")
    let math = SeriesDocumentInference.CourseCandidate(id: UUID(), code: "MATH-101", name: "Analyse I")
    check(SeriesDocumentInference.course(in: header, filename: nil, candidates: [cs, math]) == math.id,
          "« Analyse I » dans l'en-tête : MATH-101")
    check(SeriesDocumentInference.course(in: [], filename: "cs250_serie2.pdf", candidates: [cs, math]) == cs.id,
          "« cs250 » dans le nom de fichier : CS-250")
    check(SeriesDocumentInference.course(in: [line("Série 3", 14)], filename: "s3.pdf", candidates: [cs, math]) == nil,
          "aucun indice : on ne choisit pas à la place de l'étudiant·e")

    // Sans en-tête en tête de ligne, la série vient du document.
    let noHeader = [line("Exercice 1", 13), line("Soit f.", 11), line("Exercice 2", 13), line("Calculer.", 11)]
    check(SeriesLayoutParser.parse(noHeader, defaultSeries: 4).first?.exercises.map(\.number) == ["4.1", "4.2"],
          "série déduite du document : 4.1, 4.2")

    // Anglais et allemand.
    let english = [line("Exercise 1", 13), line("Prove it.", 11), line("Problem 2", 13), line("Compute.", 11)]
    check(SeriesLayoutParser.parse(english, defaultSeries: 2).first?.exercises.map(\.number) == ["2.1", "2.2"],
          "« Exercise 1 », « Problem 2 » reconnus")
    check(SeriesPDFParser.parse("Exercise 1\nExercise 2\n", defaultSeries: 3).first?.exercises.map(\.number) == ["3.1", "3.2"],
          "texte collé en anglais, série fournie")
    check(SeriesPDFParser.parse("Aufgabe 1\n").first?.exercises.count == 1, "« Aufgabe 1 » reconnu")

    // Faux positifs : une démonstration numérotée, une citation.
    let phantoms = [line("Série 3", 16), line("Exercice 1", 13),
                    line("1.5 Montrer que la suite converge vers zéro quand n tend vers l'infini.", 11),
                    line("Exercice 2 de la série précédente nous a appris que la limite existe.", 11),
                    line("Exercice 2", 13)]
    check(SeriesLayoutParser.parse(phantoms).first?.exercises.map(\.number) == ["3.1", "3.2"],
          "ni « 1.5 » de corps de texte ni une citation ne créent d'exercice — \(SeriesLayoutParser.parse(phantoms).first?.exercises.map(\.number) ?? [])")

    // Un « 1. » mis en forme de titre, dans un document sans mot-clé : un exercice.
    let numbered = [line("Série 6", 16), line("1. Suites", 12, bold: true, indent: 60),
                    line("Soit u.", 11), line("2. Séries", 12, bold: true, indent: 60)]
    check(SeriesLayoutParser.parse(numbered).first?.exercises.map(\.number) == ["6.1", "6.2"],
          "« 1. Suites » en gras : exercice 6.1")

    // Titre en ligne (LaTeX) : la ligne commence en gras.
    let runIn = [line("Série 2", 16),
                 line("Exercice 1. Soit f une fonction continue.", 11, startsBold: true),
                 line("Exercice 2. Calculer la limite.", 11, startsBold: true)]
    check(SeriesLayoutParser.parse(runIn).first?.exercises.count == 2, "titres « en ligne » reconnus")

    // Questions rattachées à l'exercice.
    let questions = [line("Série 1", 16), line("Exercice 1", 13), line("Soit f.", 11),
                     line("a) Montrer que f est continue.", 11, indent: 80),
                     line("b) En déduire la limite.", 11, indent: 80),
                     line("Exercice 2", 13), line("Question 1 : calculer.", 11), line("Question 2 : conclure.", 11)]
    let withQuestions = SeriesLayoutParser.parse(questions)
    check(withQuestions.first?.exercises.map(\.number) == ["1.1", "1.2"],
          "« Question 1 » n'est pas un exercice quand le document dit « Exercice » — \(withQuestions.first?.exercises.map(\.number) ?? [])")
    check(withQuestions.first?.exercises.first?.subQuestions.map(\.label) == ["a", "b"],
          "questions a) b) rattachées à l'exercice 1.1")
    let onlyQuestions = [line("Série 2", 16), line("Question 1", 13), line("Question 2", 13)]
    check(SeriesLayoutParser.parse(onlyQuestions).first?.exercises.count == 2,
          "sans autre mot-clé, « Question N » est un exercice")
    check(!SeriesLayoutParser.isQuestionSequence(["c", "d"]), "une liste qui ne commence pas par a/1/i n'est pas une liste de questions")

    // Fusion : une seule série, même quand les deux côtés ne s'accordent pas.
    let heuristicOne = [DetectedSeries(number: 1, title: "", exercises: [
        DetectedExercise(number: "1.1", title: "", isBonus: false),
        DetectedExercise(number: "1.2", title: "", isBonus: true),
        DetectedExercise(number: "1.5", title: "", isBonus: false, isConfident: false)
    ])]
    let aiFour = [DetectedSeries(number: 4, title: "Intégrales", exercises: [
        DetectedExercise(number: "4.1", title: "Changement de variable", isBonus: false),
        DetectedExercise(number: "4.2", title: "Intégrale impropre", isBonus: false),
        DetectedExercise(number: "4.3", title: "Fubini", isBonus: false)
    ])]
    let reconciled = SeriesAIParsing.merge(heuristic: heuristicOne, ai: aiFour, preferredSeries: 4)
    check(reconciled.count == 1 && reconciled.first?.number == 4, "une seule série, la 4 — \(reconciled.map(\.number))")
    check(reconciled.first?.exercises.map(\.number) == ["4.1", "4.2", "4.3"],
          "le « 1.5 » douteux est écarté, rien n'est dupliqué — \(reconciled.first?.exercises.map(\.number) ?? [])")
    check(reconciled.first?.exercises.first { $0.number == "4.2" }?.isBonus == true, "le bonus lu par les motifs est gardé")
    // Une note de page lue sous chaque titre : le modèle décide.
    let blanketHeuristic = [DetectedSeries(number: 6, title: "", exercises: (1...4).map {
        DetectedExercise(number: "6.\($0)", title: "", isBonus: true) })]
    let plainAI = [DetectedSeries(number: 6, title: "", exercises: (1...4).map {
        DetectedExercise(number: "6.\($0)", title: "T\($0)", isBonus: $0 == 4) })]
    check(SeriesAIParsing.merge(heuristic: blanketHeuristic, ai: plainAI).first?.exercises.map(\.isBonus) == [false, false, false, true],
          "un « facultatif » lu sous tous les titres ne fait pas toute la série bonus")
    let allBonusAI = [DetectedSeries(number: 6, title: "", exercises: (1...4).map {
        DetectedExercise(number: "6.\($0)", title: "T\($0)", isBonus: true) })]
    check(SeriesAIParsing.merge(heuristic: [], ai: allBonusAI).first?.exercises.contains(where: \.isBonus) == false,
          "une série entière en bonus est une lecture ratée : remise au programme")
    check(SeriesAIParsing.merge(heuristic: heuristicOne, ai: aiFour).first?.number == 4,
          "sans indice du document, le numéro du modèle l'emporte sur le défaut « 1 »")

    // Entrée de l'IA : mise en page conservée, tout le document dans le budget.
    var long: [PDFLayoutLine] = [line("Série 8", 16)]
    for number in 1...12 {
        long.append(line("Exercice \(number)", 13, page: number / 3))
        for _ in 0..<40 { long.append(line("Soit f une fonction continue sur un intervalle fermé borné, alors f atteint ses bornes.", 11, page: number / 3)) }
        long.append(line("a) Première question.", 11, page: number / 3, indent: 84))
    }
    let prepared = SeriesAIParsing.prepareLayout(long, seriesHint: 8)
    check(prepared.count <= SeriesAIParsing.layoutBudget, "entrée IA sous le budget (\(prepared.count) car.)")
    check(prepared.contains("# Exercice 12"), "le dernier exercice survit, marqué comme titre")
    check(prepared.contains("  a) Première question."), "le retrait d'une question est conservé")
    check(prepared.contains("série 8"), "l'indice de série est transmis")
}

print("== Import PDF de bout en bout : vrais PDF, vraie extraction ==")
do {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("polymestre-fixtures-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    func run(_ pages: [[FixtureLine]], filename: String) -> (lines: [PDFLayoutLine], series: [DetectedSeries], hint: Int?) {
        let url = directory.appendingPathComponent(filename)
        PDFFixtures.write(pages, to: url)
        guard let document = PDFDocument(url: url) else { return ([], [], nil) }
        let lines = PDFLayoutExtractor.lines(from: document)
        let hint = SeriesDocumentInference.seriesNumber(lines: lines, filename: filename)?.number
        return (lines, SeriesLayoutParser.parse(lines, defaultSeries: hint), hint)
    }

    let analyse = run(PDFFixtures.analyse, filename: "polycopie.pdf")
    check(analyse.lines.contains { $0.fontSize > 11.5 && $0.isBold }, "PDFKit rend taille et gras des titres")
    check(analyse.lines.contains { $0.startsBold && !$0.isBold }, "un titre en ligne est vu comme commençant en gras")
    let bodyIndent = analyse.lines.first { $0.trimmed.hasPrefix("Calculer") }?.indent ?? 0
    let questionIndent = analyse.lines.first { $0.trimmed.hasPrefix("a)") }?.indent ?? 0
    check(questionIndent > bodyIndent + 10, "le retrait des questions est mesuré (\(Int(bodyIndent)) → \(Int(questionIndent)))")
    check(analyse.hint == 4, "série 4 lue dans l'en-tête courant — \(analyse.hint.map(String.init) ?? "rien")")
    let four = analyse.series.first
    check(analyse.series.count == 1 && four?.number == 4, "une seule série, la 4 — \(analyse.series.map(\.number))")
    check(four?.exercises.map(\.number) == ["4.1", "4.2", "4.3", "4.4"],
          "quatre exercices, ni fantôme ni citation — \(four?.exercises.map(\.number) ?? [])")
    check(four?.exercises.first?.title == "Changement de variable", "intitulé entre parenthèses — « \(four?.exercises.first?.title ?? "") »")
    check(four?.exercises.first?.subQuestions.map(\.label) == ["a", "b"], "questions a) b) de l'exercice 4.1")
    check(four?.exercises.first { $0.number == "4.2" }?.isBonus == true, "4.2 facultatif")
    check(four?.exercises.first { $0.number == "4.3" }?.title == "Intégrale impropre",
          "titre sur la ligne suivante en page 2 — « \(four?.exercises.first { $0.number == "4.3" }?.title ?? "") »")
    let prepared = SeriesAIParsing.prepareLayout(analyse.lines, seriesHint: analyse.hint)
    check(prepared.contains("# Exercice 1") && prepared.contains("--- page 2 ---"),
          "entrée IA : titres marqués et pages séparées")

    let english = run(PDFFixtures.english, filename: "exercises.pdf")
    let seven = english.series.first
    check(english.hint == 7 && seven?.number == 7, "« Exercise Set 7 » : série 7")
    check(seven?.exercises.map(\.number) == ["7.1", "7.2", "7.3"], "trois « Problem » — \(seven?.exercises.map(\.number) ?? [])")
    check(seven?.exercises.first?.subQuestions.map(\.label) == ["a", "b"], "questions (a) (b)")
    check(seven?.exercises.first { $0.number == "7.2" }?.isBonus == true, "« optional » vaut bonus")

    let numbered = run(PDFFixtures.numbered, filename: "MATH-111_s.pdf")
    let two = numbered.series.first
    check(two?.exercises.map(\.number) == ["2.1", "2.2", "2.3"], "titres numérotés en gras — \(two?.exercises.map(\.number) ?? [])")
    check(two?.exercises.first?.title == "Espaces vectoriels", "intitulé d'un titre numéroté")

    check(SeriesDocumentInference.seriesTitle("Analyse I", courseName: "Analyse I", courseCode: "MATH-101") == "",
          "un titre de série égal au nom du cours est effacé")
    check(SeriesDocumentInference.seriesTitle("Intégrales", courseName: "Analyse I", courseCode: "MATH-101") == "Intégrales",
          "un vrai titre de série est gardé")
    check(!SeriesPDFParser.looksLikeTitle("Soit f une fonction continue sur R"), "« Soit f… » est un énoncé, pas un titre")
    check(!SeriesPDFParser.looksLikeTitle("Let f be continuous"), "« Let f… » non plus")
    check(SeriesPDFParser.looksLikeTitle("Calcul d'intégrales"), "un titre nominal reste un titre")
    check(SeriesAIParsing.parse(#"{"series":[{"number":4,"exercises":[{"number":"4.2","questions":["1.5"]}]}]}"#)
            .first?.exercises.first?.subQuestions.isEmpty == true, "une seule « question » n'en fait pas une liste")

    // Deux niveaux de questions et une liste en deux colonnes (Analyse I, série 03).
    let nested = run(PDFFixtures.nested, filename: "Analyse I Serie 03.pdf")
    let three = nested.series.first
    check(nested.series.count == 1 && three?.number == 3 && three?.title == "Suites",
          "série 3 « Suites » — \(nested.series.map { "\($0.number) \($0.title)" })")
    check(three?.exercises.map(\.number) == ["3.1", "3.2", "3.3", "3.11", "3.12"],
          "cinq exercices « Ex-03-xx » — \(three?.exercises.map(\.number) ?? [])")
    func outline(_ number: String) -> String {
        DetectedSubQuestion.outline(three?.exercises.first { $0.number == number }?.subQuestions ?? [])
    }
    check(outline("3.1") == "1(a,b,c),2(a,b,c,d,e)",
          "deux niveaux : 1(a–c) et 2(a–e), plus seulement 1 et 2 — \(outline("3.1"))")
    check(three?.exercises.first?.leafQuestionCount == 8, "huit cases réelles pour 3.1")
    check(outline("3.3") == "1,2,3,4,part",
          "liste en deux colonnes remise dans l'ordre, puis « Ensuite » — \(outline("3.3"))")
    check(outline("3.11") == "part,1,2,3",
          "la consigne avant « Ensuite » est une partie à cocher — \(outline("3.11"))")
    check(three?.exercises.first { $0.number == "3.11" }?.subQuestions.first?.text.hasPrefix("Calculer la limite") == true,
          "…avec son texte — « \(three?.exercises.first { $0.number == "3.11" }?.subQuestions.first?.text ?? "") »")
    check(outline("3.12") == "", "une liste de conditions n'est pas une liste de questions — \(outline("3.12"))")
    check(three?.exercises.first?.subQuestions.first?.text.hasPrefix("Soit (xn)") == true,
          "le texte d'une question est lu — « \(three?.exercises.first?.subQuestions.first?.text ?? "") »")
    let nestedInput = SeriesAIParsing.prepareLayout(nested.lines, seriesHint: nested.hint)
    check(!nestedInput.contains("Compilation"), "le pied de page répété n'est pas envoyé au modèle")

    // Les étiquettes, hors PDF.
    func marks(_ items: [(String, Double)]) -> [SeriesLayoutParser.QuestionMark] {
        items.map { SeriesLayoutParser.QuestionMark(label: $0.0, indent: $0.1) }
    }
    check(SeriesLayoutParser.topLevelQuestions(marks([("1", 84), ("a", 105), ("b", 105), ("2", 84), ("a", 105), ("b", 105), ("c", 106)])) == ["1", "2"],
          "premier niveau : 1, 2")
    check(DetectedSubQuestion.outline(SeriesLayoutParser.questionTree(marks([("1", 84), ("a", 105), ("b", 105), ("2", 84), ("a", 105), ("b", 105), ("c", 106)])))
            == "1(a,b),2(a,b,c)", "second niveau rattaché à sa question")
    check(SeriesLayoutParser.questionMark("1) an = 1 2) an = n 3) an = 2", allowNumbers: true, indent: 84)?.map(\.label) == ["1", "2", "3"],
          "trois questions sur une même ligne")
    check(SeriesLayoutParser.questionMark("1) Si (an) est croissante", allowNumbers: true, indent: 84)?.map(\.label) == ["1"],
          "« (an) » dans le texte n'est pas une question")
    check(SeriesLayoutParser.introListsConditions("Montrer qu'il existe une suite qui satisfait simultanément aux deux conditions suivantes :"),
          "liste de conditions reconnue")
    check(!SeriesLayoutParser.introListsConditions("Calculer les limites suivantes :"), "« limites suivantes » reste une liste de questions")
    check(SeriesLayoutParser.topLevelQuestions(marks([("1", 84), ("3", 315), ("2", 84), ("4", 315)])) == ["1", "2", "3", "4"],
          "deux colonnes triées")
    check(SeriesLayoutParser.topLevelQuestions(marks([("a", 0), ("b", 0), ("i", 0), ("j", 0)])) == ["a", "b", "i", "j"],
          "« i » dans une liste de lettres reste une lettre")
    check(SeriesLayoutParser.topLevelQuestions(marks([("i", 0), ("ii", 0), ("iii", 0), ("iv", 0)])) == ["i", "ii", "iii", "iv"],
          "chiffres romains dans l'ordre")

    // Le modèle renvoie le numéro comme titre quand le PDF n'en donne pas.
    check(!SeriesPDFParser.looksLikeTitle("Ex-03-01"), "« Ex-03-01 » n'est pas un titre")
    check(!SeriesPDFParser.looksLikeTitle("Exercice 3"), "« Exercice 3 » n'est pas un titre")
    check(SeriesPDFParser.looksLikeTitle("Exercice de synthèse"), "« Exercice de synthèse » en est un")

    // La lecture du texte l'emporte sur le modèle pour les questions.
    let local = [DetectedSeries(number: 3, title: "", exercises: [
        DetectedExercise(number: "3.10", title: "", isBonus: false,
                         subQuestions: [DetectedSubQuestion(label: "1", text: ""), DetectedSubQuestion(label: "2", text: "")])])]
    let model = [DetectedSeries(number: 3, title: "Suites", exercises: [
        DetectedExercise(number: "3.10", title: "", isBonus: false,
                         subQuestions: ["1", "2", "3"].map { DetectedSubQuestion(label: $0, text: "") })])]
    check(SeriesAIParsing.merge(heuristic: local, ai: model, aiReadsLayout: true).first?.exercises.first?.subQuestions.count == 3,
          "un modèle qui voit les pages l'emporte sur la lecture du texte")
    let localWithPart = [DetectedSeries(number: 3, title: "", exercises: [DetectedExercise(
        number: "3.11", title: "", isBonus: false,
        subQuestions: [DetectedSubQuestion(label: "", text: "Calculer lim an", kind: .part),
                       DetectedSubQuestion(label: "1"), DetectedSubQuestion(label: "2")])])]
    let seenNoPart = [DetectedSeries(number: 3, title: "", exercises: [DetectedExercise(
        number: "3.11", title: "", isBonus: false,
        subQuestions: ["1", "2", "3"].map { DetectedSubQuestion(label: $0, text: "lu") })])]
    let withPart = SeriesAIParsing.merge(heuristic: localWithPart, ai: seenNoPart, aiReadsLayout: true)
        .first?.exercises.first?.subQuestions ?? []
    check(DetectedSubQuestion.outline(withPart) == "part,1,2,3",
          "la partie sans numéro trouvée localement est remise devant les questions lues — \(DetectedSubQuestion.outline(withPart))")

    // L'identifiant se lit dans le jeton : une session sans `user_id` enregistré
    // n'est pas « non configurée ».
    let jwt = "eyJhbGciOiJIUzI1NiJ9." + Data(#"{"sub":"1b2c-uuid","role":"authenticated"}"#.utf8)
        .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".sig"
    check(StoredSession.subject(ofJWT: jwt) == "1b2c-uuid", "identifiant lu dans le jeton")
    check(StoredSession.subject(ofJWT: "pas-un-jeton") == nil, "un jeton illisible ne donne rien")
    check(SeriesAIParsing.merge(heuristic: local, ai: model).first?.exercises.first?.subQuestions.count == 2,
          "questions lues dans le PDF préférées à celles du modèle")

    // PHYS-101(en) : titres « 1. Rotating space station » dont PDFKit ne voit pas
    // le gras (tout sort en corps 10), questions « 1. » décalées de 12 pt.
    let phys: [[FixtureLine]] = [[
        FixtureLine(text: "Problem Set 4", size: 20),
        FixtureLine(text: "1. Rotating space station"),
        FixtureLine(text: "In order to create an Earth-like environment for its inhabitants, a station is rotated."),
        FixtureLine(text: "1. Find the angular speed required for the centripetal acceleration to equal g.", indent: 12),
        FixtureLine(text: "2. Express the period of rotation T in terms of R and g.", indent: 12),
        FixtureLine(text: "2. Circular motion of Earth"),
        FixtureLine(text: "Earth is spinning about its axis with a period of 23 hours 56 min."),
        FixtureLine(text: "1. Find the velocity of a person at EPFL.", indent: 12),
        FixtureLine(text: "2. Find the person's centripetal acceleration.", indent: 12),
        FixtureLine(text: "3. Find the error: Sliding block"),
        FixtureLine(text: "This looks like the solution to the problem, but it contains one or more errors."),
    ]]
    let physics = run(phys, filename: "PS4.pdf")
    let physSeries = physics.series.first
    check(physSeries?.exercises.map(\.number) == ["4.1", "4.2", "4.3"],
          "titres numérotés sur la marge, sans gras visible — \(physSeries?.exercises.map(\.number) ?? [])")
    check(physSeries?.exercises.allSatisfy(\.isConfident) == true, "une suite 1, 2, 3 sur la marge est un repère sûr")
    check(physSeries?.exercises.first?.subQuestions.map(\.label) == ["1", "2"],
          "les « 1. » décalés sont des questions — \(physSeries?.exercises.first?.subQuestions.map(\.label) ?? [])")
    check(physSeries?.exercises.first?.title == "Rotating space station", "intitulé anglais lu tel quel")
    check(SeriesDocumentInference.languageName(of: physics.lines.map(\.text).joined(separator: "\n")) == "anglais",
          "langue du document : anglais")
    check(SeriesAIParsing.prepareLayout(physics.lines, seriesHint: 4, language: "anglais").contains("ne traduis rien"),
          "la langue est dite au modèle")

    // Un modèle qui traduit ou décale ses exercices est corrigé par le PDF.
    let shifted = [DetectedSeries(number: 4, title: "", exercises: [
        DetectedExercise(number: "4.1", title: "Station spatiale en rotation", isBonus: false),
        DetectedExercise(number: "4.2", title: "Mouvement circulaire", isBonus: false),
        DetectedExercise(number: "4.3", title: "Trouver l'erreur", isBonus: false),
        DetectedExercise(number: "4.4", title: "Question promue", isBonus: false)])]
    let fixed = SeriesAIParsing.merge(heuristic: physics.series, ai: shifted, preferredSeries: 4).first?.exercises ?? []
    check(fixed.map(\.number) == ["4.1", "4.2", "4.3"],
          "un exercice inventé hors d'une numérotation complète est écarté — \(fixed.map(\.number))")
    check(fixed.first?.title == "Rotating space station", "l'intitulé imprimé l'emporte sur la traduction du modèle")

    // Un modèle de vision qui saute une colonne ne fait pas perdre de questions.
    let sixLocal = [DetectedSeries(number: 4, title: "", exercises: [DetectedExercise(
        number: "4.8", title: "", isBonus: false,
        subQuestions: (1...6).map { DetectedSubQuestion(label: String($0), text: "texte") })])]
    let threeSeen = [DetectedSeries(number: 4, title: "", exercises: [DetectedExercise(
        number: "4.8", title: "", isBonus: false,
        subQuestions: (1...3).map { DetectedSubQuestion(label: String($0), text: "b_n = \\log n") })])]
    let recovered = SeriesAIParsing.merge(heuristic: sixLocal, ai: threeSeen, aiReadsLayout: true)
        .first?.exercises.first?.subQuestions ?? []
    check(recovered.map(\.label) == ["1", "2", "3", "4", "5", "6"],
          "questions oubliées par la vision rendues — \(recovered.map(\.label))")
    check(recovered.first?.text == "b_n = \\log n", "le texte lu par le modèle est gardé")

    // Numéros du modèle : les tirets séparent, ils ne collent pas.
    check(SeriesAIParsing.normalizeNumber("4-3", series: 4) == "4.3", "« 4-3 » → 4.3 (et non 4.43)")
    check(SeriesAIParsing.normalizeNumber("Ex-04-07", series: 4) == "4.7", "« Ex-04-07 » → 4.7")
    check(SeriesAIParsing.normalizeNumber("7", series: 4) == "4.7", "« 7 » → 4.7")
    check(SeriesAIParsing.normalizeNumber("4.10", series: 4) == "4.10", "« 4.10 » reste")

    // Intitulés du modèle : un verbe est permis, un énoncé non.
    check(SeriesPDFParser.looksLikeGeneratedTitle("Calculer les sommes"), "« Calculer les sommes » est un titre de modèle")
    check(SeriesPDFParser.looksLikeGeneratedTitle("Find the error: Sliding block"), "titre imprimé commençant par un verbe gardé")
    check(!SeriesPDFParser.looksLikeGeneratedTitle("Soit f une fonction continue"), "« Soit f… » reste un énoncé")
    check(!SeriesPDFParser.looksLikeGeneratedTitle("Montrer que la suite est bornée."), "une phrase ponctuée reste un énoncé")
    check(!SeriesPDFParser.looksLikeGeneratedTitle("Ex-04-03"), "le numéro seul n'est pas un titre")

    // Le même document lu une seconde fois donne le même résultat : l'import
    // n'a plus rien d'aléatoire côté motifs.
    check(run(PDFFixtures.analyse, filename: "polycopie.pdf").series == analyse.series, "lecture déterministe")
}


print("== Import de contenu (Moodle, Courseware, Botafogo) ==")
do {
    let cal = Calendar(identifier: .gregorian)
    let termStart = cal.date(from: DateComponents(year: 2026, month: 9, day: 7))!

    // Semaines lues dans les titres de section.
    check(ContentDraftBuilder.week(fromTitle: "Semaine 3", termStart: nil) == 3, "« Semaine 3 » → S3")
    check(ContentDraftBuilder.week(fromTitle: "Week 12 - Revision", termStart: nil) == 12, "« Week 12 » → S12")
    check(ContentDraftBuilder.week(fromTitle: "S4 : intégrales", termStart: nil) == 4, "« S4 : … » → S4")
    check(ContentDraftBuilder.week(fromTitle: "21 septembre - 27 septembre", termStart: termStart, calendar: cal) == 3,
          "section Moodle datée « 21 septembre - 27 septembre » → S3")
    check(ContentDraftBuilder.week(fromTitle: "5 October - 11 October", termStart: termStart, calendar: cal) == 5,
          "section datée en anglais → S5")
    check(ContentDraftBuilder.week(fromTitle: "Généralités", termStart: termStart, calendar: cal) == nil,
          "une section sans semaine n'en invente pas")
    check(ContentDraftBuilder.week(fromTitle: "Séries numériques", termStart: nil) == nil,
          "« Séries » n'est pas « S… » + numéro")

    // Numéros.
    check(ContentDraftBuilder.seriesNumber(in: "Série 3 - énoncé") == 3, "« Série 3 - énoncé » → 3")
    check(ContentDraftBuilder.seriesNumber(in: "Serie_07.pdf") == 7, "« Serie_07 » → 7")
    check(ContentDraftBuilder.seriesNumber(in: "Exercise set 4") == 4, "« Exercise set 4 » → 4")
    check(ContentDraftBuilder.leadingNumber(in: "3.2 Limite: a_n\\to L")?.number == "3.2", "« 3.2 Limite » → 3.2")
    check(ContentDraftBuilder.leadingNumber(in: "II.4 Trigonométrie")?.number == "II.4", "« II.4 » gardé tel quel")
    check(ContentDraftBuilder.leadingNumber(in: "Chapitre 5 : Séries")?.number == "5", "« Chapitre 5 : … » → 5")
    check(ContentDraftBuilder.leadingNumber(in: "2025 Examen blanc") == nil, "une année n'est pas un chapitre")
    check(ContentDraftBuilder.cleanTitle("Nombres: \\(\\mathbb{R}\\)") == "Nombres: \\mathbb{R}",
          "délimiteurs LaTeX retirés, la formule reste pour MathText")

    // Classement.
    func kind(_ title: String, _ type: String = "resource", _ source: ContentSource = .moodle) -> ContentItemKind {
        ContentDraftBuilder.classify(ScrapedItem(title: title, type: type), title: title, source: source)
    }
    check(kind("Série 3") == .series, "« Série 3 » est une série")
    check(kind("Corrigé série 3") == .ignore, "un corrigé n'est pas une série de plus")
    check(kind("Annonces", "forum") == .ignore, "le forum d'annonces s'ignore")
    check(kind("Slides chapitre 2") == .theory, "des diapos sont de la théorie")
    check(kind("Vidéo 2.1 : dérivées", "kalvidres") == .theory, "une vidéo est de la théorie")
    check(kind("Séries numériques", "resource") == .theory, "« Séries numériques » (matière) n'est pas une série d'exercices")
    check(kind("Quiz 1", "quiz") == .ignore, "un quiz s'ignore par défaut")
    check(kind("5.3 Séries et critères", "section", .botafogo) == .theory, "Botafogo n'a que de la théorie")

    // Une page Moodle au format hebdomadaire.
    let moodle = ScrapedCourse(source: "moodle", title: "Analyse I (MATH-101)", url: "https://moodle.epfl.ch/course/view.php?id=1", sections: [
        ScrapedSection(title: "Généralités", items: [ScrapedItem(title: "Annonces", type: "forum")]),
        ScrapedSection(title: "7 septembre - 13 septembre", items: [
            ScrapedItem(title: "Vidéo 1.1 Introduction", url: "https://mediaspace.epfl.ch/1", type: "kalvidres"),
            ScrapedItem(title: "Polycopié chapitre 1 Fichier", url: "https://moodle.epfl.ch/f/1", type: "resource"),
            ScrapedItem(title: "Série 1", url: "https://moodle.epfl.ch/s/1", type: "resource"),
            ScrapedItem(title: "Série 1 (version imprimable)", url: "https://moodle.epfl.ch/s/1b", type: "resource"),
            ScrapedItem(title: "Corrigé 1", url: "https://moodle.epfl.ch/c/1", type: "resource")
        ]),
        ScrapedSection(title: "14 septembre - 20 septembre", items: [
            ScrapedItem(title: "Série 2", url: "https://moodle.epfl.ch/s/2", type: "resource")
        ])
    ])
    let draft = ContentDraftBuilder.draft(from: moodle, source: .moodle, termStart: termStart, calendar: cal)
    check(draft.sections.count == 3, "trois sections lues (\(draft.sections.count))")
    check(draft.sections.first?.isIncluded == false, "« Généralités » (que du forum) est décochée")
    check(draft.sections[1].week == 1 && !draft.sections[1].weekIsInferred, "la 1ʳᵉ semaine datée tombe en S1, lue sur la page")
    check(draft.sections[2].week == 2, "la 2ᵉ en S2")
    check(draft.seriesCount == 2, "deux séries, la version imprimable fusionnée (\(draft.seriesCount))")
    check(draft.sections[1].items.first?.theoryKind == .video && draft.sections[1].items.first?.videoCount == 1,
          "la vidéo MediaSpace compte comme une vidéo de théorie")
    check(draft.sections[1].items.first?.number == "1.1", "le numéro de la vidéo est lu dans son titre")
    check(draft.sections[1].items.contains { $0.title == "Polycopié chapitre 1" }, "le suffixe « Fichier » de Moodle est retiré")

    // Écriture : ajoute, met à jour, ne supprime rien.
    let importCourse = Course(code: "MATH-101", name: "Analyse I")
    context.insert(importCourse)
    let first = ContentDraftWriter.apply(draft, to: importCourse, context: context)
    check(first.theoryAdded == 2 && first.seriesAdded == 2, "import : 2 théorie + 2 séries — \(first.message)")
    check(importCourse.series.first { $0.seriesNumber == 2 }?.plannedWeek == 2, "la série 2 est planifiée en S2")
    importCourse.theoryItems.first { $0.number == "1.1" }?.watchedAt = Date()
    var edited = draft
    edited.sections[2].week = 3
    let second = ContentDraftWriter.apply(edited, to: importCourse, context: context)
    check(second.theoryAdded == 0 && second.seriesAdded == 0, "réimport : rien en double")
    check(importCourse.theoryItems.first { $0.number == "1.1" }?.isWatched == true, "réimport : l'avancement est gardé")
    check(importCourse.series.first { $0.seriesNumber == 2 }?.plannedWeek == 3, "réimport : la semaine corrigée est appliquée")
    check(importCourse.contentSources == ["https://moodle.epfl.ch/course/view.php?id=1"], "la page source est retenue, une fois")

    // Sans semaine sur la page : une section par semaine, proposée.
    let flat = ScrapedCourse(source: "courseware", title: "MOOC", url: "", sections: [
        ScrapedSection(title: "Introduction", items: [ScrapedItem(title: "Bienvenue", type: "sequential")]),
        ScrapedSection(title: "Module A", items: [ScrapedItem(title: "Leçon", type: "sequential", videoCount: 3)])
    ])
    let flatDraft = ContentDraftBuilder.draft(from: flat, source: .courseware, termStart: nil)
    check(flatDraft.sections.map(\.week) == [1, 2] && flatDraft.sections.allSatisfy(\.weekIsInferred),
          "semaines proposées dans l'ordre et marquées comme supposées")
    check(flatDraft.videoCount == 3, "les vidéos d'une leçon de MOOC sont comptées (\(flatDraft.videoCount))")

    // Botafogo : table des matières et vidéos d'une section.
    let toc = """
    <title>Analyse 1 | S. Friedli (EPFL)</title>
    <li class="had-nav-toplevel">
    <a href="#this-is-preface" data-bs-toggle="collapse" aria-expanded="false" >I. Préface</a>
     <ul class="had-nav-secondlevel collapse" id="this-is-preface">
      <li class="had-nav-link-secondlevel" id="a"><a href="resources/sections/m_intro_objectifs.html">I.1 Un cours d'Analyse 1</a></li>
     </ul>
    <li class="had-nav-toplevel">
    <a href="#chap-nombres-reels" data-bs-toggle="collapse" aria-expanded="false" >1. Nombres: \\(\\mathbb{R}\\)</a>
     <ul class="had-nav-secondlevel collapse" id="chap-nombres-reels">
    <li class="had-pdf-link"><a href="resources/pdfschapitres/chap-nombres-reels.pdf" target="_blank" >PDF du Chapitre</a>
      <li class="had-nav-link-secondlevel" id="b"><a href="resources/sections/m_reels_intro.html">1.1 Introduction</a></li>
      <li class="had-nav-link-secondlevel" id="c"><a href="resources/sections/m_reels_R_est_un_corps.html">1.2 Règles de calcul: \\(+,-,\\cdot,\\div\\)</a></li>
     </ul>
    """
    let base = URL(string: "https://botafogo.epfl.ch/analyse-1/")!
    let tocPage = BotafogoParser.parseTOC(html: toc, baseURL: base)
    check(tocPage.title == "Analyse 1", "titre du polycopié — \(tocPage.title)")
    check(tocPage.sections.count == 2 && tocPage.sections[1].items.count == 2,
          "deux chapitres, le PDF du chapitre n'est pas un élément")
    check(tocPage.sections[1].items.first?.url == "https://botafogo.epfl.ch/analyse-1/resources/sections/m_reels_intro.html",
          "adresse de section résolue")
    let botaDraft = ContentDraftBuilder.draft(from: tocPage, source: .botafogo, termStart: nil)
    check(botaDraft.sections.first?.isIncluded == false, "la préface (I.) est décochée")
    check(botaDraft.sections[1].week == 1, "le chapitre 1 est proposé en S1")
    check(botaDraft.sections[1].items.map(\.number) == ["1.1", "1.2"], "numéros du polycopié gardés")
    let sectionHTML = """
    <div class="video">
     <a class="video-button" data-bs-toggle="collapse" href="#IDVID-x" role="button">Suites qui tendent vers zéro</a>
     <div class="collapse" id="IDVID-x"><video class="video-plyr" playsinline controls></video></div>
    </div>
    <div class="anim-video"><video class="anim-video-plyr" preload="none" playsinline></video></div>
    """
    check(BotafogoParser.videoTitles(inSection: sectionHTML) == ["Suites qui tendent vers zéro"],
          "une vidéo de cours comptée, l'animation ignorée")
    let home = """
    <li><span class="link-description">Mon cours d'analyse:</span>
    <a href="/analyse-1/" class="button-link">Version EN LIGNE</a></li>
    """
    let catalog = BotafogoParser.catalog(html: home, baseURL: URL(string: "https://botafogo.epfl.ch/")!)
    check(catalog.first?.title == "Mon cours d'analyse" && catalog.first?.url.absoluteString == "https://botafogo.epfl.ch/analyse-1/",
          "catalogue de Botafogo lu")

    // Catégories : trois, plus Anki importé.
    check(TaskType.choices == [.theory, .exercise, .correction, .other], "trois catégories choisissables, plus « Autre »")
    check(TaskType.video.canonical == .theory && TaskType.summary.canonical == .theory,
          "une vidéo et un résumé comptent comme de la théorie")
    check(TaskType.flashcards.label == "Anki", "le temps Anki porte son étiquette")
}


print("== Temps Anki relevé automatiquement ==")
do {
    let parsed = [AnkiReview(id: 1727510000000, durationMs: 20000, deck: "EPFL::MATH-101 Analyse I"),
                  AnkiReview(id: 1727510060000, durationMs: 45000, deck: "EPFL::MATH-101 Analyse I"),
                  AnkiReview(id: 1727513000000, durationMs: 70000, deck: "EPFL::MATH-101 Analyse I")]
    let drafts = AnkiReviewImport.sessions(from: parsed)
    check(drafts.count == 2, "deux sessions : 49 min d'écart coupent la série (\(drafts.count))")
    check(drafts.first?.seconds == 65 && drafts.first?.reviewCount == 2,
          "le temps est la somme des réponses, pas l'écart entre cartes")
    check(drafts.last?.seconds == 70, "une session d'une carte longue reste comptée")
    let short = AnkiReviewImport.sessions(from: [AnkiReview(id: 1, durationMs: 8000, deck: "X")])
    check(short.isEmpty, "une carte de 8 s n'est pas une session")
    let dup = parsed + parsed.map { AnkiReview(id: $0.id, durationMs: $0.durationMs, deck: "EPFL") }
    check(AnkiReviewImport.sessions(from: dup).allSatisfy { $0.deck == "EPFL::MATH-101 Analyse I" },
          "une révision vue dans le paquet parent n'est comptée qu'une fois, au sous-paquet")
    let keys = [(code: "MATH-101", shortName: "Ana I", name: "Analyse I"),
                (code: "CS-250", shortName: "", name: "Algorithms I")]
    check(AnkiReviewImport.courseIndex(forDeck: "EPFL::MATH-101 Analyse I", courses: keys) == 0, "paquet rattaché par code")
    check(AnkiReviewImport.courseIndex(forDeck: "Algorithms I", courses: keys) == 1, "paquet rattaché par nom")
    check(AnkiReviewImport.courseIndex(forDeck: "Japonais", courses: keys) == nil, "paquet sans cours : pas d'attribution au hasard")
}

print("== Horaire : amphi ou exercices ==")
do {
    check(TimetableClassifier.roomCount("CE1101, CE1105, CO010") == 3, "trois salles comptées")
    check(TimetableClassifier.roomCount("RLC E1 240") == 1, "une salle avec espaces reste une salle")
    check(TimetableClassifier.roomCount("") == 0, "lieu vide : aucune salle")
    // Le calendrier de l'iPhone ne transmet pas CATEGORIES : seuls l'intitulé et les salles restent.
    check(TimetableClassifier.kind(title: "Physique générale : mécanique (anglais)",
                                   location: "CE1101, CE1105, CO010, CO011", hasCourse: true) == .exerciseSession,
          "plusieurs salles : séance d'exercices, même sans mot-clé")
    check(TimetableClassifier.kind(title: "Analyse I (classe inversée)", location: "CE16", hasCourse: true) == .lecture,
          "une seule salle, rattachée à un cours : cours")
    check(TimetableClassifier.kind(title: "Dîner", location: "", hasCourse: false) == .other,
          "sans cours ni mot-clé : agenda personnel")
    check(TimetableClassifier.kind(title: "Midterm Analyse", location: "CE1, CE2", hasCourse: true) == .midterm,
          "un midterm dans plusieurs salles reste un midterm")
    check(TimetableClassifier.kind(categories: "Horaires enseignés FBM,Exercices,", title: "Analyse I (classe inversée)",
                                   location: "CE1106, CE1515", hasCourse: true) == .exerciseSession,
          "CATEGORIES « Exercices » → exercices")
    check(TimetableClassifier.kind(categories: "Horaires enseignés FBM,Cours,", title: "Analyse I (classe inversée)",
                                   location: "CE16", hasCourse: true) == .lecture,
          "CATEGORIES « Cours » → amphi")

    var zurich = Calendar(identifier: .gregorian)
    zurich.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let monday = zurich.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 8, minute: 15))!
    let nextMonday = zurich.date(byAdding: .day, value: 7, to: monday)!
    let wednesday = zurich.date(byAdding: .day, value: 2, to: monday)!
    let a = TimetableClassifier.slot(owner: "X", start: monday, calendar: zurich)
    check(a == TimetableClassifier.slot(owner: "X", start: nextMonday, calendar: zurich), "même créneau d'une semaine à l'autre")
    check(a != TimetableClassifier.slot(owner: "X", start: wednesday, calendar: zurich), "un autre jour, un autre créneau")
    let b = TimetableClassifier.slot(owner: "X", start: wednesday, calendar: zurich)
    let learned = TimetableClassifier.learnedKinds([
        .init(slot: a, kind: .lecture, isManual: false),
        .init(slot: a, kind: .lecture, isManual: false),
        .init(slot: a, kind: .exerciseSession, isManual: true),
        .init(slot: b, kind: .lecture, isManual: false),
        .init(slot: b, kind: .exerciseSession, isManual: false),
    ])
    check(learned[a] == .exerciseSession, "un choix manuel l'emporte sur l'horaire")
    check(learned[b] == nil, "sources à égalité : créneau non tranché")

    let course = UUID()
    check(TimetableClassifier.isSameSession(courseA: course, startA: monday, courseB: course, startB: monday.addingTimeInterval(30)),
          "même cours, même minute : la même séance lue deux fois")
    check(!TimetableClassifier.isSameSession(courseA: course, startA: monday, courseB: UUID(), startB: monday),
          "deux cours au même moment ne sont pas un doublon")

    let hours = TimetableClassifier.weeklyHours([
        (start: monday, seconds: 225 * 60, kind: .lecture),
        (start: wednesday, seconds: 105 * 60, kind: .exerciseSession),
        (start: nextMonday, seconds: 225 * 60, kind: .lecture),
        (start: nextMonday.addingTimeInterval(2 * 86_400), seconds: 105 * 60, kind: .exerciseSession),
    ], calendar: zurich)
    check(hours.lecture == 3.75 && hours.exercise == 1.75,
          "semaine type d'Analyse : 3 h 45 d'amphi, 1 h 45 d'exercices (\(hours.lecture), \(hours.exercise))")

    // L'horaire EPFL réel : plusieurs lignes CATEGORIES, DURATION, salles multiples.
    let epfl = """
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:horaire_1@is-academia
    SUMMARY:Analyse II test (classe inversée)
    DTSTART;TZID=Europe/Berlin:20260928T081500
    DURATION:PT225M
    CATEGORIES:Horaires enseignés FBM
    LOCATION:CE16
    CATEGORIES:Cours
    CATEGORIES:
    END:VEVENT
    BEGIN:VEVENT
    UID:horaire_2@is-academia
    SUMMARY:Analyse II test (classe inversée)
    DTSTART;TZID=Europe/Berlin:20260930T101500
    DURATION:PT105M
    CATEGORIES:Horaires enseignés FBM
    LOCATION:CE1106, CE1515
    CATEGORIES:Exercices
    CATEGORIES:
    END:VEVENT
    END:VCALENDAR
    """
    // Le même cours, déjà lu dans le calendrier de l'iPhone (sans CATEGORIES) : un doublon à retirer.
    let parsedEPFL = ICSParser.parse(epfl, horizon: zurich.date(byAdding: .year, value: 2, to: monday)!)
    check(parsedEPFL.count == 2, "deux séances lues (\(parsedEPFL.count))")
    let epflResult = TimetableImport.import(epfl, into: context)
    let importedAnalyse = ((try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? [])
        .first { $0.title == "Analyse II test (classe inversée)" }?.course
    let ghost = LinkedCalendarEvent(externalEventID: "ek-1", sourceCalendarID: "Horaire EPFL",
                                    title: "Analyse II test (classe inversée)",
                                    startsAt: parsedEPFL[1].start, endsAt: parsedEPFL[1].end,
                                    location: "CE1106, CE1515", kind: .lecture)
    ghost.course = importedAnalyse
    ghost.isSkipped = true
    context.insert(ghost)
    let stray = LinkedCalendarEvent(externalEventID: "ek-2", sourceCalendarID: "Horaire EPFL",
                                    title: "Analyse II test (classe inversée)",
                                    startsAt: parsedEPFL[1].start.addingTimeInterval(86_400), endsAt: parsedEPFL[1].end.addingTimeInterval(86_400),
                                    location: "CE1, CE2", kind: .lecture)
    stray.course = importedAnalyse
    context.insert(stray)
    check(CalendarSync.repair(context: context) == 2, "réparation : un doublon retiré, une séance reclassée")
    check(stray.kind == .exerciseSession, "plusieurs salles : la séance du calendrier passe en exercices")
    context.delete(stray)
    let epflEvents = ((try? context.fetch(FetchDescriptor<LinkedCalendarEvent>())) ?? [])
        .filter { $0.title == "Analyse II test (classe inversée)" }
    check(epflResult.eventsCreated == 2, "deux séances importées (\(epflResult.eventsCreated))")
    check(epflEvents.count == 2, "le doublon du calendrier de l'iPhone est retiré (\(epflEvents.count) séances)")
    check(epflEvents.filter(\.isLecture).count == 1, "une seule séance comptée en amphi")
    check(epflEvents.contains { !$0.isLecture && $0.isSkipped }, "le doublon transmet ce qu'on y avait noté (manqué)")
    if let analyse = epflEvents.first?.course {
        check(analyse.weeklyLectureHours == 3.75 && analyse.weeklyExerciseHours == 1.75,
              "heures du cours lues dans l'horaire (\(analyse.weeklyLectureHours) + \(analyse.weeklyExerciseHours))")
        // « C'est une séance d'exercices » sur le lundi : tout le créneau suit, et le choix tient au réimport.
        if let lecture = epflEvents.first(where: \.isLecture) {
            check(CalendarSync.setKind(.exerciseSession, forSlotOf: lecture, context: context) == 1, "le créneau du lundi est reclassé")
            _ = TimetableImport.import(epfl, into: context)
            check(lecture.kind == .exerciseSession && lecture.kindIsManual, "un réimport ne défait pas un choix manuel")
        }
    }
}

print("== Moodle : du lien d'activité au PDF ==")
do {
    let page = URL(string: "https://moodle.epfl.ch/mod/page/view.php?id=77")!
    check(MoodleLinks.activityModule(of: page) == "page", "une page Moodle est reconnue")
    check(MoodleLinks.activityModule(of: URL(string: "https://moodle.epfl.ch/course/view.php?id=1")!) == nil,
          "la page d'un cours n'est pas une activité")
    check(SiteLinks.normalize(URL(string: "https://moodle.epfl.ch/mod/url/view.php?id=9")!).absoluteString
          == "https://moodle.epfl.ch/mod/url/view.php?id=9&redirect=1", "un lien Moodle s'ouvre sur sa cible")
    check(SiteLinks.normalize(page) == page, "une page Moodle n'a pas de redirection à demander")
    check(MoodleLinks.workaroundPage(URL(string: "https://moodle.epfl.ch/mod/resource/view.php?id=4&redirect=1")!).absoluteString
          == "https://moodle.epfl.ch/mod/resource/view.php?id=4&forceview=1", "la page « cliquez ici » d'un fichier")

    // Une série d'AICC publiée en page : énoncé et corrigé parmi d'autres liens.
    let aicc = """
    <div id="region-main"><h2>Série 3</h2>
    <p>Voir le <a href="https://moodle.epfl.ch/course/view.php?id=1">cours</a>.</p>
    <p><a href="https://moodle.epfl.ch/pluginfile.php/123/mod_page/content/4/serie3_sol.pdf">Corrigé</a></p>
    <p><a href="/pluginfile.php/123/mod_page/content/4/serie3.pdf?time=1&amp;forcedownload=1"><span>Énoncé</span> de la série</a></p>
    </div>
    """
    let found = MoodleLinks.statementLink(inHTML: aicc, baseURL: page)
    check(found.statement == "https://moodle.epfl.ch/pluginfile.php/123/mod_page/content/4/serie3.pdf?time=1&forcedownload=1",
          "l'énoncé est le PDF qui n'est pas le corrigé (\(found.statement ?? "nil"))")
    check(found.solution?.hasSuffix("serie3_sol.pdf") == true, "le corrigé est rangé à part")

    let workaround = """
    <div class="urlworkaround">Cliquez sur le lien
      <a href="https://ipg.epfl.ch/aicc/serie_04.pdf" onclick="this.target='_blank'">serie_04.pdf</a></div>
    """
    check(MoodleLinks.statementLink(inHTML: workaround, baseURL: page).statement == "https://ipg.epfl.ch/aicc/serie_04.pdf",
          "le lien « cliquez ici » d'une activité lien")
    check(MoodleLinks.statementLink(inHTML: "<p>Rien ici</p>", baseURL: page).statement == nil, "pas de document : rien d'inventé")

    // L'analyse du cours : une série publiée en page, sa cible lue, devient un PDF.
    var activity = MoodleActivity(id: "77", name: "Série 3", module: "page", url: page.absoluteString)
    activity.target = found.statement
    activity.solutionTarget = found.solution
    let snapshot = MoodleCourseSnapshot(title: "AICC", url: "https://moodle.epfl.ch/course/view.php?id=1",
                                        sections: [MoodleSection(number: 3, title: "Semaine 3", activities: [activity])])
    let aiccDraft = MoodleCourseAnalyzer.draft(from: snapshot, termStart: nil)
    let aiccSeries = aiccDraft.sections.flatMap(\.items).first { $0.kind == .series }
    check(aiccSeries?.pdfURL.hasSuffix("forcedownload=1") == true, "la série pointe sur le PDF, pas sur la page")
    check(aiccSeries?.solutionURL.hasSuffix("serie3_sol.pdf") == true, "et son corrigé vient de la même page")
}

print("== Chrono : le prochain exercice d'abord ==")
do {
    let course = Course(code: "TEST-777", name: "Chrono")
    context.insert(course)
    let old = ExerciseSeries(course: course, seriesNumber: 1, plannedWeek: 1)
    let current = ExerciseSeries(course: course, seriesNumber: 2, plannedWeek: 2)
    context.insert(old); context.insert(current)
    let o1 = Exercise(series: old, exerciseNumber: "1.1", sortOrder: 0)
    let o2 = Exercise(series: old, exerciseNumber: "1.2", sortOrder: 1)
    let c1 = Exercise(series: current, exerciseNumber: "2.1", sortOrder: 0)
    let c2 = Exercise(series: current, exerciseNumber: "2.2", sortOrder: 1)
    let cb = Exercise(series: current, exerciseNumber: "2.3", isBonus: true, sortOrder: 2)
    for exercise in [o1, o2, c1, c2, cb] { context.insert(exercise) }
    o1.setDone(true); o2.setDone(true); c1.setDone(true)
    let ordered = FocusTargets.exercises(of: [old, current], for: .exercise)
    check(ordered.upNext.map(\.exerciseNumber) == ["2.2", "2.3"],
          "à faire : 2.2 puis le bonus (\(ordered.upNext.map(\.exerciseNumber)))")
    check(ordered.done.map(\.exerciseNumber) == ["2.1", "1.1", "1.2"],
          "déjà faits ensuite, série en cours d'abord (\(ordered.done.map(\.exerciseNumber)))")
    o2.correct(.wrong)
    let correction = FocusTargets.exercises(of: [old, current], for: .correction)
    check(correction.upNext.first?.exerciseNumber != "1.2" && correction.upNext.last?.exerciseNumber == "1.2",
          "correction : corriger avant de refaire (\(correction.upNext.map(\.exerciseNumber)))")

    check(ExerciseRegions.shortNumber("4.3") == "3" && ExerciseRegions.shortNumber("Ex-02-03") == "3"
          && ExerciseRegions.shortNumber("3b") == "3b", "numéro court d'un exercice")
    let regions = ExerciseRegions.slices(for: [
        .init(number: "3.1", page: 0, top: 0.2),
        .init(number: "3.2", page: 0, top: 0.7),
        .init(number: "3.3", page: 1, top: 0.5),
    ], pageCount: 2)
    check(regions["1"]?.count == 1 && abs((regions["1"]?.first?.top ?? 0) - 0.18) < 1e-9
          && abs((regions["1"]?.first?.bottom ?? 0) - 0.689) < 1e-9, "l'exercice 1 va jusqu'au titre du 2")
    check(regions["2"]?.count == 2 && regions["2"]?.last?.page == 1 && abs((regions["2"]?.last?.bottom ?? 0) - 0.489) < 1e-9,
          "l'exercice 2 continue sur la page suivante")
    check(regions["3"]?.first?.bottom == 1 && abs((regions["3"]?.first?.top ?? 0) - 0.48) < 1e-9, "le dernier va jusqu'en bas")
    let paged = ExerciseRegions.slices(for: [.init(number: "1", page: 0, top: 0.15), .init(number: "2", page: 1, top: 0.11)], pageCount: 2)
    check(paged["1"]?.count == 1, "la suite d'un énoncé réduite à l'en-tête de page n'est pas montrée")
}

print("== Chrono : ce que l'horaire dit du moment ==")
do {
    let now = Date()
    let analyse = UUID(), physique = UUID()
    let slots = [
        FocusContext.Slot(courseID: analyse, courseCode: "MATH-101", kind: .exerciseSession,
                          start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(4500)),
        FocusContext.Slot(courseID: physique, courseCode: "PHYS-101", kind: .lecture,
                          start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-600)),
    ]
    let during = FocusContext.suggestion(now: now, slots: slots)
    check(during?.courseID == analyse && during?.taskType == .exercise, "pendant une séance d'exercices : ce cours, des séries")
    let after = FocusContext.suggestion(now: now, slots: [slots[1]])
    check(after?.courseID == physique && after?.taskType == .theory, "juste après un amphi : sa théorie")
    let soon = FocusContext.Slot(courseID: analyse, courseCode: "MATH-101", kind: .exerciseSession,
                                 start: now.addingTimeInterval(1200), end: now.addingTimeInterval(7500))
    check(FocusContext.suggestion(now: now, slots: [soon])?.taskType == .exercise, "une séance dans 20 min se prépare")
    let late = FocusContext.Slot(courseID: analyse, courseCode: "MATH-101", kind: .exerciseSession,
                                 start: now.addingTimeInterval(4 * 3600), end: now.addingTimeInterval(6 * 3600))
    check(FocusContext.suggestion(now: now, slots: [late]) == nil, "rien d'imminent : pas de proposition")
}

print("== Marquer une semaine faite ==")
do {
    let course = Course(code: "TEST-888", name: "Semaines")
    context.insert(course)
    let t1 = TheoryItem(course: course, sectionNumber: 1, number: "1.1", plannedWeek: 1)
    let t2 = TheoryItem(course: course, sectionNumber: 1, number: "1.2", plannedWeek: 1)
    let t3 = TheoryItem(course: course, sectionNumber: 2, number: "2.1", plannedWeek: 2)
    let s1 = ExerciseSeries(course: course, seriesNumber: 1, plannedWeek: 1)
    let s2 = ExerciseSeries(course: course, seriesNumber: 2, plannedWeek: 2)
    for item in [t1, t2, t3] { context.insert(item) }
    context.insert(s1); context.insert(s2)
    let e1 = Exercise(series: s1, exerciseNumber: "1.1", sortOrder: 0)
    let e2 = Exercise(series: s1, exerciseNumber: "1.2", sortOrder: 1)
    let eb = Exercise(series: s1, exerciseNumber: "1.3", isBonus: true, sortOrder: 2)
    let f1 = Exercise(series: s2, exerciseNumber: "2.1", sortOrder: 0)
    for exercise in [e1, e2, eb, f1] { context.insert(exercise) }
    let earlier = Date(timeIntervalSince1970: 1_000_000)
    t1.watchedAt = earlier
    e1.correct(.wrong)

    check(WeekCompletion.pending(in: 1...1, of: course) == (theory: 1, exercises: 1), "semaine 1 : 1 théorie et 1 exercice restants")
    let change = WeekCompletion.mark(1...1, of: course, scope: .all)
    check(t2.isWatched && e2.isDone && !eb.isDone, "tout est coché, sauf le bonus")
    check(t1.watchedAt == earlier, "ce qui était déjà vu garde sa date")
    check(!t3.isWatched && !f1.isDone, "la semaine 2 n'est pas touchée")
    check(change.theory == [t2.id] && change.exercises == [e2.id], "le changement ne retient que ce qui a été coché")
    check(e2.isDone && !e2.isCorrected, "« faits » : à corriger, pas corrigés")
    WeekCompletion.undo(change, in: course)
    check(!t2.isWatched && !e2.isDone && t1.isWatched && e1.redoRequired, "annuler rend exactement l'état d'avant")

    let corrected = WeekCompletion.mark(1...2, of: course, scope: .allCorrected)
    check(e2.correctness == .correct && f1.correctness == .correct, "« faits et corrigés » : vert")
    check(e1.redoRequired && e1.correctness == .wrong, "un exercice à refaire n'est pas déclaré juste")
    check(corrected.summary.contains("théorie"), "résumé lisible : \(corrected.summary)")
    WeekCompletion.undo(corrected, in: course)
    check(!e2.isDone && !f1.isDone && e1.correctness == .wrong, "annuler retire aussi les corrections ajoutées")
}

print("== Trame zstd sans compression (AnkiWeb) ==")
do {
    let small = Data(#"{"v":11,"cv":"anki,25.02.7 (6ddc22e5),ios"}"#.utf8)
    let large = Data((0..<300_000).map { UInt8($0 % 251) })
    let frame = ZstdFrame.stored(small)
    check(Array(frame.prefix(4)) == ZstdFrame.magic, "la trame commence par le nombre magique zstd")
    check(frame.count == small.count + 4 + 1 + 4 + 3, "en-tête + un bloc brut (\(frame.count) o)")
    // Le vrai décodeur, quand il est installé, relit exactement le contenu.
    let tool = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"].first { FileManager.default.isExecutableFile(atPath: $0) }
    if let tool {
        for (label, payload) in [("petit", small), ("300 ko, plusieurs blocs", large)] {
            let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zst")
            try? ZstdFrame.stored(payload).write(to: input)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-q", "-d", "-c", input.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            check(process.terminationStatus == 0 && output == payload, "zstd relit la trame (\(label))")
            try? FileManager.default.removeItem(at: input)
        }
    }
}

print("== Anki : planification des révisions ==")
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let creation = cal.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 5))!
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 14))!
    let clock = AnkiClock(now: now, creation: creation, rolloverHour: 4, calendar: cal)
    check(clock.today == 10, "jour d'Anki : 10 jours après la création (\(clock.today))")
    let earlyMorning = AnkiClock(now: cal.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 3))!,
                                 creation: creation, rolloverHour: 4, calendar: cal)
    check(earlyMorning.today == 9, "avant 4 h, c'est encore la veille")

    let options = AnkiDeckOptions()
    let new = AnkiCardState()
    let step1 = AnkiScheduler.answer(new, rating: .good, options: options, clock: clock, useFSRS: false)
    check(step1.card.type == 1 && step1.card.queue == 1 && step1.card.due == clock.seconds + 600 && step1.card.left == 1,
          "nouvelle carte, « bien » : deuxième étape, 10 min")
    check(step1.reviewType == 0 && step1.lastInterval == 0, "historique : apprentissage")
    let graduated = AnkiScheduler.answer(step1.card, rating: .good, options: options, clock: clock, useFSRS: false)
    check(graduated.card.type == 2 && graduated.card.ivl == 1 && graduated.card.due == 11 && graduated.card.factor == 2500,
          "dernière étape, « bien » : révision dans 1 jour, facilité 250 %")
    let easy = AnkiScheduler.answer(new, rating: .easy, options: options, clock: clock, useFSRS: false)
    check(easy.card.ivl == 4 && easy.card.due == 14, "« facile » d'emblée : 4 jours")
    let again = AnkiScheduler.answer(step1.card, rating: .again, options: options, clock: clock, useFSRS: false)
    check(again.card.left == 2 && again.card.due == clock.seconds + 60, "« à revoir » : retour à la première étape")
    let hardFirst = AnkiScheduler.answer(new, rating: .hard, options: options, clock: clock, useFSRS: false)
    check(hardFirst.card.due == clock.seconds + 330, "« difficile » à la première étape : moyenne des deux étapes (5,5 min)")

    let review = AnkiCardState(type: 2, queue: 2, due: 10, ivl: 10, factor: 2500, reps: 5)
    let r = AnkiRating.allCases.map { AnkiScheduler.answer(review, rating: $0, options: options, clock: clock, useFSRS: false) }
    check(r[1].card.ivl == 12 && r[1].card.factor == 2350, "révision « difficile » : 10 × 1,2 = 12 j, facilité −15 %")
    check(r[2].card.ivl == 25 && r[2].card.factor == 2500, "révision « bien » : 10 × 2,5 = 25 j")
    check(r[3].card.ivl == 33 && r[3].card.factor == 2650, "révision « facile » : 10 × 2,5 × 1,3 = 33 j, +15 %")
    check(r[0].card.type == 3 && r[0].card.queue == 1 && r[0].card.lapses == 1 && r[0].card.factor == 2300 && r[0].card.ivl == 1,
          "révision « à revoir » : réapprentissage, oubli compté, facilité −20 %")
    check(r[0].reviewType == 1 && r[0].lastInterval == 10, "historique d'une révision")
    let relearned = AnkiScheduler.answer(r[0].card, rating: .good, options: options, clock: clock, useFSRS: false)
    check(relearned.card.type == 2 && relearned.card.ivl == 1 && relearned.card.due == 11 && relearned.reviewType == 2,
          "réapprentissage terminé : de retour en révision")
    let late = AnkiCardState(type: 2, queue: 2, due: 6, ivl: 10, factor: 2500)
    check(AnkiScheduler.answer(late, rating: .good, options: options, clock: clock, useFSRS: false).card.ivl == 30,
          "4 jours de retard comptent à moitié pour « bien » : (10 + 2) × 2,5 = 30 j")
    var capped = options
    capped.maximumInterval = 20
    check(AnkiScheduler.answer(review, rating: .easy, options: capped, clock: clock, useFSRS: false).card.ivl == 20,
          "intervalle maximum du paquet respecté")

    let fsrsNew = AnkiScheduler.answer(new, rating: .good, options: options, clock: clock, useFSRS: true)
    let memory = AnkiScheduler.memory(of: fsrsNew.card)
    check(memory.map { abs($0.s - 3.173) < 0.001 } == true, "FSRS : stabilité initiale de « bien »")
    let fsrsReview = AnkiCardState(type: 2, queue: 2, due: 10, ivl: 10, factor: 2500, data: #"{"s":10,"d":5}"#)
    let f = AnkiRating.allCases.map { AnkiScheduler.answer(fsrsReview, rating: $0, options: options, clock: clock, useFSRS: true).card }
    check(f[1].ivl < f[2].ivl && f[2].ivl < f[3].ivl, "FSRS : difficile < bien < facile (\(f[1].ivl), \(f[2].ivl), \(f[3].ivl))")
    check((AnkiScheduler.memory(of: f[0])?.s ?? 99) < 10, "FSRS : un oubli fait baisser la stabilité")
    let fsrs = FSRS(params: [])
    check(abs(fsrs.interval(stability: 10, retention: 0.9) - 10) < 0.01, "FSRS : à 90 % de rétention, l'intervalle vaut la stabilité")
    var json: [String: Any] = ["new": ["delays": [1, 10], "ints": [2, 5, 0], "initialFactor": 2300, "perDay": 15],
                               "rev": ["ease4": 1.4, "maxIvl": 3650, "hardFactor": 1.1], "desiredRetention": 0.85]
    let parsed = AnkiDeckOptions(json: json)
    check(parsed.graduatingInterval == 2 && parsed.easyInterval == 5 && parsed.startingEase == 2300 && parsed.newPerDay == 15
          && parsed.easyBonus == 1.4 && parsed.maximumInterval == 3650 && parsed.desiredRetention == 0.85,
          "options du paquet lues dans le JSON")
    json = [:]
    check(AnkiScheduler.dayLabel(3) == "3 j" && AnkiScheduler.dayLabel(61) == "2,0 mois", "libellés des intervalles")
}

print("== Anki : rendu des cartes ==")
do {
    let basic = AnkiTemplate.Context(fields: ["Front": "Capitale <b>de la Suisse</b> ?", "Back": "Berne", "Extra": ""],
                                     ordinal: 0, isCloze: false)
    let front = AnkiTemplate.question("{{Front}}{{#Extra}}<i>{{Extra}}</i>{{/Extra}}", basic)
    check(front == "Capitale <b>de la Suisse</b> ?", "recto : champ inséré, section vide retirée")
    let back = AnkiTemplate.answer("{{FrontSide}}<hr id=answer>{{Back}}{{^Extra}} (sans note){{/Extra}}", front: front, basic)
    check(back == "Capitale <b>de la Suisse</b> ?<hr id=answer>Berne (sans note)", "verso : FrontSide et section inverse")
    check(AnkiTemplate.question("{{text:Front}}", basic) == "Capitale de la Suisse ?", "filtre text: retire le HTML")
    let cloze = AnkiTemplate.Context(fields: ["Text": "La dérivée de {{c1::x²}} est {{c2::2x::linéaire}}."], ordinal: 1, isCloze: true)
    check(AnkiTemplate.question("{{cloze:Text}}", cloze) == "La dérivée de x² est <span class=\"cloze\">[linéaire]</span>.",
          "trou 2 au recto : masqué avec son indice, le trou 1 en clair")
    check(AnkiTemplate.answer("{{cloze:Text}}", front: "", cloze) == "La dérivée de x² est <span class=\"cloze\">2x</span>.",
          "trou 2 au verso : la réponse surlignée")
    check(AnkiTemplate.stripHTML("a<br>b&nbsp;&amp;") == "a\nb &", "texte d'un champ HTML")
    check(AnkiTemplate.checksum(sha1Hex: "1a2b3c4d5e6f") == 0x1a2b3c4d, "somme de contrôle : 8 premiers chiffres hexadécimaux")
}

print("== Explique (AICC) : cours en replay et exercices ==")
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 7))!
    check(ExpliqueImport.slug(in: ["https://moodle.epfl.ch/x", "https://explique.epfl.ch/cs101/exercises"]) == "cs101", "cours lu dans le lien Moodle")
    check(ExpliqueImport.slug(courseCode: "CS-101") == "cs101", "cours déduit du code")
    let due = ExpliqueImport.dueDate("Tuesday 29 September at 17:00", termStart: start, calendar: cal)
    check(due.map { cal.dateComponents([.year, .month, .day, .hour], from: $0) } == DateComponents(year: 2026, month: 9, day: 29, hour: 17),
          "échéance « Tuesday 29 September at 17:00 »")
    check(ExpliqueImport.lectureNumber("Lecture 5: Proofs (view on speaker)") == 5 && ExpliqueImport.lectureNumber("Proofs - 1") == nil,
          "numéro de cours")
    // Relevé réel (semaine 3 de CS-101) : trois enregistrements du cours 5, un du 6, deux vidéos à part.
    let lectures: [ExpliqueImport.Lecture] = [
        .init(week: 3, title: "Lecture 5: Proofs (view on speaker)", url: "https://explique.epfl.ch/cs101/v/a"),
        .init(week: 3, title: "Lecture 6: Proofs", url: "https://explique.epfl.ch/cs101/v/b"),
        .init(week: 3, title: "Lecture 5: Proofs", url: "https://explique.epfl.ch/cs101/v/c"),
        .init(week: 3, title: "Lecture 5: Proofs (2026)", url: "https://explique.epfl.ch/cs101/v/d"),
        .init(week: 3, title: "Proofs - 1", url: "https://explique.epfl.ch/cs101/v/e"),
        .init(week: 1, title: "Lecture 1: Introduction", url: "https://explique.epfl.ch/cs101/v/f"),
    ]
    let exercises: [ExpliqueImport.Exercise] = [
        .init(week: 3, title: "Proofs Explanation exercise", url: "https://explique.epfl.ch/cs101/e/x", due: "Tuesday 29 September at 17:00", done: true)
    ]
    var moodleItem = ContentDraftItem(kind: .theory, number: "3", title: "Cours 6", url: "https://moodle.epfl.ch/slides6",
                                      videoCount: 0, seriesNumber: nil, theoryKind: .slides)
    moodleItem.links = [ContentLink(title: "Transparents", url: "https://moodle.epfl.ch/slides6", kind: .slides)]
    let base = ContentDraft(source: .moodle, courseTitle: "CS-101", url: "",
                            sections: [ContentDraftSection(title: "Semaine 3", week: 3, weekIsInferred: false, isIncluded: true, items: [moodleItem])])
    let merged = ExpliqueImport.merge(lectures: lectures, exercises: exercises, into: base, termStart: start, calendar: cal)
    let week3 = merged.draft.sections.first { $0.week == 3 }!
    let week3Theory = week3.items.filter { $0.kind == .theory }
    check(week3Theory.count == 1 && week3Theory.first?.title == "Cours 6",
          "semaine 3 : un seul élément, celui de Moodle (\(week3Theory.map(\.title)))")
    let videos = week3Theory.first?.links.filter { $0.kind == .video } ?? []
    check(videos.count == 5 && videos.first?.url.hasSuffix("/d") == true,
          "…avec les cinq vidéos de la semaine, l'enregistrement de l'année du cours 5 d'abord")
    check(merged.draft.sections.contains { $0.week == 1 && $0.items.contains { $0.number == "1" && $0.title == "Introduction" } },
          "une semaine absente de Moodle reçoit son élément, nommé par son sujet")
    let deadline = merged.draft.sections.flatMap(\.items).first { $0.kind == .deadline }
    check(deadline?.title == "Explique · Proofs" && deadline?.date == due, "l'exercice d'explication devient une échéance datée")
    let again = ExpliqueImport.merge(lectures: lectures, exercises: exercises, into: merged.draft, termStart: start, calendar: cal)
    check(again.added == 0, "réimporter n'ajoute rien en double")
}

print("== Réimport : les cours d'une semaine fusionnés ==")
do {
    let course = Course(code: "TEST-909", name: "Fusion")
    context.insert(course)
    let a = TheoryItem(course: course, sectionNumber: 4, number: "4.1", title: "Cours du mardi", kind: .slides, plannedWeek: 4, sortOrder: 0, urlString: "https://x/tue.pdf")
    let b = TheoryItem(course: course, sectionNumber: 4, number: "4.2", title: "Cours du mercredi", kind: .slides, plannedWeek: 4, sortOrder: 1, urlString: "https://x/wed.pdf")
    a.watchedAt = Date(); b.watchedAt = Date()
    context.insert(a); context.insert(b)
    var item = ContentDraftItem(kind: .theory, number: "4", title: "Cours de la semaine 4", url: "https://x/tue.pdf",
                                videoCount: 0, seriesNumber: nil, theoryKind: .slides)
    item.links = [ContentLink(title: "mardi", url: "https://x/tue.pdf", kind: .slides), ContentLink(title: "mercredi", url: "https://x/wed.pdf", kind: .slides)]
    let draft = ContentDraft(source: .moodle, courseTitle: "", url: "",
                             sections: [ContentDraftSection(title: "Semaine 4", week: 4, weekIsInferred: false, isIncluded: true, items: [item])])
    ContentDraftWriter.apply(draft, to: course, context: context)
    try? context.save()
    let week4 = course.theoryItems.filter { $0.plannedWeek == 4 }
    check(week4.count == 1 && week4.first?.number == "4" && week4.first?.links.count == 2, "un seul élément pour la semaine, avec les deux cours")
    check(week4.first?.isWatched == true, "la semaine reste vue : ses deux cours l'étaient")
    context.delete(course)
}

print("== Vidéos d'un cours rangées par semaine ==")
do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 7))!
    check(CourseVideos.week(of: "Semaine 3 : boucles", termStart: start, totalWeeks: 14, lecturesPerWeek: 1, calendar: cal) == 3, "« Semaine 3 »")
    check(CourseVideos.lecturesPerWeek(["Lecture 27: Advanced Probability", "Lecture 1"], totalWeeks: 14) == 2, "28 cours sur 14 semaines : deux par semaine")
    check(CourseVideos.week(of: "Lecture 7: Sets", termStart: start, totalWeeks: 14, lecturesPerWeek: 2, calendar: cal) == 4, "deux cours par semaine : le cours 7 est en semaine 4")
    check(CourseVideos.week(of: "PHYS-101(en) Lecture 3a: Forces", termStart: start, totalWeeks: 14, lecturesPerWeek: 1, calendar: cal) == 3, "« Lecture 3a » : semaine 3")
    check(CourseVideos.week(of: "CS-107 compléments du cours 4 (live-streaming du 1.10.2025)", termStart: start, totalWeeks: 14, lecturesPerWeek: 1, calendar: cal) == 4,
          "un enregistrement daté de l'an passé tombe dans la même semaine du semestre")
    check(CourseVideos.week(of: "Bienvenue", termStart: start, totalWeeks: 14, lecturesPerWeek: 1, calendar: cal) == nil, "sans indice : pas de semaine inventée")
    let draft = ContentDraft(source: .moodle, courseTitle: "", url: "", sections: [])
    let merged = CourseVideos.merge([.init(title: "Lecture 3: Forces", url: "https://m/3", week: 3),
                                     .init(title: "Intro", url: "https://m/0", week: nil)],
                                    into: draft, totalWeeks: 14, sourceLabel: "MediaSpace")
    check(merged.added == 2 && merged.draft.sections.contains { $0.week == 3 && $0.items.first?.title == "Forces" },
          "une vidéo rangée en semaine 3, l'autre gardée dans les documents")
}

print("== Moodle : formats inconnus rangés par le modèle ==")
do {
    let raw = #"Voici : {"activities":[{"id":"1","kind":"series","week":3,"series":3},{"id":"2","kind":"theory","week":3},{"id":"3","kind":"ignore","week":null},{"id":4,"kind":"solution","week":3,"series":3}]}"#
    let hints = MoodleCourseAI.parse(raw)
    check(hints["1"] == MoodleAIHint(kind: .series, week: 3, seriesNumber: 3) && hints["3"]?.kind == .ignore && hints["4"]?.kind == .solution,
          "réponse du modèle lue (texte autour, id numérique toléré)")
    func act(_ id: String, _ name: String, _ module: String = "resource") -> MoodleActivity {
        MoodleActivity(id: id, name: name, module: module, url: "https://moodle.epfl.ch/mod/\(module)/view.php?id=\(id)")
    }
    // Un cours rangé « par thème », aux noms que les règles ne comprennent pas.
    let odd = MoodleCourseSnapshot(title: "Cours bizarre", url: "u", sections: [
        MoodleSection(number: 0, title: "Général", activities: [act("2", "Séance du 21 septembre (vidéo)", "url"), act("3", "Café virtuel", "url")]),
        MoodleSection(number: 1, title: "Semaine 3", activities: [act("1", "TP-trois : récursivité"), act("4", "TP-trois : ce qu'il fallait trouver")])])
    let plain = MoodleCourseAnalyzer.draft(from: odd, termStart: nil)
    check(!plain.sections.flatMap(\.items).contains { $0.kind == .series }, "sans le modèle, « TP-trois » n'est pas reconnu comme série")
    let guided = MoodleCourseAnalyzer.draft(from: odd, termStart: nil, hints: hints)
    let week3 = guided.sections.first { $0.week == 3 }?.items ?? []
    check(week3.contains { $0.kind == .series && $0.seriesNumber == 3 && !$0.solutionURL.isEmpty }, "avec le modèle : la série 3 et son corrigé")
    check(week3.contains { $0.kind == .theory }, "la vidéo posée dans « Général » rejoint la semaine 3")
    check(!guided.sections.flatMap(\.items).contains { $0.title.contains("Café") }, "ce que le modèle écarte disparaît")
    let payload = MoodleCourseAI.payload(for: odd, termStart: nil, totalWeeks: 14)
    check((payload["outline"] as? String)?.contains("id=1 [resource] TP-trois") == true, "le plan envoyé : identifiants, types, noms")
}

print("== Plan du cours + MOOC : chapitres à regarder ==")
do {
    let answer = MoodleCourseAI.answer(#"{"activities":[{"id":"1","kind":"ignore"}],"mooc":[{"id":"block-v1:X+type@chapter+block@c1","week":2},{"id":"block-v1:X+type@chapter+block@c2","week":3}]}"#)
    check(answer.moocWeeks["block-v1:X+type@chapter+block@c1"] == 2 && answer.hints["1"]?.kind == .ignore, "réponse : activités et chapitres du MOOC")
    let mooc = ScrapedCourse(source: "courseware", title: "Initiation Java", url: "https://courseware.epfl.ch/c", sections: [
        ScrapedSection(title: "Module 1 : Variables", items: [
            ScrapedItem(title: "Variables", url: "https://courseware.epfl.ch/v1", type: "sequential", videoCount: 1,
                        links: [ContentLink(title: "Vidéo", url: "https://courseware.epfl.ch/video1", kind: .video)]),
            ScrapedItem(title: "Quiz du module 1", url: "https://courseware.epfl.ch/q1", type: "sequential")],
                       id: "block-v1:X+type@chapter+block@c1"),
        ScrapedSection(title: "Module 5 : Fonctions", items: [
            ScrapedItem(title: "Fonctions", url: "https://courseware.epfl.ch/v5", type: "sequential", videoCount: 1)],
                       id: "block-v1:X+type@chapter+block@c5")])
    let payload = MoodleCourseAI.payload(for: MoodleCourseSnapshot(title: "CS-107", url: "u", sections: []), termStart: nil, totalWeeks: 14,
                                         plan: "2 16/09 MOOC 1 : vidéos Module 1", moocs: [mooc])
    check((payload["mooc"] as? String)?.contains("id=block-v1:X+type@chapter+block@c1 : module 1 — Module 1 : Variables") == true && payload["plan"] != nil,
          "le modèle reçoit le plan et les chapitres du MOOC")
    let snapshot = MoodleCourseSnapshot(title: "CS-107", url: "u", sections: [
        MoodleSection(number: 2, title: "Semaine 2 : Premiers pas", activities: [
            MoodleActivity(id: "9", name: "Transparents (1 page sur 1)", module: "url", url: "https://moodle.epfl.ch/mod/url/view.php?id=9",
                           target: "https://proginsc.epfl.ch/cours02.pdf")])])
    let base = MoodleCourseAnalyzer.draft(from: snapshot, termStart: nil)
    let merged = MoocMerger.merge(mooc: mooc, references: [], snapshot: snapshot, into: base, termStart: nil,
                                  plannedWeeks: answer.moocWeeks)
    let week2 = merged.sections.filter { $0.week == 2 }.flatMap(\.items).filter { $0.kind == .theory }
    check(week2.contains { $0.links.contains { $0.url.contains("cours02") } }
          && week2.contains { $0.title == "MOOC · Module 1 : Variables" && $0.links.contains { $0.url == "https://courseware.epfl.ch/video1" } },
          "semaine 2 : le cours (transparents) et le Module 1 du MOOC demandé par le plan, chacun son élément")
    check(!merged.sections.flatMap(\.items).flatMap(\.links).contains { $0.url.contains("/v5") },
          "pas le module que le plan ne cite pas")
    check(week2.contains { $0.title.hasPrefix("MOOC") && $0.links.contains { $0.url.contains("/q1") && $0.kind == .page } },
          "le quiz du module est une ligne de son chapitre, pas une vidéo")
}

print("== Série restée sur le MOOC : l'adresse du cours l'emporte ==")
do {
    let course = Course(code: "TEST-107", name: "Prog")
    context.insert(course)
    let series = ExerciseSeries(course: course, seriesNumber: 3, plannedWeek: 3, urlString: "https://courseware.epfl.ch/courses/x/serie3")
    context.insert(series)
    let ex = Exercise(series: series, exerciseNumber: "3.1", statementURLString: "https://courseware.epfl.ch/courses/x/ex31")
    context.insert(ex)
    ex.setDone(true)
    var item = ContentDraftItem(kind: .series, number: "3", title: "Série 3", url: "https://proginsc.epfl.ch/wwwhiver/series/serie03/serie.html",
                                videoCount: 0, seriesNumber: 3, theoryKind: .reading)
    item.solutionURL = item.url
    let draft = ContentDraft(source: .moodle, courseTitle: "", url: "",
                             sections: [ContentDraftSection(title: "Semaine 3", week: 3, weekIsInferred: false, isIncluded: true, items: [item])])
    ContentDraftWriter.apply(draft, to: course, context: context)
    check(series.urlString.contains("proginsc") && series.needsReread, "la page de la série (proginsc) remplace le MOOC, et la série sera relue")
    check(ex.statementURLString.isEmpty && ex.isDone, "l'exercice ne pointe plus vers le MOOC, et reste fait")
    context.delete(course)
}

print("== Plan du cours lu sans modèle (CS-107) ==")
do {
    // Extrait réel du plan de CS-107, tel que l'app le lit (une cellule par ligne).
    let plan = """
    COURS
    14h15 - 15h00
    1
    09/09/2026
    11/09/2026
    14:15 Présentation du cours | Environnement | Algorithmes
    Série 1
    2
    16/09/2026
    18/09/2026
    14:15 MOOC 1 : vidéos Module 1 (Bases de programmation)
    Premiers pas en programmation
    MOOC 1 : quiz Module 1
    Série 2
    3
    23/09/2026
    25/09/2026
    14:15 MOOC 1 : vidéos Module 2
    MOOC 1 : vidéos Module 3
    Structures de contrôle
    MOOC 1 : quiz Module 2
    8
    28/10/2026
    30/10/2026
    14:15 [optionnel] MOOC 2 : vidéos Module 1
    MOOC 2 : vidéos Module 2
    9 02/11/2026
    Mini-projet 1: objectif de date pour atteindre 60% des points
    9
    04/11/2026
    06/11/2026
    14:15 MOOC 2 : vidéos Module 3
    """
    let found = CoursePlanParser.moocAssignments(in: plan, totalWeeks: 14)
    check(found == [.init(mooc: 1, module: 1, week: 2), .init(mooc: 1, module: 2, week: 3), .init(mooc: 1, module: 3, week: 3),
                    .init(mooc: 2, module: 1, week: 8), .init(mooc: 2, module: 2, week: 8), .init(mooc: 2, module: 3, week: 9)],
          "semaine de chaque module, lue ligne par ligne (\(found.map { "\($0.mooc).\($0.module)→S\($0.week)" }))")
    check(!found.contains { $0.week == 1 }, "les quiz ne sont pas des vidéos à regarder")
    func chapter(_ id: String, _ title: String) -> ScrapedSection {
        ScrapedSection(title: title, items: [ScrapedItem(title: "x", url: "u-\(id)")], id: id)
    }
    // Le chapitre d'accueil, au titre muet, reconnu à ses leçons.
    let welcome = ScrapedSection(title: "Introduction", items: [ScrapedItem(title: "Bienvenue", url: "w1"),
                                                                  ScrapedItem(title: "Informations pratiques", url: "w2")], id: "w")
    let mooc1 = ScrapedCourse(source: "courseware", title: "Java", url: "", sections: [
        welcome, chapter("b", "Bases de programmation"), chapter("c", "Branchements"), chapter("d", "Boucles")])
    let mooc2 = ScrapedCourse(source: "courseware", title: "POO", url: "", sections: [
        chapter("p", "Préambule"), chapter("i", "Introduction à la POO"), chapter("k", "Constructeurs"), chapter("h", "Héritage")])
    let weeks = CoursePlanParser.chapterWeeks(found, moocs: [mooc1, mooc2])
    check(weeks == ["b": 2, "c": 3, "d": 3, "i": 8, "k": 8, "h": 9], "module N → N-ième chapitre, préambule non compté (\(weeks))")
}

print("== Restes d'anciens imports du MOOC ==")
do {
    let course = Course(code: "TEST-108", name: "Prog")
    context.insert(course)
    let moocSeries = ExerciseSeries(course: course, seriesNumber: 6, plannedWeek: 5, urlString: "https://courseware.epfl.ch/courses/x/jump_to/block@Exercices_ID-1313")
    context.insert(moocSeries)
    let old1 = TheoryItem(course: course, sectionNumber: 2, number: "2.3", title: "Variables", kind: .video, plannedWeek: 0, urlString: "https://courseware.epfl.ch/l23")
    let old2 = TheoryItem(course: course, sectionNumber: 2, number: "2.6", title: "Contrôle des connaissances (5 Questions)", kind: .reading, plannedWeek: 0, urlString: "https://courseware.epfl.ch/l26")
    old1.videoCount = 1; old1.watchedAt = Date()
    context.insert(old1); context.insert(old2)
    var chapterItem = ContentDraftItem(kind: .theory, number: "M1-2", title: "MOOC · Bases de programmation", url: "https://courseware.epfl.ch/l22",
                                       videoCount: 1, seriesNumber: nil, theoryKind: .video, week: 2)
    chapterItem.links = [ContentLink(title: "Variables — Vidéo", url: "https://courseware.epfl.ch/xblock/v", kind: .video)]
    let draft = ContentDraft(source: .moodle, courseTitle: "", url: "",
                             sections: [ContentDraftSection(title: "Semaine 2", week: 2, weekIsInferred: false, isIncluded: true, items: [chapterItem])])
    ContentDraftWriter.apply(draft, to: course, context: context)
    try? context.save()
    check(!course.series.contains { $0.seriesNumber == 6 }, "la « série » du MOOC, pas commencée, est retirée")
    check(course.theoryItems.count == 1 && course.theoryItems.first?.isWatched == true,
          "les anciennes leçons rejoignent leur chapitre, vu puisque ses vidéos l'étaient (\(course.theoryItems.map(\.title)))")
    context.delete(course)
}

print("== Algèbre : leçons du MOOC rangées une à une par un ancien import ==")
do {
    let course = Course(code: "TEST-111", name: "Algèbre")
    context.insert(course)
    let lesson = TheoryItem(course: course, sectionNumber: 4, number: "M4.2", title: "3.2 L'espace des coordonnées", kind: .video, plannedWeek: 3,
                            urlString: "https://courseware.epfl.ch/courses/a/jump_to/l32")
    lesson.links = [ContentLink(title: "Leçon", url: "https://courseware.epfl.ch/xblock/v32", kind: .video)]
    lesson.videoCount = 1
    let weekPDF = TheoryItem(course: course, sectionNumber: 3, number: "3", title: "Cours de la semaine 3", kind: .reading, plannedWeek: 3,
                             urlString: "https://moodle.epfl.ch/mod/resource/view.php?id=1")
    context.insert(lesson); context.insert(weekPDF)
    var chapterItem = ContentDraftItem(kind: .theory, number: "M1-4", title: "MOOC · Chapitre 3 : Espaces vectoriels", url: "https://courseware.epfl.ch/courses/a/jump_to/l31",
                                       videoCount: 2, seriesNumber: nil, theoryKind: .video, week: 3)
    chapterItem.links = [ContentLink(title: "3.1 Définition — Leçon", url: "https://courseware.epfl.ch/xblock/v31", kind: .video),
                         ContentLink(title: "3.2 L'espace des coordonnées — Leçon", url: "https://courseware.epfl.ch/xblock/v32", kind: .video)]
    let draft = ContentDraft(source: .moodle, courseTitle: "", url: "",
                             sections: [ContentDraftSection(title: "Semaine 3", week: 3, weekIsInferred: false, isIncluded: true, items: [chapterItem])])
    ContentDraftWriter.apply(draft, to: course, context: context)
    try? context.save()
    check(Set(course.theoryItems.map(\.number)) == ["3", "M1-4"],
          "la leçon seule (semaine 3) disparaît derrière son chapitre, le cours de la semaine reste (\(course.theoryItems.map(\.number)))")
    context.delete(course)
}

print("== Un cours jamais vu, compris en entier (énoncés, consignes, MOOC) ==")
do {
    func act(_ id: String, _ name: String, _ module: String, target: String? = nil) -> MoodleActivity {
        MoodleActivity(id: id, name: name, module: module, url: "https://moodle.epfl.ch/mod/\(module)/view.php?id=\(id)", target: target)
    }
    // BIO-999 : la feuille d'exercices est sur le site du cours, citée dans la
    // consigne de la section ; l'activité « Feuille 2 » mène à un MOOC.
    var week2 = MoodleSection(number: 3, title: "Semaine 2 : Cellules", activities: [
        act("10", "Feuille 2", "url", target: "https://courseware.epfl.ch/courses/course-v1:EPFL+Bio+2026/jump_to/block-v1:EPFL+Bio+2026+type@sequential+block@x"),
        act("11", "Réponses feuille 2", "resource", target: "https://moodle.epfl.ch/pluginfile.php/1/rep2.pdf"),
        act("12", "Diapos semaine 2", "resource", target: "https://moodle.epfl.ch/pluginfile.php/1/diapos2.pdf")])
    week2.text = "Cette semaine : lisez le chapitre 2 et faites la feuille d'exercices sur le site du cours."
    week2.links = [ContentLink(title: "feuille d'exercices", url: "https://bio.example.org/td/feuille2.html", kind: .page)]
    week2.activities[0].destination = "mooc"
    week2.activities[0].preview = "Chapitre 2 · vidéos"
    let bio = MoodleCourseSnapshot(title: "Biologie (BIO-999)", url: "https://moodle.epfl.ch/course/view.php?id=9", sections: [week2])

    let rules = MoodleCourseAnalyzer.draft(from: bio, termStart: nil)
    let ruleSeries = rules.sections.flatMap(\.items).first { $0.kind == .series }
    check(ruleSeries.map { MoocReference.courseKey(in: $0.url) == nil } ?? true,
          "sans le modèle, un lien vers un MOOC n'est pas pris pour l'énoncé")

    let payload = MoodleCourseAI.payload(for: bio, termStart: nil, totalWeeks: 14)
    let outline = payload["outline"] as? String ?? ""
    check(outline.contains("Texte : « Cette semaine : lisez") && outline.contains("Lien L1 : feuille d'exercices → bio.example.org/td/feuille2.html")
          && outline.contains("{mooc}") && outline.contains("« Chapitre 2 · vidéos »") && payload["instructions"] == nil,
          "le modèle reçoit consignes, liens cités, nature et début de chaque cible")

    let answer = MoodleCourseAI.answer(#"{"activities":[{"id":"10","kind":"document","week":2},{"id":"11","kind":"solution","week":2,"series":2},{"id":"12","kind":"theory","week":2}],"series":[{"number":2,"week":2,"statement":"L1","solution":11},{"number":3,"week":3,"statement":"L99","solution":null}],"weeks":[{"week":2,"todo":"Lire le chapitre 2, faire la feuille 2 sur le site du cours."},{"week":40,"todo":"hors semestre"}]}"#)
    check(answer.series.first == MoodleCourseAI.SeriesPlan(number: 2, week: 2, statement: "L1", solution: "a11"),
          "réponse : série, énoncé cité dans la consigne, corrigé (id numérique toléré)")
    let understood = MoodleCourseAnalyzer.apply(answer, to: MoodleCourseAnalyzer.draft(from: bio, termStart: nil, hints: answer.hints),
                                                snapshot: bio, totalWeeks: 14)
    let series2 = understood.sections.flatMap(\.items).filter { $0.kind == .series }
    check(series2.count == 1 && series2.first?.url == "https://bio.example.org/td/feuille2.html"
          && series2.first?.solutionURL == "https://moodle.epfl.ch/pluginfile.php/1/rep2.pdf"
          && understood.sections.first { $0.items.contains { $0.kind == .series } }?.week == 2,
          "la série 2 : énoncé sur le site du cours, corrigé en PDF, en semaine 2 (\(series2.map(\.url)))")
    check(!series2.contains { $0.seriesNumber == 3 }, "une référence inconnue (L99) ne crée rien")
    check(understood.weekGuide == [2: "Lire le chapitre 2, faire la feuille 2 sur le site du cours."],
          "la consigne de la semaine, gardée dans les semaines du semestre")

    // Un énoncé déjà trouvé par les règles est remplacé par celui que le modèle désigne.
    let other = MoodleCourseSnapshot(title: "X", url: "u", sections: [MoodleSection(number: 1, title: "Semaine 1", activities: [
        act("20", "Série 1", "url", target: "https://example.org/mauvais.html"),
        act("21", "Série 1 : énoncé et corrigé", "url", target: "https://example.org/serie1.html")])])
    let fixed = MoodleCourseAnalyzer.apply(MoodleCourseAI.answer(#"{"series":[{"number":1,"week":1,"statement":"a21"}]}"#),
                                           to: MoodleCourseAnalyzer.draft(from: other, termStart: nil), snapshot: other, totalWeeks: 14)
    check(fixed.sections.flatMap(\.items).first { $0.kind == .series }?.url == "https://example.org/serie1.html",
          "l'énoncé que le modèle désigne remplace celui que les règles avaient choisi")
}

print("== Page web d'exercices, lue comme une mise en page ==")
do {
    let html = """
    <html><head><style>.x{}</style></head><body><nav>Menu</nav>
    <h1>Série 5 — Récursivité</h1>
    <h2>Exercice 1 : Factorielle</h2><p>Écrire une fonction récursive.</p>
    <ol><li>Version naïve</li><li>Version terminale</li></ol>
    <p><strong>Exercice 2.</strong> Calculer les nombres de Fibonacci.</p>
    <h2>Exercice 3 : Tours de Hanoï</h2><p>Résoudre pour n disques.</p>
    </body></html>
    """
    let lines = HTMLLayout.lines(fromHTML: html)
    check(lines.first?.text == "Série 5 — Récursivité" && lines.first?.isBold == true && !lines.contains { $0.text == "Menu" },
          "titres en gras et plus grands, menus écartés")
    let item = lines.first { $0.text == "Version naïve" }
    let body = lines.first { $0.text == "Écrire une fonction récursive." }
    check((item?.indent ?? 0) > (body?.indent ?? 0), "les questions d'une liste sont en retrait")
    check(lines.contains { $0.text.hasPrefix("Exercice 2.") && $0.startsBold }, "« Exercice 2. » en gras en début de ligne")
    let detected = SeriesLayoutParser.parse(lines, defaultSeries: 5)
    let exercises = detected.first?.exercises ?? []
    check(exercises.count == 3, "trois exercices reconnus sur une page jamais vue (\(exercises.map(\.number)))")
}

print("== Site d'un cours vide sur Moodle, trouvé sans table ==")
do {
    let home = URL(string: "https://botafogo.epfl.ch/")!
    let catalog: [(title: String, url: URL)] = [
        ("Mon cours d'analyse", home.appendingPathComponent("analyse-1/")),
        ("Mon cours d'analyse pour GM", home.appendingPathComponent("analyse-1-GM/")),
        ("Mon cours d'analyse classe inversée", home.appendingPathComponent("analyse-1-flipped/")),
        ("Le polycopié d'ICS", home.appendingPathComponent("ics/"))]
    check(BotafogoCatalog.match(courseName: "MATH-101(pi) Analyse I (classe inversée)", in: catalog)?.lastPathComponent == "analyse-1-flipped",
          "classe inversée : le polycopié dont tous les mots se retrouvent")
    check(BotafogoCatalog.match(courseName: "MATH-101(a) Analyse I", in: catalog)?.lastPathComponent == "analyse-1",
          "le cours ordinaire : pas la version GM ni inversée")
    check(BotafogoCatalog.match(courseName: "PHYS-101 Physique générale", in: catalog) == nil, "aucun site inventé")
    let cited = MoodleCourseSnapshot(title: "Y", url: "u", sections: [MoodleSection(number: 0, title: "Infos", activities: [],
        text: "", links: [ContentLink(title: "Polycopié", url: "https://botafogo.epfl.ch/analyse-b/chapitre1", kind: .page)])])
    check(BotafogoCatalog.site(in: cited)?.absoluteString.contains("analyse-b") == true, "un lien Botafogo cité par le cours l'emporte")
}

print("== MOOC : seulement les leçons demandées, chacune à sa semaine ==")
do {
    func lesson(_ n: String, _ id: String) -> ScrapedItem {
        ScrapedItem(title: n, url: "https://courseware.epfl.ch/\(id)", type: "sequential", videoCount: 1, id: "block-\(id)",
                    links: [ContentLink(title: "Leçon", url: "https://courseware.epfl.ch/video-\(id)", kind: .video)])
    }
    let mooc = ScrapedCourse(source: "courseware", title: "Algèbre", url: "https://courseware.epfl.ch/c", sections: [
        ScrapedSection(title: "Chapitre 1 : Systèmes", items: [lesson("1.1 Intro", "a"), lesson("1.2 Gauss", "b"), lesson("1.3 Échelonnées", "c"),
                                                              lesson("1.4 Option", "d")], id: "chap-1"),
        ScrapedSection(title: "Chapitre 2 : Matrices", items: [lesson("2.1 Produit", "e"), lesson("2.2 Inverse", "f")], id: "chap-2")])
    let payload = MoodleCourseAI.payload(for: MoodleCourseSnapshot(title: "MATH-999", url: "u", sections: []), termStart: nil, totalWeeks: 14, moocs: [mooc])
    check((payload["mooc"] as? String)?.contains("· m1.1.2 1.2 Gauss (1 vidéo)") == true, "chaque leçon du MOOC a sa référence")
    let answer = MoodleCourseAI.answer(#"{"mooc":[{"week":1,"lessons":["m1.1.1","m1.1.2"]},{"week":2,"lessons":["M1.1.3","m1.2.1","m9.9.9"]}]}"#)
    let lessons = MoodleCourseAI.lessonWeeks(answer, moocs: [mooc])
    check(lessons == ["block-a": 1, "block-b": 1, "block-c": 2, "block-e": 2], "références résolues, inconnues ignorées (\(lessons))")
    let snapshot = MoodleCourseSnapshot(title: "MATH-999", url: "u", sections: [])
    let merged = MoocMerger.merge(mooc: mooc, references: [], snapshot: snapshot,
                                  into: ContentDraft(source: .moodle, courseTitle: "", url: "", sections: []),
                                  termStart: nil, plannedLessons: lessons)
    let items = merged.sections.flatMap { section in section.items.filter { $0.title.hasPrefix("MOOC") }.map { (section.week, $0) } }
    let week1 = items.filter { $0.0 == 1 }.flatMap { $0.1.links.map(\.url) }
    let week2 = items.filter { $0.0 == 2 }.flatMap { $0.1.links.map(\.url) }
    check(week1 == ["https://courseware.epfl.ch/video-a", "https://courseware.epfl.ch/video-b"]
          && Set(week2) == ["https://courseware.epfl.ch/video-c", "https://courseware.epfl.ch/video-e"],
          "semaine 1 : 1.1–1.2 ; semaine 2 : 1.3 et 2.1 — ni 1.4 ni 2.2, non demandées")
    let numbers = items.map(\.1.number)
    check(Set(numbers).count == numbers.count && numbers.contains("M1-1-s1") && numbers.contains("M1-1-s2"),
          "un chapitre réparti : un élément par semaine, numéros distincts (\(numbers))")

    // Ce qui était vu le reste après le découpage.
    let course = Course(code: "TEST-999", name: "Algèbre")
    context.insert(course)
    let old = TheoryItem(course: course, sectionNumber: 1, number: "M1-1", title: "MOOC · Chapitre 1 : Systèmes", kind: .video, plannedWeek: 1,
                         urlString: "https://courseware.epfl.ch/a")
    old.links = ["a", "b", "c", "d"].map { ContentLink(title: "Leçon", url: "https://courseware.epfl.ch/video-\($0)", kind: .video) }
    old.watchedAt = Date()
    context.insert(old)
    ContentDraftWriter.apply(merged, to: course, context: context)
    try? context.save()
    let chapterOne = course.theoryItems.filter { $0.number.hasPrefix("M1-1") }
    check(chapterOne.count == 2 && chapterOne.allSatisfy(\.isWatched),
          "le chapitre vu, réparti sur deux semaines, reste vu des deux côtés (\(chapterOne.map(\.number)))")
    check(!course.theoryItems.contains { $0.number == "M1-1" }, "l'ancien élément du chapitre entier ne reste pas en double")
    context.delete(course)
}

print("== Une autre source du cours complète Moodle ==")
do {
    var moodle = ContentDraft(source: .moodle, courseTitle: "A", url: "", sections: [
        ContentDraftSection(title: "Semaine 1", week: 1, weekIsInferred: false, isIncluded: true, items: [
            ContentDraftItem(kind: .series, number: "1", title: "Série 1", url: "m1", videoCount: 0, seriesNumber: 1, theoryKind: .reading)])])
    moodle.weekGuide = [1: "x"]
    let other = ContentDraft(source: .botafogo, courseTitle: "Poly", url: "", sections: [
        ContentDraftSection(title: "Semaine 1", week: 1, weekIsInferred: false, isIncluded: true, items: [
            ContentDraftItem(kind: .series, number: "1", title: "Série 1", url: "b1", videoCount: 0, seriesNumber: 1, theoryKind: .reading),
            ContentDraftItem(kind: .theory, number: "1.1", title: "Suites", url: "t1", videoCount: 2, seriesNumber: nil, theoryKind: .video)]),
        ContentDraftSection(title: "Semaine 2", week: 2, weekIsInferred: false, isIncluded: true, items: [
            ContentDraftItem(kind: .series, number: "2", title: "Série 2", url: "b2", videoCount: 0, seriesNumber: 2, theoryKind: .reading)])])
    let done = moodle.completed(with: other)
    let all = done.sections.flatMap(\.items)
    check(all.filter { $0.kind == .series }.map(\.url) == ["m1", "b2"] && all.contains { $0.url == "t1" },
          "la série 1 reste celle de Moodle ; la série 2 et la théorie manquantes viennent de l'autre source")
    check(other.outline.contains("## Semaine 2 [semaine 2]") && other.outline.contains("Série 2 [série 2]"), "résumé lisible pour le modèle")
}

print("== Accents réparés à la source (TextRepair, MathMarkup) ==")
do {
    check(TextRepair.clean("S´erie 3 : ´equations diff´erentielles") == "Série 3 : équations différentielles",
          "PDF LaTeX : l'accent aigu dessiné avant la lettre rejoint sa lettre")
    check(TextRepair.composeAccents("e´te´, re´sume´") == "été, résumé", "…et dessiné après la lettre aussi")
    check(TextRepair.composeAccents("pr`es de la fenˆetre, M¨uller, garc¸on") == "près de la fenêtre, Müller, garçon",
          "grave, circonflexe, tréma, cédille")
    check(TextRepair.composeAccents("l´analyse, qu´il, jusqu´ici, d´efinition") == "l’analyse, qu’il, jusqu’ici, définition",
          "« ´ » tapé pour une apostrophe devient une apostrophe")
    check(TextRepair.composeAccents("x^2 + `code`, x^y, ℝ^n") == "x^2 + `code`, x^y, ℝ^n",
          "un exposant (même entre deux lettres) ou du code ne sont pas touchés")
    check(TextRepair.clean("S&eacute;rie 4 &#8211; l&#039;int&#xE9;grale &amp; co") == "Série 4 – l'intégrale & co",
          "Moodle : entités nommées, décimales et hexadécimales")
    check(TextRepair.clean("SÃ©rie 2 Ã\u{00A0} rendre â€” corrigÃ©") == "Série 2 à rendre — corrigé",
          "Moodle : texte UTF-8 relu en Latin-1 (double encodage) réparé")
    check(TextRepair.clean("e\u{0301}nonce\u{0301}") == "énoncé" && TextRepair.clean("énoncé").unicodeScalars.count == 6,
          "forme composée (NFC) : un « é » est un seul caractère")
    let clean = "Algèbre linéaire — Série 4 : l’ensemble A′ = {n : xₙ < 0}, f''(x) ≥ 0"
    check(TextRepair.clean(clean) == clean, "un texte propre ressort intact")
    check(MathMarkup.plain(#"Montrer que la s\'erie est \`a termes positifs, o\`u \^etre, na\"\i ve, gar\c{c}on"#)
          == "Montrer que la série est à termes positifs, où être, naïve, garçon",
          "MathMarkup : accents LaTeX composés au lieu de « 'e »")
    check(MathMarkup.plain("Quelques indéterminations ``\\frac{0}{0}''") == "Quelques indéterminations “0⁄0”"
          && MathMarkup.plain("f''(x) > 0") == "f''(x) > 0",
          "MathMarkup : ``guillemets'' LaTeX, sans toucher f''(x)")
}

print("== Progression de l'import (ImportProgress) ==")
do {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var progress = ImportProgress(courseIDs: ["a", "b"], now: t0)
    check(progress.fraction(at: t0) == 0 && progress.remainingSeconds(at: t0) == nil,
          "au départ : 0 %, pas d'estimation hasardeuse")
    progress.enter(.outline, course: "a", now: t0)
    progress.activities(done: 0, total: 36, course: "a", now: t0.addingTimeInterval(2))
    progress.activities(done: 18, total: 36, course: "a", now: t0.addingTimeInterval(8))
    let mid = progress.fraction(at: t0.addingTimeInterval(8))
    let later = progress.fraction(at: t0.addingTimeInterval(11))
    check(mid > 0.1 && mid < 0.2, "la moitié des activités d'un cours sur deux ≈ 15 % (\(Int(mid * 100)) %)")
    check(later > mid, "entre deux lots, l'avancement glisse au rythme mesuré")
    progress.enter(.sources, course: "a", now: t0.addingTimeInterval(14))
    progress.enter(.activities, course: "a", now: t0.addingTimeInterval(15))
    check(progress.courses[0].stage == .sources, "jamais en arrière : un message tardif est ignoré")
    progress.enter(.analysis, course: "a", now: t0.addingTimeInterval(16))
    let waiting = progress.fraction(at: t0.addingTimeInterval(300))
    check(waiting < 0.5, "l'analyse qui traîne ne termine jamais le cours avant sa réponse")
    progress.enter(.done, course: "a", now: t0.addingTimeInterval(40))
    check(abs(progress.fraction(at: t0.addingTimeInterval(40)) - 0.5) < 0.001, "un cours sur deux fini = 50 %")
    let eta = progress.remainingSeconds(at: t0.addingTimeInterval(40)) ?? -1
    check(eta > 30 && eta < 50, "temps restant extrapolé du rythme réel (\(Int(eta)) s)")
    check(ImportProgress.remainingLabel(100) == "~1 min 40" && ImportProgress.remainingLabel(23) == "~25 s"
          && ImportProgress.remainingLabel(nil) == "estimation…", "« ~1 min 40 », « ~25 s »")
    check(ImportProgress.stage(forMessage: "rangement du cours…") == .analysis
          && ImportProgress.stage(forMessage: "MOOC cité — lecture de Courseware…") == .sources,
          "les messages de la chaîne d'import deviennent des étapes")
}

print("== Accueil : ce que l'import montre, élément par élément (ImportFeed) ==")
do {
    var feed = ImportFeed()
    feed.reset([(id: "a", code: "MATH-101", name: "Analyse I", colorHex: "#0891B2"),
                (id: "b", code: "CS-107", name: "Programmation", colorHex: "#059669")])
    let sections = [
        MoodleSection(number: 0, title: "", activities: [
            MoodleActivity(id: "1", name: "Annonces", module: "forum", url: ""),
            MoodleActivity(id: "2", name: "Bienvenue", module: "label", url: "")]),
        MoodleSection(number: 3, title: "Semaine 3 &amp; suites", activities: [
            MoodleActivity(id: "3", name: "S\u{00e9}rie 3", module: "resource", url: ""),
            MoodleActivity(id: "4", name: "Vidéos", module: "url", url: "")]),
        MoodleSection(number: 4, title: "Semaine 4", activities: [
            MoodleActivity(id: "5", name: "Cach\u{00e9}", module: "label", url: "")]),
    ]
    feed.outline(sections, course: "a")
    let course = feed.courses[0]
    check(course.sections.count == 2 && course.sections[1].title == "Semaine 3 & suites"
          && course.activities.map(\.id) == ["1", "3", "4"],
          "plan : étiquettes et sections vides retirées, titres nettoyés")
    check(course.openableCount == 2 && course.openedCount == 0, "deux activités à ouvrir (le forum se lit dans le plan)")
    feed.opened(["3": "PDF", "4": "Vidéo", "zz": "PDF"], course: "a")
    check(feed.courses[0].openedCount == 2 && feed.courses[0].activities.first { $0.id == "4" }?.revealed == "Vidéo",
          "ouverture : chaque activité dit ce qu'elle cachait")
    feed.setStage(.analysis, course: "a")
    feed.setStage(.activities, course: "a")
    check(feed.courses[0].stage == .analysis, "l'étape ne recule jamais")

    var draft = ContentDraft(source: .moodle, courseTitle: "", url: "", sections: [])
    draft.sections = [ContentDraftSection(title: "S3", week: 3, weekIsInferred: false, isIncluded: true, items: [
        ContentDraftItem(kind: .series, number: "3", title: "", url: "", videoCount: 0, seriesNumber: 3, theoryKind: .reading),
        ContentDraftItem(kind: .theory, number: "3.1", title: "Limites", url: "", videoCount: 2, seriesNumber: nil, theoryKind: .video),
        ContentDraftItem(kind: .resource, number: "", title: "Formulaire", url: "", videoCount: 0, seriesNumber: nil, theoryKind: .reading),
        ContentDraftItem(kind: .deadline, number: "", title: "Midterm", url: "", videoCount: 0, seriesNumber: nil,
                         theoryKind: .reading, week: 8)]),
        ContentDraftSection(title: "Non planifié", week: 0, weekIsInferred: true, isIncluded: true, items: [
            ContentDraftItem(kind: .series, number: "9", title: "Bonus", url: "", videoCount: 0, seriesNumber: nil, theoryKind: .reading)])]
    feed.place(draft, course: "a")
    let placed = feed.courses[0].placed
    check(placed.map(\.title) == ["Limites", "Série 3", "Midterm"] && placed.map(\.week) == [3, 3, 8],
          "rangement : vidéo, série, échéance dans leur semaine ; ni document ni élément sans semaine")
    check(placed[0].kind == .video && placed[0].detail == "2 vidéos", "« 2 vidéos »")
    check(feed.week(3).count == 1 && feed.week(3)[0].items.count == 2 && feed.week(5).isEmpty,
          "la semaine 3, tous cours confondus")
    check(feed.totals.series == 1 && feed.totals.videos == 1 && feed.totals.deadlines == 1, "totaux")
    feed.remove("b")
    check(feed.courses.count == 1, "un cours ignoré disparaît")
    check(ImportFeed.openedLabel(["dates": "Due: 12 Oct"]) == "Devoir"
          && ImportFeed.openedLabel(["files": [1, 2, 3], "kind": "dossier"]) == "Dossier · 3 PDF"
          && ImportFeed.openedLabel(["target": "https://mediaspace.epfl.ch/media/x"]) == "Vidéo"
          && ImportFeed.openedLabel(["target": "https://x/a.pdf", "kind": "pdf"]) == "PDF"
          && ImportFeed.openedLabel([:]) == "Page",
          "ce que cachait une activité, en un mot")
}

print("== Import Moodle : corrections de l'audit ==")
do {
    func res(_ id: String, _ name: String, module: String = "resource") -> MoodleActivity {
        var activity = MoodleActivity(id: id, name: name, module: module, url: "https://moodle.epfl.ch/mod/\(module)/view.php?id=\(id)")
        activity.target = "https://moodle.epfl.ch/pluginfile.php/1/\(id).pdf"
        return activity
    }
    func series(_ draft: ContentDraft, _ number: Int) -> [(week: Int, url: String, solution: String)] {
        draft.sections.flatMap { section in
            section.items.filter { $0.kind == .series && $0.seriesNumber == number }
                .map { ($0.week ?? section.week, $0.pdfURL.isEmpty ? $0.url : $0.pdfURL, $0.solutionURL) }
        }
    }

    // 1. Le corrigé publié la semaine suivante rejoint sa série, qui garde sa semaine.
    let nextWeek = MoodleCourseSnapshot(title: "Analyse I", url: "u", sections: [
        MoodleSection(number: 3, title: "Semaine 3", activities: [res("31", "Série 3")]),
        MoodleSection(number: 4, title: "Semaine 4", activities: [res("41", "Série 4"), res("42", "Corrigé série 3")]),
    ])
    let joined = series(MoodleCourseAnalyzer.draft(from: nextWeek, termStart: nil, totalWeeks: 14), 3)
    check(joined.count == 1 && joined[0].week == 3 && joined[0].solution.hasSuffix("42.pdf"),
          "corrigé publié la semaine suivante : une seule « Série 3 », en semaine 3, avec son corrigé")

    // L'écriture : un corrigé seul ne déplace jamais sa série.
    let writerCourse = Course(code: "AUDIT-101", name: "Audit")
    context.insert(writerCourse)
    var split = ContentDraft(source: .moodle, courseTitle: "", url: "", sections: [])
    var statement = ContentDraftItem(kind: .series, number: "3", title: "Série 3", url: "https://x/s3.pdf", videoCount: 0, seriesNumber: 3, theoryKind: .reading)
    statement.pdfURL = "https://x/s3.pdf"
    var onlySolution = ContentDraftItem(kind: .series, number: "3", title: "Série 3", url: "", videoCount: 0, seriesNumber: 3, theoryKind: .reading)
    onlySolution.solutionURL = "https://x/s3-sol.pdf"
    split.sections = [ContentDraftSection(title: "S3", week: 3, weekIsInferred: false, isIncluded: true, items: [statement]),
                      ContentDraftSection(title: "S4", week: 4, weekIsInferred: false, isIncluded: true, items: [onlySolution])]
    _ = ContentDraftWriter.apply(split, to: writerCourse, context: context)
    let written = writerCourse.series.first { $0.seriesNumber == 3 }
    check(written?.plannedWeek == 3 && written?.solutionURLString == "https://x/s3-sol.pdf",
          "écriture : la série reste en semaine 3, le corrigé est rattaché")

    // 2. Un dossier « Séries » dans la section générale : chaque série à sa semaine.
    var folder = MoodleActivity(id: "9", name: "Séries", module: "folder", url: "f")
    folder.target = "https://moodle.epfl.ch/pluginfile.php/1/Serie_01.pdf"
    let files = (1...3).map { MoodleFolderExpander.File(title: "Serie_0\($0).pdf", url: "https://moodle.epfl.ch/pluginfile.php/1/Serie_0\($0).pdf") }
        + (1...3).map { MoodleFolderExpander.File(title: "Serie_0\($0)_sol.pdf", url: "https://moodle.epfl.ch/pluginfile.php/1/Serie_0\($0)_sol.pdf") }
    let expanded = MoodleFolderExpander.expand(folder, files: files)
    let general = MoodleCourseAnalyzer.draft(from: MoodleCourseSnapshot(title: "X", url: "u", sections: [
        MoodleSection(number: 0, title: "Général", activities: expanded),
        MoodleSection(number: 1, title: "Semaine 1", activities: [res("11", "Cours 1 slides")]),
    ]), termStart: nil, totalWeeks: 14)
    check((1...3).allSatisfy { n in series(general, n).map(\.week) == [n] && series(general, n)[0].solution.contains("_sol") },
          "dossier « Séries » en section générale : séries 1, 2, 3 suivies, chacune à sa semaine, avec son corrigé")
    check(!general.sections.flatMap(\.items).contains { $0.kind == .resource && $0.title.hasPrefix("Serie") },
          "… et plus rangées en « documents non suivis »")

    // 3. Toutes les séries du semestre posées en semaine 1.
    let firstWeek = MoodleCourseAnalyzer.draft(from: MoodleCourseSnapshot(title: "X", url: "u", sections: [
        MoodleSection(number: 1, title: "Semaine 1", activities: expanded + [res("11", "Cours 1 slides")]),
    ]), termStart: nil, totalWeeks: 14)
    check((1...3).allSatisfy { series(firstWeek, $0).map(\.week) == [$0] },
          "dossier de toutes les séries en semaine 1 : chacune à la semaine de son numéro")
    let single = MoodleCourseAnalyzer.draft(from: MoodleCourseSnapshot(title: "X", url: "u", sections: [
        MoodleSection(number: 2, title: "Semaine 2", activities: [res("21", "Série 1")]),
    ]), termStart: nil, totalWeeks: 14)
    check(series(single, 1).map(\.week) == [2], "une série seule reste dans sa section (série 1 posée en semaine 2)")

    // 4. Botafogo : le nom du cours doit être expliqué en entier.
    let catalog: [(title: String, url: URL)] = [
        ("Mon cours d'analyse", URL(string: "https://botafogo.epfl.ch/analyse-1/")!),
        ("Mon cours d'analyse pour GM", URL(string: "https://botafogo.epfl.ch/analyse-1-GM/")!),
        ("Mon cours d'analyse classe inversée", URL(string: "https://botafogo.epfl.ch/analyse-1-flipped/")!),
        ("Le polycopié d'Algèbre linéaire et Géométrie", URL(string: "https://botafogo.epfl.ch/algebre-lineaire-geometrie/")!),
        ("Le polycopié d'analyse-b", URL(string: "https://botafogo.epfl.ch/analyse-b/matiere/m_suites_intro")!),
        ("Mon cours d'algèbre linéaire", URL(string: "https://botafogo.epfl.ch/algebre-lineaire/index.html")!),
    ]
    func site(_ name: String) -> String { BotafogoCatalog.match(courseName: name, in: catalog)?.absoluteString.replacingOccurrences(of: "https://botafogo.epfl.ch", with: "") ?? "aucun" }
    check(site("Analyse I (MATH-101(e))") == "/analyse-1/", "Analyse I → analyse-1 (\(site("Analyse I (MATH-101(e))")))")
    check(site("Analyse I (classe inversée) (MATH-101(pi))") == "/analyse-1-flipped/", "Analyse I classe inversée → analyse-1-flipped")
    check(site("Algèbre linéaire (MATH-111(e))") == "/algebre-lineaire/index.html", "Algèbre linéaire → algebre-lineaire")
    check(site("Analyse numérique (MATH-251(a))") == "aucun" && site("Analyse II (MATH-106(en))") == "aucun"
          && site("Algèbre linéaire avancée I (MATH-110)") == "aucun" && site("Physique générale I") == "aucun",
          "Analyse numérique, Analyse II, Algèbre linéaire avancée : aucun polycopié (et plus celui d'Analyse I)")
    check(site("Analyse B (MATH-105)") == "/analyse-b/matiere/m_suites_intro", "Analyse B → analyse-b")

    // 10. Une date courte n'est pas un numéro.
    let now = Date()
    check(MoodleCourseAnalyzer.shortDate(in: "Projet 1.2 — consignes", termStart: now, calendar: .current) == nil
          && MoodleCourseAnalyzer.shortDate(in: "Partie 3.1", termStart: now, calendar: .current) == nil,
          "« Projet 1.2 », « Partie 3.1 » ne sont pas des échéances")
    check(MoodleCourseAnalyzer.shortDate(in: "Sélection d'un groupe (DÉLAI 13.10, 18:00)", termStart: now, calendar: .current) != nil
          && MoodleCourseAnalyzer.shortDate(in: "Examen Final (samedi 12.12, 09:00-12:00)", termStart: now, calendar: .current) != nil
          && MoodleCourseAnalyzer.shortDate(in: "Rendu le 4.11", termStart: now, calendar: .current) != nil,
          "les vraies dates courtes restent lues (délai, examen, « le 4.11 »)")

    // La consigne du serveur est celle de l'app (le serveur n'accepte plus celle du client).
    let function = FileManager.default.currentDirectoryPath + "/supabase/functions/analyze-course/index.ts"
    if let source = try? String(contentsOfFile: function, encoding: .utf8),
       let start = source.range(of: "const INSTRUCTIONS = "), let end = source.range(of: "\";\n", range: start.upperBound..<source.endIndex),
       let literal = String(source[start.upperBound..<end.lowerBound]).appending("\"").data(using: .utf8),
       let serverText = try? JSONDecoder().decode(String.self, from: literal) {
        check(serverText == MoodleCourseAI.instructions, "analyze-course : la consigne du serveur est celle de l'app (sinon : la recopier et redéployer)")
    } else {
        check(false, "analyze-course : consigne du serveur introuvable dans \(function)")
    }

    // Quand redemander l'analyse : la structure, pas le texte qui bouge.
    var base = MoodleCourseSnapshot(title: "X", url: "u", sections: [
        MoodleSection(number: 3, title: "Semaine 3 (semaine courante)", activities: [res("31", "Série 3")], text: "Rendu lundi")])
    let before = MoodleCourseAI.structure(of: base, hasPlan: true)
    base.sections[0].text = "Rendu mardi"
    base.sections[0].activities[0].preview = "Dernière mise à jour : 3 octobre"
    base.sections[0].activities[0].target = "https://moodle.epfl.ch/pluginfile.php/1/mod_resource/content/7/31.pdf?forcedownload=1"
    var moved = base
    moved.sections[0].title = "Semaine 3"
    check(MoodleCourseAI.structure(of: base, hasPlan: true) == MoodleCourseAI.structure(of: moved, hasPlan: true),
          "structure : ni texte de section, ni aperçu, ni révision de fichier, ni « semaine courante »")
    base.sections[0].activities.append(res("32", "Corrigé série 3"))
    check(MoodleCourseAI.structure(of: base, hasPlan: true) != before, "structure : une activité publiée la change")
    let day: TimeInterval = 86_400
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    check(MoodleCourseAI.reuses(cachedStructure: "s", cachedFull: "f", cachedAt: t0, structure: "s", full: "f", now: t0.addingTimeInterval(30 * day))
          && MoodleCourseAI.reuses(cachedStructure: "s", cachedFull: "f", cachedAt: t0, structure: "s", full: "g", now: t0.addingTimeInterval(3 * day))
          && !MoodleCourseAI.reuses(cachedStructure: "s", cachedFull: "f", cachedAt: t0, structure: "s", full: "g", now: t0.addingTimeInterval(8 * day))
          && !MoodleCourseAI.reuses(cachedStructure: "s", cachedFull: "f", cachedAt: t0, structure: "t", full: "f", now: t0)
          && !MoodleCourseAI.reuses(cachedStructure: nil, cachedFull: "f", cachedAt: t0, structure: "s", full: "f", now: t0),
          "réanalyse : structure nouvelle → toujours ; texte changé → au plus une fois par semaine ; rien → jamais")

    // L'accueil : la source lue d'après les messages de la chaîne.
    check(ImportFeed.source(ofMessage: "vidéos MediaSpace…") == "MediaSpace"
          && ImportFeed.source(ofMessage: "MOOC cité — lecture de Courseware…") == "MOOC"
          && ImportFeed.source(ofMessage: "rangement du cours…") == nil
          && ImportProgress.stage(forMessage: "vidéos MediaSpace…") == .sources
          && ImportProgress.stage(forMessage: "outils du cours : Explique…") == .sources,
          "MediaSpace et Explique sont lus pendant l'étape « sources », avant l'analyse")
}

print("== Temps d'étude : cours automatiques, exercices chronométrés (StudyTime) ==")
do {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    check(StudyTime.lectureSeconds(start: at(0), end: at(105), minus: []) == 105 * 60,
          "un cours de 1 h 45 compte 1 h 45 sans rien lancer")
    check(StudyTime.lectureSeconds(start: at(0), end: at(105), minus: [.init(start: at(30), end: at(60))]) == 75 * 60,
          "un chrono de 30 min pendant le cours n'est pas compté deux fois")
    check(StudyTime.lectureSeconds(start: at(0), end: at(105),
                                   minus: [.init(start: at(-10), end: at(40)), .init(start: at(20), end: at(50))]) == 55 * 60,
          "deux chronos qui se chevauchent ne retirent pas deux fois la même minute")
    check(StudyTime.lectureSeconds(start: at(0), end: at(24 * 60), minus: []) == 0,
          "une « séance » de 24 h (journée, échéance) ne compte pas comme cours")

    let course = Course(code: "MATH-101", name: "Analyse I")
    context.insert(course)
    let lecture = LinkedCalendarEvent(title: "Analyse I", startsAt: at(-3000), endsAt: at(-2895), kind: .lecture)
    lecture.course = course
    let exercises = LinkedCalendarEvent(title: "Analyse I", startsAt: at(-2880), endsAt: at(-2760), kind: .exerciseSession)
    exercises.course = course
    let chrono = StudySession(course: course, taskType: .exercise, startedAt: at(-2870), durationSeconds: 50 * 60)
    context.insert(lecture); context.insert(exercises); context.insert(chrono)
    let blocks = StudyTime.blocks(events: [lecture, exercises], sessions: [chrono])
    check(blocks.reduce(0) { $0 + $1.seconds } == (105 + 50) * 60,
          "séance d'exercices de 2 h : seules les 50 min chronométrées comptent ; le cours compte seul")
    check(blocks.contains { $0.taskType == "lecture" && $0.courseCode == "MATH-101" },
          "le cours part dans les groupes avec son code et la nature « lecture »")

    // Ce qui compte, au choix (StudyTime.Counting).
    var choice = StudyTime.Counting()
    choice.exerciseSessions = true
    check(StudyTime.total(StudyTime.blocks(events: [lecture, exercises], sessions: [chrono], counting: choice)) == (105 + 120) * 60,
          "séances d'exercices comptées : la séance de 2 h compte, le chrono qu'elle recouvre n'est pas doublé")
    choice = StudyTime.Counting(); choice.lectures = .confirmed
    check(StudyTime.total(StudyTime.lectureBlocks(events: [lecture], sessions: [], counting: choice)) == 0,
          "amphi « seulement confirmés » : un cours non confirmé ne compte pas")
    lecture.isAttended = true
    check(StudyTime.total(StudyTime.lectureBlocks(events: [lecture], sessions: [], counting: choice)) == 105 * 60,
          "amphi confirmé (« J'y étais ») : il compte")
    lecture.isAttended = false
    choice = StudyTime.Counting(); choice.lectures = .off; choice.timer = false
    let manual = StudySession(course: course, taskType: .theory, startedAt: at(-2000), durationSeconds: 1800, isManual: true)
    let amphiTimer = StudySession(course: course, taskType: .lecture, startedAt: at(-1900), durationSeconds: 1800)
    check(StudyTime.total(StudyTime.blocks(events: [lecture], sessions: [chrono, manual, amphiTimer], counting: choice)) == 1800,
          "sans amphi ni chrono : seule la saisie manuelle compte")
    let twin = LinkedCalendarEvent(title: "Analyse I", startsAt: at(-3000), endsAt: at(-2895), kind: .lecture)
    twin.course = course; context.insert(twin)
    check(StudyTime.total(StudyTime.lectureBlocks(events: [lecture, twin], sessions: [], counting: StudyTime.Counting())) == 105 * 60,
          "la même séance lue deux fois (horaire et calendrier) ne compte qu'une fois")
    let other = Course(code: "PHYS-101", name: "Physique"); context.insert(other)
    let otherTimer = StudySession(course: other, taskType: .exercise, startedAt: at(-3000), durationSeconds: 3600)
    check(StudyTime.total(StudyTime.lectureBlocks(events: [lecture], sessions: [otherTimer], counting: StudyTime.Counting())) == 45 * 60,
          "un chrono d'un autre cours pendant l'amphi : on n'était pas en amphi, il n'est pas doublé")
    course.isTracked = false
    check(StudyTime.lectureBlocks(events: [lecture], sessions: [], counting: StudyTime.Counting()).isEmpty,
          "un cours retiré du suivi ne gonfle plus les heures")
    course.isTracked = true

    check(TimetableClassifier.kind(title: "🧠 MATH-111 — finir la série", location: "", hasCourse: true) == .study
          && TimetableClassifier.kind(title: "✓ [MATH-101] Série 2", location: "", hasCourse: true) == .study,
          "un bloc personnel qui cite un cours n'est pas un cours (ni une séance d'exercices)")
    check(TimetableClassifier.kind(title: "[CS-107] Rendu mini-projet 2 — 50 %", location: "", hasCourse: true) == .other
          && TimetableClassifier.kind(title: "[CS-107] Défense du projet noté", location: "", hasCourse: true) == .other,
          "une échéance n'est pas un cours")
    check(TimetableClassifier.kind(title: "Analyse I (classe inversée)", location: "CE1", hasCourse: true) == .lecture,
          "l'horaire EPFL reste un cours")
}

print("== Accueil : les cours lus sur Moodle (MoodleOnboarding) ==")
do {
    let refs = [
        MoodleCourseRef(id: 15221, fullname: "Analyse I (classe inversée) (MATH-101(pi))", shortname: "MATH-101(pi)"),
        MoodleCourseRef(id: 15272, fullname: "Algèbre linéaire (classe inversée) (MATH-111(pi))", shortname: "MATH-111(pi)"),
        MoodleCourseRef(id: 99, fullname: "Aide Moodle pour les étudiants", shortname: "AIDE-ETU"),
        MoodleCourseRef(id: 14847, fullname: "Introduction à la programmation", shortname: "CS-107"),
        MoodleCourseRef(id: 15000, fullname: "Analyse I (MATH-101(e))", shortname: "MATH-101(e)"),
        MoodleCourseRef(id: 18568, fullname: "CS-101 Advanced information, computation, communication I", shortname: "AICC-I")
    ]
    let planned = MoodleOnboarding.courses(from: refs)
    check(planned.map(\.code) == ["MATH-101", "MATH-111", "CS-107", "CS-101"],
          "les cours EPFL seulement, une fois chacun (deux sections Moodle du même cours → un cours)")
    check(planned.map(\.name) == ["Analyse I (classe inversée)", "Algèbre linéaire (classe inversée)",
                                  "Introduction à la programmation", "Advanced information, computation, communication I"],
          "noms nettoyés du code et de la section")
    check(planned[0].ref.id == 15221, "le cours garde **sa** page Moodle (la première inscription)")
}

print("== Dossiers Moodle dépliés (MoodleFolderExpander) ==")
do {
    let folder = MoodleActivity(id: "1377178", name: "Séries", module: "folder",
                                url: "https://moodle.epfl.ch/mod/folder/view.php?id=1377178")
    let base = "https://moodle.epfl.ch/pluginfile.php/1/mod_folder/content/0/"
    let files: [MoodleFolderExpander.File] = [
        .init(title: "Serie_01.pdf", url: base + "Serie_01.pdf"),
        .init(title: "Serie_02.pdf", url: base + "Serie_02.pdf"),
        .init(title: "Corrigé série 1.pdf", url: base + "Corrige_01.pdf"),
        .init(title: "", url: base + "S%C3%A9rie%2003.pdf"),
        .init(title: "Serie_02.pdf", url: base + "Serie_02.pdf"),
        .init(title: "Solution 7.pdf", url: base + "sol7.pdf")
    ]
    let out = MoodleFolderExpander.expand(folder, files: files)
    check(out.count == 4, "un dossier de 3 séries + 2 corrigés donne 4 éléments (doublon retiré, corrigé orphelin gardé)")
    check(out.map(\.name) == ["Serie 01", "Serie 02", "Série 03", "Solution 7"],
          "noms lisibles, tirés du fichier quand le lien n'a pas de texte (accents décodés)")
    check(out[0].solutionTarget == base + "Corrige_01.pdf" && out[1].solutionTarget == nil,
          "le corrigé rejoint l'énoncé du même numéro")
    check(out.allSatisfy { $0.module == "resource" && $0.destination == "pdf" && $0.target?.hasPrefix(base) == true }
          && Set(out.map(\.id)).count == 4, "chaque fichier devient un PDF à part, d'identifiant unique")
    check(MoodleFolderExpander.expand(folder, files: [files[0], files[2]]) == [folder],
          "un dossier d'un énoncé et de son corrigé reste tel quel")
    check(MoodleFolderExpander.number(in: .init(title: "ex03_2026.pdf", url: "x")) == 3
          && MoodleFolderExpander.number(in: .init(title: "Week-12 exercises", url: "x")) == 12,
          "numéro de série lu dans « ex03_2026 » et « Week-12 », pas l'année")
}

print("== Entraide chiffrée de bout en bout (GroupCrypto) ==")
do {
    let group = "56B0C700-8B2E-4D63-A661-7CDB3E9B026F"
    let alice = Curve25519.KeyAgreement.PrivateKey()
    let bob = Curve25519.KeyAgreement.PrivateKey()
    let eve = Curve25519.KeyAgreement.PrivateKey()
    let key = GroupCrypto.newGroupKey()

    let sealed = try GroupCrypto.seal("Je bloque sur 4.3 (b) — l'intégrale ∫ diverge ?", key: key, groupID: group, authorID: "a1")
    check(sealed.hasPrefix("v1:") && !sealed.contains("bloque"), "le message part chiffré, versionné, sans texte lisible")
    check((try? GroupCrypto.open(sealed, key: key, groupID: group.lowercased(), authorID: "A1")) == "Je bloque sur 4.3 (b) — l'intégrale ∫ diverge ?",
          "déchiffré à l'identique, accents et symboles compris (identifiants insensibles à la casse)")
    check((try? GroupCrypto.open(sealed, key: key, groupID: group, authorID: "b2")) == nil,
          "recollé sous le nom d'un autre auteur : refusé")
    check((try? GroupCrypto.open(sealed, key: key, groupID: "autre-groupe", authorID: "a1")) == nil,
          "recollé dans un autre groupe : refusé")
    check((try? GroupCrypto.open(sealed, key: GroupCrypto.newGroupKey(), groupID: group, authorID: "a1")) == nil,
          "une autre clé ne l'ouvre pas")
    check(GroupCrypto.keyID(of: key) == GroupCrypto.keyID(of: GroupCrypto.decodeKey(GroupCrypto.encode(key))!)
          && GroupCrypto.keyID(of: key).count == 16, "l'identifiant de clé est stable et court")

    let envelope = try GroupCrypto.wrap(key, from: alice, to: bob.publicKey, groupID: group)
    let opened = try? GroupCrypto.unwrap(envelope, with: bob, from: alice.publicKey, groupID: group)
    check(opened.map(GroupCrypto.keyID) == GroupCrypto.keyID(of: key), "Bob ouvre l'enveloppe qu'Alice lui a scellée")
    check((try? GroupCrypto.unwrap(envelope, with: eve, from: alice.publicKey, groupID: group)) == nil,
          "Ève, qui lit la base, ne l'ouvre pas")
    check((try? GroupCrypto.unwrap(envelope, with: bob, from: alice.publicKey, groupID: "autre")) == nil,
          "une enveloppe ne sert que pour son groupe")
    let pk = GroupCrypto.publicKeyString(bob.publicKey)
    check(pk.count == 44 && GroupCrypto.publicKey(from: pk)?.rawRepresentation == bob.publicKey.rawRepresentation,
          "clé publique publiée en base64 (44 caractères, accepté par la contrainte SQL)")

    let missing = GroupCrypto.missingRecipients(memberIDs: ["a", "b", "c"],
                                                publicKeys: [("a", "KA"), ("b", "KB"), ("b", "KB2"), ("x", "KX"), ("b", "KB")],
                                                servedKeys: ["KA"])
    check(missing.map(\.key) == ["KB", "KB2"],
          "distribution : seules les clés de membres non servies, sans doublon ni ancien membre")
} catch {
    check(false, "GroupCrypto a levé : \(error)")
}

// MARK: Nouveautés Moodle (notifications)
do {
    func activity(_ id: String, _ name: String, _ module: String = "resource", visible: Bool = true) -> MoodleActivity {
        MoodleActivity(id: id, name: name, module: module, url: "https://moodle.epfl.ch/mod/\(module)/view.php?id=\(id)",
                       isVisible: visible)
    }
    func snapshot(_ week: [MoodleActivity]) -> MoodleCourseSnapshot {
        MoodleCourseSnapshot(title: "Analyse I", url: "https://moodle.epfl.ch/course/view.php?id=1",
                             sections: [MoodleSection(number: 0, title: "Général", activities: [activity("1", "Forum", "forum")]),
                                        MoodleSection(number: 3, title: "Semaine 3", activities: week)])
    }
    let before = snapshot([activity("10", "Série 3"), activity("11", "Corrigé série 3", visible: false)])
    let first = MoodleNews.diff(before, known: nil)
    check(first.new.isEmpty && first.seen == ["10"], "premier relevé : tout est retenu, rien n'est annoncé (le forum et le caché exclus)")

    let after = snapshot([activity("10", "Série 3"), activity("11", "Corrigé série 3"),
                          activity("12", "Série 4"), activity("13", "Rendu 2", "assign"), activity("14", "Annonces", "forum")])
    let second = MoodleNews.diff(after, known: first.seen)
    check(second.new.map(\.id) == ["11", "12", "13"], "corrigé dévoilé, nouvelle série et nouveau rendu annoncés")
    check(second.new.map(\.kind) == [.solution, .series, .deadline], "chaque nouveauté rangée : corrigé, série, rendu")
    check(MoodleNews.diff(before, known: second.seen).new.isEmpty, "une activité cachée de nouveau n'est pas réannoncée")

    check(MoodleNews.message(courseCode: "MATH-101", items: [second.new[1]])! == ("Nouvelle série · MATH-101", "Série 4"),
          "une nouveauté : son genre en titre, son nom en texte")
    let many = MoodleNews.message(courseCode: "MATH-101", items: second.new + [second.new[0]])!
    check(many.title == "4 nouveautés · MATH-101" && many.body.hasSuffix(" · +1"), "plusieurs : le compte, trois noms, le reste")
    check(MoodleNews.message(courseCode: "X", items: []) == nil, "rien de neuf, pas de notification")

    check(MoodleNews.Kind.decode(nil) == MoodleNews.Kind.defaults, "par défaut : séries, corrigés, rendus")
    check(MoodleNews.Kind.decode("") == [], "tout décoché reste tout décoché")
    check(MoodleNews.Kind.decode(MoodleNews.Kind.encode([.lecture, .series])) == [.lecture, .series], "le choix se relit")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
    func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 30))!
    }
    check(MoodleNews.deliveryDate(now: at(3, 14), quietStart: 22, quietEnd: 8, calendar: calendar) == nil, "l'après-midi : tout de suite")
    check(MoodleNews.deliveryDate(now: at(3, 23), quietStart: 22, quietEnd: 8, calendar: calendar)
          == calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 8)), "23 h 30 : le lendemain à 8 h")
    check(MoodleNews.deliveryDate(now: at(4, 3), quietStart: 22, quietEnd: 8, calendar: calendar)
          == calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 8)), "3 h 30 : à 8 h le jour même")
    check(MoodleNews.deliveryDate(now: at(3, 13), quietStart: 12, quietEnd: 14, calendar: calendar) != nil, "fenêtre en journée respectée")
    check(MoodleNews.deliveryDate(now: at(3, 23), quietStart: 8, quietEnd: 8, calendar: calendar) == nil, "début = fin : pas d'heures calmes")
}

// MARK: Hors ligne : ordre et plafond
do {
    func C(key: String, week: Int, isSolution: Bool, current: Int = 4) -> OfflinePlan.Candidate {
        OfflinePlan.Candidate(key: key, week: week, isSolution: isSolution, currentWeek: current)
    }
    let all = [C(key: "s1", week: 1, isSolution: false), C(key: "c1", week: 1, isSolution: true),
               C(key: "s4", week: 4, isSolution: false), C(key: "c4", week: 4, isSolution: true),
               C(key: "s5", week: 5, isSolution: false), C(key: "s3", week: 3, isSolution: false),
               C(key: "s9", week: 9, isSolution: false), C(key: "s4", week: 4, isSolution: false)]
    let ordered = OfflinePlan.order(all, includeSolutions: true).map(\.key)
    check(ordered == ["s4", "c4", "s5", "s3", "s1", "c1", "s9"],
          "semaine en cours puis suivante, l'énoncé avant le corrigé, le passé récent, le futur lointain ; sans doublon")
    let mixed = OfflinePlan.order([C(key: "a3", week: 3, isSolution: false), C(key: "b6", week: 6, isSolution: false, current: 6)],
                                  includeSolutions: true).map(\.key)
    check(mixed == ["b6", "a3"], "deux cours : la semaine en cours de chacun passe avant le passé de l'autre")
    check(!OfflinePlan.order(all, includeSolutions: false).contains { $0.isSolution }, "corrigés exclus si non voulus")
    let sizes = ["s4": 40, "c4": 30, "s5": 20, "s3": 50, "s1": 5]
    check(OfflinePlan.kept(ordered, sizes: sizes, limit: 100) == ["s4", "c4", "s5"],
          "plafond : on s'arrête au premier qui dépasse, l'ordre reste respecté")
    check(OfflinePlan.kept(ordered, sizes: [:], limit: 100).isEmpty, "rien de téléchargé, rien de gardé")
}

// MARK: iCloud : fusion des doublons
do {
    let dupContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let ctx = ModelContext(dupContainer)
    // Deux appareils ont importé le même semestre et le même cours, chacun de son côté.
    let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let termA = AcademicTerm(year: 2026, season: .autumn, startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 1))
    let termB = AcademicTerm(year: 2026, season: .autumn, startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 1))
    let a = Course(id: idB, code: "CS-250", name: "Algorithms I", credits: 6)   // identifiant plus grand
    let b = Course(id: idA, code: "cs-250", name: "Algorithms I", credits: 6)   // gardé : plus petit
    a.term = termA; b.term = termB
    a.isTracked = true
    a.contentSources = ["https://moodle.epfl.ch/course/view.php?id=1"]
    [termA, termB].forEach(ctx.insert); [a, b].forEach(ctx.insert)
    let sa = ExerciseSeries(course: a, seriesNumber: 1); let sb = ExerciseSeries(course: b, seriesNumber: 1)
    let sb2 = ExerciseSeries(course: b, seriesNumber: 2)
    let a11 = Exercise(series: sa, exerciseNumber: "1.1"); let a12 = Exercise(series: sa, exerciseNumber: "1.2")
    let b11 = Exercise(series: sb, exerciseNumber: "1.1"); let b12 = Exercise(series: sb, exerciseNumber: "1.2")
    let b21 = Exercise(series: sb2, exerciseNumber: "2.1")
    let early = Date(timeIntervalSince1970: 1_000_000), late = Date(timeIntervalSince1970: 2_000_000)
    a11.doneAt = late; a11.correctedAt = early; a11.correctness = .wrong; a11.redoRequired = true
    b11.doneAt = early; b11.correctedAt = late; b11.correctness = .correct
    b12.doneAt = late
    [sa, sb, sb2].forEach(ctx.insert); [a11, a12, b11, b12, b21].forEach(ctx.insert)
    let sessA = StudySession(course: a, taskType: .exercise, startedAt: early, durationSeconds: 600)
    let sessB = StudySession(course: b, taskType: .exercise, startedAt: late, durationSeconds: 900)
    sessB.exercise = b12
    let ankiA = StudySession(course: a, taskType: .flashcards, startedAt: early, durationSeconds: 300)
    let ankiB = StudySession(course: b, taskType: .flashcards, startedAt: early, durationSeconds: 300)
    ankiA.externalKey = "anki:42"; ankiB.externalKey = "anki:42"
    [sessA, sessB, ankiA, ankiB].forEach(ctx.insert)
    let m1 = AcademicMilestone(externalID: "epfl-rentree", title: "Rentrée", date: early, kind: .teachingStart)
    let m2 = AcademicMilestone(externalID: "epfl-rentree", title: "Rentrée", date: early, kind: .teachingStart)
    [m1, m2].forEach(ctx.insert)
    try ctx.save()

    let report = SyncDeduplicator.run(in: ctx)
    let courses = try ctx.fetch(FetchDescriptor<Course>())
    check(courses.count == 1 && courses[0].id == idA, "un seul CS-250, le même gardé sur chaque appareil (plus petit identifiant)")
    let kept = courses[0]
    check(try ctx.fetch(FetchDescriptor<AcademicTerm>()).count == 1 && kept.term != nil, "un seul semestre, le cours y reste rattaché")
    check(kept.isTracked && kept.contentSources.count == 1, "suivi et sources repris de l'autre copie")
    check(kept.series.count == 2, "séries fusionnées par numéro, la série 2 rapatriée (\(kept.series.count))")
    let s1 = kept.series.first { $0.seriesNumber == 1 }!
    check(s1.exercises.count == 2, "exercices fusionnés par numéro (\(s1.exercises.count))")
    let e11 = s1.exercises.first { $0.exerciseNumber == "1.1" }!
    let e12 = s1.exercises.first { $0.exerciseNumber == "1.2" }!
    check(e11.doneAt == early, "fait : la date la plus ancienne")
    check(e11.correctness == .correct && !e11.redoRequired && e11.correctedAt == late, "la correction la plus récente l'emporte, en bloc")
    check(e12.isDone, "un exercice fait d'un seul côté reste fait")
    let sessions = try ctx.fetch(FetchDescriptor<StudySession>())
    check(sessions.count == 3, "aucune session perdue ; la révision Anki relevée deux fois n'est comptée qu'une fois (\(sessions.count))")
    check(sessions.allSatisfy { $0.course?.id == idA }, "chaque session suit le cours gardé")
    check(sessB.exercise?.exerciseNumber == "1.2" && sessB.exercise?.series?.course?.id == idA, "une session garde sa cible, fusionnée elle aussi")
    check(try ctx.fetch(FetchDescriptor<AcademicMilestone>()).count == 1, "le calendrier de l'EPFL installé deux fois : une seule échéance")
    check(report.merged["cours"] == 1 && report.merged["sessions"] == 1, "compte rendu : \(report.summary)")
    check(SyncDeduplicator.run(in: ctx).total == 0, "deuxième passage : plus rien à fusionner")
} catch {
    check(false, "fusion iCloud : \(error)")
}

// MARK: Entre appareils : chrono partagé, Moodle relu une fois
do {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    var session = FocusTimerState(sessionStartedAt: t0, courseID: nil, taskTypeRaw: TaskType.exercise.rawValue)
    session.start(at: t0)
    func snap(_ state: FocusTimerState?, ended: Date? = nil, at: TimeInterval, device: String = "mac") -> CloudRelay.TimerSnapshot {
        CloudRelay.TimerSnapshot(state: state, endedSession: ended, updatedAt: t0.addingTimeInterval(at), device: device)
    }
    let now = t0.addingTimeInterval(120)
    check(CloudRelay.decide(local: nil, remote: snap(session, at: 1), lastApplied: nil, device: "iphone", now: now) == .adopt(session),
          "chrono démarré sur le Mac : l'iPhone le reprend")
    check(CloudRelay.decide(local: nil, remote: snap(session, at: 1, device: "iphone"), lastApplied: nil, device: "iphone", now: now) == .ignore,
          "son propre écho est ignoré")
    check(CloudRelay.decide(local: nil, remote: snap(session, at: 1), lastApplied: t0.addingTimeInterval(5), device: "iphone", now: now) == .ignore,
          "un état plus ancien que le dernier appliqué est ignoré")
    var paused = session; paused.pause(at: t0.addingTimeInterval(60))
    check(CloudRelay.decide(local: session, remote: snap(paused, at: 60), lastApplied: t0, device: "iphone", now: now) == .adopt(paused),
          "pause sur le Mac : même session, l'iPhone suit")
    check(CloudRelay.decide(local: session, remote: snap(nil, ended: t0, at: 90), lastApplied: t0, device: "iphone", now: now) == .close,
          "terminée sur le Mac : l'iPhone ferme sans enregistrer une seconde fois")
    var other = FocusTimerState(sessionStartedAt: t0.addingTimeInterval(30)); other.start(at: t0.addingTimeInterval(30))
    check(CloudRelay.decide(local: other, remote: snap(session, at: 60), lastApplied: t0, device: "iphone", now: now) == .ignore,
          "deux sessions différentes ne s'écrasent jamais")
    check(CloudRelay.decide(local: other, remote: snap(nil, ended: t0, at: 90), lastApplied: t0, device: "iphone", now: now) == .ignore,
          "la fin d'une autre session ne ferme pas la mienne")
    // Terminer puis relancer aussitôt sur l'iPhone : seule la nouvelle session arrive.
    var next = FocusTimerState(sessionStartedAt: t0.addingTimeInterval(100)); next.start(at: t0.addingTimeInterval(100))
    check(CloudRelay.decide(local: session, remote: snap(next, ended: t0, at: 101), lastApplied: t0, device: "iphone", now: now) == .adopt(next),
          "nouvelle session après avoir terminé la mienne ailleurs : elle remplace la mienne")
    check(CloudRelay.decide(local: session, remote: snap(next, at: 101), lastApplied: t0, device: "iphone", shared: t0, now: now) == .adopt(next),
          "ma session était partagée et l'autre appareil en a lancé une plus récente : il l'a fermée")
    check(CloudRelay.decide(local: session, remote: snap(next, at: 101), lastApplied: t0, device: "iphone", now: now) == .ignore,
          "session jamais partagée : une autre session ne l'écrase pas")
    // L'iPhone a dormi pendant trois sessions du Mac : la sienne est dans la liste des fermées.
    var several = snap(next, ended: t0.addingTimeInterval(50), at: 101)
    several.endedSessions = [t0.addingTimeInterval(50), t0.addingTimeInterval(20), t0]
    check(CloudRelay.decide(local: session, remote: several, lastApplied: t0, device: "iphone", now: now) == .adopt(next),
          "plusieurs sessions fermées pendant que l'iPhone dormait : il reconnaît la sienne et suit")
    var closedOld = snap(nil, ended: t0.addingTimeInterval(50), at: 101)
    closedOld.endedSessions = [t0.addingTimeInterval(50), t0]
    check(CloudRelay.decide(local: session, remote: closedOld, lastApplied: t0, device: "iphone", now: now) == .close,
          "sa session figure parmi les fermées : il la ferme")
    check(CloudRelay.decide(local: next, remote: snap(session, at: 101), lastApplied: t0, device: "iphone", shared: t0.addingTimeInterval(100), now: now) == .ignore,
          "une session plus ancienne ne remplace jamais une plus récente")

    // Voie instantanée : même canal et même clé sur chaque appareil, contenu illisible sans la clé.
    check(TimerLink.channel(for: "_abc") == TimerLink.channel(for: "_abc") && TimerLink.channel(for: "_abc") != TimerLink.channel(for: "_abd"),
          "le canal se déduit de l'identité iCloud, pareil partout")
    check(!TimerLink.channel(for: "_abc").contains("abc"), "le nom du canal ne révèle pas l'identité")
    let sealedSnap = snap(paused, ended: t0, at: 42)
    if let sealed = TimerLink.seal(sealedSnap, key: TimerLink.key(for: "_abc")) {
        check(TimerLink.open(sealed, key: TimerLink.key(for: "_abc")) == sealedSnap, "chiffré puis déchiffré : le même état")
        check(TimerLink.open(sealed, key: TimerLink.key(for: "_autre")) == nil, "une autre clé ne lit rien")
    } else {
        check(false, "chiffrement du lien")
    }

    let viaKVS = snap(nil, ended: t0, at: 10)
    let viaBase = snap(session, at: 20, device: "iphone")
    let mine = snap(session, at: 30, device: "mac-self")
    check(CloudRelay.newest([viaKVS, viaBase, mine], excluding: "mac-self") == viaBase,
          "deux voies (clé-valeur, base) : le plus récent des autres appareils fait foi")
    let hour: TimeInterval = 3600
    check(CloudRelay.refreshIsDue(localLast: nil, claim: nil, device: "a", interval: 12 * hour, now: t0), "jamais relu : à faire")
    check(!CloudRelay.refreshIsDue(localLast: nil, claim: .init(at: t0.addingTimeInterval(-hour), device: "b"), device: "a", interval: 12 * hour, now: t0),
          "relu par l'iPad il y a une heure : l'iPhone ne relit pas")
    check(CloudRelay.refreshIsDue(localLast: nil, claim: .init(at: t0.addingTimeInterval(-13 * hour), device: "b"), device: "a", interval: 12 * hour, now: t0),
          "relu ailleurs il y a 13 h : à refaire")
    check(!CloudRelay.refreshIsDue(localLast: t0.addingTimeInterval(-hour), claim: nil, device: "a", interval: 12 * hour, now: t0),
          "relu ici il y a une heure : pas encore")
    let merged = CloudRelay.mergeKnown(["1": ["a", "b"]], ["1": ["b", "c"], "2": ["x"]])
    check(merged == ["1": ["a", "b", "c"], "2": ["x"]], "activités vues : union de tous les appareils")
}

// MARK: Session de groupe : l'horloge commune, le travail à soi
do {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var host = FocusTimerState(sessionStartedAt: start, pomodoro: true)
    host.cycle = PomodoroSettings(focusMinutes: 50, shortBreakMinutes: 10)
    host.start(at: start)
    let clock = GroupClock(host)
    let link = GroupSessionLink(sessionID: "s", groupID: "g", groupName: "BA3")
    let joinedAt = start.addingTimeInterval(20 * 60)
    let course = UUID()
    var joiner = clock.joining(link: link, courseID: course, taskTypeRaw: TaskType.exercise.rawValue, targetID: nil, at: joinedAt)
    check(joiner.blockEndDate(settings: joiner.cycle(or: PomodoroSettings())) == host.blockEndDate(settings: host.cycle!),
          "le membre qui rejoint finit le bloc au même instant que l'hôte")
    let end = start.addingTimeInterval(45 * 60)
    let own = joiner.allocatedSeconds(at: end).filter { $0.segment.excluded != true }
    check(own.reduce(0) { $0 + $1.seconds } == 25 * 60 && own.allSatisfy { $0.segment.courseID == course },
          "seul le temps depuis son arrivée est à lui (25 min sur 45), sur son cours")
    var paused = host
    paused.pause(at: start.addingTimeInterval(30 * 60))
    GroupClock(paused).apply(to: &joiner)
    check(!joiner.isRunning && joiner.courseID == course && joiner.groupSession == link,
          "une pause de l'hôte arrête le chrono du membre, qui garde son cours et son lien")
}

// MARK: Pluriels : la règle de la langue
check(Plural.usesSingular(0, language: "fr") && Plural.usesSingular(1, language: "fr") && !Plural.usesSingular(2, language: "fr"),
      "français : 0 et 1 au singulier")
check(!Plural.usesSingular(0, language: "en") && Plural.usesSingular(1, language: "en"), "anglais : seul 1 au singulier")

// MARK: Chrono partagé : le cycle Pomodoro voyage avec la session
do {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let mac = PomodoroSettings(focusMinutes: 50, shortBreakMinutes: 10)
    let phone = PomodoroSettings(focusMinutes: 25, shortBreakMinutes: 5)
    var session = FocusTimerState(sessionStartedAt: start, pomodoro: true)
    session.cycle = mac
    session.start(at: start)
    // L'iPhone (25/5) lit la session démarrée sur le Mac (50/10) : même fin de bloc.
    check(session.blockEndDate(settings: session.cycle(or: phone)) == start.addingTimeInterval(50 * 60),
          "le bloc finit à 50 min sur les deux appareils, pas à 25 sur l'iPhone")
    var onPhone = session
    let events = onPhone.advance(settings: onPhone.cycle(or: phone), to: start.addingTimeInterval(30 * 60))
    check(events.isEmpty && onPhone.isRunning, "à 30 min, l'iPhone ne coupe pas le bloc du Mac")
    let encoded = try! JSONEncoder().encode(session)
    check((try? JSONDecoder().decode(FocusTimerState.self, from: encoded))?.cycle == mac, "le cycle est publié avec l'état")
    var old = session
    old.cycle = nil
    let legacy = try! JSONEncoder().encode(old)
    check((try? JSONDecoder().decode(FocusTimerState.self, from: legacy))?.cycle(or: phone) == phone,
          "un état d'avant (sans cycle) prend les réglages de l'appareil")
}

// MARK: Avec mesure (Claude Code) — les mêmes cas que ClaudePlugin/mesure/hooks/policy.test.ts
do {
    print("== Avec mesure : temps de Claude Code et règles ==")
    typealias CM = ClaudeMeasure
    let cal = Calendar.current
    func at(_ h: Int, _ m: Int = 0, day: Int = 27) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }
    func ms(_ d: Date) -> Double { CM.ms(d) }
    let minute = 60_000.0
    func session(_ id: String, _ category: CM.Category, _ marks: [(Double, CM.EventKind)], headless: Bool = false) -> CM.SessionRecord {
        CM.SessionRecord(session: id, cwd: "/x", category: category, headless: headless,
                         events: marks.map { CM.Event(t: $0.0, k: $0.1) }, blocks: [])
    }
    let studied = CM.Studied(day: "2026-10-27", seconds: 4 * 3600, accumulated: 0, runningSince: nil)
    func policy(_ rules: CM.Rules = .standard, _ context: CM.Context? = nil, enforceFrom: Double = 0) -> CM.Policy {
        CM.Policy(writtenAt: 0, enabled: true, enforceFrom: enforceFrom, rules: rules, pending: nil,
                  context: context ?? CM.Context(studyMode: nil, classes: [], studied: studied))
    }
    let none = CM.Usage()

    // Le temps compté : une réponse longue plafonnée, une absence oubliée.
    let t0 = ms(at(14))
    let long = session("a", .projets, [(t0, .s), (t0 + minute, .p), (t0 + 3 * minute, .d), (t0 + 6 * minute, .p),
                                       (t0 + 40 * minute, .d), (t0 + 60 * minute, .p), (t0 + 61 * minute, .d), (t0 + 62 * minute, .e)])
    let counted = CM.intervals(long, from: ms(at(0)), to: ms(at(0, day: 28)), now: t0 + 70 * minute, live: false)
        .reduce(0) { $0 + $1.end - $1.start }
    check(counted == 28 * minute, "mesure : 1 + 2 + 3 + 20 (plafond) + 0 (absence) + 1 + 1 = 28 min (obtenu \(counted / minute))")

    // Deux terminaux en même temps : une seule fois.
    let t1 = ms(at(15))
    let a = session("a", .projets, [(t1, .p), (t1 + 10 * minute, .d), (t1 + 11 * minute, .e)])
    let b = session("b", .projets, [(t1 + 5 * minute, .p), (t1 + 12 * minute, .d), (t1 + 12 * minute, .e)])
    check(CM.usage([a, b], now: CM.date(t1 + 30 * minute), rules: .standard).projets == 12 * 60,
          "mesure : deux terminaux en même temps ne comptent qu'une fois")
    let live = session("a", .projets, [(ms(at(16)), .p), (ms(at(16, 2)), .d)])
    check(CM.usage([live], now: at(16, 5), rules: .standard, liveSession: "a").projets == 5 * 60
          && CM.usage([live], now: at(16, 5), rules: .standard).projets == 2 * 60,
          "mesure : la frappe en cours compte pour la séance vivante seulement")
    check(CM.usage([session("h", .projets, [(t1, .p), (t1 + 30 * minute, .d)], headless: true)], now: at(16), rules: .standard).projets == 0,
          "mesure : une séance sans clavier (claude -p) ne compte pas")

    // Couvre-feu, classement.
    let curfew = CM.Curfew(start: "23:30", end: "07:00")
    check(CM.curfewEnd(curfew, now: at(23, 45)) == at(7, day: 28) && CM.curfewEnd(curfew, now: at(6)) == at(7)
          && CM.curfewEnd(curfew, now: at(12)) == nil, "mesure : le couvre-feu passe minuit")
    let home = "/Users/eleve"
    check(CM.categorize("\(home)/EPFL/AICC", rules: .standard, home: home) == .etude
          && CM.categorize("\(home)/EPFLX", rules: .standard, home: home) == .projets
          && CM.categorize("\(home)/Prog/studytrack", rules: .standard, home: home) == .projets,
          "mesure : ~/EPFL est l'étude, ~/EPFLX non, le reste est projets")
    var free = CM.Rules.standard
    free.freeFolders = ["~/Notes"]
    check(CM.categorize("\(home)/Notes/x", rules: free, home: home) == .libre, "mesure : un dossier libre est exempté")

    // Les règles, dans l'ordre.
    var spent = none
    spent.projets = 95 * 60
    let budget = CM.evaluate(.projets, headless: false, policy: policy(), use: spent, passes: [], now: at(15))
    check(!budget.allow && budget.rule == .budget && budget.passable && budget.message.contains("/mesure encore"),
          "mesure : budget atteint → bloqué, un pass possible")
    let pass = CM.Pass(at: ms(at(14, 55)), from: ms(at(14, 57)), until: ms(at(15, 12)), reason: "finir le correctif", rule: .budget, session: "a")
    let withPass = CM.evaluate(.projets, headless: false, policy: policy(), use: spent, passes: [pass], now: at(15))
    check(withPass.allow && (withPass.warn ?? "").contains("Pass ouvert"), "mesure : un pass ouvert lève le budget")
    check(CM.evaluate(.etude, headless: false, policy: policy(), use: spent, passes: [], now: at(15)).allow,
          "mesure : l'étude n'a pas de budget")
    var near = none
    near.projets = 75 * 60
    let warned = CM.evaluate(.projets, headless: false, policy: policy(), use: near, passes: [], now: at(15))
    check(warned.allow && warned.remainingMinutes == 15 && (warned.warn ?? "").contains("Projets"), "mesure : près du budget, une alerte")
    let lesson = CM.Context(studyMode: nil, classes: [CM.Lesson(start: ms(at(14)), end: ms(at(16)), title: "AICC")], studied: studied)
    let inClass = CM.evaluate(.projets, headless: false, policy: policy(.standard, lesson), use: none, passes: [], now: at(15))
    check(inClass.rule == .lesson && !inClass.passable, "mesure : pendant un cours, bloqué sans pass")
    let mode = CM.StudyModeInfo(since: ms(at(14)), until: ms(at(16)), blocks: true, locks: false)
    check(CM.evaluate(.projets, headless: false, policy: policy(.standard, CM.Context(studyMode: mode, classes: [], studied: studied)),
                      use: none, passes: [], now: at(15)).rule == .studyMode, "mesure : mode étude → les projets attendent")
    var locked = mode
    locked.locks = true
    let lockCtx = CM.Context(studyMode: locked, classes: [], studied: studied)
    check(CM.evaluate(.libre, headless: false, policy: policy(.standard, lockCtx), use: none, passes: [], now: at(15)).rule == .lock
          && CM.evaluate(.etude, headless: false, policy: policy(.standard, lockCtx), use: none, passes: [], now: at(15)).allow,
          "mesure : le verrou ferme aussi le libre, pas l'étude")
    let early = CM.Context(studyMode: nil, classes: [],
                           studied: CM.Studied(day: "2026-10-27", seconds: 20 * 60, accumulated: 5 * 60, runningSince: ms(at(14, 50))))
    let first = CM.evaluate(.projets, headless: false, policy: policy(.standard, early), use: none, passes: [], now: at(15))
    check(first.rule == .studyFirst && first.message.contains("25 min"), "mesure : d'abord étudier (35 min sur 60, encore 25)")
    let stale = CM.Context(studyMode: nil, classes: [], studied: CM.Studied(day: "2026-10-26", seconds: 0, accumulated: 0, runningSince: nil))
    check(CM.evaluate(.projets, headless: false, policy: policy(.standard, stale), use: none, passes: [], now: at(15)).allow
          && CM.evaluate(.projets, headless: false, policy: policy(.standard, .empty), use: none, passes: [], now: at(15)).allow,
          "mesure : temps étudié inconnu (Polymestre fermé) → « d'abord étudier » ne bloque pas")
    check(CM.evaluate(.projets, headless: false, policy: policy(), use: none, passes: [], now: at(23, 50)).rule == .curfew
          && CM.evaluate(.etude, headless: false, policy: policy(), use: none, passes: [], now: at(23, 50)).allow,
          "mesure : couvre-feu pour les projets, pas pour l'étude")
    var all = CM.Rules.standard
    all.curfewAll = true
    check(CM.evaluate(.etude, headless: false, policy: policy(all), use: none, passes: [], now: at(23, 50)).rule == .curfew,
          "mesure : couvre-feu « tout »")
    var marks: [(Double, CM.EventKind)] = []
    for i in 0..<12 { marks += [(t0 + Double(i) * 5 * minute, .p), (t0 + Double(i) * 5 * minute + 4 * minute, .d)] }
    let run = CM.usage([session("a", .projets, marks)], now: CM.date(t0 + 60 * minute), rules: .standard)
    let paused = CM.evaluate(.projets, headless: false, policy: policy(), use: run, passes: [], now: CM.date(t0 + 60 * minute))
    check(paused.rule == .pause && paused.until == CM.date(t0 + 69 * minute), "mesure : pause de 10 min après 59 min d'affilée")
    check(CM.usage([session("a", .projets, marks)], now: CM.date(t0 + 70 * minute), rules: .standard).streak == nil,
          "mesure : dix minutes sans rien, la série est finie")
    var lots = none
    lots.projets = 200 * 60
    let observing = CM.evaluate(.projets, headless: false, policy: policy(enforceFrom: ms(at(16))), use: lots, passes: [], now: at(15))
    check(observing.allow && observing.observing && observing.message.hasPrefix("Observation"), "mesure : le jour d'observation ne bloque rien")
    check(CM.evaluate(.projets, headless: true, policy: policy(), use: lots, passes: [], now: at(15)).allow
          && CM.evaluate(.projets, headless: false, policy: nil, use: lots, passes: [], now: at(15)).allow,
          "mesure : sans clavier ou sans règles, jamais bloqué")

    // Le contrat de fichiers : des `null` écrits, et ce que le mod écrit se relit.
    var open = CM.Rules.standard
    open.budgetWeekday = nil
    open.curfew = nil
    let json = String(decoding: try! JSONEncoder().encode(policy(open)), as: UTF8.self)
    check(json.contains("\"budgetWeekday\":null") && json.contains("\"curfew\":null") && json.contains("\"pending\":null"),
          "mesure : « sans limite » s'écrit null (le mod ne le lirait pas absent)")
    let fromMod = #"{"v":1,"session":"s1","cwd":"/Users/eleve/Prog","category":"projets","headless":false,"events":[{"t":1793054518868,"k":"s"},{"t":1793054519000,"k":"p"}],"blocks":[{"t":1793054520000,"rule":"class"}]}"#
    let decoded = try? JSONDecoder().decode(CM.SessionRecord.self, from: Data(fromMod.utf8))
    check(decoded?.events.count == 2 && decoded?.blocks.first?.rule == .lesson, "mesure : une séance écrite par le mod se relit (« class » → cours)")
    let older = #"{"budgetWeekday":45}"#
    let partial = try? JSONDecoder().decode(CM.Rules.self, from: Data(older.utf8))
    check(partial?.budgetWeekday == 45 && partial?.curfew == CM.Rules.standard.curfew, "mesure : des règles incomplètes prennent les défauts")

    // Durcir tout de suite, assouplir le lendemain.
    check(CM.nextMorning(after: at(23, 45)) == at(4, day: 29) && CM.nextMorning(after: at(10)) == at(4, day: 28),
          "mesure : « le lendemain » = 4 h du matin, au moins 12 h plus tard")
    let start = CM.apply(desired: .standard, enabled: true, to: nil, now: at(23, 45))
    check(start.enabled && start.enforceFrom == ms(at(4, day: 29)), "mesure : mise en route → une journée d'observation")
    var running = start
    running.enforceFrom = 0
    var tighter = CM.Rules.standard
    tighter.budgetWeekday = 45
    let tightened = CM.apply(desired: tighter, enabled: true, to: running, now: at(15))
    check(tightened.rules.budgetWeekday == 45 && tightened.pending == nil, "mesure : durcir s'applique tout de suite")
    var looser = CM.Rules.standard
    looser.budgetWeekday = 240
    looser.curfew = CM.Curfew(start: "01:00", end: "06:00")
    let loosened = CM.apply(desired: looser, enabled: true, to: tightened, now: at(15))
    check(loosened.rules.budgetWeekday == 45 && loosened.rules.curfew == CM.Rules.standard.curfew
          && loosened.pending?.rules == looser && loosened.pending?.from == ms(at(4, day: 28)),
          "mesure : assouplir attend le lendemain à 4 h (la règle en vigueur reste la plus stricte)")
    var mixed = looser
    mixed.studyFirstWeekday = 90
    let both = CM.apply(desired: mixed, enabled: true, to: tightened, now: at(15))
    check(both.rules.studyFirstWeekday == 90 && both.rules.budgetWeekday == 45, "mesure : dans un même réglage, ce qui durcit vaut déjà")
    let again = CM.apply(desired: looser, enabled: true, to: loosened, now: at(18))
    check(again.pending?.from == loosened.pending?.from, "mesure : redemander n'avance ni ne repousse l'heure")
    let off = CM.apply(desired: .standard, enabled: false, to: running, now: at(15))
    check(off.enabled && off.pending?.enabled == false
          && !CM.evaluate(.projets, headless: false, policy: off, use: lots, passes: [], now: at(15)).allow
          && CM.evaluate(.projets, headless: false, policy: off, use: lots, passes: [], now: at(5, day: 28)).allow,
          "mesure : couper Avec mesure attend aussi le lendemain")
    let settled = CM.settle(loosened, now: at(5, day: 28))
    check(settled.rules == looser && settled.pending == nil, "mesure : à l'heure dite, l'assouplissement s'applique")
    var widened = CM.Rules.standard
    widened.studyFolders = ["~/EPFL", "~/Prog"]
    check(CM.apply(desired: widened, enabled: true, to: running, now: at(15)).rules.studyFolders == ["~/EPFL"],
          "mesure : ajouter un dossier d'étude est un assouplissement")

    // Le bilan d'un jour.
    let day = CM.summary(day: at(12), records: [a, b, long], passes: [pass], rules: .standard, now: at(20))
    // 26 min (14 h) + 12 min (15 h, trois séances qui se chevauchent : comptées une fois).
    check(day.day == "2026-10-27" && day.projets == 38 * 60 && day.passes == 1, "mesure : le bilan du jour (38 min, 1 pass)")
}

// MARK: Distribution (retour, mises à jour du Mac)
do {
    print("== Distribution : retour et mises à jour du Mac ==")
    let entry = LogEntry(id: UUID(), date: Date(timeIntervalSince1970: 2_000_000_000), level: .error,
                         category: "Sync", message: "a & b = c ?", detail: "ligne 1\nligne 2")
    let mail = FeedbackMail.url(to: "polymestre@example.ch", version: "2.1 (3)", device: "iPhone · iOS 27.0", entries: [entry])
    let text = mail?.absoluteString ?? ""
    check(text.hasPrefix("mailto:polymestre@example.ch?subject="), "retour : un lien mailto vers l'adresse configurée")
    let body = text.components(separatedBy: "&body=").last ?? ""
    check(!body.contains("&") && !body.contains("="), "retour : « & » et « = » du journal encodés (le corps n'est pas coupé)")
    check((body.removingPercentEncoding ?? "").contains("a & b = c ?") && (body.removingPercentEncoding ?? "").contains("2.1 (3)"),
          "retour : le journal et la version sont dans le corps")
    check((body.removingPercentEncoding ?? "").contains("\r\n"), "retour : fins de ligne CRLF (RFC 6068)")
    let many = (0..<500).map { _ in LogEntry(id: UUID(), date: Date(), level: .info, category: "x", message: String(repeating: "é", count: 80), detail: nil) }
    let long = FeedbackMail.url(to: "a@b.ch", version: "1", device: "Mac", entries: many)
    check(((long?.absoluteString.components(separatedBy: "&body=").last ?? "").removingPercentEncoding ?? "").count <= FeedbackMail.maxBody + 200,
          "retour : un long journal est tronqué")

    let json = #"{"version":"2.2","build":7,"url":"https://studytrack.hczr.ch/mac/Polymestre.dmg","notes":"Mise à jour"}"#
    let feed = MacUpdateFeed.decode(Data(json.utf8))
    check(feed?.build == 7 && feed?.version == "2.2", "mise à jour : le flux se lit")
    check(feed?.isNewer(thanBuild: "3") == true, "mise à jour : build 7 > 3 → proposée")
    check(feed?.isNewer(thanBuild: "7") == false && feed?.isNewer(thanBuild: "9") == false, "mise à jour : même build ou plus récente → rien")
    check(feed?.isNewer(thanBuild: nil) == false, "mise à jour : build inconnue → rien")
    check(MacUpdateFeed.decode(Data("<html>".utf8)) == nil, "mise à jour : une page d'erreur n'est pas un flux")
    let t = Date(timeIntervalSince1970: 2_000_000_000)
    check(MacUpdateFeed.isDue(lastCheck: nil, now: t), "mise à jour : jamais lue → à lire")
    check(!MacUpdateFeed.isDue(lastCheck: t.addingTimeInterval(-3600), now: t), "mise à jour : lue il y a une heure → pas encore")
    check(MacUpdateFeed.isDue(lastCheck: t.addingTimeInterval(-90_000), now: t), "mise à jour : lue hier → à relire")
    check(MacUpdateFeed.isDue(lastCheck: t.addingTimeInterval(3600), now: t), "mise à jour : horloge reculée → à relire")
}

// MARK: Mode étude
do {
    // Bloquer le reste : choisi pour une nouvelle installation, gardé pour qui
    // s'en servait avec l'ancien défaut, jamais réécrit une fois choisi.
    let suite = "polymestre.validation.blocking.\(UUID().uuidString)"
    let fresh = UserDefaults(suiteName: suite)!
    StudyMode.settleBlockingDefaults(["studyMode.blocking"], existingUser: false, in: fresh)
    check(fresh.object(forKey: "studyMode.blocking") as? Bool == false, "nouvelle installation : le mode étude ne bloque rien")
    StudyMode.settleBlockingDefaults(["studyMode.blocking"], existingUser: true, in: fresh)
    check(fresh.object(forKey: "studyMode.blocking") as? Bool == false, "un choix déjà écrit n'est pas réécrit")
    let existing = UserDefaults(suiteName: suite + ".existing")!
    StudyMode.settleBlockingDefaults(["mac.studyBlocking", "mac.studySystemLock"], existingUser: true, in: existing)
    check(existing.bool(forKey: "mac.studyBlocking") && existing.bool(forKey: "mac.studySystemLock"),
          "utilisateur d'avant : blocage et verrou système gardés")
    let chosen = UserDefaults(suiteName: suite + ".chosen")!
    chosen.set(false, forKey: "mac.studyBlocking")
    StudyMode.settleBlockingDefaults(["mac.studyBlocking"], existingUser: true, in: chosen)
    check(!chosen.bool(forKey: "mac.studyBlocking"), "utilisateur d'avant qui l'avait coupé : reste coupé")
    for name in [suite, suite + ".existing", suite + ".chosen"] { dropSuite(name) }
}
do {
    let t0 = Date(timeIntervalSince1970: 2_000_000_000)
    var state = FocusTimerState(sessionStartedAt: t0)
    state.start(at: t0)
    check(!StudyMode.isActive(state, at: t0), "sans date : pas de mode étude")
    state.studyUntil = t0.addingTimeInterval(50 * 60)
    check(StudyMode.isActive(state, at: t0.addingTimeInterval(60)), "pendant les 50 min : actif")
    check(!StudyMode.isActive(state, at: t0.addingTimeInterval(50 * 60)), "à l'échéance : levé")
    check(StudyMode.isOver(state, at: t0.addingTimeInterval(51 * 60)), "échéance passée, session ouverte : « terminé »")
    check(StudyMode.remaining(state, at: t0.addingTimeInterval(10 * 60)) == 40 * 60, "reste 40 min après 10")
    check(abs(StudyMode.progress(state, since: t0, at: t0.addingTimeInterval(25 * 60)) - 0.5) < 0.001, "à mi-chemin : 0,5")
    var entered = FocusTimerState(sessionStartedAt: t0)
    StudyMode.enter(&entered, minutes: 50, now: t0.addingTimeInterval(600))
    check(entered.studySince == t0.addingTimeInterval(600) && entered.studyUntil == t0.addingTimeInterval(600 + 3000),
          "entrer en cours de session : 50 min à partir de maintenant")
    check(abs(StudyMode.progress(entered, at: t0.addingTimeInterval(600 + 1500)) - 0.5) < 0.001, "l'anneau part du début du mode étude")
    StudyMode.leave(&entered)
    check(entered.studyUntil == nil && entered.studySince == nil && !StudyMode.isActive(entered), "sortir : plus de mode étude")
    check(StudyMode.extended(t0.addingTimeInterval(600), by: 25, now: t0) == t0.addingTimeInterval(600 + 1500),
          "prolonger avant la fin : à partir de la fin prévue")
    check(StudyMode.extended(t0, by: 25, now: t0.addingTimeInterval(300)) == t0.addingTimeInterval(300 + 1500),
          "prolonger après coup : à partir de maintenant")

    // Le mode étude voyage avec le chrono : un état sans le champ se relit.
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    if let data = try? encoder.encode(state), let back = try? decoder.decode(FocusTimerState.self, from: data) {
        check(back.studyUntil == state.studyUntil, "la fin du mode étude passe d'un appareil à l'autre")
    } else {
        check(false, "codage du mode étude")
    }
    let legacy = #"{"accumulated":0,"sessionStartedAt":0,"taskTypeRaw":"exercise","note":"","contextLabel":"","pomodoro":false}"#
    check((try? decoder.decode(FocusTimerState.self, from: Data(legacy.utf8)))?.studyUntil == nil,
          "un chrono d'une version précédente se relit, sans mode étude")
    var changed = state
    changed.studyUntil = nil
    check(changed != state, "lever le mode étude est un changement (publié aux autres appareils)")

    // Sites
    check(StudyMode.normalizedDomain("https://www.Moodle.EPFL.ch/my/?x=1") == "moodle.epfl.ch", "adresse → domaine")
    check(StudyMode.normalizedDomain("*.epfl.ch") == "epfl.ch", "joker → domaine")
    check(StudyMode.normalizedDomain("claude.ai:443") == "claude.ai", "port retiré")
    check(StudyMode.normalizedDomain("pas un site") == nil && StudyMode.normalizedDomain("") == nil, "texte libre refusé")
    let sites = StudyMode.defaultSites
    check(StudyMode.isAllowed(host: "moodle.epfl.ch", sites: sites), "Moodle permis")
    check(StudyMode.isAllowed(host: "botafogo.epfl.ch", sites: sites), "Botafogo permis")
    check(StudyMode.isAllowed(host: "courseware.epfl.ch", sites: sites), "Courseware permis")
    check(StudyMode.isAllowed(host: "claude.ai", sites: sites), "Claude permis")
    check(!StudyMode.isAllowed(host: "notepfl.ch", sites: sites), "un domaine qui finit pareil n'est pas permis")
    check(!StudyMode.isAllowed(host: "www.youtube.com", sites: sites), "YouTube bloqué par défaut")
    check(!StudyMode.isAllowed(host: "instagram.com", sites: sites), "Instagram bloqué")
    check(StudyMode.isAllowed(url: URL(string: "about:blank"), sites: sites), "page vide permise")
    check(!StudyMode.isAllowed(url: URL(string: "file:///etc/hosts"), sites: sites), "fichiers locaux refusés")
    check(!StudyMode.isAllowed(url: URL(string: "https://epfl.ch.evil.com/"), sites: sites), "faux sous-domaine refusé")

    // Apps (Mac)
    let apps = StudyMode.defaultMacApps
    check(!StudyMode.shouldBlock(bundleID: "com.goodnotesapp.x", isRegular: true, own: "me", allowed: apps), "GoodNotes permis")
    check(StudyMode.shouldBlock(bundleID: "com.apple.Safari", isRegular: true, own: "me", allowed: apps), "Safari bloqué (le navigateur du mode étude le remplace)")
    check(StudyMode.shouldBlock(bundleID: "com.spotify.client", isRegular: true, own: "me", allowed: apps), "Spotify bloqué")
    check(!StudyMode.shouldBlock(bundleID: "me", isRegular: true, own: "me", allowed: apps), "Polymestre jamais bloqué")
    check(!StudyMode.shouldBlock(bundleID: "com.apple.loginwindow", isRegular: true, own: "me", allowed: apps), "le système jamais bloqué")
    check(!StudyMode.shouldBlock(bundleID: "com.example.agent", isRegular: false, own: "me", allowed: apps), "un agent sans fenêtre n'est pas bloqué")
    check(!StudyMode.shouldBlock(bundleID: "com.anthropic.claudefordesktop.helper", isRegular: true, own: "me", allowed: apps),
          "l'assistant d'une app permise l'est avec elle")

    // Outils
    let tools = StudyMode.tools(courseName: "Analyse I", courseLinks: ["https://moodle.epfl.ch/course/view.php?id=1", "pas une url", "https://moodle.epfl.ch/course/view.php?id=1"])
    check(tools.first?.title == "Moodle du cours" && tools.filter { $0.id.hasPrefix("course:") }.count == 1,
          "outils : la page du cours d'abord, sans doublon ni lien invalide")
    check(tools.contains { $0.id == "claude-app" } && tools.contains { $0.id == "goodnotes" } && !tools.contains { $0.id == "claude" },
          "outils : l'app Claude et GoodNotes, plus claude.ai en site")
}

// MARK: Calculatrice du mode étude (MathEngine)
do {
    func calc(_ text: String, _ env: inout MathEngine.Environment) -> Double? { try? env.run(text) }
    var env = MathEngine.Environment()
    func near(_ a: Double?, _ b: Double, _ eps: Double = 1e-9) -> Bool { a.map { abs($0 - b) < eps } ?? false }
    check(near(calc("1 + 2 * 3", &env), 7), "priorités : 1 + 2·3 = 7")
    check(near(calc("2^3^2", &env), 512), "puissance à droite : 2^3^2 = 512")
    check(near(calc("-2^2", &env), -4), "−2² = −4 (l'exposant d'abord)")
    check(near(calc("(1+2)(3+4)", &env), 21), "multiplication implicite entre parenthèses")
    check(near(calc("2pi", &env), 2 * .pi), "2π implicite")
    check(near(calc("5!", &env), 120), "factorielle")
    check(near(calc("sin(pi/6)", &env), 0.5, 1e-12), "sin(π/6) = 1/2")
    check(near(calc("1e-3 * 2", &env), 0.002), "notation scientifique")
    check(near(calc("2e", &env), 2 * M_E), "2e = 2·e (pas une notation scientifique)")
    check(near(calc("ans + 1", &env), 2 * M_E + 1), "ans reprend le dernier résultat")
    check(near(calc("binom(5, 2)", &env), 10), "coefficient binomial")
    check(near(calc("max(3; 7; 2)", &env), 7), "le point-virgule sépare aussi les arguments")
    check(near(calc("a = 3", &env), 3) && near(calc("2a + 1", &env), 7), "variable nommée puis réutilisée")
    check(near(calc("a(a+1)", &env), 12), "a(a+1) : un produit, pas un appel")
    check(calc("f(x) = x^2 - 2", &env) == nil, "définir une fonction ne rend pas de valeur")
    check(near(calc("f(3)", &env), 7), "appeler une fonction définie")
    check(near(calc("f'(3)", &env), 6, 1e-6), "dérivée numérique : f'(3) = 6")
    check(near(calc("f''(1)", &env), 2, 1e-3), "dérivée seconde : f''(1) = 2")
    check(near(calc("int(f, 0, 3)", &env), 3, 1e-9), "intégrale de Simpson : ∫₀³ (x² − 2) dx = 3")
    check(near(calc("root(f, 0, 2)", &env), 2.squareRoot(), 1e-10), "racine par dichotomie : √2")
    check(MathEngine.roots("f", from: -3, to: 3, in: env).count == 2, "deux racines de x² − 2 sur [−3, 3]")
    check(calc("g(x) = 1/x", &env) == nil && MathEngine.roots("g", from: -1, to: 1, in: env).isEmpty,
          "une asymptote n'est pas une racine")
    check(MathEngine.sample("g", from: -1, to: 1, count: 5, in: env).count == 4, "le tracé saute la valeur indéfinie")
    check((try? env.run("sqrt(-1)")) == nil, "racine d'un négatif : erreur, pas NaN")
    check((try? env.run("1/0")) == nil, "division par zéro : erreur")
    check((try? env.run("2 +")) == nil && (try? env.run("zz + 1")) == nil, "syntaxe incomplète et nom inconnu refusés")
    check((try? env.run("pi = 3")) == nil, "une constante ne se redéfinit pas")
    env.degrees = true
    check(near(calc("sin(30)", &env), 0.5, 1e-12), "mode degrés")
    check(MathEngine.format(0.1 + 0.2) == "0.3" && MathEngine.format(42) == "42" && MathEngine.format(-0.0) == "0",
          "affichage : arrondi propre")
    check(MathEngine.format(6.02e23).contains("10^23"), "affichage : notation scientifique")
}

// MARK: La semaine relie la fiche (RevisionSheet.chapters(forPath:))
do {
    func entry(_ id: String, _ link: String) -> RevisionSheet.Entry { .init(id: id, kind: .theorem, title: id, body: "b", source: "", link: link) }
    let sheet = RevisionSheet(origin: .handout, generatedAt: Date(), chapters: [
        .init(id: "c0", title: "Suites", entries: [entry("a", "/handout/matiere/m_suites"), entry("b", "/handout/matiere/m_suites/cauchy")]),
        .init(id: "c1", title: "Limites", entries: [entry("c", "polymestre-poly:///handout/matiere/m_limites")]),
        .init(id: "c2", title: "Sans lien", entries: [entry("d", "")]),
    ])
    check(sheet.chapters(forPath: "/handout/matiere/m_suites").map(\.id) == ["c0"], "semaine : une section → son chapitre")
    check(sheet.chapters(forPath: "/handout/matiere/m_suites/cauchy/detail").map(\.id) == ["c0"], "semaine : une sous-section d'un renvoi → le chapitre")
    check(sheet.chapters(forPath: "/handout/matiere/m_limites").map(\.id) == ["c1"], "semaine : un lien de l'app est reconnu")
    check(sheet.chapters(forPath: "/handout/matiere/autre").isEmpty && sheet.chapters(forPath: "").isEmpty, "semaine : rien à relier")
}

// MARK: Le cadre du tuteur (TutorFramework)
do {
    typealias T = TutorFramework
    // Les numéros de page : le seul texte libre qu'on lit.
    check(T.pageRequest(in: "regarde page 4") == [4], "page : « regarde page 4 »")
    check(T.pageRequest(in: "regarde p. 4 et 5") == [4, 5], "page : « p. 4 et 5 »")
    check(T.pageRequest(in: "pages 3-5") == [3, 4, 5], "page : une plage")
    check(T.pageRequest(in: "p4") == [4], "page : « p4 »")
    check(T.pageRequest(in: "je bloque sur le 6.3") == [], "page : pas de page sans le mot")
    check(T.pageRequest(in: "map 3") == [], "page : un mot qui finit par p n'est pas une page")
    check(T.pageRequest(in: "pages 1-40").count == 1 || T.pageRequest(in: "pages 1-40") == [1], "page : une plage trop longue n'est pas dépliée")
    check(T.copyPageRequest(in: "regarde page 4") == [4], "copie : page 4 de la copie")
    check(T.copyPageRequest(in: "regarde la page 4 de la série") == [] && T.copyPageRequest(in: "page 4 du polycopié") == [],
          "copie : la page de la série ou du poly n'est pas dans le cahier")
    check(T.ranges([5, 3, 4, 9]) == "3–5, 9", "pages : plages")

    // L'état : le mot qui ne dit pas « pas essayé », l'indice suivant.
    var state = T.State(exercise: "Série 6 · Exercice 6.3", hintLevel: 1, questionsDone: 0, questionsTotal: 3,
                        copy: .init(notebook: "Séance Et Série 6", pagesSeen: [1, 2, 3, 4], total: 11))
    let card = T.card(state, attached: [.copy(notebook: "Séance Et Série 6", pages: [4], total: 11, requested: true)])
    check(card.hasPrefix(ClaudeTutor.contextOpen) && card.contains(ClaudeTutor.contextClose), "carte : dans le bloc que l'app retire")
    check(card.contains("pas encore marqué fait") && !card.contains("à faire"), "carte : « pas encore marqué fait », pas « à faire »")
    check(card.contains("jusqu'au niveau 1/4") && card.contains("niveau 2 (outil)"), "carte : le niveau suivant est dit")
    check(card.contains("mon écriture") && card.contains("pas un corrigé"), "carte : la copie est de l'étudiant·e")
    check(card.contains("celles que je te demande de regarder") && card.contains("1re page est la page 4"), "carte : la page demandée et sa numérotation")
    check(card.contains("pages que tu as déjà reçues : 1–4 sur 11"), "carte : les pages déjà reçues")
    check(card.split(separator: "\n").count <= 8, "carte : courte")
    check(ClaudeTutor.displayText(card + "et maintenant ?") == "et maintenant ?", "carte : retirée à l'affichage")
    check(T.exercise(inSent: card) == "Série 6 · Exercice 6.3" && T.shortExercise("Série 6 · Exercice 6.3") == "Exercice 6.3",
          "carte : l'exercice se relit (séparateurs d'une conversation reprise)")
    state.hintLevel = 0
    check(T.card(state).contains("Un premier indice est de niveau 1"), "carte : aucun indice → niveau 1")
    state.tutor = false
    check(!T.card(state).contains("niveau 1 (orientation)") && T.card(state).contains("explications"), "carte : mode explications")
    check(T.card(.init()).contains("pas d'exercice choisi") && T.exercise(inSent: T.card(.init())) == nil, "carte : sans exercice")
    check(T.chip(.copy(notebook: "N", pages: [4], total: 11, requested: true)) == "Ma copie · p. 4", "bulle : « Ma copie · p. 4 »")

    // Les gestes.
    check(T.hintPrompt(after: 0).contains("niveau 1") && T.hintPrompt(after: 1).contains("niveau 2") && T.hintPrompt(after: 2).contains("niveau 3")
          && T.hintPrompt(after: 3).contains("niveau 3"), "indice : un cran de plus (le 4 est « La solution »)")
    var s1 = T.State(exercise: "E", hintLevel: 0, copy: .init(notebook: "N", pagesSeen: [], total: 3))
    check(T.suggestions(s1, replyAsksQuestion: false).first == .hint(1), "propositions : d'abord l'indice 1")
    s1.hintLevel = 1
    check(T.suggestions(s1, replyAsksQuestion: false).first == .hint(2), "propositions : après l'indice 1, l'indice 2")
    check(T.suggestions(s1, replyAsksQuestion: true).first == .tryIt, "propositions : une question posée → à toi d'essayer")
    s1.hintLevel = 3
    check(T.suggestions(s1, replyAsksQuestion: false).contains(.solution) && !T.suggestions(s1, replyAsksQuestion: false).contains(.hint(4)),
          "propositions : après l'amorce, la solution")
    s1.copy = nil; s1.hintLevel = 0
    check(!T.suggestions(s1, replyAsksQuestion: false).contains(.check), "propositions : pas de vérification de copie sans copie")
    check(T.suggestions(.init(), replyAsksQuestion: false) == [.explain], "propositions : sans exercice, la notion")
    check(T.suggestions(s1, replyAsksQuestion: false).count <= 3, "propositions : trois au plus")
    check(T.asksQuestion("Quel X isole une colonne ?\n\n```polymestre\n6.3 | 1 | x\n```") && !T.asksQuestion("Voilà."), "réponse : finit sur une question")

    // Les règles de la consigne.
    let prompt = ClaudeTutor.systemPrompt(mode: .tutor)
    check(prompt.contains("Ne refuse jamais de lire") && prompt.contains("niveau **suivant**") && prompt.contains("une centaine de mots"),
          "consigne : copie à lui, indice suivant, brièveté")
    check(!ClaudeTutor.systemPrompt(mode: .explain).contains("Échelle d'indices"), "consigne : pas d'échelle en mode explications")
    // Pour rejouer une conversation avec la vraie consigne : POLYMESTRE_DUMP_PROMPT=/chemin ./validate.sh
    if let path = ProcessInfo.processInfo.environment["POLYMESTRE_DUMP_PROMPT"] {
        try? prompt.write(toFile: path, atomically: true, encoding: .utf8)
        try? T.card(.init(exercise: "Série 6 · Exercice 6.3", hintLevel: 1, questionsTotal: 0), attached: []).write(toFile: path + ".card1", atomically: true, encoding: .utf8)
    }

    // L'indice sans son mot-clé, vu en vrai (« 6.3 | 1 | … »), est noté.
    let bare = SeriesReview.parse("Quel X ?\n\n```polymestre\n6.3 | 1 | Choisis un X qui isole une colonne.\n```")
    check(bare.hints.count == 1 && bare.hints[0].exercise == "6.3" && bare.hints[0].level == 1, "indice : « 6.3 | 1 | … » sans le mot indice")
    let keyed = SeriesReview.parse("```polymestre\nindice 6.3 | 2 | L'outil\n```")
    check(keyed.hints.count == 1 && keyed.hints[0].level == 2, "indice : avec le mot indice")
    check(SeriesReview.parse("```polymestre\n6.3 : juste\n```").hints.isEmpty && SeriesReview.parse("```polymestre\n6.3 : juste\n```").verdicts.count == 1,
          "indice : un verdict n'est pas pris pour un indice")
}

// MARK: Claude dans le mode étude (ClaudeTutor, RichMarkup)
do {
    let series = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let sid = ClaudeTutor.sessionID(seriesID: series, profile: .isolated)
    check(sid == ClaudeTutor.sessionID(seriesID: series, profile: .isolated), "session : la même pour une série")
    check(sid != ClaudeTutor.sessionID(seriesID: series, profile: .project)
          && sid != ClaudeTutor.sessionID(seriesID: series, profile: .isolated, generation: 1)
          && sid != ClaudeTutor.sessionID(seriesID: UUID(), profile: .isolated), "session : autre profil, autre génération, autre série")
    check(sid.uuidString.dropFirst(14).first == "5", "session : un UUID de forme v5")

    let args = ClaudeTutor.arguments(.init(sessionID: sid.uuidString, systemPrompt: "P"))
    check(args.contains("--safe-mode") && args.contains("--strict-mcp-config") && args.contains("--disable-slash-commands"),
          "Claude isolé : sans configuration, sans MCP, sans commandes")
    check(!args.contains("--no-session-persistence"), "Claude : la conversation est gardée")
    if let i = args.firstIndex(of: "--session-id") { check(args[i + 1] == sid.uuidString, "Claude : la session de la série") } else { check(false, "Claude : --session-id présent") }
    if let i = args.firstIndex(of: "--tools") { check(args[i + 1] == "", "Claude isolé : aucun outil") } else { check(false, "Claude : --tools présent") }
    check(!args.contains("--model"), "Claude : le modèle de l'abonnement par défaut")
    check(!args.contains { $0.contains("api-key") }, "Claude : jamais de clé d'API")
    let resumed = ClaudeTutor.arguments(.init(sessionID: "S", resume: true, systemPrompt: "P"))
    check(resumed.contains("--resume") && !resumed.contains("--session-id"), "Claude : une session existante se reprend")

    let projectFile = ClaudeProject.File(mcpServers: ["notion": .init(url: "https://mcp.notion.com/mcp")])
    let project = ClaudeTutor.arguments(.init(profile: .project, sessionID: "S", systemPrompt: "P", mcpConfigPath: "/tmp/mcp.json",
                                              allowedTools: ClaudeProject.allowedTools(file: projectFile, polymestre: false),
                                              tools: ClaudeProject.tools(file: projectFile), deniedServers: ["rea"]))
    check(!project.contains("--safe-mode") && !project.contains("--disable-slash-commands"), "projet EPFL : compétences et commandes chargées")
    check(!project.contains("--setting-sources") && !project.contains("--strict-mcp-config"), "projet : les connecteurs du compte se chargent")
    if let i = project.firstIndex(of: "--settings") { check(project[i + 1] == #"{"deniedMcpServers":[{"serverName":"rea"}]}"#, "projet : serveurs locaux écartés") } else { check(false, "projet : --settings") }
    check(project.contains("/tmp/mcp.json"), "projet : les serveurs du fichier en plus")
    let listed = ClaudeProject.servers(mcpList: "Checking MCP server health…\n\nclaude.ai Claude Docs: https://api.anthropic.com/v1/pages/mcp - ✔ Connected\nclaude.ai Notion: https://mcp.notion.com/mcp - ✔ Connected\nrea: npx -y rea-agents@6.4.0 mcp - ✔ Connected\n")
    check(listed.connectors == ["claude.ai Claude Docs", "claude.ai Notion"] && listed.local == ["rea"], "mcp list : connecteurs et serveurs locaux")
    check(ClaudeProject.toolPrefix(server: "claude.ai Claude Docs") == "mcp__claude_ai_Claude_Docs", "préfixe d'outils d'un connecteur")
    check(ClaudeProject.allowedTools(file: ClaudeProject.File(), polymestre: false, connectors: ["claude.ai Notion"]) == ["Read", "Glob", "Skill", "mcp__claude_ai_Notion"],
          "les connecteurs du compte sont permis")
    // L'éditeur des boutons ne réécrit que les boutons et les modèles.
    let original = Data(#"{"skills":["epfl-serie"],"mcpServers":{"todoist":{"url":"https://ai.todoist.net/mcp"}},"maClé":42,"commands":[]}"#.utf8)
    let edited = ClaudeProject.updating(original, commands: [.init(id: "brief", label: "Brief", icon: "sun.max", prompt: "brief"),
                                                             .init(id: "bloque", label: "Bloqué", prompt: "indice {exercice}", scope: .series, model: "tutor", capture: true)],
                                        models: .init(tutor: "haiku", system: nil))
    let reread = edited.flatMap { ClaudeProject.File.decode($0) }
    check(reread?.commands.map(\.id) == ["brief", "bloque"] && reread?.commands[1].scope == .series && reread?.commands[1].capture == true
          && reread?.commands[0].capture == nil, "éditeur : boutons écrits et relus")
    check(reread?.skills == ["epfl-serie"] && reread?.mcpServers["todoist"]?.url == "https://ai.todoist.net/mcp"
          && reread?.models.tutor == "haiku" && reread?.models.system == nil, "éditeur : le reste du fichier gardé")
    check(edited.map { String(decoding: $0, as: UTF8.self).contains("\"maClé\" : 42") } == true, "éditeur : une clé inconnue gardée")
    check(ClaudeProject.updating(Data("[1]".utf8), commands: [], models: .init()) == nil, "éditeur : un fichier qui n'est pas un objet n'est pas écrasé")
    check(ClaudeProject.updating(nil, commands: [], models: .init()).flatMap { ClaudeProject.File.decode($0) } != nil, "éditeur : fichier neuf")
    check(ClaudeProject.commandID(for: "Où j'en suis", taken: []) == "ou-j-en-suis"
          && ClaudeProject.commandID(for: "Brief", taken: ["brief"]) == "brief-2" && ClaudeProject.commandID(for: "!!", taken: []) == "bouton",
          "éditeur : identifiant tiré du libellé")
    if let i = project.firstIndex(of: "--allowedTools") { check(project[i + 1] == "Read,Glob,Skill,mcp__notion", "projet EPFL : outils permis") } else { check(false, "projet : --allowedTools") }
    if let i = project.firstIndex(of: "--tools") { check(project[i + 1] == "Read,Glob,Skill", "projet EPFL : ni terminal ni écriture") } else { check(false, "projet : --tools") }
    check(project.contains("--append-system-prompt") && !project.contains("--system-prompt"), "projet EPFL : la consigne s'ajoute à celle de Claude Code")

    check(ClaudeTutor.sessionRecovery(stderr: "Error: No conversation found with session ID: abc") == .startFresh, "session perdue : on repart")
    check(ClaudeTutor.sessionRecovery(stderr: "Error: Session ID abc is already in use.") == .resume, "session déjà là : on la reprend")
    check(ClaudeTutor.sessionRecovery(stderr: "autre chose") == nil, "autre erreur : rien")
    check(ClaudeTutor.sessionFolderName(workingDirectory: "/Users/a/Library/Caches/Polymestre/claude") == "-Users-a-Library-Caches-Polymestre-claude"
          && ClaudeTutor.sessionFolderName(workingDirectory: "/Users/a/Application Support/x.y") == "-Users-a-Application-Support-x-y",
          "dossier des sessions de Claude Code")

    let opening = ClaudeTutor.openingMessage(series: .init(courseCode: "MATH-101", title: "Série 3", week: 3, due: "jeudi",
                                                          exercises: [.init(number: "1", status: "fait"), .init(number: "2", status: "à faire")],
                                                          pdfAttached: true),
                                             exercise: nil, skill: "epfl-serie")
    check(opening.hasPrefix("/epfl-serie ") && opening.contains("- 2 : à faire") && opening.contains("PDF joint"),
          "série : la compétence lancée avec la série et ses exercices")
    let plain = ClaudeTutor.openingMessage(series: .init(title: "Série 3"), exercise: nil, skill: nil)
    check(!plain.hasPrefix("/") && plain.contains("Série 3"), "série sans compétence : le contexte seul")
    check(ClaudeTutor.displayText(opening) == "/epfl-serie On attaque « Série 3 » (MATH-101).", "affichage : sans le contexte de l'app")
    let switched = ClaudeTutor.exerciseSwitch(.init(exercise: "Exercice 2"))
    check(switched.contains("autre exercice") && switched.contains("Exercice 2") && ClaudeTutor.displayText(switched + "Et là ?") == "Et là ?",
          "changer d'exercice dans la conversation")

    let report = "Bilan.\n\n```polymestre\n1 : juste\nEx 2 : moyen\nexercice 3: FAUX\n4 : ?\n```\nVoilà."
    check(ClaudeTutor.verdicts(in: report) == [.init(exercise: "1", result: .correct), .init(exercise: "2", result: .partial),
                                                 .init(exercise: "3", result: .wrong)], "post-mortem : verdicts lus")
    check(ClaudeTutor.withoutVerdicts(report) == "Bilan.\n\n\nVoilà." || !ClaudeTutor.withoutVerdicts(report).contains("polymestre"),
          "post-mortem : le bloc ne s'affiche pas en texte")
    check(ClaudeTutor.verdicts(in: "rien") == [], "pas de bloc, pas de verdict")
    check(ClaudeTutor.postMortemPrompt(useSkill: true).contains("```polymestre"), "post-mortem : le format demandé")
    check(ClaudeTutor.matchExercise("2", numbers: ["1", "2", "3"]) == 1, "verdict → exercice 2")
    check(ClaudeTutor.matchExercise("3", numbers: ["Ex-03-01", "Ex-03-03"]) == 1, "verdict → numéro à tirets")
    check(ClaudeTutor.matchExercise("1.2", numbers: ["1.1", "1.2"]) == 1 && ClaudeTutor.matchExercise("9", numbers: ["1"]) == nil,
          "verdict : numéro composé, inconnu")

    let initLine = #"{"type":"system","subtype":"init","session_id":"S","model":"claude-opus","permissionMode":"default","skills":["anthropic-skills:pdf","epfl-serie"],"tools":["Read","Skill"],"mcp_servers":[{"name":"notion","status":"needs-auth"}]}"#
    if case .started(let info)? = ClaudeTutor.parse(line: initLine) {
        check(info.sessionID == "S" && info.hasSkill("epfl-serie") && info.hasSkill("pdf") && !info.hasSkill("epfl-anki"), "début : session et compétences")
        check(info.mcpServers == [.init(name: "notion", status: "needs-auth")] && info.permissionMode == "default", "début : MCP et permissions")
    } else {
        check(false, "début de session lu")
    }
    check(ClaudeTutor.parse(line: #"{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":900}}"#)
          == .finished(error: nil, contextTokens: 1002), "fin : taille du contexte")
    check(ClaudeTutor.parse(line: #"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"mcp__notion__notion-search"}}}"#)
          == .tool("mcp__notion__notion-search"), "flux : un outil")
    check(ClaudeTutor.toolLabel("mcp__notion__notion-search") == "Notion" && ClaudeTutor.toolLabel("mcp__polymestre__get_course") == "Polymestre",
          "outil : nom lisible")
    let jsonl = [
        #"{"type":"user","message":{"role":"user","content":"<command-message>epfl-serie</command-message>\n<command-name>/epfl-serie</command-name>\n<command-args>On attaque.\n\n[Polymestre]\nCours : X\n[/Polymestre]\n\nPar où ?</command-args>"}}"#,
        #"{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Salut"},{"type":"tool_use","name":"Read"}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"x"}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On commence."}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"document"},{"type":"text","text":"[Polymestre]\nCours : X\n[/Polymestre]\n\nUn indice ?"}]}}"#,
    ].joined(separator: "\n")
    check(ClaudeTutor.history(jsonl: jsonl) == [.init(fromStudent: true, text: "/epfl-serie On attaque.\n\nPar où ?"), .init(fromStudent: false, text: "Salut\n\nOn commence."),
                                                 .init(fromStudent: true, text: "Un indice ?")],
          "conversation reprise : messages réaffichés, sans contexte ni outils")

    // Le projet EPFL
    let md = ClaudeProject.claudeMD(existing: nil, context: "A")
    check(md.contains(ClaudeProject.beginMarker) && md.contains("A"), "CLAUDE.md : créé")
    let mine = "# Mes notes\n\nGarder ça."
    let merged = ClaudeProject.claudeMD(existing: mine, context: "A")
    check(merged.hasPrefix(mine) && merged.contains("A"), "CLAUDE.md : la partie de l'app s'ajoute")
    let updated = ClaudeProject.claudeMD(existing: merged, context: "B")
    check(updated.hasPrefix(mine) && updated.contains("B") && !updated.contains("\nA\n")
          && updated.components(separatedBy: ClaudeProject.beginMarker).count == 2, "CLAUDE.md : la partie de l'app est remplacée, le reste gardé")
    let ctx = ClaudeProject.context(courses: [.init(code: "MATH-101", name: "Analyse I", week: 4, progress: "Série 4 : 1/5")], week: 4, date: "12 oct.")
    check(ctx.contains("MATH-101 — Analyse I (semaine 4) · Série 4 : 1/5") && ctx.contains("Semaine du semestre : 4"), "CLAUDE.md : cours et semaine")
    let json = """
    {"skills":["epfl-serie","epfl-planning"],"seriesSkill":"epfl-serie","models":{"tutor":"haiku","system":"sonnet"},
     "mcpServers":{"notion":{"type":"http","url":"https://mcp.notion.com/mcp"},"todoist":{"type":"http","url":"https://ai.todoist.net/mcp"}},
     "allowedTools":["Write(./memoire/**)","Edit(./memoire/**)"],
     "commands":[{"id":"brief","label":"Brief","icon":"sun.max","prompt":"brief"},
                 {"id":"pm","label":"Post-mortem","prompt":"post-mortem série {serie} {cours}","scope":"series","model":"system","verdicts":true},
                 {"id":"bloque","label":"Bloqué","prompt":"bloqué sur l'exercice {exercice}","scope":"series","capture":true}]}
    """
    if let file = ClaudeProject.File.decode(Data(json.utf8)) {
        check(file.commands(.system).map(\.id) == ["brief"] && file.commands(.series).map(\.id) == ["pm", "bloque"], "fichier : boutons par conversation")
        check(file.model(for: file.commands[0], scope: .system) == "sonnet" && file.model(for: file.commands[2], scope: .series) == "haiku"
              && file.model(for: file.commands[1], scope: .series) == "sonnet", "fichier : le modèle de chaque bouton")
        check(ClaudeProject.tools(file: file) == ["Read", "Glob", "Skill", "Write", "Edit"], "fichier : écriture limitée chargée")
        check(ClaudeProject.allowedTools(file: file, polymestre: false) == ["Read", "Glob", "Skill", "mcp__notion", "mcp__todoist",
                                                                           "Write(./memoire/**)", "Edit(./memoire/**)"], "fichier : règles permises")
        let mcp = ClaudeProject.mcpConfig(file: file, polymestreURL: "https://x.supabase.co/functions/v1/mcp/T")
        if let object = try? JSONSerialization.jsonObject(with: Data(mcp.utf8)) as? [String: Any], let servers = object["mcpServers"] as? [String: Any] {
            check(Set(servers.keys) == ["notion", "todoist", "polymestre"], "MCP : les serveurs du fichier et Polymestre")
        } else { check(false, "MCP : JSON lisible") }
        check(!ClaudeProject.mcpConfig(file: file, polymestreURL: "http://pas-sur").contains("polymestre"), "MCP : une adresse non chiffrée est refusée")
        let withLocal = ClaudeProject.mcpConfig(file: file, polymestreURL: nil, localFilesURL: "http://127.0.0.1:47821/TOKEN")
        let declared = (try? JSONSerialization.jsonObject(with: Data(withLocal.utf8))) as? [String: Any]
        let localEntry = (declared?["mcpServers"] as? [String: Any])?["polymestre-files"] as? [String: Any]
        check(localEntry?["url"] as? String == "http://127.0.0.1:47821/TOKEN" && localEntry?["type"] as? String == "http", "MCP : le serveur local des fichiers est déclaré")
        check(!ClaudeProject.mcpConfig(file: file, polymestreURL: nil, localFilesURL: "http://evil.example:47821/T").contains("polymestre-files"),
              "MCP : seule la boucle locale est acceptée comme serveur de fichiers")
        check(!ClaudeProject.mcpConfig(file: file, polymestreURL: nil, localFilesURL: nil).contains("polymestre-files"), "MCP : éteint, il n'est pas déclaré")
        check(ClaudeProject.allowedTools(file: file, polymestre: false, localFiles: true).contains("mcp__polymestre-files")
              && !ClaudeProject.allowedTools(file: file, polymestre: false).contains("mcp__polymestre-files"), "MCP : ses outils ne sont permis que s'il tourne")
        check(ClaudeProject.permissionSummary(file: file, polymestre: false, localFiles: true).contains("fichiers du Mac"), "MCP : les permis le disent")
        check(ClaudeProject.permissionSummary(file: file, polymestre: true) == "lecture, compétences, écriture limitée, Notion, Todoist, Polymestre",
              "permissions en clair")
        check(ClaudeProject.expand(file.commands[1].prompt, .init(code: "MATH-101", course: "analyse", seriesNumber: "4")) == "post-mortem série 4 analyse",
              "commande : série et cours remplis")
    } else {
        check(false, "fichier du projet lisible")
    }
    check(ClaudeProject.File.decode(Data(ClaudeProject.emptyFileTemplate.utf8)) == ClaudeProject.File(), "fichier vide : lisible, sans rien")
    check(ClaudeProject.File.decode(Data("{}".utf8))?.commands.isEmpty == true, "fichier minimal : aucun bouton")
    check(ClaudeProject.shortCourseName("Analyse I classe inversée") == "analyse" && ClaudeProject.shortCourseName("Algèbre linéaire") == "algebre",
          "nom court d'un cours")

    let line = ClaudeTutor.userLine(text: "Aide", attachments: [.init(kind: .pdf, data: Data([1, 2, 3]), name: "Série 3")])
    if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
       let message = object["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
        check(object["type"] as? String == "user" && content.count == 2, "message : pièce jointe puis texte")
        check(content[0]["type"] as? String == "document" && content.last?["text"] as? String == "Aide", "message : le PDF est un document")
    } else {
        check(false, "message JSON lisible")
    }
    check(ClaudeTutor.parse(line: #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Bon"}}}"#) == .text("Bon"),
          "flux : un morceau de texte")
    check(ClaudeTutor.parse(line: #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}}"#) == .thinking,
          "flux : Claude réfléchit")
    check(ClaudeTutor.parse(line: #"{"type":"result","subtype":"success","is_error":false}"#) == .finished(error: nil), "flux : réponse finie")
    check(ClaudeTutor.parse(line: #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"limite"}"#) == .finished(error: "limite"),
          "flux : une erreur se dit")
    check(ClaudeTutor.parse(line: #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"five_hour":{"utilization":0.33}}}}"#) == .usage(0.33),
          "flux : l'usage de l'abonnement")
    check(ClaudeTutor.parse(line: #"{"type":"system","subtype":"init"}"#) == nil && ClaudeTutor.parse(line: "pas du json") == nil, "flux : le bruit est ignoré")
    check(ClaudeTutor.systemPrompt(mode: .tutor).contains("Échelle d'indices"), "tuteur : indices avant la solution")
    let preamble = ClaudeTutor.contextPreamble(.init(courseCode: "MATH-101", exercise: "Série 3 · Ex 2", statement: "Montrer que…", questions: ["1. a", "1. b"], doneQuestions: 1))
    check(preamble.contains("MATH-101") && preamble.contains("(1/2 faites)"), "contexte : cours, exercice, avancement")
    check(ClaudeTutor.contextPreamble(.init()).isEmpty, "contexte vide : rien d'ajouté")

    let blocks = RichMarkup.blocks("""
    ## Idée
    On pose $u_n$ et
    on conclut.

    - premier
      - sous-point
    1. étape
    $$\\sum_{k=1}^n k = \\frac{n(n+1)}{2}$$
    ```
    let x = 1
    ```
    """)
    check(blocks == [.heading("Idée", level: 2), .paragraph("On pose $u_n$ et on conclut."), .bullet("premier", depth: 0),
                     .bullet("sous-point", depth: 1), .numbered("étape", number: 1),
                     .math("\\sum_{k=1}^n k = \\frac{n(n+1)}{2}"), .code("let x = 1")],
          "réponse : titres, paragraphes, listes, formule isolée, code")
    check(RichMarkup.blocks("$$\na^2\n$$") == [.math("a^2")], "formule isolée sur plusieurs lignes")
    check(RichMarkup.inlines("Le **point** clé : $x_n$, `f` et *vite*.") ==
          [.text("Le "), .bold("point"), .text(" clé : "), .math("x_n"), .text(", "), .code("f"), .text(" et "), .italic("vite"), .text(".")],
          "en ligne : gras, formule, code, italique")
    check(RichMarkup.inlines("nom_de_variable et 5\\$") == [.text("nom_de_variable et 5$")], "pas d'italique dans un mot, dollar échappé")

    // Courseware : la formule isolée arrive au milieu du paragraphe.
    let quiz = RichMarkup.blocks("les matrices \\[ A_1=\\begin{pmatrix} 0 & 1 \\\\ 0 & 0 \\end{pmatrix} \\] Parmi les possibilités suivantes")
    check(quiz == [.paragraph("les matrices"), .math("A_1=\\begin{pmatrix} 0 & 1 \\\\ 0 & 0 \\end{pmatrix}"), .paragraph("Parmi les possibilités suivantes")],
          "formule \\[…\\] au milieu d'une ligne : sur sa propre ligne")
    check(RichMarkup.blocks("Soit $$x^2$$ donc") == [.paragraph("Soit"), .math("x^2"), .paragraph("donc")], "formule $$…$$ au milieu d'une ligne")
    check(RichMarkup.blocks("On a \\begin{align} a &= b \\end{align} fin").contains(.math("\\begin{align} a &= b \\end{align}")),
          "environnement align hors délimiteur : formule isolée")
    check(RichMarkup.blocks("```\n\\[ x \\]\n```") == [.code("\\[ x \\]")], "pas de formule dans un bloc de code")
    check(RichMarkup.inlines("Voir [le corrigé](https://moodle.epfl.ch/x.pdf) ici") ==
          [.text("Voir "), .link("le corrigé", url: "https://moodle.epfl.ch/x.pdf"), .text(" ici")], "lien Markdown")
    check(RichMarkup.inlines("l'intervalle [0, 1](x) reste") == [.text("l'intervalle [0, 1](x) reste")], "crochets qui ne sont pas un lien")

    // Le TeX des sites, pour le moteur natif.
    check(TeXNormalizer.normalize("\\dfrac{1}{2}") == "{\\displaystyle\\frac{1}{2}}", "TeX : \\dfrac reste grand")
    check(TeXNormalizer.normalize("\\tfrac{1}{2}") == "\\frac{1}{2}", "TeX : \\tfrac → \\frac")
    check(TeXNormalizer.normalize("\\begin{pmatrix} -1 & -2 \\\\ -3 & 4 \\end{pmatrix}") == "\\begin{pmatrix} -\\!\\!1 & -\\!\\!2 \\\\ -\\!\\!3 & 4 \\end{pmatrix}",
          "TeX : moins en tête de case rapproché")
    check(TeXNormalizer.normalize("a - b") == "a - b", "TeX : soustraction intacte")
    check(TeXNormalizer.normalize("\\operatorname{rg}(A)") == "\\mathrm{rg}(A)", "TeX : \\operatorname → \\mathrm")
    // Le polycopié de Botafogo, formule par formule (audit de 11 590 formules).
    check(TeXNormalizer.normalize("\\overline{S}_{\\sigma^{(N)}}") == "\\overline{S}{}_{\\sigma^{(N)}}", "TeX : trait au-dessus indicé posé sur un groupe vide (plantage SwiftMath)")
    check(TeXNormalizer.normalize("\\begin{aligned}x\\mapsto f(x)\\end{aligned}") == "\\begin{gather}x\\mapsto f(x)\\end{gather}", "TeX : aligned sans & → gather")
    check(TeXNormalizer.normalize("\\begin{aligned}a&=b&c&=d\\end{aligned}") == "\\begin{matrix}a&=b&c&=d\\end{matrix}", "TeX : aligned à 4 colonnes → matrix")
    check(TeXNormalizer.normalize("\\begin{cases}\\text{a}\\\\ \\text{b}\\end{cases}") == "\\begin{cases}\\text{a}&\\\\ \\text{b}&\\end{cases}", "TeX : cases à une colonne complété")
    check(TeXNormalizer.normalize("\\begin{aligned}a&=b\\\\&=\\begin{cases}1&x\\\\2&y\\end{cases}\\end{aligned}")?.contains("\\begin{aligned}") == true, "TeX : aligned emboîtant cases intact")
    check(TeXNormalizer.normalize("x\\not\\in A") == "x\\notin A" && TeXNormalizer.normalize("x\\not=y") == "x\\neq y", "TeX : \\not\\in, \\not=")
    check(TeXNormalizer.normalize("a\\stackrel{BH}{=}b") == "a{=}^{BH}b", "TeX : \\stackrel → exposant")
    check(TeXNormalizer.normalize("{\\small a+b}") == "{ a+b}", "TeX : \\small retiré")
    check(TeXNormalizer.normalize("\\cancel{x}") == "\\textcolor{gray}{x}", "TeX : \\cancel grisé")
    check(TeXNormalizer.normalize("\\sum_{\\substack{n\\geq1\\\\n}}") == "\\sum_{{\\begin{matrix}n\\geq1\\\\n\\end{matrix}}}", "TeX : \\substack → matrix")
    check(TeXNormalizer.normalize("a\\:b") == "a\\;b", "TeX : \\: → \\;")
    check(TeXNormalizer.normalize("\\underbrace{a+2}_{=0}") == "\\underline{a+2}_{=0}", "TeX : \\underbrace → trait dessous, l'annotation reste dessous")
    let lifted = BotafogoPage.liftingDisplayMath("Par exemple, $\\begin{align*}1+\\tfrac12&=\\tfrac32\\end{align*}$ et voilà la suite.")
    check(lifted == [.paragraph("Par exemple,"), .math("\\begin{align*}1+\\tfrac12&=\\tfrac32\\end{align*}"), .paragraph("et voilà la suite.")],
          "Botafogo : un calcul aligné entre $…$ devient une formule isolée")
    check(BotafogoPage.liftingDisplayMath("$f(x)=\\begin{cases}1&x\\end{cases}$ ok") == [.paragraph("$f(x)=\\begin{cases}1&x\\end{cases}$ ok")], "Botafogo : cases en ligne reste en ligne")
    // Le rapport d'une série (bloc ```polymestre) et la file de reprise.
    let reviewText = """
    Voilà le post-mortem.
    ```polymestre
    1 : juste
    2 : faux
    erreur 2 | Méthode | oubli de vérifier la continuité en 0 | vérifier f continue en 0 avant le TAF | continuité
    erreur Ex. 3 | étourderie | signe perdu ligne 4 | recopier la ligne
    erreur 4 | n'importe quoi | ignoré
    reprise 2 | méthode : n'a pas vu le critère | Pose M_n = sup |f_n(x)|
    ```
    Et un indice :
    ```polymestre
    indice 3 | 2 | Le critère de Weierstrass s'applique
    ```
    """
    let review = SeriesReview.parse(reviewText)
    check(review.verdicts.map(\.result) == [.correct, .wrong], "Rapport : verdicts lus")
    check(review.mistakes.count == 2 && review.mistakes[0].kind == .method && review.mistakes[0].notion == "continuité"
          && review.mistakes[1].exercise == "3" && review.mistakes[1].kind == .slip, "Rapport : erreurs lues (type inconnu ignoré, « Ex. 3 » → 3)")
    check(review.admissions == [.init(exercise: "2", why: "méthode : n'a pas vu le critère", firstMove: "Pose M_n = sup |f_n(x)|")],
          "Rapport : admission en reprise, avec la barre dans l'amorce")
    check(review.hints == [.init(exercise: "3", level: 2, text: "Le critère de Weierstrass s'applique")], "Rapport : indice lu dans un second bloc")
    check(SeriesReview.withoutBlocks(reviewText) == "Voilà le post-mortem.\n\nEt un indice :", "Rapport : la réponse sans ses blocs")
    check(SeriesReview.MistakeKind.parse("Lacune de cours") == .gap && SeriesReview.MistakeKind.parse("Lecture de l'énoncé") == .reading,
          "Rapport : types d'erreur en toutes lettres")
    check(!SeriesReview.instruction(features: .init(mistakes: false, redo: false)).contains("erreur numéro"),
          "Rapport : carnet éteint, la consigne ne le demande pas")
    var ladderCalendar = Calendar(identifier: .gregorian)
    ladderCalendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let ladderNow = ladderCalendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 18))!
    let ladderExam = ladderCalendar.date(from: DateComponents(year: 2027, month: 1, day: 20))!
    let ladder = RedoLadder.Config()
    let first = RedoLadder.due(step: ladder.steps[0], from: ladderNow, examDate: nil, calendar: ladderCalendar)
    check(first.map { ladderCalendar.dateComponents([.month, .day], from: $0) } == DateComponents(month: 10, day: 21), "Reprise : J+7")
    let passed = RedoLadder.after(.passed, pass: 0, failures: 0, config: ladder, now: ladderNow, examDate: ladderExam, calendar: ladderCalendar)
    check(passed.pass == 1 && passed.due.map { ladderCalendar.dateComponents([.month, .day], from: $0) } == DateComponents(month: 11, day: 4),
          "Reprise : réussi avec aide → J+21")
    let last = RedoLadder.after(.passed, pass: 1, failures: 0, config: ladder, now: ladderNow, examDate: ladderExam, calendar: ladderCalendar)
    check(last.pass == 2 && last.due.map { ladderCalendar.dateComponents([.month, .day], from: $0) } == DateComponents(month: 1, day: 15),
          "Reprise : palier pré-examen, 5 jours avant l'examen")
    check(RedoLadder.after(.passed, pass: 2, failures: 0, config: ladder, now: ladderNow, examDate: nil).pass == nil, "Reprise : après le dernier palier, sorti")
    check(RedoLadder.after(.cleared, pass: 0, failures: 1, config: ladder, now: ladderNow, examDate: nil).pass == nil, "Reprise : sans notes, sorti d'emblée")
    let failedOnce = RedoLadder.after(.failed, pass: 1, failures: 0, config: ladder, now: ladderNow, examDate: nil)
    let failedTwice = RedoLadder.after(.failed, pass: 1, failures: 1, config: ladder, now: ladderNow, examDate: nil)
    check(failedOnce.pass == 1 && !failedOnce.gap && failedTwice.gap, "Reprise : raté → même palier ; deux fois → lacune de cours")
    check(RedoLadder.admissible(review.admissions + [.init(exercise: "5", why: "", firstMove: ""), .init(exercise: "6", why: "", firstMove: "")],
                                alreadyQueued: 1, config: ladder).count == 1, "Reprise : plafond par série (2), moins ce qui y est déjà")
    let customLadder = try? JSONDecoder().decode(RedoLadder.Config.self, from: Data(#"{"steps":[3,10,"exam"],"maxPerSeries":1}"#.utf8))
    check(customLadder?.steps == [.days(3), .days(10), .exam] && customLadder?.maxPerSeries == 1 && customLadder?.perSession == 3,
          "Reprise : paliers du projet (polymestre.json)")
    let hinted = Exercise(exerciseNumber: "3")
    hinted.recordHint(level: 2, text: "Weierstrass | majoration\nvérifie", at: ladderNow)
    hinted.recordHint(level: 1, text: "Chapitre 6", at: ladderNow)
    check(hinted.hintLevel == 2 && hinted.hints.count == 2 && hinted.hints[0].text == "Weierstrass / majoration vérifie",
          "Indices : journal et niveau le plus haut")

    // Noter un rapport confirmé, dans une vraie base.
    do {
        let reviewContainer = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let reviewContext = ModelContext(reviewContainer)
        let reviewCourse = Course(code: "MATH-101", name: "Analyse I")
        reviewContext.insert(reviewCourse)
        let reviewSeries = ExerciseSeries(course: reviewCourse, seriesNumber: 6, title: "Série 6")
        reviewContext.insert(reviewSeries)
        for n in 1...4 {
            reviewContext.insert(Exercise(series: reviewSeries, exerciseNumber: "6.\(n)", sortOrder: n))
        }
        let report = SeriesReview.parse("""
        ```polymestre
        6.1 : juste
        2 : faux
        erreur 2 | méthode | oubli de la continuité en 0 | vérifier la continuité | continuité
        reprise 2 | méthode | Pose g = f - id
        reprise 3 | lacune de cours | Relis 5.2
        reprise 4 | méthode | Trace le graphe
        ```
        """)
        let features = SeriesReview.Features(mistakes: true, redo: true, hints: true, redoPerSeries: 2)
        let applied = SeriesReview.apply(report, to: reviewSeries, features: features, ladder: RedoLadder.Config(), examDate: nil, context: reviewContext)
        let again = SeriesReview.apply(report, to: reviewSeries, features: features, ladder: RedoLadder.Config(), examDate: nil, context: reviewContext)
        let second = reviewSeries.sortedExercises[1]
        check(applied.corrected == 2 && applied.mistakes == 1 && applied.queued == ["6.2", "6.3"] && applied.overCap == ["6.4"],
              "Rapport noté : corrections, carnet, reprise plafonnée à 2 (\(applied.summary))")
        check(again.mistakes == 0 && again.corrected == 0 && again.queued.isEmpty, "Rapport noté deux fois : rien en double")
        check(second.isQueuedForRedo && second.redoRequired && second.redoFirstMove == "Pose g = f - id" && second.redoDueAt != nil
              && second.mistakes.first?.kind == .method, "Rapport noté : l'exercice 6.2 en reprise, son amorce et son erreur")
        let outcome = SeriesReview.recordRedo(.cleared, on: second, ladder: RedoLadder.Config(), examDate: nil)
        check(outcome.pass == nil && !second.isQueuedForRedo && !second.redoRequired && second.redoClearedAt != nil,
              "Reprise réussie sans notes : sort de la file")
        check(SeriesReview.recordHints([.init(exercise: "6.4", level: 3, text: "Trace le graphe")], in: reviewSeries) == 1
              && SeriesReview.recordHints([.init(exercise: "6.4", level: 3, text: "Trace le graphe")], in: reviewSeries) == 0,
              "Indices : notés une fois")
        try reviewContext.save()
        check(true, "Rapport noté : la base enregistre (Mistake dans le schéma)")
    } catch {
        check(false, "Rapport noté : \(error)")
    }

    let exerciseText = BotafogoPage.text([.paragraph("Résoudre dans $\\mathbb{C}$ :"),
                                          .list([[.paragraph("$z^2=1$")], [.paragraph("$z^3=i$")]], ordered: true, columns: 2),
                                          .folded(.solution, title: "Solution", [.math("z=\\pm 1")])])
    check(exerciseText.contains("1. $z^2=1$") && exerciseText.contains("2. $z^3=i$") && exerciseText.contains("<Solution officielle (ne pas révéler en mode tuteur)>")
          && exerciseText.contains("$$z=\\pm 1$$"), "Botafogo : l'énoncé en texte pour Claude, solution marquée")
    // Un seul lecteur pour le Mac et l'iPhone.
    do {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let mac = MusicLink.State(device: "MAC", platform: .mac, title: "Wait for Me", artist: "Reeve Carney", duration: 240, elapsed: 30,
                                  readAt: t0, isPlaying: true, updatedAt: t0)
        let linkKey = TimerLink.key(for: "_identity")
        let sealed = MusicLink.seal(.state(mac), key: linkKey)
        check(sealed.flatMap { MusicLink.open($0, key: linkKey) } == .state(mac), "Musique : état chiffré, relu à l'identique")
        check(sealed.flatMap { MusicLink.open($0, key: TimerLink.key(for: "autre")) } == nil, "Musique : illisible sans la clé du compte")
        let command = MusicLink.Command(from: "PHONE", to: "MAC", action: .handoff(.init(title: "Wait for Me", artist: "Reeve Carney", duration: 240), elapsed: 95, playing: true), sentAt: t0)
        check(MusicLink.seal(.command(command), key: linkKey).flatMap { MusicLink.open($0, key: linkKey) } == .command(command), "Musique : commande de passage chiffrée")
        check(MusicLink.route(localPlaying: false, localHasTrack: true, remotes: [mac], pinned: nil, now: t0.addingTimeInterval(60)) == .remote("MAC"),
              "Musique : le lecteur montre l'appareil qui joue")
        check(MusicLink.route(localPlaying: true, localHasTrack: true, remotes: [mac], pinned: "MAC", now: t0) == .local, "Musique : ici joue, ici d'abord")
        check(MusicLink.route(localPlaying: false, localHasTrack: true, remotes: [mac], pinned: nil, now: t0.addingTimeInterval(3 * 3600)) == .local,
              "Musique : un état « en lecture » périmé (appareil éteint) ne compte plus")
        var paused = mac
        paused.isPlaying = false
        check(MusicLink.route(localPlaying: false, localHasTrack: true, remotes: [paused], pinned: "MAC", now: t0) == .remote("MAC"),
              "Musique : rien ne joue, le choix fait à la main")
        var drifted = mac
        drifted.readAt = t0.addingTimeInterval(10)
        drifted.elapsed = 40
        check(!MusicLink.changed(mac, drifted), "Musique : la position qui avance ne republie pas")
        drifted.elapsed = 120
        check(MusicLink.changed(mac, drifted), "Musique : un saut republie")
        check(MusicLink.changed(mac, paused), "Musique : une pause republie")
        check(abs(mac.elapsed(at: t0.addingTimeInterval(20)) - 50) < 0.01, "Musique : la position se déduit de l'instant de lecture")
    }

    do {
        let dropKey = TimerLink.key(for: "_identity")
        let drop = DeskDrop(from: "PHONE", intent: .stuck, document: Data(repeating: 7, count: 300_000), isPDF: true,
                            question: "bloqué sur le 6.2", exerciseID: UUID(), sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        let sealedDrop = DeskDrop.seal(drop, key: dropKey)
        check(sealedDrop.flatMap { DeskDrop.open($0, key: dropKey) } == drop && (sealedDrop?.count ?? .max) < 950_000,
              "Bureau : une numérisation de 300 Ko passe le relais, chiffrée")
        var heavy = drop
        heavy.document = Data(count: DeskDrop.maxDocumentBytes + 1)
        check(DeskDrop.seal(heavy, key: dropKey) == nil, "Bureau : trop lourde, refusée avant l'envoi")
    }

    check(BotafogoPage.quizzes([.exercise(label: "Exercice 1", [.quiz(title: "Quiz 0.9", prompt: [], choices: [.init(text: "VRAI", correct: true)], columns: 2)]),
                                .quiz(title: "vide", prompt: [], choices: [], columns: 1),
                                .theorem(kind: .remark, title: "", [.quiz(title: "Quiz 0.10", prompt: [], choices: [.init(text: "a", correct: false)], columns: 1)])])
          .map(\.title) == ["Quiz 0.9", "Quiz 0.10"], "Botafogo : les quiz d'une page, même dans un exercice ou un encadré")
    // Naviguer dans un cours Botafogo.
    let navBlocks: [BotafogoBlock] = [.paragraph("intro"), .theorem(kind: .definition, title: "Définition 5.1", []),
                                      .theorem(kind: .example, title: "Exemple 5.1", []), .heading("5.1.1 Divergence", level: 3),
                                      .quiz(title: "Quiz 5.1.1", prompt: [], choices: [], columns: 1), .theorem(kind: .remark, title: "", [])]
    let navOutline = BotafogoNavigation.outline(navBlocks)
    check(navOutline.map(\.index) == [1, 2, 3, 4] && navOutline.map(\.kind) == [.statement, .example, .heading, .quiz],
          "Botafogo : « Sur cette page » liste énoncés, exemples, titres et quiz (pas les encadrés sans titre)")
    check(BotafogoNavigation.current(navOutline, tops: [1: -300, 2: 40, 3: 400, 4: 900]) == 2, "Botafogo : le repère courant est le dernier passé sous la ligne de lecture")
    check(BotafogoNavigation.current(navOutline, tops: [1: 300, 2: 600]) == 1, "Botafogo : en haut de page, le premier repère")
    let navChapters = [BotafogoSite.Chapter(title: "1", sections: [.init(title: "1.1", path: "/a"), .init(title: "1.2", path: "/b")]),
                       BotafogoSite.Chapter(title: "2", sections: [.init(title: "2.1", path: "/c")])]
    let navAround = BotafogoNavigation.neighbours(of: "/b", in: navChapters)
    check(navAround.previous?.path == "/a" && navAround.next?.path == "/c", "Botafogo : précédent / suivant franchissent les chapitres")
    check(BotafogoNavigation.neighbours(of: "/a", in: navChapters).previous == nil, "Botafogo : pas de précédent en tête du polycopié")
    check(BotafogoNavigation.nextUnread(in: navChapters[0].sections, read: ["/a"])?.path == "/b", "Botafogo : reprendre à la première section non lue")
    check(BotafogoNavigation.progress(navChapters[0], read: ["/a", "/c"]) == (1, 2), "Botafogo : progression d'un chapitre")
    check(BotafogoNavigation.plainTitle("2 Nombres: $\\mathbb{C}$").contains("ℂ"), "Botafogo : titre de chapitre sans TeX (fil d'Ariane)")
    check(RichMarkup.inlines("on [peut](polymestre-poly:///handout/matiere/m_x) calculer").contains(.link("peut", url: "polymestre-poly:///handout/matiere/m_x")),
          "Texte : lien à schéma polymestre-poly reconnu")
    check(TeXNormalizer.normalize("\\mathscr{B}=(v_1,\\ldots,v_n)") == "\\mathcal{B}=(v_1,\\ldots,v_n)", "TeX : \\mathscr")
    check(TeXNormalizer.normalize("\\left[\\begin{array}{cc|c} 1 & 2 & 3 \\end{array}\\right]") == "\\left[\\begin{matrix} 1 & 2 & 3 \\end{matrix}\\right]",
          "TeX : array → matrix")
    check(TeXNormalizer.normalize("\\begin{align*} a &= b \\label{eq} \\end{align*}") == "\\begin{aligned} a &= b  \\end{aligned}", "TeX : align*, label retiré")
    check(TeXNormalizer.normalize("\\begin{equation} x \\end{equation}") == "x", "TeX : equation sans numéro")
    check(TeXNormalizer.normalize("x \\in \\R") == "x \\in \\mathbb{R}", "TeX : macro \\R")
    check(TeXNormalizer.normalize("a ≤ b, x ∈ ℝ") == "a \\leq b, x \\in \\mathbb{R}", "TeX : symboles Unicode → commandes")
    check(TeXNormalizer.normalize("a &amp; b \\\\ c") == "a & b \\\\ c", "TeX : entités et retour à la ligne gardé")
    check(TeXNormalizer.normalize("a \\pmod{n}") == "a \\quad(\\mathrm{mod}\\ n)", "TeX : \\pmod")
    check(TeXNormalizer.normalize("x ⊞ y") == nil, "TeX : symbole inconnu → affichage en ligne")
    check(TeXNormalizer.normalize("\\Re z") == "\\Re z", "TeX : \\Re n'est pas \\R")
}

// MARK: Sites du cours lus en natif (SiteContent)
do {
    let base = URL(string: "https://moodle.epfl.ch/mod/page/view.php?id=5")!
    let html = """
    <div class="box generalbox"><h2>Consignes</h2><p>Lire le <strong>chapitre 2</strong> et
    <em>noter</em> \\(x_n\\).</p><script>alert(1)</script>
    <ul><li>un</li><li>deux</li></ul><ol><li>a</li></ol>
    <p>Voir <a href="/pluginfile.php/12/mod_page/content/serie.pdf">la série</a>.</p>
    <img src="/pluginfile.php/12/fig.png" alt="">
    <iframe src="https://api.cast.switch.ch/p/113/embedPlaykitJs/uiconf_id/1?iframeembed=true&amp;entry_id=0_5f16lokn" title="Cours 1"></iframe>
    <table><tr><th>Date</th><th>Salle</th></tr><tr><td>lundi</td><td>CE1</td></tr></table>
    <pre>let x = 1</pre><a href="#main" class="sr-only">Passer au contenu principal</a><p>&eacute;t&eacute; &amp; co</p></div>
    """
    let blocks = SiteHTML.blocks(html, base: base)
    check(blocks.first == .markdown("### Consignes"), "HTML : un titre")
    check(blocks.contains(.markdown("Lire le **chapitre 2** et *noter* \\(x_n\\).")), "HTML : gras, italique, formule gardée")
    check(!blocks.contains { if case .markdown(let t) = $0 { return t.contains("alert") }; return false }, "HTML : pas de script")
    check(blocks.contains(.markdown("- un\n- deux\n1. a")) || blocks.contains(.markdown("- un\n- deux")), "HTML : listes")
    check(blocks.contains(.file(title: "la série", url: "https://moodle.epfl.ch/pluginfile.php/12/mod_page/content/serie.pdf")), "HTML : un fichier lié")
    check(blocks.contains(.image("https://moodle.epfl.ch/pluginfile.php/12/fig.png")), "HTML : une image, adresse résolue")
    check(blocks.contains { if case .video(let title, _) = $0 { return title == "Cours 1" }; return false }, "HTML : une vidéo intégrée")
    check(blocks.contains(.markdown("- Date · Salle\n- lundi · CE1")), "HTML : un tableau en lignes")
    check(blocks.contains(.markdown("```\nlet x = 1\n```")), "HTML : du code")
    check(blocks.last == .markdown("été & co"), "HTML : entités décodées")
    // Un bloc écrit en Markdown dans la page : sa mise en page est gardée.
    let markdownPage = SiteHTML.blocks("<div class=\"md\">\n  ## Objectifs\n  - lire le **chapitre 4**\n  - voir [la vidéo](https://example.org/v)\n</div>")
    check(markdownPage == [.markdown("## Objectifs\n- lire le **chapitre 4**\n- voir [la vidéo](https://example.org/v)")], "HTML : texte Markdown gardé ligne par ligne")
    check(!SiteHTML.looksLikeMarkdown("\n   Soient \\(V\\) un espace\n   vectoriel. "), "HTML : texte indenté ordinaire, pas du Markdown")
    // Courseware : titres et gras vides (`<h3></h3>`, `<strong></strong>`).
    let emptyTags = SiteHTML.blocks("<h2>Contenu de la leçon</h2><h3></h3><p>Dans cette leçon.</p><h2></h2><ol><li>comparer ;<strong></strong></li></ol>")
    check(emptyTags == [.markdown("### Contenu de la leçon"), .markdown("Dans cette leçon."), .markdown("1. comparer ;")], "HTML : pas de « #### » ni « **** » pour des balises vides")

    // Ed : les sondages.
    check(EdDiscussion.pollIDs(in: #"<document version="2.0"><paragraph>Soient $S$.</paragraph><poll id="3395"/></document>"#) == [3395], "Ed : sondage repéré dans le message")
    check(!EdDiscussion.blocks(#"<document><paragraph>a</paragraph><poll id="1"/></document>"#).contains { if case .markdown(let t) = $0 { return t.contains("poll") }; return false },
          "Ed : la balise du sondage n'est pas affichée")
    let pollJSON = #"{"poll":{"id":3230,"content":"<document version=\"1.0\"><paragraph>Cochez</paragraph></document>","data":{"multiple_choice":true,"options":[{"content":"a","response_count":3},{"content":"b","response_count":115}]},"is_closed":false,"response":{"data":{"option_indices":[1]}},"response_count":116,"reveal_votes":"after_response"}}"#
    let poll = EdDiscussion.poll(json: Data(pollJSON.utf8))
    check(poll?.options.count == 2 && poll?.multipleChoice == true && poll?.chosen == [1] && poll?.voters == 116, "Ed : sondage lu (options, plusieurs réponses, mon vote)")
    check(poll?.showsResults == true && abs((poll?.share(1) ?? 0) - 115.0 / 116.0) < 0.001, "Ed : votes montrés après ma réponse, part de la classe")
    var unanswered = poll
    unanswered?.chosen = nil
    check(unanswered?.showsResults == false, "Ed : votes cachés avant de répondre")

    check(SiteRouter.route("https://moodle.epfl.ch/mod/page/view.php?id=42") == .moodle(module: "page", id: 42), "lien : page Moodle")
    check(SiteRouter.route("https://moodle.epfl.ch/mod/resource/view.php?id=42") == .pdf, "lien : fichier Moodle → PDF")
    check(SiteRouter.route("https://moodle.epfl.ch/pluginfile.php/1/x/slides.pptx") == .file, "lien : diapositives")
    check(SiteRouter.route("https://mediaspace.epfl.ch/media/Cours+1/0_5f16lokn") == .mediaspace(entryID: "0_5f16lokn"), "lien : vidéo MediaSpace")
    check(SiteRouter.route("https://www.youtube.com/watch?v=abc123") == .youtube(id: "abc123")
          && SiteRouter.route("https://youtu.be/xyz") == .youtube(id: "xyz"), "lien : YouTube")
    check(SiteRouter.route("https://courseware.epfl.ch/courses/course-v1:EPFLx+MATH101+2025/course/") == .courseware(courseKey: "course-v1:EPFLx+MATH101+2025"),
          "lien : Courseware")
    check(SiteRouter.route("https://botafogo.epfl.ch/analyse-1-GM/") == .botafogo && SiteRouter.route("https://www.geogebra.org/calculator") == .geogebra,
          "lien : Botafogo, GeoGebra")
    check(SiteRouter.route("https://example.com/a.pdf") == .pdf && SiteRouter.route("https://example.com/") == .web, "lien : PDF ailleurs, page web")

    check(Kaltura.manifestURL(entryID: "0_5f16lokn")?.absoluteString
          == "https://api.cast.switch.ch/p/113/sp/11300/playManifest/entryId/0_5f16lokn/format/applehttp/protocol/https/a.m3u8",
          "Kaltura : manifeste HLS d'une vidéo publique")
    check(Kaltura.manifestURL(entryID: "0_x", ks: "KEY")?.absoluteString.contains("/ks/KEY/a.m3u8") == true, "Kaltura : avec la clé de session")
    let page = #"<script>var x = {"partnerId":"113","ks":"djJ8MTEzfJfIN6eBQhUqAAAAAAAAAA=="};</script>"#
    check(Kaltura.config(html: page).partnerID == 113 && Kaltura.config(html: page).ks == "djJ8MTEzfJfIN6eBQhUqAAAAAAAAAA==", "Kaltura : partenaire et clé lus")
    check(Kaltura.isPlayableManifest("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nx") && !Kaltura.isPlayableManifest("<html>"), "Kaltura : manifeste reconnu")

    let edx = """
    {"root":"r","blocks":{
     "r":{"type":"course","display_name":"MOOC","children":["c1"]},
     "c1":{"type":"chapter","display_name":"Semaine 1","children":["s1"]},
     "s1":{"type":"sequential","display_name":"Suites","children":["u1"]},
     "u1":{"type":"vertical","display_name":"Définition","children":["v1","h1","p1"]},
     "v1":{"type":"video","display_name":"Vidéo","student_view_url":"https://c/xblock/v1",
           "student_view_data":{"encoded_videos":{"mobile_low":{"url":"https://v/low.mp4"},"hls":{"url":"https://v/a.m3u8"},"youtube":{"url":"https://www.youtube.com/watch?v=YT1"}}}},
     "h1":{"type":"html","display_name":"Texte","student_view_url":"https://c/xblock/h1"},
     "p1":{"type":"problem","display_name":"Quiz"}}}
    """
    if let outline = EdXOutline.parse(json: Data(edx.utf8)) {
        let unit = outline.chapters.first?.sequences.first?.units.first
        check(outline.chapters.map(\.title) == ["Semaine 1"] && unit?.title == "Définition", "edX : chapitres, séquences, unités")
        check(unit?.blocks.map(\.kind) == [.video, .html, .problem], "edX : les blocs d'une unité")
        check(unit?.blocks.first?.videoURL == "https://v/a.m3u8" && unit?.blocks.first?.youTubeID == "YT1", "edX : HLS d'abord, YouTube en secours")
        check(unit?.blocks[1].viewURL == "https://c/xblock/h1", "edX : le texte par son adresse seule")
    } else {
        check(false, "edX : plan lisible")
    }
    check(EdXOutline.bestVideo(["all_sources": ["https://a/x.webm", "https://a/x.mp4"]]) == "https://a/x.mp4", "edX : mp4 parmi les sources")

    let moodle = MoodleActivityContent.decode(#"{"module":"assign","title":"Devoir 1 &amp; 2","html":"<p>Rendre</p>","dates":["À rendre : lundi"],"files":[{"name":"enonce.pdf","url":"https://moodle.epfl.ch/pluginfile.php/1/enonce.pdf"}],"status":["Statut : Aucune remise"]}"#)
    check(moodle?.title == "Devoir 1 & 2" && moodle?.dates == ["À rendre : lundi"] && moodle?.files.count == 1
          && moodle?.status.first == "Statut : Aucune remise" && moodle?.posts == [], "Moodle : un devoir lu")
    check(MoodleActivityContent.decode(#"{"module":"page","needsLogin":true}"#)?.needsLogin == true, "Moodle : page de connexion reconnue")
    let hidden = MoodleActivityContent.decode(#"{"module":"url","title":"","unavailable":true,"notice":"Pas disponible avant le 17 octobre"}"#)
    check(hidden?.unavailable == true && hidden?.notice == "Pas disponible avant le 17 octobre" && hidden?.target == nil,
          "Moodle : activité pas encore ouverte, pas la page du cours")
    check(MoodleActivityContent.decode(#"{"module":"url","title":"x","notice":""}"#)?.notice == nil, "Moodle : avis vide ignoré")
    check(BotafogoFigure.imagePath(script: "/media/jsxgraph/jsx_suite_divergente.js") == "/media/jsxgraph/jsx_suite_divergente.png",
          "Botafogo : l'image fixe d'une figure interactive")
}

// MARK: Moodle : la page du cours
do {
    let json = #"{"title":"PHYS-101","sections":[{"number":0,"title":"General","summary":"<p>Bienvenue</p>","activities":[{"id":1,"module":"label","name":"Organisation","url":"","html":"<p>Chaque semaine…</p>"}]},{"number":6,"title":"12 October- 18 October","activities":[{"id":2,"module":"resource","name":"Problem Set 6: Momentum","url":"https://moodle.epfl.ch/mod/resource/view.php?id=2"},{"id":3,"module":"url","name":"Lecture 6a recording","url":"https://moodle.epfl.ch/mod/url/view.php?id=3","completed":true}]}]}"#
    if let page = MoodleCoursePage.decode(json) {
        check(page.sections.count == 2 && page.sections[1].activities[0].isSeries && page.sections[1].activities[1].isVideo
              && page.sections[1].activities[1].completed, "Moodle : sections, série, vidéo, achèvement")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        check(page.currentSection(today: today, calendar: calendar)?.number == 6, "Moodle : la semaine en cours d'après le titre")
        check(MoodleCoursePage.range(of: "7 septembre - 13 septembre", year: 2026, calendar: calendar) != nil
              && MoodleCoursePage.range(of: "General", year: 2026, calendar: calendar) == nil, "Moodle : dates en français, titre sans dates")
    } else {
        check(false, "Moodle : page du cours lisible")
    }
    check(MoodleCoursePage.decode(#"{"title":"x","sections":[]}"#) == nil, "Moodle : page vide refusée")
}

// MARK: Mode étude : durée libre
do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 16, minute: 10))!
    let at = { (h: Int, m: Int) in calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))! }
    check(StudyMode.minutes(until: at(18, 30), now: now, calendar: calendar) == 140, "jusqu'à 18 h 30 : 2 h 20")
    check(StudyMode.minutes(until: at(16, 12), now: now, calendar: calendar) == 5, "trop court : 5 min au moins")
    check(StudyMode.minutes(until: at(1, 0), now: now, calendar: calendar) == 530, "1 h du matin : demain")
    check(StudyMode.minutes(until: at(16, 0), now: now, calendar: calendar) == 720, "heure passée de peu : bornée à 12 h")
}

// MARK: Ed Discussion
do {
    let user = #"{"user":{"id":1},"courses":[{"course":{"id":101,"code":"CS-101","name":"AICC I"},"role":{"role":"student"}},{"course":{"id":200,"code":"CS-101 2026","name":"AICC I"}},{"course":{"id":7,"code":"MATH-111","name":"Algèbre"}}]}"#
    let courses = EdDiscussion.courses(userJSON: Data(user.utf8))
    check(courses.map(\.id) == [101, 200, 7], "Ed : les cours de l'utilisateur·rice")
    check(EdDiscussion.match(code: "CS-101", in: courses)?.id == 200 && EdDiscussion.match(code: "MATH-111", in: courses)?.id == 7
          && EdDiscussion.match(code: "PHYS-101(c)", in: courses) == nil, "Ed : le cours du même code, le plus récent")
    let list = #"{"threads":[{"id":5,"number":12,"title":"Série 3, ex 2","category":"Séries","type":"question","is_pinned":false,"is_answered":true,"reply_count":2,"created_at":"2026-10-10T10:00:00Z","document":"Bonjour"}]}"#
    check(EdDiscussion.threads(json: Data(list.utf8)).first?.isAnswered == true, "Ed : la liste des fils")
    let thread = #"{"thread":{"id":5,"user_id":1,"content":"<document version=\"2.0\"><paragraph>Pourquoi <math>x_n \\to 0</math> ?</paragraph></document>","answers":[{"user_id":2,"is_endorsed":true,"content":"<document version=\"2.0\"><paragraph>Par <bold>encadrement</bold>.</paragraph></document>","comments":[{"user_id":1,"content":"<document version=\"2.0\"><paragraph>Merci</paragraph></document>"}]}],"comments":[]},"users":[{"id":1,"name":"Hugo"},{"id":2,"name":"Assistant"}]}"#
    if let post = EdDiscussion.thread(json: Data(thread.utf8)) {
        check(post.author == "Hugo" && post.replies.first?.author == "Assistant" && post.replies.first?.isEndorsed == true
              && post.replies.first?.replies.first?.author == "Hugo", "Ed : fil, réponse validée, commentaire")
        check(EdDiscussion.blocks(post.content) == [.markdown("Pourquoi \\(x_n \\to 0\\) ?")], "Ed : formule gardée")
        check(EdDiscussion.blocks(post.replies[0].content) == [.markdown("Par **encadrement**.")], "Ed : gras")
    } else {
        check(false, "Ed : fil lisible")
    }
    let doc = #"<document version="2.0"><heading level="2">Titre</heading><list style="bullet"><list-item><paragraph>un</paragraph></list-item></list><snippet language="py">print(1)</snippet></document>"#
    check(EdDiscussion.blocks(doc) == [.markdown("### Titre"), .markdown("- un"), .markdown("```\nprint(1)\n```")], "Ed : titre, liste, code")
}

// MARK: Ed : écrire, leçons, quiz
do {
    let doc = EdDiscussion.document(fromMarkdown: "Pourquoi **ça** marche si $x_n < 1$ ?\n\n- un\n- deux\n\n```\nprint(1)\n```")
    check(doc == #"<document version="2.0"><paragraph>Pourquoi <bold>ça</bold> marche si <math>x_n &lt; 1</math> ?</paragraph><list style="bullet"><list-item><paragraph>un</paragraph></list-item><list-item><paragraph>deux</paragraph></list-item></list><snippet language="none" runnable="false" line-numbers="true">print(1)</snippet></document>"#,
          "Ed : Markdown → document")
    check(EdDiscussion.blocks(doc).first == .markdown("Pourquoi **ça** marche si \\(x_n < 1\\) ?"), "Ed : aller-retour du document")
    check(EdDiscussion.categories(courseJSON: Data(#"{"course":{"settings":{"discussion":{"categories":[{"name":"General"},{"name":"Exercises"}]}}}}"#.utf8))
          == ["General", "Exercises"], "Ed : catégories du forum")
    let lessons = EdDiscussion.lessons(json: Data(#"{"lessons":[{"id":9,"title":"Quiz 1","module_id":3,"status":"attempted"}],"modules":[{"id":3,"name":"Semaine 1"}]}"#.utf8))
    check(lessons == [.init(id: 9, title: "Quiz 1", module: "Semaine 1", status: "attempted")], "Ed : leçons et modules")
    let slides = EdDiscussion.slides(lessonJSON: Data(#"{"lesson":{"slides":[{"id":1,"type":"document","title":"Intro","content":"<document/>","status":"completed"},{"id":2,"type":"quiz","title":"Q"}]}}"#.utf8))
    check(slides.map(\.type) == ["document", "quiz"] && slides[0].isCompleted, "Ed : diapositives")
    let questions = EdDiscussion.questions(json: Data(#"{"questions":[{"id":7,"data":{"type":"multiple-choice","content":"<document/>","answers":["<document>A</document>","<document>B</document>"],"multiple_selection":true}},{"id":8,"data":{"type":"true-false","content":"x"}},{"id":10,"data":{"type":"numerical","content":"y"}}]}"#.utf8))
    check(questions.map(\.kind) == [.choice(multiple: true), .choice(multiple: false), .number] && questions[1].answers == ["Vrai", "Faux"],
          "Ed : questions de quiz")
    check((EdDiscussion.response(choices: [2, 0], text: "", for: .choice(multiple: true)) as? [Int]) == [0, 2]
          && (EdDiscussion.response(choices: [], text: "3,5", for: .number) as? Double) == 3.5, "Ed : la réponse envoyée")
}

// MARK: Courseware : problèmes et navigation
do {
    let problem = EdXProblem.decode(#"{"url":"https://c/handler/xmodule_handler","title":"Question 1","prompt":"<p>?</p>","groups":[{"name":"input_x_2_1[]","type":"checkbox","options":[{"value":"choice_0","label":"A"},{"value":"choice_1","label":"B"}]}],"score":0,"total":1,"attempts":2}"#)
    check(problem?.groups.first?.options.count == 2 && problem?.attempts == 2, "Courseware : un problème lu")
    check(EdXProblem.formBody(["input_x_2_1[]": ["choice_0", "choice_1"]]) == "input_x_2_1%5B%5D=choice_0&input_x_2_1%5B%5D=choice_1",
          "Courseware : le formulaire envoyé")
    check(EdXProblem.result(json: Data(#"{"success":"correct","current_score":1.0,"total_possible":1.0}"#.utf8))?.isCorrect == true
          && EdXProblem.result(json: Data(#"{"success":"incorrect"}"#.utf8))?.isCorrect == false, "Courseware : le verdict")
    let edx = #"{"root":"r","blocks":{"r":{"type":"course","children":["c"]},"c":{"type":"chapter","display_name":"Ch","children":["s"]},"s":{"type":"sequential","display_name":"S","children":["u0","u1","u2"]},"u0":{"type":"vertical","display_name":"Accueil","completion":0,"children":[]},"u1":{"type":"vertical","display_name":"U1","completion":1,"children":[]},"u2":{"type":"vertical","display_name":"U2","completion":0,"children":[]}}}"#
    if let outline = EdXOutline.parse(json: Data(edx.utf8)) {
        check(outline.units.map(\.id) == ["u0", "u1", "u2"] && outline.units[1].completed && outline.resumeUnit?.id == "u2",
              "Courseware : reprise après la dernière unité faite")
        check(outline.place(of: "u2")?.sequence.title == "S", "Courseware : chapitre et séquence d'une unité")
    } else { check(false, "Courseware : plan lisible") }
}

// MARK: Calcul : comme sur papier (MathWorkbench)
do {
    var session = MathWorkbench.Session()
    func run(_ line: String) -> MathWorkbench.Output? { try? MathWorkbench.run(line, in: &session) }
    check(run("x^2 - 2") == .plotted("f(x) = x^2 - 2") && session.engine.functions["f"] != nil, "une inconnue libre : tracée, sans « x n'est pas défini »")
    check(run("sin(t)") == .plotted("g(t) = sin(t)"), "une deuxième fonction : g")
    check(run("x^2 = 2") == .solutions(variable: "x", ["-1.41421", "1.41421"]) || {
        if case .solutions(_, let roots)? = run("x^2 = 2") { return roots.count == 2 }; return false }(), "équation du second degré")
    if case .solutions(_, let roots)? = run("z^5 = 1") {
        check(roots.count == 5 && roots.contains("1") && roots.contains("e^(i·2π/5)"), "z⁵ = 1 : cinq racines, dont 1 et e^(i·2π/5)")
    } else { check(false, "z⁵ = 1 résolu") }
    if case .solutions(_, let roots)? = run("z^2 = -3+4i") {
        check(Set(roots) == ["1 + 2i", "-1 - 2i"], "z² = -3+4i : ±(1+2i)")
    } else { check(false, "z² = -3+4i résolu") }
    if case .solutions(_, let roots)? = run("cos(x) = x") {
        check(roots.count == 1 && roots[0].hasPrefix("0.739"), "cos(x) = x : racine numérique")
    } else { check(false, "cos(x) = x résolu") }
    check(run("(1+2i)/(3-i)") == .complex("1/10 + 7/10i", polar: Complex(re: 0.1, im: 0.7).polar), "division complexe exacte")
    if case .complex(let value, _)? = run("e^(i*pi)") { check(value == "-1", "e^(iπ) = -1") } else { check(false, "e^(iπ)") }
    check(Complex(re: 1, im: 1).polar == "1.41421·e^(i·1π/4)" || Complex(re: 1, im: 1).polar.contains("π/4"), "forme polaire")
    check(run("a = 3") == .value("3") && run("2a + 1") == .value("7"), "les définitions marchent toujours")
    check(run("A = [[1,2],[3,4]]") == .matrix([["1", "2"], ["3", "4"]]), "matrice définie")
    check(run("det(A)") == .value("-2"), "déterminant")
    check(run("inv(A)") == .matrix([["-2", "1"], ["3/2", "-1/2"]]), "inverse, en fractions")
    check(run("A*A") == .matrix([["7", "10"], ["15", "22"]]) && run("2A") == .matrix([["2", "4"], ["6", "8"]]), "produit, scalaire")
    check(run("rref([[1,2,3],[2,4,6]])") == .matrix([["1", "2", "3"], ["0", "0", "0"]]) && run("rank([[1,2,3],[2,4,6]])") == .value("1"),
          "forme échelonnée réduite, rang")
    check(run("solve(A, [5,6])") == .matrix([["-4"], ["9/2"]]), "système A·x = b")
    check((try? MathWorkbench.run("inv([[1,2],[2,4]])", in: &session)) == nil, "matrice non inversible refusée")
    check(MathWorkbench.format(0.75) == "3/4" && MathWorkbench.format(2) == "2" && MathWorkbench.format(.pi) == MathEngine.format(.pi), "fractions quand c'en est")
}

// MARK: Notes (GoodNotes → Google Drive)
do {
    let courses: [NotesLibrary.CourseKey] = [
        .init(code: "CS-101", name: "Advanced information, computation, communication I"),
        .init(code: "CS-107", name: "Introduction à la programmation"),
        .init(code: "MATH-101", name: "Analyse I classe inversée"),
        .init(code: "MATH-111", name: "Algèbre linéaire classe inversée"),
        .init(code: "PHYS-101", name: "Physique générale : mécanique anglais"),
    ]
    func course(_ folder: String) -> String? { NotesLibrary.course(forNotebook: folder, among: courses)?.code }
    check(course("MATH-111 Algèbre linéaire") == "MATH-111" && course("PHYS-101 Mécanique") == "PHYS-101", "cahier : par le code")
    check(course("Algèbre Linéaire") == "MATH-111" && course("Mécanique") == "PHYS-101" && course("Analyse") == "MATH-101"
          && course("Programmation") == "CS-107", "cahier : par le nom")
    check(course("AICC") == "CS-101", "cahier : par l'acronyme")
    check(course("Photos") == nil, "cahier sans cours")
    let now = Date()
    let doc = NotesLibrary.document(path: "EPFL BA1/Algèbre Linéaire/Semaine 3/Série 3.pdf", modified: now)
    check(doc?.notebook == "Algèbre Linéaire" && doc?.week == 3 && doc?.seriesNumber == 3 && doc?.isSolution == false, "document : cahier, semaine, série")
    check(NotesLibrary.document(path: "EPFL BA1/Algèbre Linéaire/Semaine 3/Serie 03 Solutions.pdf", modified: now)?.isSolution == true,
          "document : un corrigé")
    check(NotesLibrary.seriesNumber("PS5 (1)") == 5 && NotesLibrary.seriesNumber("Séance et série 4") == 4
          && NotesLibrary.seriesNumber("Problem Set 6") == 6 && NotesLibrary.seriesNumber("Lecture 5a") == nil, "numéro de série")
    let docs = [
        NotesLibrary.document(path: "N/Semaine 3/Série 3 poly.pdf", modified: now.addingTimeInterval(-100))!,
        NotesLibrary.document(path: "N/Semaine 3/Série 3.pdf", modified: now)!,
        NotesLibrary.document(path: "N/Semaine 3/Serie 03 Solutions.pdf", modified: now.addingTimeInterval(10))!,
        NotesLibrary.document(path: "N/Semaine 5/Séance Et Série 5.pdf", modified: now)!,
    ]
    check(NotesLibrary.copy(seriesNumber: 3, week: 3, in: docs)?.title == "Série 3", "ta copie : la plus récente, pas le corrigé")
    check(NotesLibrary.copy(seriesNumber: 9, week: 5, in: docs)?.title == "Séance Et Série 5", "ta copie : la série de la semaine")
}

// MARK: Profil d'école (Institution)
do {
    check(Institution.current == .epfl, "l'EPFL par défaut : rien ne change")
    check(Institution.detect(email: "prenom.nom@epfl.ch")?.id == "epfl" && Institution.detect(email: "a@gmail.com") == nil,
          "l'école d'une adresse")
    let other = Institution(id: "uni", name: "Université fictive", emailDomains: ["uni.example"],
                            moodle: .init(base: "https://cours.uni.example", oauthProviderID: nil),
                            openEdX: .init(base: "https://mooc.uni.example", loginBackend: nil, ssoHost: nil, ssoIdP: nil),
                            video: .init(host: "video.uni.example", kalturaAPI: "https://api.kaltura.example", kalturaPartner: 42,
                                         wayfHost: nil, identityProvider: nil, passwordIdPHost: nil),
                            ed: .init(region: "us"), studyDomains: ["uni.example"])
    let saved = Institution.current
    Institution.current = other
    check(SiteRouter.route("https://cours.uni.example/mod/page/view.php?id=7") == .moodle(module: "page", id: 7), "autre école : son Moodle")
    check(SiteRouter.route("https://moodle.epfl.ch/mod/page/view.php?id=7") == .web, "autre école : le Moodle de l'EPFL n'est plus le sien")
    check(SiteRouter.route("https://video.uni.example/media/t/0_abcdefgh") == .mediaspace(entryID: "0_abcdefgh"), "autre école : ses vidéos")
    check(SiteRouter.route("https://mooc.uni.example/courses/course-v1:UNI+X+2026/course/") == .courseware(courseKey: "course-v1:UNI+X+2026"),
          "autre école : son Open edX")
    check(SiteRouter.route("https://botafogo.epfl.ch/x/") != .botafogo, "autre école : pas de Botafogo")
    check(Kaltura.manifestURL(entryID: "0_x")?.absoluteString.hasPrefix("https://api.kaltura.example/p/42/sp/4200/") == true, "autre école : son Kaltura")
    check(StudyMode.defaultSites.first == "uni.example" && !StudyMode.defaultSites.contains("epfl.ch"), "autre école : ses sites permis")
    check(StudyMode.tools(courseName: nil, courseLinks: []).first { $0.id == "moodle" }.map { if case .web(let url) = $0.kind { return url.host == "cours.uni.example" }; return false } == true,
          "autre école : l'outil Moodle")
    check(Institution.generic.moodle == nil && StudyMode.defaultSites(for: .generic).contains("claude.ai"), "école inconnue : l'essentiel marche")
    Institution.current = saved
    check(SiteRouter.route("https://moodle.epfl.ch/mod/page/view.php?id=7") == .moodle(module: "page", id: 7), "retour à l'EPFL")
    let encoded = try? JSONEncoder().encode(Institution.epfl)
    check(encoded.flatMap { try? JSONDecoder().decode(Institution.self, from: $0) } == .epfl, "un profil s'écrit et se relit")
}

// MARK: Personnalisation : règles des notes, étapes de la session
do {
    let courses: [NotesLibrary.CourseKey] = [.init(code: "MATH-101", name: "Analyse I"), .init(code: "MATH-106", name: "Analyse II")]
    var rules = NotesLibrary.Rules(notebooks: ["Analyse": "MATH-106", "Brouillons": ""])
    check(NotesLibrary.course(forNotebook: "Analyse", among: courses, rules: rules)?.code == "MATH-106", "cahier rangé à la main : l'emporte")
    check(NotesLibrary.course(forNotebook: "Brouillons", among: courses, rules: rules) == nil, "cahier écarté à la main")
    rules.seriesWords = ["TD", "Übung"]
    rules.weekWords = ["Woche"]
    check(NotesLibrary.seriesNumber("TD 4 corrigé", rules: rules) == 4 && NotesLibrary.seriesNumber("Übung 07", rules: rules) == 7
          && NotesLibrary.seriesNumber("Série 3", rules: rules) == nil, "mots d'une série choisis")
    check(NotesLibrary.weekNumber("Woche 3", rules: rules) == 3 && NotesLibrary.weekNumber("Semaine 3", rules: rules) == nil, "mot de semaine choisi")
    check(NotesLibrary.seriesNumber("laps 3") == nil && NotesLibrary.seriesNumber("PS5") == 5, "un mot court commence un mot")
    check(NotesLibrary.Rules.standard == (try? JSONDecoder().decode(NotesLibrary.Rules.self, from: Data("{}".utf8))), "règles par défaut relues")

    var flow = SessionFlow.standard
    check(flow.steps == [.course, .series, .help, .debrief], "session : les quatre étapes par défaut")
    flow.toggle(.course)
    check(flow.steps == [.series, .help, .debrief], "session : une étape retirée")
    flow.toggle(.course)
    check(flow.steps == [.course, .series, .help, .debrief], "session : remise à sa place")
    flow.move(.debrief, by: -3)
    check(flow.steps.first == .debrief, "session : réordonnée")
    var single = SessionFlow(steps: [.series]); single.toggle(.series)
    check(single.steps == [.series], "session : jamais vide")
}

// MARK: Formules : commandes de police
do {
    check(MathMarkup.plain("$z^2=-3+4\\mathsf{i}$") == "z2=-3+4i", "\\mathsf{i} → i")
    check(MathMarkup.plain("$\\textbf{v}$ et $\\mathtt{x}$") == "v et x", "\\textbf, \\mathtt")
}

// MARK: Mode étude sans blocage
do {
    var state = FocusTimerState()
    StudyMode.enter(&state, minutes: 30)
    check(StudyMode.locks(state) && state.studyLocks == nil, "mode étude : bloque par défaut")
    StudyMode.enter(&state, minutes: 30, locks: false)
    check(StudyMode.isActive(state) && !StudyMode.locks(state), "mode étude sans blocage : actif, rien de bloqué")
    StudyMode.leave(&state)
    check(state.studyLocks == nil && !StudyMode.locks(state), "sortie : plus de blocage")
    let old = try? JSONDecoder().decode(FocusTimerState.self, from: JSONEncoder().encode(FocusTimerState()))
    check(old?.studyLocks == nil, "un état d'avant se lit (champ absent)")
}

// MARK: Verrou du mode étude
do {
    var state = FocusTimerState()
    StudyMode.enter(&state, minutes: 30)
    check(!StudyMode.canLeave(state), "verrou : on ne sort pas avant l'heure")
    check(StudyMode.canLeave(state, at: Date().addingTimeInterval(31 * 60)), "verrou : l'heure passée, on sort")
    StudyMode.enter(&state, minutes: 30, locks: false)
    check(StudyMode.canLeave(state), "sans verrou : on sort quand on veut")
    check(StudyMode.emergencyNote("") == "Sortie d'urgence", "sortie d'urgence : notée")
    check(StudyMode.emergencyNote("Analyse") == "Analyse · Sortie d'urgence", "sortie d'urgence : après la note")
    check(StudyMode.emergencyNote("Analyse · Sortie d'urgence") == "Analyse · Sortie d'urgence", "sortie d'urgence : une fois")
    check(StudyMode.defaultSites(for: .epfl).contains("speakup.info"), "sondages en amphi permis")
}

// MARK: Mode étude sans fin
do {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var state = FocusTimerState()
    StudyMode.enter(&state, minutes: nil, now: t0)
    let later = t0.addingTimeInterval(5 * 3600)
    check(StudyMode.isOpenEnded(state) && StudyMode.isActive(state, at: later), "sans fin : actif des heures après")
    check(!StudyMode.isOver(state, at: later), "sans fin : jamais « terminé » de lui-même")
    check(StudyMode.blocks(state, at: later) && !StudyMode.locks(state, at: later), "sans fin : bloque le reste, sans verrou")
    check(StudyMode.canLeave(state, at: t0), "sans fin : on termine quand on a fini")
    check(StudyMode.clock(state, at: t0.addingTimeInterval(90.6)) == 90, "sans fin : l'horloge compte le temps passé")
    check(abs(StudyMode.progress(state, at: t0.addingTimeInterval(5400)) - 0.5) < 0.001, "sans fin : l'anneau fait le tour en une heure")
    check(StudyMode.extended(state.studyUntil, by: 25, now: later) == state.studyUntil, "sans fin : prolonger ne donne pas d'heure")
    check(StudyMode.tickAnchor(state) == t0.addingTimeInterval(0.05), "sans fin : l'horloge bat depuis le début")
    let back = try? JSONDecoder().decode(FocusTimerState.self, from: JSONEncoder().encode(state))
    check(StudyMode.isOpenEnded(back), "sans fin : passe d'un appareil à l'autre")
    StudyMode.enter(&state, minutes: 30, now: t0)
    check(!StudyMode.isOpenEnded(state) && StudyMode.locks(state, at: t0), "une durée : verrou comme avant")
    check(StudyMode.clock(state, at: t0.addingTimeInterval(60.2)) == 29 * 60, "une durée : l'horloge compte ce qui reste")
    check(StudyMode.backgroundApps.contains("com.apple.Music"), "Music joue en arrière-plan pendant le mode étude")
    // Finder : masqué, jamais fermé ; lanceurs : fermés même sans icône dans le Dock.
    let d = { (id: String?, regular: Bool, allowed: [String]) in StudyMode.disposition(bundleID: id, isRegular: regular, own: "me", allowed: allowed) }
    check(!StudyMode.defaultMacApps.contains(StudyMode.finderBundleID), "le Finder n'est plus permis d'office")
    check(d("com.apple.finder", true, StudyMode.defaultMacApps) == .hideOnly, "Finder : masqué quand il passe devant, jamais fermé")
    check(d("com.apple.finder", true, StudyMode.defaultMacApps + ["com.apple.finder"]) == .allowed, "Finder permis explicitement : permis")
    check(d("com.apple.Music", true, []) == .hideOnly, "Music : masqué, jamais fermé")
    check(d("com.raycast.macos", false, StudyMode.defaultMacApps) == .close, "Raycast : fermé même sans icône dans le Dock")
    check(d("com.runningwithcrayons.Alfred", false, []) == .close && d("at.obdev.LaunchBar", false, []) == .close, "Alfred et LaunchBar : fermés")
    check(d("com.lwouis.alt-tab-macos", false, StudyMode.defaultMacApps) == .close, "AltTab : fermé, c'est une porte de sortie")
    check(d("com.raycast.macos", false, ["com.raycast.macos"]) == .allowed, "un lanceur permis explicitement le reste")
    check(d("com.example.agent", false, []) == .system, "un agent quelconque : hors de portée")
    check(d("com.apple.Safari", true, StudyMode.defaultMacApps) == .close, "Safari : fermé")
    check(d(nil, true, []) == .system && d("", true, []) == .system, "sans identifiant : hors de portée")
    check(d("com.apple.Spotlight", true, []) == .system, "Spotlight reste hors de portée de la règle des apps")
    check(StudyMode.removingFinder(from: ["com.goodnotesapp.x", "com.apple.finder", "com.apple.Preview"]) == ["com.goodnotesapp.x", "com.apple.Preview"], "migration : le Finder sort de la liste")
    check(StudyMode.removingFinder(from: StudyMode.removingFinder(from: ["com.apple.finder"])) == [], "migration : sans effet la seconde fois")
}

// MARK: Verrou du Mac : raccourcis du système éteints, puis rallumés
do {
    let on: Set<Int> = [1, 2, 64, 65, 32, 52]
    let first = StudyLockPlan.plan(wanted: [1, 2, 64, 65, 118, 28], enabledNow: { on.contains($0) }, existing: nil,
                                   dockNow: false, menuBarNow: true, now: Date(timeIntervalSince1970: 100))
    check(Set(first.disable) == [1, 2, 64, 65], "verrou : seuls les raccourcis allumés sont éteints")
    check(!first.record.shortcuts.contains(118), "verrou : un raccourci déjà éteint par l'utilisateur·rice n'est pas sur la fiche")
    check(!first.disable.contains(28) && !first.record.shortcuts.contains(28), "verrou : les captures d'écran ne sont jamais touchées")
    check(first.record.dockAutohide == false && first.record.menuBarAutohide == true, "verrou : les valeurs d'origine du Dock et des menus sont gardées")
    // L'app est relancée en plein blocage : tout ce qu'elle avait éteint se lit « éteint ».
    let second = StudyLockPlan.plan(wanted: [1, 2, 64, 65, 32], enabledNow: { _ in false }, existing: first.record,
                                    dockNow: true, menuBarNow: false, now: Date(timeIntervalSince1970: 200))
    check(second.record.shortcuts == first.record.shortcuts, "relance : la fiche d'origine gagne, rien ne s'ajoute à tort")
    check(second.record.dockAutohide == false && second.record.menuBarAutohide == true, "relance : les valeurs d'origine ne sont pas remplacées par celles que nous avons posées")
    check(second.record.createdAt == first.record.createdAt, "relance : la fiche garde sa date")
    check(Set(second.disable) == Set(first.disable), "relance : on éteint encore ce qui est sur la fiche")
    // Un raccourci rallumé entre-temps (32 devient allumé) rejoint la fiche.
    let third = StudyLockPlan.plan(wanted: [32], enabledNow: { $0 == 32 }, existing: first.record, dockNow: nil, menuBarNow: nil)
    check(third.record.shortcuts.contains(32), "un raccourci allumé et voulu rejoint la fiche existante")
    check(Set(StudyLockPlan.restore(first.record)) == [1, 2, 64, 65], "rétablir : seulement ce que nous avons éteint")
    check(StudyLockPlan.restore(first.record) == StudyLockPlan.restore(first.record), "rétablir deux fois : le même résultat")
    check(StudyLockPlan.restore(StudyLockPlan.Record(shortcuts: [27, 118], createdAt: Date())) == [118], "rétablir : jamais ⌘` ni les captures")
    let back = StudyLockPlan.decode(StudyLockPlan.encode(first.record))
    check(back == first.record, "fiche : relue telle qu'écrite")
    let g1 = [StudyLockPlan.GestureOriginal(domain: "d", key: "k", value: 2), StudyLockPlan.GestureOriginal(domain: "d", key: "absent", value: nil)]
    let g2 = [StudyLockPlan.GestureOriginal(domain: "d", key: "k", value: 0)]
    check(StudyLockPlan.mergeGestures(existing: nil, current: g1) == g1, "gestes : sans fiche, les valeurs lues sont gardées")
    check(StudyLockPlan.mergeGestures(existing: g1, current: g2) == g1, "gestes : après une relance, la fiche d'origine gagne")
    var withGestures = first.record
    withGestures.gestures = g1
    check(StudyLockPlan.decode(StudyLockPlan.encode(withGestures))?.gestures == g1, "gestes : la fiche garde les valeurs d'origine, y compris « absente »")
    check(StudyLockPlan.decode(StudyLockPlan.encode(first.record))?.gestures == nil, "gestes : une ancienne fiche se relit sans eux")
    check(StudyLockPlan.gestureTargets.contains { $0.key == "TrackpadThreeFingerHorizSwipeGesture" && $0.blocked == 0 && !$0.isBool }
          && StudyLockPlan.gestureTargets.contains { $0.key == "showMissionControlGestureEnabled" && $0.isBool }, "gestes : les balayages à trois doigts et Mission Control sont dans la liste")
    check(StudyLockPlan.decode(Data("pas du json".utf8)) == nil && StudyLockPlan.decode(nil) == nil, "fiche illisible : ignorée")
    check(Set(StudyLockPlan.shortcutIDs).isDisjoint(with: StudyLockPlan.neverTouched), "la liste ne contient aucun raccourci intouchable")
    check(StudyLockPlan.shortcutIDs.contains(64) && StudyLockPlan.shortcutIDs.contains(65) && StudyLockPlan.shortcutIDs.contains(1),
          "la liste couvre Spotlight, ⌥⌘Espace et ⌘Tab")
}

// MARK: Sélecteur et recherche d'étude
do {
    var model = StudySwitcherModel()
    model.touch("pane:exercise"); model.touch("app:goodnotes"); model.touch("pane:course")
    let all = ["pane:desk", "pane:exercise", "pane:course", "app:goodnotes", "claude"]
    check(model.order(available: all) == ["pane:course", "app:goodnotes", "pane:exercise", "pane:desk", "claude"], "sélecteur : le plus récent d'abord, puis l'ordre donné")
    check(model.order(available: ["claude", "pane:course"]) == ["pane:course", "claude"], "sélecteur : seulement ce qui existe")
    model.touch("pane:exercise")
    check(model.recent.first == "pane:exercise" && model.recent.filter { $0 == "pane:exercise" }.count == 1, "sélecteur : pas de doublon")
    for i in 0..<40 { model.touch("x\(i)") }
    check(model.recent.count == StudySwitcherModel.memory, "sélecteur : mémoire bornée")
    check(StudySwitcherModel.move(from: 0, by: 1, count: 4) == 1 && StudySwitcherModel.move(from: 3, by: 1, count: 4) == 0, "sélecteur : en avant, en boucle")
    check(StudySwitcherModel.move(from: 0, by: -1, count: 4) == 3 && StudySwitcherModel.move(from: 0, by: 1, count: 0) == 0, "sélecteur : en arrière, en boucle ; vide")
    check(StudySearchQuery.mathExpression("2+3*4") == "2+3*4", "recherche : un calcul est un calcul")
    check(StudySearchQuery.mathExpression("= x^2 - 2") == "x^2 - 2", "recherche : « = » force le calcul")
    check(StudySearchQuery.mathExpression("sqrt(2)+1") == "sqrt(2)+1", "recherche : les fonctions connues")
    check(StudySearchQuery.mathExpression("série 3") == nil && StudySearchQuery.mathExpression("PHYS-101") == nil, "recherche : « série 3 » et un code de cours restent des recherches")
    check(StudySearchQuery.mathExpression("analyse") == nil && StudySearchQuery.mathExpression("") == nil && StudySearchQuery.mathExpression("=") == nil, "recherche : des mots, du vide")
    check(StudySearchQuery.mathExpression("12") == nil, "recherche : un nombre seul n'est pas un calcul")
    typealias Q = StudySearchQuery
    check(Q.group(.tool, title: "GoodNotes", needle: "good") == .toolPrefix && Q.group(.tool, title: "GoodNotes", needle: "notes") == .tool, "recherche : un outil dont le nom commence par la requête passe avant")
    check(Q.group(.tool, title: "Calcul", needle: "CALC") == .toolPrefix && Q.group(.tool, title: "Écrire", needle: "ecr") == .toolPrefix, "recherche : sans casse ni accents")
    check(Q.group(.content, title: "Série 3", needle: "se") == .content && Q.group(.site, title: "x", needle: "x") == .site, "recherche : le reste garde son groupe")
    check(Q.Group.math < .toolPrefix && Q.Group.toolPrefix < .content && Q.Group.content < .tool && Q.Group.tool < .action && Q.Group.action < .kept && Q.Group.kept < .site,
          "recherche : calcul, outil préfixé, contenu, autres outils, actions, gardés, sites")
    check(Q.claudeQuestion("pourquoi la suite est croissante ?") != nil && Q.claudeQuestion("comment faire 3.2") != nil && Q.claudeQuestion("calcul") == nil && Q.claudeQuestion("  ") == nil && Q.claudeQuestion("quoi?") != nil,
          "recherche : une phrase devient une question pour Claude, un mot reste une recherche")
}

// MARK: Pomodoro allumé en cours de séance
do {
    let cycle = PomodoroSettings(focusMinutes: 25, shortBreakMinutes: 5)
    let t0 = Date(timeIntervalSince1970: 100_000)
    // Une séance de 37 minutes de travail, le chrono tourne.
    var state = FocusTimerState(accumulated: 37 * 60, runningSince: t0, sessionStartedAt: t0.addingTimeInterval(-37 * 60), pomodoro: false)
    check(state.cycleOriginSeconds == 0 && state.cycleAccumulated == 37 * 60, "pomodoro : sans origine, le cycle compte depuis le début")
    state.setPomodoro(true, at: t0.addingTimeInterval(120))
    check(state.pomodoro && abs(state.cycleOriginSeconds - 39 * 60) < 0.01 && state.cycleAccumulated == 0, "pomodoro : allumé à 39 min de travail, le cycle repart de zéro")
    check(abs(state.elapsed(at: t0.addingTimeInterval(120)) - 39 * 60) < 0.01, "pomodoro : le temps déjà travaillé reste compté")
    let end = state.blockEndDate(settings: cycle)
    check(end == t0.addingTimeInterval(120 + 25 * 60), "pomodoro : le premier bloc dure un bloc entier à partir de maintenant")
    // Avant la fin du bloc : rien ; à la fin : une pause.
    check(state.advance(settings: cycle, to: t0.addingTimeInterval(120 + 24 * 60)).isEmpty, "pomodoro : pas de pause avant la fin du bloc")
    let events = state.advance(settings: cycle, to: t0.addingTimeInterval(120 + 26 * 60))
    check(events == [.blockEnded(block: 1, kind: .short)], "pomodoro : à la fin du premier bloc, la première pause")
    check(abs(state.accumulated - (39 + 25) * 60) < 0.01 && state.currentBreak != nil, "pomodoro : le travail est coupé à la frontière du bloc")
    let status = PomodoroEngine.status(elapsed: 64 * 60, focusMinutes: 25, origin: 39 * 60)
    check(status.completedBlocks == 1 && status.blockNumber == 1, "pomodoro : le statut compte depuis l'origine")
    // La pause finie, le bloc suivant : numéro 2.
    _ = state.advance(settings: cycle, to: t0.addingTimeInterval(120 + 26 * 60 + 5 * 60 + 1))
    check(state.currentBreak == nil, "pomodoro : la pause finit")
    // Couper pendant une pause : la pause s'arrête, le travail reprend.
    var paused = state
    paused.skipBreak(at: t0.addingTimeInterval(4000))
    var onBreak = FocusTimerState(accumulated: 25 * 60, sessionStartedAt: t0, pomodoro: true)
    onBreak.breakKindRaw = PomodoroBreak.short.rawValue
    onBreak.breakStartedAt = t0
    onBreak.breakEndsAt = t0.addingTimeInterval(300)
    onBreak.setPomodoro(false, at: t0.addingTimeInterval(60))
    check(!onBreak.pomodoro && onBreak.currentBreak == nil && onBreak.cycleOrigin == nil && onBreak.runningSince != nil, "pomodoro : coupé pendant une pause, la pause s'arrête et le travail reprend")
    // Rallumer plus tard repart d'un bloc plein.
    onBreak.setPomodoro(true, at: t0.addingTimeInterval(600))
    check(onBreak.cycleOriginSeconds > 25 * 60 && abs(onBreak.cycleAccumulated) < 0.01, "pomodoro : rallumé, un nouveau cycle")
    // Ancien état sans origine : lu comme avant.
    let legacy = FocusTimerState(accumulated: 50 * 60, sessionStartedAt: t0, pomodoro: true)
    check(PomodoroEngine.status(elapsed: 50 * 60, focusMinutes: 25).completedBlocks == 2 && legacy.cycleOrigin == nil, "pomodoro : un état d'avant se lit comme avant")
    // Aller-retour JSON, groupe compris.
    let back = try? JSONDecoder().decode(FocusTimerState.self, from: JSONEncoder().encode(state))
    check(back?.cycleOrigin == state.cycleOrigin, "pomodoro : l'origine voyage d'un appareil à l'autre")
    check(GroupClock(state).cycleOrigin == state.cycleOrigin, "pomodoro : l'horloge d'un groupe la porte aussi")
}

// MARK: Fiche compréhensible : liens, carte, schémas, parcours
do {
    typealias E = RevisionSheet.Entry
    func entry(_ id: String, _ kind: E.Kind, _ title: String, _ body: String = "…") -> E { E(id: id, kind: kind, title: title, body: body) }
    let sheet = RevisionSheet(origin: .ai, generatedAt: Date(timeIntervalSince1970: 0), chapters: [
        .init(id: "c0", title: "Suites", entries: [
            entry("a", .definition, "Définition 1.1 (suite bornée)", "Une suite est bornée si…"),
            entry("b", .theorem, "Théorème 1.2 (monotone bornée)", "Par la définition 1.1, une suite monotone bornée converge."),
            entry("c", .method, "Montrer qu'une suite converge", "Utiliser le théorème 1.2 puis la proposition 2.1."),
        ]),
        .init(id: "c1", title: "Séries", entries: [
            entry("d", .proposition, "Proposition 2.1 (critère de Cauchy)", "Une suite de Cauchy converge."),
            entry("e", .pitfall, "Piège : série et suite", "Ne pas confondre une série et sa suite des termes."),
            entry("f", .definition, "Définition 1.1 (suite bornée)", "doublon"),
        ]),
    ])
    let keyed = sheet.keyed
    check(keyed.count == 6 && Set(keyed.map(\.key)).count == 6, "carte : chaque notion a une clé, un doublon prend « #2 »")
    check(keyed[0].key == "definition 1.1 (suite bornee)" && keyed[5].key == "definition 1.1 (suite bornee)#2", "carte : la clé est le titre sans accents ni casse")
    check(sheet.entry(forKey: keyed[1].key)?.entry.id == "b", "carte : on retrouve une notion par sa clé")

    // Liens déduits des citations
    let cited = StudyLinks.cited(in: sheet)
    let byID = Dictionary(uniqueKeysWithValues: keyed.map { ($0.entry.id, $0.key) })
    func has(_ from: String, _ to: String) -> Bool { cited.contains { $0.from == byID[from] && $0.to == byID[to] && $0.relation == .uses } }
    check(has("b", "a"), "liens : « par la définition 1.1 » → le théorème se sert de la définition")
    check(has("c", "b") && has("c", "d"), "liens : la méthode cite le théorème 1.2 et la proposition 2.1")
    check(!cited.contains { $0.from == $0.to }, "liens : jamais une notion qui se cite elle-même")
    check(!has("a", "b"), "liens : le sens est celui de la citation")

    // Fusion : ce qu'on a posé à la main reste
    var userLink = StudyMap.Link(from: byID["e"]!, to: byID["d"]!, relation: .contrast, note: "à ne pas confondre", userMade: true)
    userLink.userMade = true
    let stale = StudyMap.Link(from: byID["a"]!, to: "disparu", relation: .needs)
    let merged = StudyLinks.merged(existing: [userLink, stale], generated: cited, keys: Set(keyed.map(\.key)))
    check(merged.contains(userLink) && !merged.contains(stale) && merged.count == cited.count + 1, "liens : ceux posés à la main restent, un lien vers rien tombe")
    check(StudyLinks.merged(existing: [userLink], generated: [userLink], keys: Set(keyed.map(\.key))).count == 1, "liens : pas de doublon")

    // Voisinage
    var map = StudyMap()
    map.links = cited + [userLink]
    let near = StudyLinks.neighbourhood(of: byID["b"]!, in: map, among: Set(keyed.map(\.key)))
    check(near.before.map(\.key) == [byID["a"]!] && near.after.map(\.key) == [byID["c"]!], "voisinage : ce qui précède (la définition), ce qui suit (la méthode)")
    check(StudyLinks.neighbourhood(of: byID["e"]!, in: map, among: Set(keyed.map(\.key))).aside.map(\.key) == [byID["d"]!], "voisinage : à ne pas confondre, dans les deux sens")
    check(StudyLinks.neighbourhood(of: byID["d"]!, in: map, among: Set(keyed.map(\.key))).aside.map(\.key) == [byID["e"]!], "voisinage : de l'autre côté aussi")

    // Parcours : une notion jamais avant ce dont elle a besoin
    var inverted = StudyMap()
    inverted.links = [StudyMap.Link(from: byID["a"]!, to: byID["d"]!, relation: .needs)]   // la définition 1.1 a besoin de la proposition 2.1 (située plus loin)
    let order = LearningPath.order(sheet: sheet, map: inverted)
    check(order.firstIndex(of: byID["d"]!)! < order.firstIndex(of: byID["a"]!)!, "parcours : la proposition passe avant ce qui en a besoin, même plus loin dans la fiche")
    check(Set(order) == Set(keyed.map(\.key)) && order.count == 6, "parcours : toutes les notions, une fois")
    check(LearningPath.order(sheet: sheet, map: StudyMap()) == keyed.map(\.key), "parcours : sans lien, l'ordre de la fiche")
    var cyclic = StudyMap()
    cyclic.links = [StudyMap.Link(from: byID["a"]!, to: byID["b"]!, relation: .needs), StudyMap.Link(from: byID["b"]!, to: byID["a"]!, relation: .needs)]
    check(LearningPath.order(sheet: sheet, map: cyclic).count == 6, "parcours : un cycle ne bloque rien")
    var progress = StudyMap()
    progress.links = cited
    check(LearningPath.next(sheet: sheet, map: progress) == keyed[0].key, "parcours : on commence par la première notion pas solide")
    progress.progress[keyed[0].key] = .init(level: .solid, at: Date())
    check(LearningPath.next(sheet: sheet, map: progress) != keyed[0].key, "parcours : une notion solide passe")
    progress.progress[keyed[1].key] = .init(level: .shaky, at: Date())
    let counts = LearningPath.counts(sheet: sheet, map: progress)
    check(counts.solid == 1 && counts.shaky == 1 && counts.unknown == 4 && counts.total == 6 && abs(counts.fraction - 1.0 / 6) < 1e-9, "parcours : le compte (solide, fragile, pas encore)")
    // Ce qui porte beaucoup pèse plus.
    var weak = StudyMap()
    weak.links = [StudyMap.Link(from: byID["b"]!, to: byID["a"]!, relation: .needs), StudyMap.Link(from: byID["c"]!, to: byID["a"]!, relation: .needs), StudyMap.Link(from: byID["e"]!, to: byID["a"]!, relation: .needs)]
    check(LearningPath.weakSpots(sheet: sheet, map: weak, limit: 1) == [byID["a"]!], "parcours : la notion dont trois autres dépendent est à reprendre d'abord")
    weak.progress[byID["a"]!] = .init(level: .solid, at: Date())
    check(!LearningPath.weakSpots(sheet: sheet, map: weak, limit: 10).contains(byID["a"]!), "parcours : le solide n'est pas à reprendre")
    check(LearningPath.shakyPrerequisites(of: byID["b"]!, map: weak, among: Set(keyed.map(\.key))).isEmpty, "parcours : prérequis tous solides, rien à reprendre d'abord")
    weak.progress[byID["a"]!] = .init(level: .shaky, at: Date())
    check(LearningPath.shakyPrerequisites(of: byID["b"]!, map: weak, among: Set(keyed.map(\.key))) == [byID["a"]!], "parcours : « reprends d'abord… » quand un prérequis est fragile")

    // Carte mentale
    var tidy = StudyMap()
    tidy.customNodes = [.init(id: "x1", title: "Mon idée", note: nil, parent: byID["b"]!), .init(id: "x2", title: "Orpheline", note: nil, parent: "disparu")]
    let nodes = MindGraph.nodes(sheet: sheet, map: tidy, courseTitle: "Analyse")
    check(nodes.first?.id == "root" && nodes.filter { $0.role == .chapter }.count == 2 && nodes.count == 1 + 2 + 6 + 2, "carte : la racine, les chapitres, les notions, les idées")
    check(nodes.first { $0.id == "custom:x1" }?.parent == byID["b"]! && nodes.first { $0.id == "custom:x2" }?.parent == "root", "carte : une idée est accrochée à sa notion, sinon à la racine")
    let positions = MindLayout.twoSided(nodes)
    check(positions["root"] == StudyMap.Point(x: 0, y: 0), "carte : la racine est au centre")
    check(nodes.filter { $0.depth == 1 && $0.role == .chapter }.contains { (positions[$0.id]?.x ?? 0) > 0 } && nodes.filter { $0.role == .chapter }.contains { (positions[$0.id]?.x ?? 0) < 0 }, "carte : les chapitres des deux côtés de la racine")
    var seenPoints = Set<String>()
    var overlap = false
    for node in nodes { if let p = positions[node.id], !seenPoints.insert("\(p.x)|\(p.y)").inserted { overlap = true } }
    check(!overlap && positions.count == nodes.count, "carte : pas deux nœuds au même endroit")
    let chapterX = nodes.filter { $0.role == .chapter }.compactMap { positions[$0.id]?.x }.map(abs)
    let entryX = nodes.filter { if case .entry = $0.role { return true } else { return false } }.compactMap { positions[$0.id]?.x }.map(abs)
    check(Set(chapterX).count == 1 && Set(entryX).count == 1 && entryX[0] > chapterX[0], "carte : une colonne par profondeur, les notions plus loin que les chapitres")
    let hiddenNodes = MindGraph.visible(nodes, collapsed: [MindGraph.chapterNode("c0")])
    check(hiddenNodes.count == nodes.count - 3 - 1 && !hiddenNodes.contains { $0.id == byID["a"]! } && hiddenNodes.contains { $0.id == MindGraph.chapterNode("c0") }, "carte : replier un chapitre cache ses notions (et leurs idées)")
    check(MindLayout.twoSided([]) .isEmpty, "carte : rien à placer, rien")
    let box = MindLayout.bounds(positions)!
    check(box.minX < 0 && box.maxX > 0, "carte : les bornes englobent les deux côtés")

    // Schémas
    var diagram = Diagram(id: "s", title: "Choisir", kind: .tree)
    diagram.nodes = [.init(id: "q", label: "Monotone ?"), .init(id: "y", label: "Oui : bornée ?"), .init(id: "n", label: "Non : Cauchy ?"), .init(id: "z", label: "Converge")]
    diagram.edges = [.init(from: "q", to: "y", label: "oui"), .init(from: "q", to: "n", label: "non"), .init(from: "y", to: "z"), .init(from: "n", to: "z")]
    let layout = DiagramLayout.layered(diagram)
    check(layout.layers.count == 3 && layout.layers[0] == ["q"] && Set(layout.layers[1]) == ["y", "n"] && layout.layers[2] == ["z"], "schéma : couches du plus long chemin")
    check(layout.positions["q"]!.y < layout.positions["y"]!.y && layout.positions["y"]!.y < layout.positions["z"]!.y, "schéma : de haut en bas")
    check(layout.positions["y"]!.x != layout.positions["n"]!.x && layout.width > 0 && layout.height > 0, "schéma : deux nœuds d'une couche côte à côte")
    check(abs(layout.positions["q"]!.x - layout.width / 2) < 1e-9 && abs(layout.positions["z"]!.x - layout.width / 2) < 1e-9, "schéma : une couche seule est centrée")
    var cycle = Diagram(id: "c", title: "Boucle", kind: .flow)
    cycle.nodes = [.init(id: "a", label: "A"), .init(id: "b", label: "B"), .init(id: "c", label: "C")]
    cycle.edges = [.init(from: "a", to: "b"), .init(from: "b", to: "c"), .init(from: "c", to: "a")]
    let looped = DiagramLayout.layered(cycle)
    check(looped.layers.count == 3 && looped.backEdges.count == 1 && looped.positions.count == 3, "schéma : un cycle est tracé, la flèche de retour mise à part")
    var broken = diagram
    broken.edges.append(.init(from: "q", to: "inconnu"))
    broken.edges.append(.init(from: "z", to: "z"))
    check(DiagramLayout.layered(broken).positions.count == 4, "schéma : une flèche vers rien ou vers soi-même est ignorée")
    check(DiagramLayout.layered(Diagram(id: "v", title: "Vide", kind: .flow)).positions.isEmpty, "schéma : vide, rien")

    // Réponse de Claude
    let (prompt, ids) = StudyMapAI.prompt(course: "Analyse", sheet: sheet)
    check(ids.count == 6 && prompt.contains("[e1] (definition) Définition 1.1") && prompt.contains("## Séries"), "IA : le message donne chaque notion avec son identifiant")
    let answer = """
    Voici :
    ```json
    {"entries":[{"id":"e2","gist":"Une suite qui monte sans dépasser un plafond finit par se poser.","why":"C'est le critère de convergence le plus utilisé.","example":"$u_n = 1 - 1/n$","question":"Pourquoi borné est-il nécessaire ?","answer":"Sinon elle peut diverger vers l'infini."},
                {"id":"e99","gist":"inconnue"}, {"id":"e5","gist":""}],
     "links":[{"from":"e2","to":"e1","relation":"needs","note":"borné"},{"from":"e5","to":"e4","relation":"à ne pas confondre"},{"from":"e2","to":"e77","relation":"needs"},{"from":"e2","to":"e1","relation":"???"}],
     "schemas":[{"title":"Choisir un critère","kind":"tree","nodes":[{"id":"n1","label":"Monotone ?","entry":"e2"},{"id":"n2","label":"Converge","entry":"e99"}],"edges":[{"from":"n1","to":"n2","label":"oui"},{"from":"n1","to":"zz"}]},
                {"title":"Trop petit","kind":"flow","nodes":[{"id":"x","label":"seul"}],"edges":[]},
                {"title":"Suite ou série","kind":"comparison","columns":["Suite","Série"],"rows":[["Objet","u_n","somme"]]},
                {"kind":"flow"}]}
    ```
    """
    var seeded = StudyMap()
    seeded.progress[byID["a"]!] = .init(level: .solid, at: Date(timeIntervalSince1970: 5))
    seeded.notes[byID["a"]!] = "ma note"
    seeded.links = [userLink]
    let applied = StudyMapAI.apply(answer: answer, sheet: sheet, ids: ids, to: seeded, now: Date(timeIntervalSince1970: 99))
    check(applied != nil, "IA : une réponse avec du texte et un bloc de code se lit")
    check(applied?.enrichment[byID["b"]!]?.gist?.hasPrefix("Une suite qui monte") == true && applied?.enrichment[byID["b"]!]?.check?.answer == "Sinon elle peut diverger vers l'infini.", "IA : la phrase en clair et la question")
    check(applied?.enrichment.count == 1, "IA : une notion inconnue ou vide ne donne rien")
    check(applied?.links.contains(userLink) == true && applied?.links.contains { $0.from == byID["b"]! && $0.to == byID["a"]! && $0.relation == .needs && $0.note == "borné" } == true, "IA : ses liens s'ajoutent, ceux posés à la main restent")
    check(applied?.links.contains { $0.relation == .contrast && $0.from == byID["e"]! && $0.to == byID["d"]! } == true, "IA : « à ne pas confondre » en toutes lettres devient un lien de contraste")
    check(applied?.links.filter { $0.to == "e77" || $0.relation == .needs && $0.to == byID["a"]! && $0.from == byID["b"]! }.count == 1, "IA : un lien vers une notion inconnue ou à la relation illisible tombe (sans doublon)")
    check(applied?.links.contains { $0.from == byID["b"]! && $0.to == byID["a"]! && $0.relation == .uses } == true, "IA : les citations de la fiche s'ajoutent aussi")
    check(applied?.diagrams.count == 2 && applied?.diagrams[0].kind == .tree && applied?.diagrams[0].nodes.count == 2, "IA : un schéma d'un seul nœud ou sans titre tombe")
    check(applied?.diagrams[0].nodes[0].entry == byID["b"]! && applied?.diagrams[0].nodes[1].entry == nil, "IA : un nœud désigne sa notion, ou rien si elle n'existe pas")
    check(applied?.diagrams[0].edges.count == 1, "IA : une flèche vers un nœud absent tombe")
    check(applied?.diagrams[1].kind == .comparison && applied?.diagrams[1].rows?.first == ["Objet", "u_n", "somme"], "IA : une comparaison garde ses colonnes et ses lignes")
    check(applied?.progress[byID["a"]!]?.level == .solid && applied?.notes[byID["a"]!] == "ma note", "IA : où tu en es et tes notes ne bougent pas")
    check(applied?.enrichedAt == Date(timeIntervalSince1970: 99), "IA : la date de l'enrichissement")
    check(StudyMapAI.apply(answer: "pas de json", sheet: sheet, ids: ids, to: seeded) == nil, "IA : une réponse sans JSON est refusée")

    // Une nouvelle fiche : ce qui désigne encore quelque chose reste
    let shorter = RevisionSheet(origin: .ai, generatedAt: Date(), chapters: [.init(id: "z0", title: "Nouveau", entries: [entry("a2", .definition, "Définition 1.1 (suite bornée)"), entry("b2", .theorem, "Théorème nouveau")])])
    var richer = applied!
    richer.customNodes = [.init(id: "x", title: "idée", note: nil, parent: nil)]
    let rebased = StudyMapAI.rebased(richer, onto: shorter)
    check(rebased.progress.keys.contains(byID["a"]!) && rebased.notes.count == 1, "nouvelle fiche : la maîtrise et les notes d'une notion qui existe encore restent")
    check(rebased.enrichment.isEmpty && rebased.links.allSatisfy { Set(shorter.keyed.map(\.key)).contains($0.from) && Set(shorter.keyed.map(\.key)).contains($0.to) }, "nouvelle fiche : ce qui désignait une notion disparue tombe")
    check(rebased.customNodes.count == 1, "nouvelle fiche : tes idées restent")

    // Garder
    let back = StudyMap.decode(applied!.encoded())
    check(back == applied, "carte : se relit telle qu'écrite")
    check(StudyMap.decode("") == nil && StudyMap.decode("pas du json") == nil, "carte : vide ou illisible, rien")
    check(StudyMap().isEmpty && !applied!.isEmpty, "carte : « vide » veut dire rien du tout")
    check(StudyMap.Relation.needs.label != StudyMap.Relation.needs.inverseLabel && StudyMap.Link(from: "a", to: "b", relation: .implies).prerequisite! == (before: "a", after: "b"), "liens : « implique » met le premier avant, « a besoin de » le second")
    check(StudyMap.Link(from: "a", to: "b", relation: .contrast).prerequisite == nil, "liens : un contraste n'a pas d'ordre")

    // Un même voisin n'est montré qu'une fois (citation + lien de Claude sur la même paire)
    var twice = StudyMap()
    twice.links = [.init(from: "x", to: "y", relation: .uses), .init(from: "x", to: "y", relation: .needs, note: "un plafond")]
    let once = StudyLinks.neighbourhood(of: "x", in: twice, among: ["x", "y"])
    check(once.before.count == 1 && once.before[0].note == "un plafond", "voisinage : un voisin une seule fois, avec l'explication")

    // Par chapitre : la même fiche, regardée un chapitre à la fois
    check(sheet.keyed(in: "c1").map(\.entry.id) == ["d", "e", "f"] && sheet.keyed(in: nil).count == 6 && sheet.keyed(in: "inconnu").isEmpty, "chapitre : ses notions, ou toutes")
    check(sheet.keyed(in: "c1").first?.key == keyed[3].key, "chapitre : les clés restent celles de la fiche entière")
    let oneChapter = MindGraph.nodes(sheet: sheet, map: StudyMap(), courseTitle: "Analyse", chapter: "c1")
    check(oneChapter.first?.title == "Séries" && oneChapter.first?.role == .root && oneChapter.count == 4 && oneChapter.dropFirst().allSatisfy { $0.parent == MindGraph.rootID && $0.depth == 1 }, "carte d'un chapitre : lui en racine, ses notions autour")
    var withIdea = StudyMap()
    withIdea.customNodes = [.init(id: "i", title: "idée", note: nil, parent: MindGraph.chapterNode("c1")), .init(id: "j", title: "ailleurs", note: nil, parent: MindGraph.chapterNode("c0"))]
    let ideas = MindGraph.nodes(sheet: sheet, map: withIdea, courseTitle: "Analyse", chapter: "c1").filter { $0.role == .custom }
    check(ideas.map(\.title) == ["idée"] && ideas[0].parent == MindGraph.rootID, "carte d'un chapitre : seulement les idées de ce chapitre")
    var mastered = StudyMap()
    mastered.progress[keyed[3].key] = .init(level: .solid, at: Date())
    check(LearningPath.counts(sheet: sheet, map: mastered, chapter: "c1") == .init(unknown: 2, shaky: 0, solid: 1) && LearningPath.counts(sheet: sheet, map: mastered).total == 6, "parcours d'un chapitre : le compte de ce chapitre seul")
    check(LearningPath.order(sheet: sheet, map: mastered, chapter: "c1").count == 3 && LearningPath.next(sheet: sheet, map: mastered, chapter: "c1") == keyed[4].key, "parcours d'un chapitre : l'ordre et la suite de ce chapitre")

    let scopedPrompt = StudyMapAI.prompt(course: "Analyse", sheet: sheet, chapter: "c1")
    check(scopedPrompt.text.contains("CHAPITRE : Séries") && !scopedPrompt.text.contains("Théorème 1.2") && scopedPrompt.ids.count == 3 && scopedPrompt.ids["e4"] == keyed[3].key, "IA d'un chapitre : seulement ses notions, avec leurs identifiants de la fiche entière")
    let chapterAnswer = """
    {"entries":[{"id":"e4","gist":"Si les termes se rapprochent, ça converge."}],
     "links":[{"from":"e5","to":"e4","relation":"contrast","note":"à ne pas confondre"}],
     "schemas":[{"title":"Cauchy","kind":"flow","nodes":[{"id":"a","label":"Termes proches"},{"id":"b","label":"Converge"}],"edges":[{"from":"a","to":"b"}]}]}
    """
    var base = StudyMap()
    base.links = [.init(from: keyed[1].key, to: keyed[0].key, relation: .needs, note: "d'ailleurs")]
    base.diagrams = [Diagram(id: "ailleurs", title: "Autre chapitre", summary: nil, kind: .flow)]
    let scoped = StudyMapAI.apply(answer: chapterAnswer, sheet: sheet, ids: scopedPrompt.ids, to: base, now: Date(timeIntervalSince1970: 5), chapter: "c1")
    check(scoped != nil && scoped!.enrichment[keyed[3].key]?.gist != nil && scoped!.enrichedChapters?["c1"] == Date(timeIntervalSince1970: 5) && scoped!.enrichedAt == nil, "IA d'un chapitre : la phrase en clair, et ce chapitre est noté comme relu (pas le cours)")
    check(scoped!.links.contains { $0.from == keyed[1].key && $0.note == "d'ailleurs" } && scoped!.links.contains { $0.relation == .contrast }, "IA d'un chapitre : les liens des autres chapitres restent, les siens s'ajoutent")
    check(scoped!.diagrams.count == 2 && scoped!.diagrams.contains { $0.chapter == "c1" && $0.title == "Cauchy" } && scoped!.diagrams.contains { $0.id == "ailleurs" }, "IA d'un chapitre : son schéma s'ajoute, celui d'un autre reste")
    let again = StudyMapAI.apply(answer: chapterAnswer, sheet: sheet, ids: scopedPrompt.ids, to: scoped!, chapter: "c1")!
    check(again.diagrams.count == 2, "IA d'un chapitre : refaire remplace ses schémas au lieu de les doubler")
    let whole = StudyMapAI.apply(answer: "{\"schemas\":[{\"title\":\"Tout\",\"kind\":\"flow\",\"nodes\":[{\"id\":\"a\",\"label\":\"x\"},{\"id\":\"b\",\"label\":\"y\"}],\"edges\":[{\"from\":\"a\",\"to\":\"b\"}]}]}", sheet: sheet, ids: [:], to: scoped!)!
    check(whole.diagrams.contains { $0.chapter == "c1" } && whole.diagrams.contains { $0.title == "Tout" && $0.chapter == nil } && !whole.diagrams.contains { $0.id == "ailleurs" }, "IA du cours : remplace ceux du cours, garde ceux des chapitres")
    let gone = StudyMapAI.rebased(scoped!, onto: RevisionSheet(origin: .ai, generatedAt: Date(), chapters: [.init(id: "c0", title: "Suites", entries: [entry("a", .definition, "Définition 1.1 (suite bornée)", "x")])]))
    check(gone.enrichedChapters?["c1"] == nil && gone.diagrams.allSatisfy { $0.chapter == nil }, "nouvelle fiche : un chapitre disparu ne laisse rien derrière lui")

    let chapterFiles = NotebookExport.files(courseName: "Analyse", code: "MATH-101", sheet: sheet, map: scoped!, chapter: "c1")
    let chapterSheet = chapterFiles.first { $0.name.hasPrefix("01") }?.text ?? ""
    check(chapterSheet.contains("Piège : série et suite") && !chapterSheet.contains("Théorème 1.2") && chapterFiles.allSatisfy { $0.name.contains("Séries") }, "NotebookLM d'un chapitre : seulement ses notions, nommé d'après lui")
    check((chapterFiles.first { $0.name.hasPrefix("03") }?.text ?? "").contains("Cauchy") && !(chapterFiles.first { $0.name.hasPrefix("03") }?.text ?? "").contains("Autre chapitre"), "NotebookLM d'un chapitre : seulement ses schémas")

    // NotebookLM
    var notebook = applied!
    notebook.enrichment[byID["a"]!] = .init(gist: "Un plafond et un plancher.", why: nil, example: nil, check: nil)
    let files = NotebookExport.files(courseName: "Analyse I", code: "MATH-101", sheet: sheet, map: notebook)
    check(files.map(\.name).contains("01 Fiche · MATH-101.md") && files.map(\.name).contains("02 Liens entre les notions · MATH-101.md") && files.map(\.name).contains("03 Schémas · MATH-101.md")
          && files.map(\.name).contains("04 Questions pour se tester · MATH-101.md") && files.map(\.name).contains("00 Lis-moi · MATH-101.md"), "NotebookLM : la fiche, les liens, les schémas, les questions, le mode d'emploi")
    let sheetFile = files.first { $0.name.hasPrefix("01") }!.text
    check(sheetFile.contains("### Théorème 1.2 (monotone bornée) (Théorème)") && sheetFile.contains("En clair : Un plafond et un plancher.") && sheetFile.contains("À comprendre avant : Définition 1.1 (suite bornée)"), "NotebookLM : chaque notion avec son en clair et ce qu'il faut comprendre avant")
    check(files.first { $0.name.hasPrefix("02") }!.text.contains("**Théorème 1.2 (monotone bornée)** a besoin de **Définition 1.1 (suite bornée)** — borné"), "NotebookLM : les liens en phrases")
    check(files.first { $0.name.hasPrefix("03") }!.text.contains("| Objet | u_n | somme |") && files.first { $0.name.hasPrefix("03") }!.text.contains("Monotone ? →"), "NotebookLM : un tableau et les flèches des schémas")
    check(NotebookExport.files(courseName: "X", code: "X", sheet: sheet, map: StudyMap()).map(\.name) == ["01 Fiche · X.md", "00 Lis-moi · X.md"], "NotebookLM : sans liens ni schémas, la fiche seule")
}

// MARK: Une épreuve n'est pas un devoir
do {
    check(ExamKind.exam.isSitting && ExamKind.midterm.isSitting, "épreuve : un examen et un midterm comptent")
    check(!ExamKind.quiz.isSitting && !ExamKind.assignment.isSitting && !ExamKind.project.isSitting && !ExamKind.other.isSitting,
          "épreuve : un quiz, un devoir, un projet ou une échéance importée ne font pas passer en révision")
}

// MARK: Bureau selon le contexte
do {
    typealias D = DeskArrangement
    func ctx(_ moment: DeskMoment = .series, _ edit: (inout D.Context) -> Void = { _ in }) -> D.Context {
        var c = D.Context(moment: moment); edit(&c); return c
    }
    let doing = D.layout(for: ctx { $0.hasTarget = true; $0.hasCopy = true })
    check(doing.center == .exercise && doing.side == [.copy] && doing.sideOpen, "bureau : un exercice en cours → l'énoncé au centre, ta copie à côté")
    let notesOnly = D.layout(for: ctx { $0.hasTarget = true; $0.hasCourseNotes = true })
    check(notesOnly.side == [.courseNotes], "bureau : sans copie, les notes du cours à côté")
    let nothing = D.layout(for: ctx { $0.hasTarget = true })
    check(nothing.center == .exercise && nothing.side.isEmpty && !nothing.sideOpen, "bureau : rien à garder à côté, le volet reste fermé")
    let done = D.layout(for: ctx { $0.hasTarget = true; $0.targetDone = true; $0.solutionAvailable = true; $0.hasCopy = true })
    check(done.side == [.solution], "bureau : fait et corrigé publié → le corrigé vient à côté")
    let notPublished = D.layout(for: ctx { $0.hasTarget = true; $0.targetDone = true; $0.hasCopy = true })
    check(notPublished.side == [.copy], "bureau : corrigé pas publié → la copie reste")
    check(D.layout(for: ctx { $0.hasTarget = true; $0.seriesComplete = true }).openClaude, "bureau : série finie → Claude pour clore")
    check(!D.layout(for: ctx { $0.hasTarget = true }).openClaude, "bureau : série en cours → pas de Claude d'office")
    let writing = D.layout(for: ctx { $0.hasTarget = true; $0.hasCopy = true; $0.writingApp = true })
    check(writing.side == [.series] && writing.sideOpen, "bureau : GoodNotes au centre → l'énoncé à côté (écrire au centre, lire à côté)")
    check(D.signature(ctx { $0.hasTarget = true; $0.writingApp = true }) != D.signature(ctx { $0.hasTarget = true }), "bureau : entrer dans GoodNotes est un changement de moment")
    check(D.layout(for: ctx(.lecture) { $0.hasTarget = true; $0.writingApp = true }).side.isEmpty, "bureau : en cours, GoodNotes ne déplace rien")
    let theory = D.layout(for: ctx { $0.isTheory = true; $0.hasCourseNotes = true })
    check(theory.center == .course && theory.side == [.courseNotes], "bureau : théorie → le cours au centre, les notes à côté")
    let lecture = D.layout(for: ctx(.lecture) { $0.hasTarget = true })
    check(lecture.center == .desk && lecture.side.isEmpty && !lecture.openClaude, "bureau : en cours → l'accueil du cours, rien à côté")
    let revision = D.layout(for: ctx(.revision))
    check(revision.center == .desk && revision.side == [.sheet] && revision.sideOpen, "bureau : révision → l'accueil et la fiche à côté")
    check(D.layout(for: ctx()).center == .desk, "bureau : sans cible → l'accueil")
    check(D.layout(for: ctx(.together) { $0.hasTarget = true }).center == .exercise, "bureau : ensemble → comme une série")
    // Ce qui prend l'écran.
    check(D.takeover(for: ctx { $0.phase = .onBreak }) == .onBreak, "bureau : une pause Pomodoro prend l'écran")
    check(D.takeover(for: ctx { $0.phase = .paused }) == .paused, "bureau : la pause manuelle aussi")
    check(D.takeover(for: ctx { $0.minutesLeft = 4 }) == .wrapUp && D.takeover(for: ctx { $0.minutesLeft = 5 }) == .wrapUp, "bureau : cinq minutes avant la fin → le bilan")
    check(D.takeover(for: ctx { $0.minutesLeft = 6 }) == .none && D.takeover(for: ctx()) == .none, "bureau : assez de temps, ou sans fin → rien")
    check(D.takeover(for: ctx(.lecture) { $0.classBreak = true }) == .classBreak, "bureau : la pause du cours")
    check(D.takeover(for: ctx { $0.phase = .ended; $0.minutesLeft = 1 }) == .none, "bureau : session finie → rien")
    // Épingles : le bureau ne bouge pas sous les mains.
    let base = ctx { $0.hasTarget = true; $0.hasCopy = true }
    let key = D.signature(base)
    check(key == D.signature(base) && key != D.signature(ctx { $0.hasTarget = true; $0.hasCopy = true; $0.targetDone = true }), "bureau : la clé change avec le moment")
    check(D.signature(ctx { $0.minutesLeft = 40 }) == D.signature(ctx { $0.minutesLeft = 12 }), "bureau : les minutes qui passent ne changent pas la clé")
    check(D.signature(ctx { $0.phase = .paused }) == D.signature(ctx { $0.phase = .running }), "bureau : mettre en pause puis reprendre ne réarrange pas")
    check(D.signature(ctx { $0.phase = .onBreak }) == D.signature(ctx { $0.minutesLeft = 3 }), "bureau : une pause ou le bilan ne réarrangent pas non plus")
    var pins = D.Pins(center: true, side: false, claude: false)
    check(D.pins(pins, previous: key, current: key) == pins, "bureau : même moment → les épingles restent")
    check(D.pins(pins, previous: key, current: "autre").isEmpty, "bureau : nouveau moment → les épingles tombent")
    let applicable = D.applicable(D.layout(for: base), pins: pins)
    check(applicable.center == nil && applicable.side == [.copy], "bureau : le centre épinglé n'est pas touché, le côté oui")
    pins = D.Pins(center: false, side: true, claude: true)
    let again = D.applicable(D.layout(for: ctx { $0.hasTarget = true; $0.seriesComplete = true }), pins: pins)
    check(again.center == .exercise && again.side == nil && !again.claude, "bureau : le côté et Claude épinglés ne bougent pas")
}

// MARK: Notifications du bureau
do {
    typealias N = DeskNotice
    let t0 = Date(timeIntervalSince1970: 1000)
    func item(_ kind: N.Kind, _ text: String, at offset: TimeInterval) -> N.Item { N.Item(kind: kind, text: text, icon: "x", at: t0.addingTimeInterval(offset)) }
    var queue: [N.Item] = []
    queue = N.adding(item(.blockedApp, "Safari", at: 0), to: queue)
    let firstID = queue[0].id
    queue = N.adding(item(.blockedApp, "Mail", at: 2), to: queue)
    check(queue.count == 1 && queue[0].text == "Mail" && queue[0].id == firstID, "notifications : deux du même genre à moins de 4 s n'en font qu'une")
    queue = N.adding(item(.blockedApp, "Notes", at: 10), to: queue)
    check(queue.count == 2, "notifications : plus de 4 s après, une autre")
    queue = N.adding(item(.iPhone, "Photo", at: 10), to: queue)
    queue = N.adding(item(.claude, "Réponse", at: 11), to: queue)
    check(queue.count == N.maxVisible && queue.first?.text == "Notes", "notifications : trois au plus, la plus ancienne part")
    check(N.visible(queue, at: t0.addingTimeInterval(12)).count == 3, "notifications : elles restent un moment")
    check(N.visible(queue, at: t0.addingTimeInterval(15)).map(\.kind) == [.claude], "notifications : chacune part à son heure")
    check(N.visible(queue, at: t0.addingTimeInterval(30)).isEmpty, "notifications : puis plus rien")
    check(N.duration(.claude) > N.duration(.blockedApp), "notifications : la réponse de Claude reste plus longtemps")
    check([N.Kind.classSoon, .solution, .breakSoon, .info].allSatisfy { N.duration($0) > 0 }, "notifications : chaque genre a une durée")
    var history: [N.Item] = []
    for i in 0..<30 { history = N.remembering(item(.info, "n\(i)", at: Double(i)), in: history) }
    check(history.count == N.historyLimit && history.first?.text == "n29" && history.last?.text == "n10", "notifications : l'historique garde les vingt dernières, la plus récente d'abord")
    let again = item(.info, "frais", at: 40)
    var merged = N.remembering(again, in: [])
    var refreshed = again; refreshed.text = "plus frais"
    merged = N.remembering(refreshed, in: merged)
    check(merged.count == 1 && merged[0].text == "plus frais", "notifications : une notification fusionnée n'est qu'une fois dans l'historique")
}

// MARK: Cartes du bureau
do {
    typealias W = DeskWidgets
    func kinds(_ list: [W.Placement]) -> [W.Kind] { list.map(\.kind) }
    let free = W.defaults(W.Context(moment: .series, hasCourse: false))
    check(kinds(free).first == .courses && kinds(free).contains(.today) && !kinds(free).contains(.target) && !kinds(free).contains(.steps), "cartes : session libre → choisir sur quoi, l'horaire, rien sur une cible")
    let course = W.defaults(W.Context(moment: .series, hasCourse: true, hasSeries: true, hasTarget: true))
    check(Array(kinds(course).prefix(2)) == [.session, .target] && kinds(course).contains(.steps), "cartes : un exercice visé → la session, l'exercice, les étapes")
    check(!kinds(course).contains(.upNext), "cartes : l'exercice montre déjà la suite, pas de seconde liste")
    check(kinds(W.defaults(W.Context(moment: .series, hasCourse: true, hasSeries: true))).contains(.upNext) && !kinds(W.defaults(W.Context(moment: .series, hasCourse: true, hasSeries: true))).contains(.target),
          "cartes : une série sans exercice visé → la suite, pas de carte d'exercice")
    check(!kinds(W.defaults(W.Context(moment: .series, hasCourse: true))).contains(.upNext), "cartes : sans série, pas de « suite »")
    check(!kinds(course).contains(.redo) && kinds(W.defaults(W.Context(moment: .series, hasCourse: true, redosDue: 2))).contains(.redo), "cartes : les reprises seulement quand il y en a")
    check(kinds(W.defaults(W.Context(moment: .series, hasCourse: true, daysToExam: 10))).contains(.exam) && !kinds(W.defaults(W.Context(moment: .series, hasCourse: true, daysToExam: 60))).contains(.exam), "cartes : l'examen à moins de trois semaines")
    let revisionCards = kinds(W.defaults(W.Context(moment: .revision, hasCourse: true)))
    check(revisionCards.first == .revisionExam && revisionCards.contains(.revisionPast) && revisionCards.contains(.revisionSheet), "cartes : en révision, l'examen, la fiche, les annales")
    let lectureCards = kinds(W.defaults(W.Context(moment: .lecture, hasCourse: true)))
    check(lectureCards.first == .lectureClock && lectureCards.contains(.lectureMarks) && lectureCards.contains(.lectureWeek) && !lectureCards.contains(.target),
          "cartes : en cours, l'horloge, les repères, la semaine — pas d'exercice")
    check(kinds(course).contains(.deadlines) && kinds(free).contains(.deadlines), "cartes : les échéances de la semaine sont là")
    check(!kinds(course).contains(.group) && kinds(W.defaults(W.Context(moment: .series, hasCourse: true, hasSeries: true, inGroup: true, hasTarget: true))).contains(.group),
          "cartes : les membres du groupe seulement en session commune")
    check(!kinds(W.defaults(W.Context(moment: .lecture, hasCourse: false))).contains(.lectureClock), "cartes : un cours sans cours choisi reste une session libre")
    // Rangement de l'étudiant·e
    var mine = course
    mine = W.toggled(.claude, in: mine)
    mine = W.resized(.music, in: mine)
    check(mine.first { $0.kind == .claude }?.hidden == true && mine.first { $0.kind == .music }?.size == .medium, "cartes : masquer, agrandir")
    check(W.resized(.music, in: W.resized(.music, in: mine)).first { $0.kind == .music }?.size == .small, "cartes : la taille tourne (petite, moyenne, grande, petite)")
    let merged = W.merged(defaults: course, stored: mine)
    check(merged == mine, "cartes : ce qui est rangé est gardé tel quel")
    let withRedo = W.merged(defaults: W.defaults(W.Context(moment: .series, hasCourse: true, hasSeries: true, redosDue: 1)), stored: mine)
    check(withRedo.contains { $0.kind == .redo } && withRedo.first { $0.kind == .claude }?.hidden == true, "cartes : une carte du moment jamais vue s'ajoute, le reste est gardé")
    check(W.merged(defaults: course, stored: nil) == course, "cartes : sans rangement, les cartes du moment")
    let stale = W.merged(defaults: free, stored: course)
    check(!stale.contains { $0.kind == .target }, "cartes : une carte que le moment n'offre pas ne reste pas")
    let moved = W.moved(.target, by: 1, in: course)
    check(moved[1].kind == .steps || moved.firstIndex { $0.kind == .target }! > course.firstIndex { $0.kind == .target }!, "cartes : déplacer d'un cran")
    check(W.moved(.session, by: -1, in: course) == course, "cartes : la première ne remonte pas")
    var hiddenMid = course
    hiddenMid = W.toggled(.target, in: hiddenMid)
    let skip = W.moved(.session, by: 1, in: hiddenMid)
    check(skip.firstIndex { $0.kind == .session }! > skip.firstIndex { $0.kind == .target }!, "cartes : déplacer saute les cartes masquées")
    check(W.decode(W.encode(mine)) == mine && W.decode(nil) == nil && W.decode(Data("x".utf8)) == nil, "cartes : le rangement voyage en JSON")
    check(W.columnCount(available: 1360) == 4 && W.columnCount(available: 1000) == 3 && W.columnCount(available: 640) == 2 && W.columnCount(available: 400) == 1 && W.columnCount(available: 100) == 1,
          "cartes : la grille a de une à quatre colonnes selon la place")
    check(W.columnCount(available: 3000) == W.maximumColumns, "cartes : jamais plus de quatre colonnes")
    check(W.span(of: .large, columns: 4) == 3 && W.span(of: .large, columns: 2) == 2 && W.span(of: .medium, columns: 1) == 1 && W.span(of: .small, columns: 4) == 1,
          "cartes : une carte ne dépasse jamais la grille")
    check(W.storageKey(.lecture) != W.storageKey(.series), "cartes : un bureau par moment")
    check(W.Size.small.span < W.Size.medium.span && W.Size.medium.span < W.Size.large.span, "cartes : trois tailles")
}

// MARK: Géométrie du bureau (placement des apps permises)
do {
    typealias G = DeskGeometry
    // Écran principal de 982 pt ; fenêtre du bureau plein écran ; centre à (100, 86), 1100 × 700 depuis le haut.
    let window = G.Rect(x: 0, y: 0, width: 1512, height: 982)
    let hole = G.accessibilityRect(window: window, local: G.Rect(x: 100, y: 86, width: 1100, height: 700), primaryHeight: 982)
    check(hole == G.Rect(x: 100, y: 86, width: 1100, height: 700), "géométrie : fenêtre plein écran, le repère de l'Accessibilité est celui de SwiftUI")
    let preview = G.Rect(x: 80, y: 20, width: 1440, height: 900)   // en repère AppKit : haut à 920
    let shifted = G.accessibilityRect(window: preview, local: G.Rect(x: 100, y: 86, width: 1000, height: 600), primaryHeight: 982)
    check(shifted.x == 180 && shifted.y == 62 + 86, "géométrie : une fenêtre décalée (haut à 982 − 920 = 62)")
    let fill = G.placement(current: G.Rect(x: 0, y: 0, width: 400, height: 300), minimum: nil, resizable: true, in: hole)
    check(fill == hole, "placement : une fenêtre redimensionnable remplit le trou")
    let big = G.placement(current: G.Rect(x: 0, y: 0, width: 400, height: 300), minimum: (width: 1300, height: 500), resizable: true, in: hole)
    check(big.width == 1300 && big.x == hole.x && big.height == 700, "placement : un minimum plus large que le trou part du coin haut-gauche")
    let fixed = G.placement(current: G.Rect(x: 0, y: 0, width: 400, height: 300), minimum: nil, resizable: false, in: hole)
    check(fixed == G.Rect(x: 450, y: 286, width: 400, height: 300), "placement : une fenêtre de taille fixe est centrée dans le trou")
    let huge = G.placement(current: G.Rect(x: 0, y: 0, width: 2000, height: 1200), minimum: nil, resizable: false, in: hole)
    check(huge.x == hole.x && huge.y == hole.y, "placement : trop grande, elle part du coin haut-gauche")
    check(hole.contains(fixed) && !hole.contains(huge) && hole.contains(hole), "géométrie : « contenu dans le trou »")
    // Fenêtres du bureau : écran 1512 × 982, barre 66, colonne 76.
    let full = G.Rect(x: 0, y: 0, width: 1512, height: 982)
    let noDock = PanelLayout.frames(screen: full, visible: G.Rect(x: 0, y: 0, width: 1512, height: 958), bar: 66, rail: 76, sideWidth: nil, secondScreen: nil)
    check(noDock.bar == G.Rect(x: 0, y: 916, width: 1512, height: 66) && noDock.rail == G.Rect(x: 0, y: 0, width: 76, height: 916), "fenêtres : barre en haut, colonne dessous")
    check(noDock.desk == G.Rect(x: 75, y: 0, width: 1437, height: 917) && noDock.side == nil, "fenêtres : le bureau passe 1 pt sous la barre et la colonne, rien à côté")
    let withSide = PanelLayout.frames(screen: full, visible: G.Rect(x: 0, y: 0, width: 1512, height: 958), bar: 66, rail: 76, sideWidth: 460, secondScreen: nil)
    check(withSide.desk.width == 1437 - 460 && withSide.side == G.Rect(x: 1052, y: 0, width: 460, height: 916), "fenêtres : le volet prend la droite, le centre le reste")
    let dockBottom = PanelLayout.frames(screen: full, visible: G.Rect(x: 0, y: 70, width: 1512, height: 888), bar: 66, rail: 76, sideWidth: nil, secondScreen: nil)
    check(dockBottom.desk.y == 70 && dockBottom.rail.y == 70 && dockBottom.rail.height == 846, "fenêtres : un Dock visible n'est jamais recouvert")
    let dockLeft = PanelLayout.frames(screen: full, visible: G.Rect(x: 80, y: 0, width: 1432, height: 958), bar: 66, rail: 76, sideWidth: nil, secondScreen: nil)
    check(dockLeft.rail.x == 80 && dockLeft.desk.x == 155, "fenêtres : un Dock à gauche pousse la colonne")
    let second = G.Rect(x: 1512, y: 0, width: 1920, height: 1080)
    let onSecond = PanelLayout.frames(screen: full, visible: G.Rect(x: 0, y: 0, width: 1512, height: 958), bar: 66, rail: 76, sideWidth: 460, secondScreen: second)
    check(onSecond.side == second && onSecond.desk.width == 1437, "fenêtres : le volet sur un second écran le remplit, le centre garde toute la largeur")
    check(StudyReadiness.missing(blocking: false, placeApps: true, trusted: false, hideChrome: true, automationGranted: false).isEmpty, "permissions : sans blocage, rien à demander")
    check(StudyReadiness.missing(blocking: true, placeApps: true, trusted: false, hideChrome: true, automationGranted: false) == [.accessibility, .systemEvents], "permissions : Accessibilité et System Events manquent")
    check(StudyReadiness.missing(blocking: true, placeApps: false, trusted: false, hideChrome: false, automationGranted: false).isEmpty, "permissions : réglages éteints, rien à demander")
    check(StudyReadiness.missing(blocking: true, placeApps: true, trusted: true, hideChrome: true, automationGranted: true).isEmpty, "permissions : tout est accordé")
    check(StudyMode.writingApps.contains("com.goodnotesapp.x") && !StudyMode.writingApps.contains("com.anthropic.claudefordesktop"), "apps d'écriture : GoodNotes oui, Claude non")
}

// MARK: Une app permise un moment
do {
    let t0 = Date(timeIntervalSince1970: 5000)
    var allowance = TemporaryAllowance()
    check(allowance.allowed(at: t0).isEmpty && allowance.nextExpiry(after: t0) == nil, "permission brève : rien au départ")
    allowance.allow("com.apple.systempreferences", for: 90, now: t0)
    check(allowance.allowed(at: t0.addingTimeInterval(60)) == ["com.apple.systempreferences"], "permission brève : permise pendant sa durée")
    check(allowance.allowed(at: t0.addingTimeInterval(91)).isEmpty, "permission brève : bloquée de nouveau après")
    check(allowance.nextExpiry(after: t0) == t0.addingTimeInterval(90) && allowance.nextExpiry(after: t0.addingTimeInterval(100)) == nil, "permission brève : l'heure de fin")
    allowance.allow("com.apple.systempreferences", for: 30, now: t0.addingTimeInterval(80))
    check(allowance.allowed(at: t0.addingTimeInterval(100)) == ["com.apple.systempreferences"], "permission brève : redemandée, elle repart")
}

// MARK: Série révisée : les exercices suivent leur contenu (AICC semaine 6)
do {
    typealias I = SeriesReconciler.Item
    // Ce que l'app avait importé (première version du PDF)…
    let stored = [
        I(number: "6.1", title: "Telescoping", statement: "Show that \\sum_{j=1}^n (a_j-a_{j-1})=a_n-a_0 for a sequence of real numbers."),
        I(number: "6.2", title: "Sum both sides of the identity k2", statement: "Use k^2-(k-1)^2=2k-1 and Exercise 1 to find formulas for two sums."),
        I(number: "6.3", title: "Sorting algorithms", statement: "Use Bubble Sort, Selection Sort, and Insertion Sort to sort the given sequence."),
        I(number: "6.4", title: "Bubble sort", statement: "Adapt bubble sort to stop when no swaps are required and express it in pseudocode."),
        I(number: "6.5", title: "Anagrams", statement: "Devise an algorithm to determine whether two strings are anagrams."),
        I(number: "6.6", title: "Injective functions", statement: "Describe an algorithm to determine whether a function between finite sets is injective."),
        I(number: "6.7", title: "Stable matching", statement: "Determine whether the given matching is unstable, stable and optimal, or stable but not optimal."),
        I(number: "6.8", title: "Making change", statement: "Use the cashier's algorithm to make change using quarters, dimes, nickels, and pennies."),
        I(number: "6.9", title: "Gale-Shapley algorithm", statement: "Find the matchings produced by the Gale-Shapley algorithm for both proposer groups and identify a's best stable partner."),
        I(number: "6.10", title: "Sorting algorithm analysis", statement: "Count comparisons and swaps for the given sequence, then determine their worst-case order for input length n+1."),
    ]
    // …et le PDF révisé, tel que la lecture le donne (titre vide, début de l'énoncé).
    let revised = [
        I(number: "6.1", title: "", statement: "(Repeated from Week 5) Solve the following recurrence relation using generating functions: an = 4an−1 − 4an−2, n ≥ 2, with a0 = 1 and a1 = 4."),
        I(number: "6.2", title: "", statement: "Show that ∑ (aj − aj−1) = an − a0, where a0, a1, ..., an is a sequence of real numbers. This type of sum is called telescoping."),
        I(number: "6.3", title: "", statement: "Sum both sides of the identity k2 − (k − 1)2 = 2k − 1 from k = 1 to k = n and use Exercise 2 to find a formula for the sum of the first n odd natural numbers"),
        I(number: "6.4", title: "", statement: "The following three algorithms sort the input sequence of real numbers in ascending order. Use Bubble Sort, Selection Sort and Insertion Sort to sort the following sequence"),
        I(number: "6.5", title: "", statement: "Adapt the bubble sort algorithm so that it stops when no swaps are required (when the list is sorted). Express this more efficient version of the algorithm in pseudocode."),
        I(number: "6.6", title: "", statement: "Two strings are anagrams if each can be formed from the other string by rearranging its characters. Devise an algorithm to determine whether two strings are anagrams"),
        I(number: "6.7", title: "", statement: "Describe an algorithm that determines whether a function from a finite set to another finite set is injective."),
        I(number: "6.8", title: "", statement: "We use Bubble Sort, Selection Sort, and Insertion Sort to sort the following sequence. How many comparisons are done in each of the algorithms? How many swaps? In the worst-case scenario, what is the order"),
    ]
    let found = SeriesReconciler.match(existing: stored, incoming: revised)
    check(found == [nil, 0, 1, 2, 3, 4, 5, 9], "série révisée : chaque exercice retrouve le sien (\(found))")
    check(SeriesReconciler.match(existing: stored, incoming: stored) == Array(0..<10).map { Optional($0) }, "même énoncé : rien ne bouge")
    let renumbered = stored.enumerated().map { I(number: "6.\($0.offset + 3)", title: $0.element.title, statement: $0.element.statement) }
    check(SeriesReconciler.match(existing: stored, incoming: renumbered) == Array(0..<10).map { Optional($0) }, "numéros changés : le contenu l'emporte")
    check(SeriesReconciler.match(existing: [], incoming: revised).allSatisfy { $0 == nil }, "série vide : tout est nouveau")
    let blank = [I(number: "6.1", title: "", statement: ""), I(number: "6.2", title: "", statement: "")]
    check(SeriesReconciler.match(existing: blank, incoming: blank) == [0, 1], "sans texte : le numéro départage")
    check(SeriesLayoutParser.firstSentence(of: "Exercise 5. Adapt the bubble sort algorithm so that it stops when no swaps are required (when the list is sorted). Express this in pseudocode.")
          == "Adapt the bubble sort algorithm so that it stops when no swaps are required (when the list is sorted).", "énoncé lu dans le PDF : la première phrase, sans « Exercise 5. »")

    // L'écriture : l'avancement suit l'exercice, les retirés vierges partent,
    // un retiré déjà travaillé reste, marqué.
    let aicc = Course(code: "CS-101", name: "AICC", credits: 4)
    let first = SeriesDraftWriter.write(SeriesDraft(number: 6, title: "", plannedWeek: 6, exercises: stored.map { item in
        var draft = ExerciseDraft(minor: String(item.number.dropFirst(2)), title: item.title, isBonus: false)
        draft.statement = item.statement
        return draft
    }), to: aicc, mode: .importMerge, context: nil).series
    let telescoping = first.sortedExercises[0]
    telescoping.doneAt = Date()
    let matching = first.sortedExercises[6]
    matching.confidenceRaw = ConfidenceLevel.medium.rawValue
    let revision = SeriesDraftWriter.write(SeriesDraft(existingID: first.id, number: 6, title: "", plannedWeek: 6, exercises: revised.map { item in
        var draft = ExerciseDraft(minor: String(item.number.dropFirst(2)), title: item.title, isBonus: false)
        draft.statement = item.statement
        return draft
    }), to: aicc, mode: .revision, context: nil)
    let now6 = revision.series.sortedExercises
    check(revision.outcome == .init(created: 1, updated: 7, deleted: 3), "révision : 1 nouveau, 7 retrouvés, 3 retirés supprimés — \(revision.outcome)")
    check(now6.prefix(8).map(\.exerciseNumber) == (1...8).map { "6.\($0)" }, "révision : numéros du PDF")
    check(telescoping.exerciseNumber == "6.2" && telescoping.isDone && telescoping.title == "Telescoping", "le télescopage devient 6.2 et reste fait")
    check(now6[0].statement.contains("generating functions") && !now6[0].isDone, "6.1 est le nouvel exercice, vierge")
    check(revision.series.exercises.count == 8 && !revision.series.exercises.contains { $0.id == matching.id },
          "retiré de l'énoncé : supprimé, même déjà commencé")
}

// MARK: Réveil des autres appareils (verrou)
do {
    check(TimerLink.shouldWake(previous: nil, now: true), "réveil : un premier état verrouillé réveille")
    check(!TimerLink.shouldWake(previous: nil, now: false), "réveil : un premier état libre, non")
    check(TimerLink.shouldWake(previous: true, now: false), "réveil : le verrou se lève")
    check(!TimerLink.shouldWake(previous: true, now: true), "réveil : rien ne change, rien n'est envoyé")
}

// MARK: Bureau : la forme du moment
do {
    check(DeskMoment.resolve(taskType: .lecture, inGroup: false, daysToExam: nil) == .lecture, "bureau : en cours")
    check(DeskMoment.resolve(taskType: .lecture, inGroup: true, daysToExam: 3) == .together, "bureau : le groupe d'abord")
    check(DeskMoment.resolve(taskType: .theory, inGroup: false, daysToExam: 5) == .revision, "bureau : examen proche → révision")
    check(DeskMoment.resolve(taskType: .exercise, inGroup: false, daysToExam: 5) == .series, "bureau : une série reste une série")
    check(DeskMoment.resolve(taskType: .theory, inGroup: false, daysToExam: 30) == .series, "bureau : examen loin → séries")
    check(DeskMoment.resolve(taskType: .video, inGroup: false, daysToExam: 2) == .revision, "bureau : vidéo = théorie")

    let course = UUID()
    let day = Calendar.current.date(bySettingHour: 8, minute: 15, second: 0, of: Date())!
    let lecture = FocusContext.Slot(courseID: course, courseCode: "MATH-101", kind: .lecture, start: day, end: day.addingTimeInterval(105 * 60))
    let later = FocusContext.Slot(courseID: UUID(), courseCode: "CS-107", kind: .exerciseSession,
                                  start: day.addingTimeInterval(3 * 3600), end: day.addingTimeInterval(5 * 3600))
    check(LectureClock.current(at: day.addingTimeInterval(-5 * 60), in: [lecture, later])?.courseID == course, "horloge : dix minutes avant, le cours")
    check(LectureClock.current(at: day.addingTimeInterval(-20 * 60), in: [lecture]) == nil, "horloge : trop tôt")
    check(LectureClock.next(after: day.addingTimeInterval(60), in: [lecture, later])?.courseCode == "CS-107", "horloge : la suite")
    check(LectureClock.phase(of: lecture, at: day.addingTimeInterval(50 * 60)) == .pause(untilMinutes: 10), "horloge : la pause à +45")
    check(LectureClock.phase(of: lecture, at: day.addingTimeInterval(20 * 60)) == .running, "horloge : en cours")
    check(LectureClock.phase(of: lecture, at: day.addingTimeInterval(-3 * 60)) == .before(minutes: 3), "horloge : avant")
    check(LectureClock.phase(of: lecture, at: day.addingTimeInterval(2 * 3600)) == .over, "horloge : fini")
    check(LectureClock.breakWindow(of: FocusContext.Slot(courseID: course, courseCode: "X", kind: .lecture, start: day,
                                                         end: day.addingTimeInterval(45 * 60))) == nil, "horloge : 45 min sans pause")
    check(LectureClock.studyMinutes(for: lecture, now: day) == 105, "horloge : le mode étude tient jusqu'à la fin")
    check(abs(LectureClock.progress(of: lecture, at: day.addingTimeInterval(52.5 * 60)) - 0.5) < 0.001, "horloge : à mi-chemin")

    let first = LectureMark(courseID: course, classStart: day, at: day.addingTimeInterval(754))
    check(first.offsetLabel == "12:34", "repère : 12:34")
    check(LectureMark(courseID: course, classStart: day, at: day.addingTimeInterval(3723)).offsetLabel == "1:02:03", "repère : plus d'une heure")
    var marks = LectureMarks.adding(first, to: [], now: day)
    marks = LectureMarks.adding(LectureMark(courseID: course, classStart: day, at: day.addingTimeInterval(760)), to: marks, now: day)
    check(marks.count == 1, "repère : deux touchers rapprochés n'en font qu'un")
    marks = LectureMarks.adding(LectureMark(courseID: course, classStart: day, at: day.addingTimeInterval(1500)), to: marks, now: day)
    check(LectureMarks.of(courseID: course, classStart: day, in: marks).count == 2, "repère : ceux du cours")
    check(LectureMarks.classes(of: course, in: marks).count == 1, "repère : un créneau")
    let stale = LectureMark(courseID: course, classStart: day.addingTimeInterval(-40 * 86_400), at: day.addingTimeInterval(-40 * 86_400))
    check(LectureMarks.adding(first, to: [stale], now: day).count == 1, "repère : un mois au plus")
    check(LectureMarks.decode(LectureMarks.encode(marks)) == marks, "repère : aller-retour")
    let video = URL(string: "https://mediaspace.epfl.ch/media/1_abc")!
    check(LectureMarks.seekURL(video, offset: 754).absoluteString == "https://mediaspace.epfl.ch/media/1_abc?st=754", "repère : MediaSpace à la minute")
    check(LectureMarks.seekURL(URL(string: "https://www.youtube.com/watch?v=x")!, offset: 60).absoluteString.hasSuffix("t=60"), "repère : YouTube")
    check(LectureMarks.startOffset(in: "https://mediaspace.epfl.ch/media/1_abc?st=754") == 754, "repère : relu")
    check(LectureMarks.startOffset(in: "https://x.ch/v.mp4#t=30") == 30, "repère : fragment relu")

    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let order = RevisionFocus.pastExamOrder([(a, 2022, true, .high), (b, 2023, false, nil), (c, 2021, true, .low), (d, 2024, false, nil)])
    check(order == [d, b, c, a], "révision : jamais faites, puis rouges, les sues en dernier")
}

// MARK: Botafogo : noms et macros
do {
    check(MathMarkup.plain("$x \\in \\bR$") == "x ∈ ℝ", "macro Botafogo \\bR → ℝ")
    check(BotafogoNode(type: "session", name: "seance-HY-03").displayName == "Séance 3", "séance : nom lisible")
    check(BotafogoNode(type: "weekContent", name: "week-HY-02").displayName == "La semaine", "contenu de semaine : nom lisible")
    check(BotafogoNode(type: "series", name: "Suites réelles").displayName == "Suites réelles", "une série garde son nom")
}

// MARK: Widgets : les instants où ils changent d'eux-mêmes
do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!
    let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
    let at = { (h: Int, m: Int) in calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: h, minute: m))! }
    var snapshot = WidgetSnapshot(updatedAt: now)
    snapshot.schedule = [
        WidgetEvent(id: "a", start: at(8, 15), end: at(10, 0), title: "Analyse", subtitle: "", colorHex: "#000000"),
        WidgetEvent(id: "b", start: at(10, 15), end: at(12, 0), title: "Physique", subtitle: "", colorHex: "#000000"),
    ]
    snapshot.deadlines = [
        WidgetDeadline(id: "d", title: "Série 3", courseCode: "MATH-101", date: at(18, 0), colorHex: "#000000"),
        WidgetDeadline(id: "e", title: "Plus tard", courseCode: "CS-101", date: midnight.addingTimeInterval(86_400), colorHex: "#000000"),
    ]
    let idle = snapshot.timelineDates(from: now, calendar: calendar)
    check(idle.dates == [now, at(10, 15), at(12, 0), at(18, 0), midnight], "widget : une entrée par changement du jour, jusqu'à minuit")
    check(idle.reloadAfter == midnight, "widget : rechargé à minuit, pas toutes les 30 min")
    snapshot.timer = WidgetTimer(label: "", colorHex: "#000000", effectiveStart: now, isRunning: true, elapsedWhenPaused: 0)
    let running = snapshot.timelineDates(from: now, calendar: calendar)
    // 10 h 15 et 12 h 00 tombent déjà sur un cours : 6 entrées en plus, pas 8.
    check(running.dates.contains(at(10, 30)) && running.dates.contains(at(11, 45)) && running.dates.count == idle.dates.count + 6,
          "widget : chrono en marche, un quart d'heure sur deux heures")
    check(running.dates == running.dates.sorted() && Set(running.dates).count == running.dates.count, "widget : entrées triées, sans doublon")
}

// MARK: Mode étude : garder le Mac éveillé
do {
    let plugged = KeepAwakePolicy.Power.plugged
    let hold = { (mode: KeepAwakePolicy.Mode, running: Bool, onBreak: Bool, power: KeepAwakePolicy.Power) in
        KeepAwakePolicy.hold(mode: mode, studying: true, running: running, onBreak: onBreak, power: power)
    }
    check(hold(.off, true, false, plugged) == nil, "veille : réglage « Non », rien n'est tenu")
    check(KeepAwakePolicy.hold(mode: .display, studying: false, running: true, onBreak: false, power: plugged) == nil,
          "veille : hors mode étude, rien n'est tenu")
    check(hold(.display, false, false, plugged) == nil, "veille : chrono en pause, le Mac dort")
    check(hold(.system, true, false, plugged) == .system, "veille : « Le Mac », l'écran s'éteint comme d'habitude")
    check(hold(.display, true, false, plugged) == .display, "veille : « Le Mac et l'écran », sur secteur")
    check(hold(.display, false, true, plugged) == .system, "veille : pause Pomodoro, l'écran peut s'éteindre")
    check(hold(.display, true, false, .init(lowPowerMode: true)) == .system, "veille : économie d'énergie, l'écran n'est plus tenu")
    check(hold(.display, true, false, .init(onBattery: true, batteryLevel: 0.15)) == .system, "veille : batterie sous 20 %, l'écran n'est plus tenu")
    check(hold(.display, true, false, .init(onBattery: true, batteryLevel: 0.6)) == .display, "veille : batterie suffisante, l'écran reste allumé")
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    check(KeepAwakePolicy.expiry(until: now.addingTimeInterval(3000), now: now) == now.addingTimeInterval(3000 + KeepAwakePolicy.endMargin),
          "veille : l'assertion expire avec la session (plus une marge)")
    check(KeepAwakePolicy.expiry(until: nil, now: now) == now.addingTimeInterval(KeepAwakePolicy.openEndedLease),
          "veille : session sans fin, un bail de deux heures renouvelé")
}

// MARK: Botafogo : les quatre parties (polycopié, séances, exercices, infos)
do {
    // Extrait réel de `analyse-1-flipped/api/content/nav?collection=handout`.
    let nav = ##"[{"title":"I Préface","path":"/handout/analyse-1","children":[{"title":"I Préface","path":"#i-préface","children":[{"title":"I.1 Un cours d'Analyse 1","path":"/handout/matiere/m_intro_objectifs"}]},{"title":"1 Nombres: $\\mathbb{R}$","path":"#_1-nombres-mathbbr","children":[{"title":"1.1 Introduction","path":"/handout/matiere/m_reels_intro"},{"title":"1.2 Règles de calcul","path":"/handout/matiere/m_reels_r_est_un_corps"}]},{"title":"Vide","path":"#vide","children":[]}]}]"##
    let chapters = BotafogoSite.chapters(fromNavJSON: Data(nav.utf8))
    check(chapters.map(\.title) == ["I Préface", "1 Nombres: $\\mathbb{R}$"], "Botafogo : chapitres du polycopié (vides écartés)")
    check(chapters.last?.sections.map(\.path) == ["/handout/matiere/m_reels_intro", "/handout/matiere/m_reels_r_est_un_corps"], "Botafogo : sections d'un chapitre")
    check(BotafogoSite.handoutCollection(html: #"latex:{collections:{handout:{url:"/handout/analyse-1",author:""}}}"#) == "/handout/analyse-1",
          "Botafogo : collection du polycopié lue dans la page")
    check(BotafogoSite.isHandout("/handout/matiere/m_reels_intro") && !BotafogoSite.isHandout("series/AN_serie_01"), "Botafogo : polycopié ou cours")

    let week = { (name: String, date: String) in
        BotafogoNode(type: "week", name: name, children: [
            BotafogoNode(type: "session", name: "seance-HY-01", url: "seances/seance-HY-01", metadata: ["date": date]),
            BotafogoNode(type: "series", name: "Fonctions", url: "series/AN_serie_01"),
        ])
    }
    let weeks = [week("Nombres réels", "2026-09-07T12:00:00.000Z"), week("Suites réelles", "2026-09-14T12:00:00.000Z"), week("Séries", "2026-09-21T12:00:00.000Z")]
    let mid = BotafogoProgram.date("2026-09-16T08:00:00.000Z")!
    check(BotafogoSite.currentWeek(weeks, now: mid) == 1, "Botafogo : la semaine en cours d'après la séance")
    check(BotafogoSite.currentWeek(weeks, now: BotafogoProgram.date("2026-09-19T20:00:00.000Z")!) == 2, "Botafogo : le week-end montre la semaine qui vient")
    check(BotafogoSite.currentWeek(weeks, now: BotafogoProgram.date("2026-08-01T08:00:00.000Z")!) == nil, "Botafogo : avant la rentrée, pas de semaine")
    check(BotafogoSite.seriesTitle(BotafogoNode(type: "series", name: "Fonctions", url: "series/AN_serie_01")) == "Série 1", "Botafogo : « Série 1 »")
    check(BotafogoSite.isSessionPart(BotafogoNode(type: "weekContent")) && !BotafogoSite.isSessionPart(BotafogoNode(type: "series")),
          "Botafogo : séance et exercices séparés")
}

// MARK: Botafogo : les documents lus comme le site les montre
do {
    func page(_ json: String) -> [BotafogoBlock] {
        guard let node = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        return BotafogoPage.blocks(node)
    }

    // Un quiz VRAI/FAUX : l'énoncé (avec ses formules) et les deux choix — pas seulement son titre.
    if case .quiz(let title, let prompt, let choices, _)? = page(BotafogoFixtures.quiz_vf).first {
        check(title == "Quiz 0.9", "quiz : son titre")
        check(choices.map(\.text) == ["VRAI", "FAUX"] && choices.map(\.correct) == [true, false], "quiz : VRAI juste, FAUX faux")
        check(prompt.contains { if case .paragraph(let text) = $0 { return text.contains("$z\\neq 0$") }; return false }, "quiz : l'énoncé et ses formules")
    } else { check(false, "quiz : lu comme un quiz") }

    // Un QCM du polycopié : les choix lus dans leur emplacement `#text`, l'explication attachée.
    if case .quiz(_, _, let choices, _)? = page(BotafogoFixtures.quiz_expl).first {
        check(choices.count >= 3 && choices.filter(\.correct).count >= 1, "QCM : plusieurs choix, au moins un juste")
        check(choices.contains { $0.text.contains("$a_{n}\\leqslant x_{n}\\leqslant b_{n}$") }, "QCM : le texte du choix, pas l'attribut aux espaces mangés")
        check(choices.contains { $0.explanation?.isEmpty == false }, "QCM : l'explication suit son choix")
    } else { check(false, "QCM : lu comme un quiz") }

    // Un exercice de série : étiquette, énoncé, formule isolée, indication et solution repliées.
    if case .exercise(let label, let content)? = page(BotafogoFixtures.ex).first {
        check(label.hasPrefix("Ex-"), "exercice : son étiquette « Ex-… » à part")
        check(content.contains { if case .math = $0 { return true }; return false }, "exercice : la formule isolée (displayMode vide = oui)")
        check(content.contains { if case .folded(.hint, _, let inner) = $0 { return !inner.isEmpty }; return false }, "exercice : l'indication, avec son contenu")
        check(content.contains { if case .folded(.solution, _, let inner) = $0 { return !inner.isEmpty }; return false }, "exercice : la solution, avec son contenu")
    } else { check(false, "exercice : lu comme un exercice") }

    // Un théorème encadré du polycopié.
    let theorem = page(BotafogoFixtures.theo)
    if case .theorem(let kind, let title, let content)? = theorem.first {
        check(kind == .theorem && title.contains("Théorème"), "théorème : son genre et son titre (\(title))")
        check(!content.isEmpty, "théorème : son énoncé")
    } else { check(false, "théorème : lu comme un encadré (\(theorem.prefix(1)))") }

    // Des sous-questions en colonnes, comme sur le site.
    check(page(BotafogoFixtures.mc).contains { if case .list(let items, true, 3) = $0 { return items.count >= 3 }; return false },
          "multicols : une liste numérotée en trois colonnes")

    // Une séance : « **Exercice.** (3) … » et ce qui suit forment une carte.
    let grouped = BotafogoPage.groupingExercises([.heading("Aujourd'hui", level: 4), .paragraph("**Exercice.** (3) Expliquer pourquoi."),
                                                  .math("P(z)"), .folded(.solution, title: "Solution", [.paragraph("Car.")]),
                                                  .paragraph("**Exercice.** (4)"), .heading("Extras", level: 4)])
    check(grouped.count == 4, "séance : deux cartes d'exercice entre les titres")
    if case .exercise(let label, let content) = grouped[1] {
        check(label == "Exercice 3" && content.count == 3, "séance : l'exercice 3 garde son texte, sa formule, sa solution")
    } else { check(false, "séance : une carte d'exercice") }

    // Un renvoi au polycopié : un lien qui s'ouvre dans l'app.
    if case .paragraph(let text)? = page(BotafogoFixtures.ref).first {
        check(text == "[Suites de Cauchy](polymestre-poly:///handout/matiere/m_suites_cauchy)", "renvoi : lien vers la section du polycopié (\(text))")
    } else { check(false, "renvoi : lu comme un lien") }
    check(BotafogoPage.handoutPath(link: URL(string: "polymestre-poly:///handout/matiere/m_suites_cauchy")!) == "/handout/matiere/m_suites_cauchy",
          "renvoi : l'adresse du lien redonne le chemin")
}

// MARK: Fiche de révision
do {
    print("\n— Fiche de révision —")
    let blocks: [BotafogoBlock] = [
        .paragraph("Introduction."),
        .theorem(kind: .definition, title: "Définition 5.1", [.paragraph("Une suite $(a_n)$ est de **Cauchy** si…")]),
        .theorem(kind: .theorem, title: "Théorème 5.4 (critère de d'Alembert)", [
            .paragraph("Si $\\lim |a_{n+1}/a_n| < 1$, la série converge."),
            .folded(.proof, title: "Preuve", [.paragraph("On compare à une série géométrique.")])
        ]),
        .theorem(kind: .example, title: "Exemple 5.2", [.paragraph("La série harmonique.")]),
        .aside(title: "Informel", [.theorem(kind: .proposition, title: "Proposition 5.3", [.paragraph("Le terme général tend vers $0$.")])])
    ]
    let found = RevisionSheetBuilder.entries(fromHandout: blocks, section: "5.1 Séries", path: "/handout/matiere/m_series")
    check(found.map(\.title) == ["Définition 5.1", "Théorème 5.4 (critère de d'Alembert)", "Proposition 5.3"],
          "polycopié : définitions, théorèmes, propositions (même dans un encadré), sans les exemples — \(found.map(\.title))")
    check(found.dropFirst().first.map { !$0.body.contains("géométrique") && $0.body.contains("converge") } == true,
          "polycopié : l'énoncé sans sa preuve")
    check(found.first?.link == "/handout/matiere/m_series" && found.first?.source == "5.1 Séries", "polycopié : la section où le relire")

    let sheet = RevisionSheetBuilder.sheet(chapters: [.init(title: "5 Séries", sections: [.init(title: "5.1 Séries", path: "/handout/matiere/m_series")])],
                                          pages: ["/handout/matiere/m_series": blocks])
    check(sheet.chapters.count == 1 && sheet.entries.count == 3, "polycopié : un chapitre, trois énoncés")
    check(RevisionSheet.decode(sheet.encoded()) == sheet, "la fiche se garde et se relit telle quelle")
    check(sheet.filtered("alembert").flatMap(\.entries).count == 1, "l'index retrouve « d'Alembert » sans accent ni casse")
    check(sheet.filtered("").count == 1, "sans recherche, toute la fiche")

    let relevant = sheet.relevant(to: "Étudier la convergence de la série $\\sum n!/n^n$ avec le critère de d'Alembert.")
    check(relevant.first?.title.contains("Alembert") == true, "à savoir : le critère cité par l'exercice vient d'abord — \(relevant.map(\.title))")
    check(sheet.relevant(to: "Dessiner un triangle équilatéral.").isEmpty, "à savoir : rien plutôt qu'un hasard")
    check(sheet.relevant(to: "Appliquer le théorème 5.4.").first?.title.hasPrefix("Théorème 5.4") == true, "à savoir : un numéro cité suffit")

    let answer = """
    Voici la fiche :
    ```json
    {"chapters":[{"title":"Applications linéaires","entries":[
      {"kind":"définition","title":"Noyau","body":"$\\\\ker T$","source":"Cours 5"},
      {"kind":"Méthode","title":"Famille libre","body":"Poser une combinaison nulle…"},
      {"kind":"bizarre","title":"","body":"Toujours vérifier les hypothèses."},
      {"kind":"theorem","title":"","body":""}]},
      {"title":"Vide","entries":[]}]}
    ```
    """
    let ai = RevisionSheetAI.sheet(fromAnswer: answer)
    check(ai?.chapters.count == 1 && ai?.entries.map(\.kind) == [.definition, .method, .remark],
          "réponse du modèle : genres reconnus, entrées vides et chapitres vides écartés — \(ai?.entries.map(\.kind.rawValue) ?? [])")
    check(ai?.entries.last?.title == "Remarque", "réponse du modèle : un titre manquant prend le nom du genre")
    check(RevisionSheetAI.sheet(fromAnswer: "Désolé, je ne peux pas.") == nil, "réponse du modèle sans JSON : pas de fiche")
    let long = RevisionSheetAI.prompt(course: "X", documents: [("A", String(repeating: "a", count: 300_000)), ("B", String(repeating: "b", count: 300_000)), ("C", "court")],
                                      budget: 100_000)
    check(long.count < 110_000 && long.contains("=== C ===\ncourt"), "consigne : le matériel tient dans le budget, les petits documents restent entiers")
}

// MARK: Lire, c'est cocher ; chercher dans les vidéos
do {
    print("\n— Liens du cours et transcriptions —")
    let a = StudyLinkKey.key("https://botafogo.epfl.ch/analyse-1-flipped/?cours=&polycopie=/handout/matiere/m_Suites_Cauchy")
    let b = StudyLinkKey.key("https://botafogo.epfl.ch/analyse-1-flipped/?polycopie=matiere/m_suites_cauchy")
    check(a == b && a == StudyLinkKey.key("/handout/matiere/m_suites_cauchy"), "polycopié : trois formes du même lien, une seule section — \(a)")
    let unit = "block-v1:EPFL+Algebre123+2025+type@video+block@635aa0b7"
    check(StudyLinkKey.key("https://courseware.epfl.ch/xblock/" + unit) == StudyLinkKey.key(unit), "Courseware : le bloc, avec ou sans adresse")
    check(StudyLinkKey.key("https://moodle.epfl.ch/pluginfile.php/1/x.pdf#page=2") == StudyLinkKey.key("https://moodle.epfl.ch/pluginfile.php/1/x.pdf/"),
          "document : sans fragment ni barre finale")

    let srt = "1\n00:00:01,000 --> 00:00:04,000\nBonjour, aujourd'hui\n\n2\n00:01:02,500 --> 00:01:05,000\nla <i>convergence</i> absolue\n\n3\n00:01:06,000 --> 00:01:09,000\nd'une série.\n"
    let cues = CoursewareTranscripts.cues(from: srt)
    check(cues.count == 3 && cues[1].start == 62.5 && cues[1].text == "la convergence absolue", "SRT : instants et texte sans balises — \(cues.map(\.text))")
    let json = #"{"start":[0,61500],"end":[3000,64000],"text":["Intro","Le d\u00e9terminant"]}"#
    check(CoursewareTranscripts.cues(from: json).map(\.start) == [0, 61.5], "transcription edX en JSON : millisecondes en secondes")
    let videos = [CoursewareTranscripts.Video(block: "v1", unit: "u1", title: "Séries", cues: cues)]
    let hits = CoursewareTranscripts.search("Convergence Serie", in: videos)
    check(hits.count == 1 && hits.first?.start == 62.5, "recherche : tous les mots, sans accents, même sur deux phrases — \(hits.map(\.start))")
    check(CoursewareTranscripts.search("matrice", in: videos).isEmpty, "recherche : rien quand la vidéo ne le dit pas")
    check(CoursewareTranscripts.transcriptURLs(["transcripts": ["en": "/e", "de": "/d", "fr": "/f"]]) == ["/f", "/e", "/d"],
          "transcriptions : le français d'abord, puis l'anglais")
}

// MARK: Spotify (protocole du lecteur web, d'après SpotAPI)
print("\n— Spotify —")
do {
    let secret = SpotifyWire.fallbackSecret.bytes
    check(SpotifyWire.totp(secret: secret, at: Date(timeIntervalSince1970: 59)) == "332823", "Spotify : TOTP à 59 s (comme pyotp)")
    check(SpotifyWire.totp(secret: secret, at: Date(timeIntervalSince1970: 1_700_000_000)) == "371599", "Spotify : TOTP à 1 700 000 000 s")
    let dict = #"{"59":[1,2],"61":[44,55],"x":[3]}"#.data(using: .utf8)!
    check(SpotifyWire.latestSecret(from: dict)?.version == 61, "Spotify : la clé la plus récente du dictionnaire")
    let html = "<script id=\"appServerConfig\" type=\"text/plain\">" + Data(#"{"clientVersion":"1.2.3.g1"}"#.utf8).base64EncodedString() + "</script>"
    check(SpotifyWire.clientVersion(inPage: html) == "1.2.3.g1", "Spotify : version du lecteur lue dans la page")
    let token = SpotifyWire.webToken(from: Data(#"{"accessToken":"abc","clientId":"cid","accessTokenExpirationTimestampMs":1700000000000,"isAnonymous":false}"#.utf8))
    check(token?.accessToken == "abc" && token?.clientID == "cid" && token?.anonymous == false, "Spotify : jeton du lecteur web")
    let zipped = Data(base64Encoded: "H4sIAAAAAAAA/6tWSs4pLS5JLVKyUqhWSkwuySxLjU9JLctMTo3PTAEKKqUYKtXWAgDNw9NCJwAAAA==")!
    let dealer = try! JSONSerialization.data(withJSONObject: ["type": "message", "uri": "hm://connect-state/v1/cluster", "headers": ["Transfer-Encoding": "gzip"], "payloads": [zipped.base64EncodedString()]])
    let payload = SpotifyWire.clusterPayloads(fromDealer: dealer).first
    let decoded = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(decoded.map { SpotifyWire.now(fromCluster: $0).activeDevice } == "d1", "Spotify : état du dealer décompressé (gzip)")
    let cluster: [String: Any] = [
        "active_device_id": "mac", "server_timestamp_ms": "10000",
        "devices": ["mac": ["device_id": "mac", "name": "MacBook", "device_type": "COMPUTER", "volume": 32768, "can_play": true],
                    "hobs_x": ["name": "obs", "capabilities": ["hidden": true]]],
        "player_state": ["is_playing": true, "is_paused": false, "timestamp": "8000", "position_as_of_timestamp": "30000", "duration": "200000",
                         "options": ["shuffling_context": true, "repeating_context": false, "repeating_track": true],
                         "track": ["uri": "spotify:track:T1", "metadata": ["title": "Song", "artist_name": "Artist", "image_url": "spotify:image:ab12"]],
                         "next_tracks": [["uri": "spotify:track:T2", "metadata": ["title": "Next"]], ["uri": "spotify:delimiter"]]],
    ]
    let now = SpotifyWire.now(fromCluster: cluster)
    check(now.track?.title == "Song" && now.track?.artist == "Artist", "Spotify : morceau en cours")
    check(now.track?.artwork?.absoluteString == "https://i.scdn.co/image/ab12", "Spotify : pochette spotify:image → i.scdn.co")
    check(now.isPlaying && abs(now.position - 32) < 0.01 && now.duration == 200, "Spotify : position ramenée à l'heure du serveur")
    check(now.shuffle && now.repeatTrack && !now.repeatContext, "Spotify : aléatoire et répétition")
    check(now.devices.map(\.id) == ["mac"] && abs((now.volume ?? 0) - 0.5) < 0.01, "Spotify : appareils visibles et volume")
    check(now.upNext.map(\.uri) == ["spotify:track:T2"], "Spotify : à suivre, sans délimiteur")
    let play = SpotifyWire.commandBody(.play(context: "spotify:playlist:P"))["command"] as? [String: Any]
    check(play?["endpoint"] as? String == "play" && (play?["context"] as? [String: Any])?["url"] as? String == "context://spotify:playlist:P", "Spotify : lancer une playlist")
    check(SpotifyWire.volumeBody(0.5)["volume"] as? Int == 32768, "Spotify : volume sur 65 535")
    let lists = SpotifyWire.playlists(from: Data(#"{"items":[{"uri":"spotify:playlist:P","name":"Focus","images":[{"url":"https://x/y.jpg"}],"owner":{"display_name":"Hugo"}}]}"#.utf8))
    check(lists.first?.name == "Focus" && lists.first?.image != nil, "Spotify : mes playlists")
    check(SpotifyWire.isSignedIn(cookieNames: ["sp_t", "sp_dc"]) && !SpotifyWire.isSignedIn(cookieNames: ["sp_t"]), "Spotify : connecté·e = cookie sp_dc")
}

if CommandLine.arguments.contains("--bench") {
    runBenchmark()
}

print("")
// MARK: NotebookLM : le protocole (NotebookLMWire)
do {
    let id = "11111111-2222-3333-4444-555555555555"
    let body = NotebookLMWire.body(rpc: .createNotebook, params: NotebookLMWire.createNotebookParams(title: "Analyse & co"), token: "AB:12=")
    check(body.hasPrefix("f.req=") && body.hasSuffix("&") && body.contains("&at=AB%3A12%3D&"), "NotebookLM : le corps porte f.req et le jeton at, encodés")
    check(body.contains("CCqFvf") && body.contains("Analyse%20%26%20co"), "NotebookLM : le code d'appel et le titre (encodé) sont dans le corps")
    let url = NotebookLMWire.url(host: "https://notebook.google.com", rpc: .addSource, sourcePath: "/notebook/\(id)", session: "123")!.absoluteString
    check(url.contains("rpcids=izAoDd") && url.contains("f.sid=123") && url.contains("rt=c") && url.contains("source-path=/notebook/"), "NotebookLM : l'adresse d'un appel")
    check(NotebookLMWire.createNotebookParams(title: "T").count == 4, "NotebookLM : créer un carnet = titre + 3 emplacements")

    let text = NotebookLMWire.addTextSourceParams(notebookID: id, title: "Fiche", text: "Corps")
    check(text.count == 3 && (text[1] as? String) == id, "NotebookLM : une source texte vise le carnet")
    let audio = NotebookLMWire.createAudioParams(notebookID: id, sourceIDs: ["s1", "s2"], instructions: "Consigne", language: "fr", format: .deepDive, length: .standard)
    let sent = String(data: try! JSONSerialization.data(withJSONObject: audio), encoding: .utf8)!
    check(sent.contains("\"s1\"") && sent.contains("\"s2\"") && sent.contains("Consigne") && sent.contains("\"fr\""), "NotebookLM : le podcast cite ses sources, la consigne et la langue")

    // Réponse : préfixe anti-XSSI, longueur, bloc wrb.fr
    let payload = "[[\"" + id + "\",\"Titre\"]]"
    let inner = String(data: try! JSONSerialization.data(withJSONObject: ["wrb.fr", "CCqFvf", payload, NSNull(), NSNull(), NSNull(), "generic"]), encoding: .utf8)!
    let response = ")]}'\n\n123\n[" + inner + "]\n25\n[[\"e\",4,null,null,64]]\n"
    let parsed = try? NotebookLMWire.result(of: response, rpc: .createNotebook)
    check(NotebookLMWire.firstID(in: parsed ?? nil) == id, "NotebookLM : l'identifiant du carnet se retrouve dans la réponse")
    check((try? NotebookLMWire.result(of: response, rpc: .addSource)) == nil && { if case .some = (try? NotebookLMWire.result(of: response, rpc: .addSource)) { return false }; return true }(), "NotebookLM : une réponse à un autre appel n'est pas la nôtre")
    var notAnswer = false
    do { _ = try NotebookLMWire.result(of: "<html>Connexion</html>", rpc: .createNotebook) } catch NotebookLMWire.ParseError.notAnswer { notAnswer = true } catch {}
    check(notAnswer, "NotebookLM : la page de connexion à la place d'une réponse = session expirée")
    let refusedRow = String(data: try! JSONSerialization.data(withJSONObject: ["wrb.fr", "CCqFvf", NSNull(), NSNull(), NSNull(), [3], "generic"]), encoding: .utf8)!
    var refused: Int?
    do { _ = try NotebookLMWire.result(of: ")]}'\n10\n[" + refusedRow + "]", rpc: .createNotebook) } catch NotebookLMWire.ParseError.refused(let code) { refused = code } catch {}
    check(refused == 3, "NotebookLM : un code d'erreur dans la réponse est remonté")

    // Les jetons de la page
    let page = "<script>window.WIZ_global_data = {\"SNlM0e\":\"AF1_Qp:1785\",\"FdrFJe\":\"-98765\",\"x\":1}</script>"
    check(NotebookLMWire.field("SNlM0e", inPage: page) == "AF1_Qp:1785" && NotebookLMWire.field("FdrFJe", inPage: page) == "-98765", "NotebookLM : le jeton et la session se lisent dans la page")
    check(NotebookLMWire.field("SNlM0e", inPage: "<html>rien</html>") == nil, "NotebookLM : pas de jeton, rien")

    // L'adresse d'un carnet
    check(NotebookLMWire.notebookID(fromURL: "https://notebooklm.google.com/notebook/\(id)?authuser=0") == id, "NotebookLM : l'identifiant se lit dans l'adresse du carnet")
    check(NotebookLMWire.notebookID(fromURL: "https://notebooklm.google.com/") == nil && NotebookLMWire.notebookID(fromURL: "n'importe quoi") == nil, "NotebookLM : sans carnet dans l'adresse, rien")

    // Les artefacts : état, type, adresse du son
    let ready: [Any] = ["a1", "Résumé audio", 1, NSNull(), 3, NSNull(), [NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), [["https://x.test/a.m4a", NSNull(), "audio/mp4"], ["https://x.test/b.webm", NSNull(), "audio/webm"]]]]
    let working: [Any] = ["a2", "En cours", 1, NSNull(), 2]
    let failed: [Any] = ["a3", "Raté", 1, NSNull(), 4]
    for shape in [[[ready, working, failed]], [ready, working, failed]] as [[Any]] {
        let list = NotebookLMWire.artifacts(from: shape)
        check(list.map(\.state) == [.ready, .working, .failed] && list[0].audioURL?.absoluteString == "https://x.test/a.m4a" && list[1].audioURL == nil, "NotebookLM : les artefacts (enveloppés ou à plat) : état et son")
    }
    check(NotebookLMWire.artifacts(from: nil).isEmpty && NotebookLMWire.artifacts(from: "n'importe quoi").isEmpty, "NotebookLM : pas d'artefacts, une liste vide")
    check(!NotebookLMWire.isSignedIn(cookieNames: ["NID", "__Secure-1PSIDTS", "SIDCC"]) && NotebookLMWire.isSignedIn(cookieNames: ["NID", "SAPISID"]), "NotebookLM : connecté seulement avec un cookie de session, pas ceux d'une simple visite")
    check(NotebookLMWire.isApp(host: "notebook.google.com") && NotebookLMWire.isApp(host: "notebooklm.google.com") && !NotebookLMWire.isApp(host: "accounts.google.com") && !NotebookLMWire.isApp(host: "notebooklm.google"), "NotebookLM : l'app, pas la page de connexion ni la vitrine")
    check(NotebookLMWire.podcastInstructions(courseName: "Analyse I").contains("Analyse I"), "NotebookLM : la consigne cite le cours")
}

// MARK: - Maintiens pour finir

print("\n== Tenir pour terminer (le geste et son temps) ==")
do {
    let hold = HoldProgress(duration: 1.5)
    check(hold.fraction(after: 0) == 0 && hold.fraction(after: 0.75) == 0.5, "tenir : la barre suit le temps à mi-chemin")
    check(hold.fraction(after: 0.01) > 0, "tenir : la barre avance dès le premier instant (le doigt voit qu'il est pris en compte)")
    check(hold.isComplete(after: 1.5) && hold.isComplete(after: 9), "tenir : au bout du temps, le geste compte")
    check(!hold.isComplete(after: 1.49), "tenir : juste avant, il ne compte pas encore")
    check(hold.fraction(after: 99) == 1, "tenir : la barre ne déborde pas")
    check(hold.remaining(after: 0.5) == 1, "tenir : ce qui reste se dit au doigt")
    // Une sortie d'urgence tient huit secondes, pas une seconde et demie.
    let urgent = HoldProgress(duration: StudyMode.emergencyHold)
    check(!urgent.isComplete(after: 1.5) && urgent.isComplete(after: StudyMode.emergencyHold), "tenir : la sortie d'urgence demande bien ses huit secondes")
    // Le doigt qui glisse : la page défile, l'appui se relâche.
    check(HoldProgress.isOnButton(translation: CGSize(width: 30, height: 30)), "tenir : un doigt qui bouge un peu reste sur le bouton")
    check(!HoldProgress.isOnButton(translation: CGSize(width: 0, height: 60)), "tenir : un doigt qui glisse de 60 points relâche l'appui (le défilement reprend)")
    check(!HoldProgress.isOnButton(translation: CGSize(width: -200, height: 5)), "tenir : une glissade latérale aussi")
    // Un appui bref dit quoi faire ; un tapotement ne le dit pas à chaque fois.
    check(hold.shouldExplainRelease(after: 0.5), "tenir : lâché trop tôt, on dit quoi faire")
    check(!hold.shouldExplainRelease(after: 0.02), "tenir : un vrai tapotement ne déclenche pas de conseil")
    check(!hold.shouldExplainRelease(after: 2), "tenir : une fois tenu, rien à expliquer")
    // Un bouton sans tenir (clic) agit au contact.
    let click = HoldProgress(duration: 0)
    check(click.isComplete(after: 0) && !click.shouldExplainRelease(after: 0), "tenir : un bouton qui n'attend pas de tenir agit au contact")
    check(HoldProgress(duration: -3).duration == 0, "tenir : un temps négatif ne fait pas tenir à l'envers")
}

do {
    // L'agenda : les événements qui se chevauchent, côte à côte.
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ h: Double) -> Date { base.addingTimeInterval(h * 3600) }
    let slots = AgendaLanes.assign([(at(8), at(10)), (at(9), at(11)), (at(12), at(13)), (at(8), at(20)), (at(10), at(12))])
    check(slots[3] == .init(lane: 0, lanes: 3), "agenda : le plus long d'abord, en première colonne")
    check(slots[0].lane == 1 && slots[1].lane == 2 && slots[0].lanes == 3, "agenda : chevauchement → colonnes suivantes, largeur partagée")
    check(slots[4].lane == 1, "agenda : une colonne libérée se réutilise")
    let apart = AgendaLanes.assign([(at(8), at(9)), (at(9), at(10))])
    check(apart.allSatisfy { $0 == .init(lane: 0, lanes: 1) }, "agenda : bout à bout, pas de chevauchement")
    check(AgendaLanes.assign([]).isEmpty, "agenda : un jour vide")
}

if failures == 0 {
    print("✅ TOUS LES CONTRÔLES SONT PASSÉS")
} else {
    print("❌ \(failures) contrôle(s) en échec")
    exit(1)
}

// MARK: - Repères de performance (--bench)
//
// Aucun simulateur iOS n'est installé : c'est la seule mesure exécutable du
// projet. Elle porte sur la logique pure (`Domain/`), pas sur le rendu SwiftUI.
// Elle chiffre donc le coût d'**une** passe de dérivation, puis reconstitue le
// coût d'un rendu à partir du nombre de lectures que `body` effectuait.

func runBenchmark() {
    print("")
    print("== Repères de performance — semestre simulé ==")

    let benchConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    guard let benchContainer = try? ModelContainer(for: schema, configurations: [benchConfig]) else {
        print("  conteneur indisponible")
        return
    }
    let ctx = ModelContext(benchContainer)

    let start = DateUtils.addWeeks(-6, to: DateUtils.startOfWeek(Date()))
    let benchTerm = AcademicTerm(year: 2026,
                                 season: .spring,
                                 startDate: start,
                                 endDate: DateUtils.addWeeks(14, to: start),
                                 totalWeeks: 14)
    ctx.insert(benchTerm)

    let specs = [("CS-250", "Algorithmes"), ("MATH-101", "Analyse I"),
                 ("PHYS-101", "Physique I"), ("CS-251", "Structures de données"),
                 ("MATH-102", "Algèbre linéaire"), ("PHYS-102", "Physique II")]
    var benchCourses: [Course] = []
    for spec in specs {
        let course = Course(code: spec.0, name: spec.1, credits: 4, term: benchTerm)
        ctx.insert(course)

        for index in 0..<40 {
            let video = TheoryItem(course: course,
                                    sectionNumber: index / 5 + 1,
                                    number: "\(index / 5 + 1).\(index % 5 + 1)",
                                    title: "Vidéo \(index + 1)",
                                    durationSeconds: 900,
                                    plannedWeek: index % 14 + 1)
            if index % 20 < 11 { video.watchedAt = Date() }
            if index % 20 < 7 { video.summarizedAt = Date() }
            ctx.insert(video)
        }

        for s in 0..<12 {
            let series = ExerciseSeries(course: course,
                                        seriesNumber: s + 1,
                                        plannedWeek: s % 14 + 1)
            ctx.insert(series)
            for e in 0..<8 {
                let exercise = Exercise(series: series,
                                        exerciseNumber: "\(s + 1).\(e + 1)",
                                        isBonus: e == 7,
                                        sortOrder: e)
                if e < 4 { exercise.doneAt = Date() }
                if e < 2 {
                    exercise.correctedAt = Date()
                    exercise.correctness = .correct
                }
                if e == 0 { exercise.redoRequired = true }
                ctx.insert(exercise)
            }
        }
        benchCourses.append(course)
    }

    for week in 0..<16 {
        for course in benchCourses {
            for day in 0..<5 {
                ctx.insert(StudySession(course: course,
                                        taskType: TaskType.allCases[(week + day) % TaskType.allCases.count],
                                        startedAt: DateUtils.addWeeks(-week, to: DateUtils.addDays(day, to: start)),
                                        durationSeconds: 3600))
            }
        }
    }
    try? ctx.save()

    let benchAll = (try? ctx.fetch(FetchDescriptor<Course>())) ?? []
    let benchSessions = (try? ctx.fetch(FetchDescriptor<StudySession>())) ?? []
    let benchTracked = benchAll.filter(\.isTracked)
    print("  jeu : \(benchAll.count) cours · \(benchAll.reduce(0) { $0 + $1.theoryItems.count }) vidéos"
        + " · \(benchAll.reduce(0) { $0 + $1.allExercises.count }) exercices"
        + " · \(benchSessions.count) sessions"
        + " · semaine courante \(benchTracked.first?.currentWeek ?? 0)")
    print("")

    func measure(_ label: String, iterations: Int = 20, _ block: () -> Void) -> Double {
        block()
        let clock = ContinuousClock()
        let total = clock.measure {
            for _ in 0..<iterations { block() }
        }
        let ms = Double(total / Duration.milliseconds(1)) / Double(iterations)
        print("  " + label.padding(toLength: 36, withPad: " ", startingAt: 0)
            + String(format: "%8.3f ms", ms))
        return ms
    }

    print("  coût d'UNE passe de dérivation d'« Aujourd'hui » :")
    _ = measure("WeekCourseSummary (tous cours)") {
        for course in benchTracked { _ = WeekCourseSummary(course: course) }
    }
    _ = measure("Deadline.upcoming (14 j)") {
        _ = Deadline.upcoming(in: benchTracked, days: 14)
    }
    _ = measure("WorkloadEngine.aggregate") {
        _ = WorkloadEngine.aggregate(courses: benchTracked, hoursPerCredit: 30)
    }
    _ = measure("ProgressEngine.progress (tous cours)") {
        for course in benchTracked { _ = ProgressEngine.progress(for: course) }
    }
}
