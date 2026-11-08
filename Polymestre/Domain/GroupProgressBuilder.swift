import Foundation

/// Traduit les modèles SwiftData d'un groupe en entrées du moteur de comparaison.
///
/// Toute la logique de décision est dans `GroupProgressEngine` ; ce fichier ne fait
/// que la plomberie « modèle → valeur », pour que le moteur reste testable sans
/// base de données.
enum GroupProgressBuilder {

    /// Le référentiel d'une matière, d'après **mon** cours.
    ///
    /// Les numéros viennent de mon côté parce que l'EPFL publie une seule série par
    /// semaine et par matière : deux inscrits au même cours ont les mêmes numéros.
    /// Un cours que je ne suis pas donne un référentiel vide — la comparaison reste
    /// alors possible sur les séries, jamais sur les exercices, et l'écran le dit.
    static func reference(for course: Course?) -> SubjectReference {
        guard let course else { return SubjectReference() }
        return SubjectReference(
            seriesNumbers: Array(Set(course.sortedSeries.map(\.seriesNumber))).sorted(),
            exerciseNumbers: Array(Set(course.allExercises.map(\.groupNumber))).sorted(),
            theoryNumbers: Array(Set(course.theoryItems.map(\.number))).sorted())
    }

    /// Ce que chaque membre a validé dans une matière.
    static func contributions(subject: String, group: StudyGroup) -> [SubjectContribution] {
        let target = subject.uppercased()
        var byUser: [String: SubjectContribution] = [:]

        for completion in group.completions where completion.courseCode.uppercased() == target {
            byUser[completion.userID, default: SubjectContribution(userID: completion.userID)]
                .seriesNumbers.insert(completion.seriesNumber)
        }

        for item in group.itemCompletions where item.courseCode.uppercased() == target {
            switch item.kind {
            case .exercise:
                byUser[item.userID, default: SubjectContribution(userID: item.userID)]
                    .exerciseNumbers.insert(item.itemNumber)
            case .theory:
                byUser[item.userID, default: SubjectContribution(userID: item.userID)]
                    .theoryNumbers.insert(item.itemNumber)
            }
        }

        return Array(byUser.values)
    }

    /// La comparaison complète d'une matière : classement, mon écart, et le reste.
    static func comparison(subject: String,
                           group: StudyGroup,
                           course: Course?,
                           meID: String?) -> GroupProgressEngine.SubjectComparison {
        let members = group.members.map {
            (userID: $0.userID, displayName: $0.displayName, isMe: $0.isMe)
        }
        return GroupProgressEngine.compare(subject: subject.uppercased(),
                                           reference: reference(for: course),
                                           contributions: contributions(subject: subject, group: group),
                                           members: members,
                                           meID: meID)
    }

    /// L'avancement du groupe sur **une** matière, réduit à ce qu'affiche la liste
    /// des matières : le mien, et celui du plus avancé.
    struct SubjectHeadline {
        var me: SubjectMemberProgress?
        /// Le membre le plus avancé autre que moi, s'il y en a un.
        var leader: SubjectMemberProgress?
        var memberCount: Int
        /// Membres qui suivent cette matière.
        var followerCount: Int

        /// « Alice a 4 éléments d'avance sur toi » — nil quand je suis devant.
        var leadLabel: String? {
            guard let leader, let me, !leader.isMe else { return nil }
            let gap = leader.doneTotal - me.doneTotal
            guard gap > 0 else { return nil }
            let unit = gap == 1 ? "élément" : "éléments"
            return "\(leader.displayName) a \(gap) \(unit) d'avance"
        }
    }

    static func headline(subject: String,
                         group: StudyGroup,
                         course: Course?,
                         meID: String?) -> SubjectHeadline {
        let comparison = comparison(subject: subject, group: group, course: course, meID: meID)
        let followers = group.members.filter { $0.follows(subject) }
        return SubjectHeadline(me: comparison.me,
                               leader: comparison.rows.first { !$0.isMe },
                               memberCount: group.members.count,
                               followerCount: followers.count)
    }
}

// MARK: - Séries

extension GroupProgressBuilder {
    /// Les tableaux « série par série » d'une matière, d'après mon cours.
    static func seriesBoards(subject: String,
                             group: StudyGroup,
                             course: Course?,
                             meID: String?) -> [SeriesBoard] {
        let target = subject.uppercased()
        let refs = (course?.sortedSeries ?? []).map { series in
            GroupSeriesEngine.SeriesRef(number: series.seriesNumber,
                                        label: series.label,
                                        title: series.title,
                                        plannedWeek: series.plannedWeek,
                                        required: series.sortedExercises.filter { !$0.isBonus }.map(\.groupNumber),
                                        bonus: series.sortedExercises.filter(\.isBonus).map(\.groupNumber))
        }
        let members = group.members.map {
            GroupSeriesEngine.MemberRef(userID: $0.userID, displayName: $0.shownName, isMe: $0.isMe)
        }
        let items = group.itemCompletions
            .filter { $0.courseCode.uppercased() == target && $0.kind == .exercise }
            .map { GroupSeriesEngine.ItemDone(userID: $0.userID, number: $0.itemNumber) }
        let declared = group.completions
            .filter { $0.courseCode.uppercased() == target }
            .map { GroupSeriesEngine.SeriesDone(userID: $0.userID, seriesNumber: $0.seriesNumber) }
        return GroupSeriesEngine.boards(series: refs,
                                        members: members,
                                        itemsDone: items,
                                        seriesDone: declared,
                                        meID: meID)
    }
}
