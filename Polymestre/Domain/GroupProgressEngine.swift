import Foundation

/// Ce qu'un membre a validé dans **une** matière.
///
/// Type valeur volontairement : le moteur qui compare les membres ne connaît ni
/// SwiftData ni le réseau, donc il se teste sans base ni serveur.
struct SubjectContribution: Equatable {
    var userID: String
    var seriesNumbers: Set<Int> = []
    var exerciseNumbers: Set<String> = []
    var theoryNumbers: Set<String> = []

    init(userID: String,
         seriesNumbers: Set<Int> = [],
         exerciseNumbers: Set<String> = [],
         theoryNumbers: Set<String> = []) {
        self.userID = userID
        self.seriesNumbers = seriesNumbers
        self.exerciseNumbers = exerciseNumbers
        self.theoryNumbers = theoryNumbers
    }
}

/// Ce qu'il y a à faire dans une matière — le **référentiel** de comparaison.
///
/// Il vient toujours de *mon* cours : l'EPFL publie une seule série par semaine et
/// par matière, donc deux étudiants inscrits au même cours ont les mêmes numéros.
/// C'est ce qui rend la comparaison possible sans rien demander de plus.
struct SubjectReference: Equatable {
    var seriesNumbers: [Int]
    var exerciseNumbers: [String]
    var theoryNumbers: [String]

    init(seriesNumbers: [Int] = [],
         exerciseNumbers: [String] = [],
         theoryNumbers: [String] = []) {
        self.seriesNumbers = seriesNumbers
        self.exerciseNumbers = exerciseNumbers
        self.theoryNumbers = theoryNumbers
    }

    var seriesTotal: Int { seriesNumbers.count }
    var exerciseTotal: Int { exerciseNumbers.count }
    var theoryTotal: Int { theoryNumbers.count }
    var isEmpty: Bool { seriesTotal == 0 && exerciseTotal == 0 && theoryTotal == 0 }
}

/// L'avancement d'un membre sur une matière, **et son écart avec moi**.
struct SubjectMemberProgress: Identifiable, Equatable {
    var userID: String
    var displayName: String
    var isMe: Bool
    var isPresent: Bool
    var seriesDone: Int
    var exercisesDone: Int
    var theoryDone: Int
    var reference: SubjectReference
    /// Écart signé avec moi : positif = il a fait plus que moi.
    var gapExercises: Int = 0
    var gapSeries: Int = 0
    var gapTheory: Int = 0
    /// Y a-t-il quelqu'un à qui me comparer ?
    ///
    /// Sans cette information, des écarts tous nuls se lisaient « au même point »
    /// pour tout le monde — un membre non identifié voyait un groupe parfaitement
    /// synchronisé alors qu'aucune comparaison n'avait eu lieu.
    var hasGapReference: Bool = false

    var id: String { userID }

    var seriesTotal: Int { reference.seriesTotal }
    var exerciseTotal: Int { reference.exerciseTotal }
    var theoryTotal: Int { reference.theoryTotal }

    var seriesPercent: Double { Self.ratio(seriesDone, seriesTotal) }
    var exercisePercent: Double { Self.ratio(exercisesDone, exerciseTotal) }
    var theoryPercent: Double { Self.ratio(theoryDone, theoryTotal) }

    /// Avancement global de la matière : tous les éléments comptent pareil.
    ///
    /// On ne moyenne pas les trois pourcentages : une matière sans théorie (ou sans
    /// série publiée) ferait alors peser un axe vide pour un tiers du résultat.
    var overallPercent: Double {
        Self.ratio(seriesDone + exercisesDone + theoryDone,
                   seriesTotal + exerciseTotal + theoryTotal)
    }

    var doneTotal: Int { seriesDone + exercisesDone + theoryDone }
    var itemTotal: Int { seriesTotal + exerciseTotal + theoryTotal }

    /// « 8/12 exercices · 3/9 théorie » — les axes qui existent seulement.
    var detailLabel: String {
        var parts: [String] = []
        if exerciseTotal > 0 { parts.append(String(localized: "\(exercisesDone)/\(exerciseTotal) exercices")) }
        if theoryTotal > 0 { parts.append(String(localized: "\(theoryDone)/\(theoryTotal) théorie")) }
        if seriesTotal > 0 { parts.append(String(localized: "\(seriesDone)/\(seriesTotal) séries")) }
        return parts.joined(separator: " · ")
    }

    /// « +3 exercices d'avance », « 5 exercices de retard », « au même point ».
    ///
    /// `nil` quand je ne suis pas identifié·e : sans point de repère, il n'y a rien
    /// à annoncer — et surtout pas « au même point ».
    var gapLabel: String? {
        guard !isMe, hasGapReference else { return nil }
        let gap = gapExercises + gapTheory + gapSeries
        if gap == 0 { return String(localized: "au même point") }
        let unit = abs(gap) == 1 ? String(localized: "élément") : String(localized: "éléments")
        return gap > 0 ? "\(gap) \(unit) d'avance" : "\(abs(gap)) \(unit) de retard"
    }

    private static func ratio(_ done: Int, _ total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(done) / Double(total)))
    }
}

/// Compare l'avancement des membres d'un groupe sur une matière.
enum GroupProgressEngine {

    /// Résultat complet pour une matière : le classement et mon écart.
    struct SubjectComparison {
        var subject: String
        var reference: SubjectReference
        /// Trié : le plus avancé d'abord, « moi » à égalité de rang.
        var rows: [SubjectMemberProgress]
        var me: SubjectMemberProgress?
        /// Nombre de membres qui n'ont encore rien fait sur cette matière.
        var notStarted: Int
        /// Vrai quand personne (moi compris) n'a de repère : rien à comparer.
        var isComparable: Bool { !reference.isEmpty && rows.count > 1 }
    }

    /// Construit la comparaison.
    ///
    /// - Parameters:
    ///   - subject: code de la matière (« CS-250 »).
    ///   - reference: ce qu'il y a à faire, d'après mon cours.
    ///   - contributions: ce que chaque membre a validé.
    ///   - members: les membres du groupe, pour les noms et le périmètre.
    ///   - meID: l'identifiant de l'utilisateur courant, s'il est connu.
    static func compare(subject: String,
                        reference: SubjectReference,
                        contributions: [SubjectContribution],
                        members: [(userID: String, displayName: String, isMe: Bool)],
                        meID: String?) -> SubjectComparison {
        // Normalisation : un numéro inconnu du référentiel ne compte pas. Sans ça,
        // quelqu'un ayant importé une série que je n'ai pas ferait dépasser 100 %.
        let validSeries = Set(reference.seriesNumbers)
        let validExercises = Set(reference.exerciseNumbers)
        let validTheory = Set(reference.theoryNumbers)

        let byUser = Dictionary(grouping: contributions, by: \.userID)

        var rows: [SubjectMemberProgress] = members.map { member in
            let mine = byUser[member.userID] ?? []
            let series = Set(mine.flatMap(\.seriesNumbers)).intersection(validSeries)
            let exercises = Set(mine.flatMap(\.exerciseNumbers)).intersection(validExercises)
            let theory = Set(mine.flatMap(\.theoryNumbers)).intersection(validTheory)
            return SubjectMemberProgress(
                userID: member.userID,
                displayName: member.displayName,
                isMe: member.isMe || member.userID == meID,
                isPresent: true,
                seriesDone: series.count,
                exercisesDone: exercises.count,
                theoryDone: theory.count,
                reference: reference)
        }

        // Les contributions d'un membre qui n'est plus dans la liste (retiré du
        // groupe, ou pas encore rapatrié) ne doivent pas disparaître en silence :
        // elles sont visibles, sans nom.
        let known = Set(members.map(\.userID))
        for (userID, mine) in byUser where !known.contains(userID) {
            let series = Set(mine.flatMap(\.seriesNumbers)).intersection(validSeries)
            let exercises = Set(mine.flatMap(\.exerciseNumbers)).intersection(validExercises)
            let theory = Set(mine.flatMap(\.theoryNumbers)).intersection(validTheory)
            guard !series.isEmpty || !exercises.isEmpty || !theory.isEmpty else { continue }
            rows.append(SubjectMemberProgress(
                userID: userID,
                displayName: String(localized: "Membre"),
                isMe: userID == meID,
                isPresent: false,
                seriesDone: series.count,
                exercisesDone: exercises.count,
                theoryDone: theory.count,
                reference: reference))
        }

        let me = rows.first { $0.isMe }
        if let me {
            for index in rows.indices {
                rows[index].gapExercises = rows[index].exercisesDone - me.exercisesDone
                rows[index].gapSeries = rows[index].seriesDone - me.seriesDone
                rows[index].gapTheory = rows[index].theoryDone - me.theoryDone
                // Le point de repère existe : les écarts veulent dire quelque chose.
                rows[index].hasGapReference = true
            }
        }

        // Tri : avancement décroissant, puis les membres présents avant les
        // contributions orphelines, puis le nom — pour que l'ordre soit stable
        // d'une synchronisation à l'autre.
        rows.sort { lhs, rhs in
            if lhs.doneTotal != rhs.doneTotal { return lhs.doneTotal > rhs.doneTotal }
            if lhs.isPresent != rhs.isPresent { return lhs.isPresent }
            if lhs.isMe != rhs.isMe { return lhs.isMe }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        return SubjectComparison(subject: subject.uppercased(),
                                 reference: reference,
                                 rows: rows,
                                 me: me,
                                 notStarted: rows.filter { $0.isPresent && $0.doneTotal == 0 }.count)
    }
}
