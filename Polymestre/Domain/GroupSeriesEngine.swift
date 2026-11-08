import Foundation

/// L'avancement d'**un** membre sur **une** série : quels exercices sont faits.
struct SeriesMemberProgress: Identifiable, Equatable {
    var userID: String
    var displayName: String
    var isMe: Bool
    /// Numéros faits, dans l'ordre de la série.
    var doneNumbers: [String]
    var total: Int
    /// Le membre a déclaré la série terminée (partage au niveau série).
    var declaredComplete: Bool

    var id: String { userID }
    var doneCount: Int { doneNumbers.count }
    var isComplete: Bool { declaredComplete || (total > 0 && doneCount >= total) }
    /// Une série déclarée terminée est pleine, même sans le détail des exercices.
    var percent: Double {
        if isComplete { return 1 }
        guard total > 0 else { return 0 }
        return min(1, Double(doneCount) / Double(total))
    }
}

/// Une série du référentiel, avec la ligne de chaque membre.
struct SeriesBoard: Identifiable, Equatable {
    var seriesNumber: Int
    /// « b », « mardi » : deux séries de même numéro (`SeriesIdentity`).
    var label: String = ""
    var title: String
    var plannedWeek: Int
    /// Les exercices **obligatoires** de la série, d'après mon cours.
    var exerciseNumbers: [String]
    var bonusNumbers: [String]
    /// Trié : le plus avancé d'abord, moi à égalité.
    var rows: [SeriesMemberProgress]

    var id: String { "\(seriesNumber)|\(label)" }
    var displayName: String { SeriesIdentity.displayName(number: seriesNumber, label: label) }
    var total: Int { exerciseNumbers.count }
    var completedCount: Int { rows.filter(\.isComplete).count }
    var startedCount: Int { rows.filter { $0.doneCount > 0 || $0.declaredComplete }.count }
    var me: SeriesMemberProgress? { rows.first(where: \.isMe) }

    /// « 3 membres sur 5 ont terminé », « personne n'a commencé ».
    var summary: String {
        if rows.isEmpty { return String(localized: "Aucun membre") }
        if completedCount == rows.count { return String(localized: "Tout le monde a terminé") }
        if startedCount == 0 { return String(localized: "Personne n'a commencé") }
        let unit = completedCount == 1 ? String(localized: "a terminé") : String(localized: "ont terminé")
        return String(localized: "\(completedCount) sur \(rows.count) \(unit)")
    }
}

/// Construit la vue « série par série » d'une matière dans un groupe.
///
/// Le référentiel (quelles séries, quels exercices) vient de **mon** cours : l'EPFL
/// publie la même série à tout le monde. Ce que chacun a fait vient des
/// complétions partagées. Une série que je n'ai pas encore importée n'apparaît pas
/// — on ne devine jamais une structure.
enum GroupSeriesEngine {

    struct MemberRef: Equatable {
        var userID: String
        var displayName: String
        var isMe: Bool
    }

    struct ItemDone: Equatable {
        var userID: String
        var number: String
    }

    struct SeriesDone: Equatable {
        var userID: String
        var seriesNumber: Int
    }

    struct SeriesRef: Equatable {
        var number: Int
        var label: String = ""
        var title: String
        var plannedWeek: Int
        var required: [String]
        var bonus: [String]
    }

    static func boards(series: [SeriesRef],
                       members: [MemberRef],
                       itemsDone: [ItemDone],
                       seriesDone: [SeriesDone],
                       meID: String?) -> [SeriesBoard] {
        let doneByUser = Dictionary(grouping: itemsDone, by: \.userID)
            .mapValues { Set($0.map(\.number)) }
        let declared = Set(seriesDone.map { "\($0.userID)|\($0.seriesNumber)" })

        return series.sorted { SeriesIdentity.Key($0.number, $0.label) < SeriesIdentity.Key($1.number, $1.label) }.map { ref in
            let required = ref.required
            var rows = members.map { member -> SeriesMemberProgress in
                let mine = doneByUser[member.userID] ?? []
                let done = required.filter { mine.contains($0) }
                return SeriesMemberProgress(userID: member.userID,
                                            displayName: member.displayName,
                                            isMe: member.isMe || member.userID == meID,
                                            doneNumbers: done,
                                            total: required.count,
                                            // Une déclaration « série 5 » ne vaut que pour la série 5 sans étiquette.
                                            declaredComplete: ref.label.isEmpty && declared.contains("\(member.userID)|\(ref.number)"))
            }
            rows.sort { lhs, rhs in
                if lhs.isComplete != rhs.isComplete { return lhs.isComplete }
                if lhs.doneCount != rhs.doneCount { return lhs.doneCount > rhs.doneCount }
                if lhs.isMe != rhs.isMe { return lhs.isMe }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
            return SeriesBoard(seriesNumber: ref.number,
                               label: ref.label,
                               title: ref.title,
                               plannedWeek: ref.plannedWeek,
                               exerciseNumbers: required,
                               bonusNumbers: ref.bonus,
                               rows: rows)
        }
    }

    /// Le plus avancé sur la matière, hors moi, et mon retard sur lui, en exercices.
    static func gapToLeader(_ boards: [SeriesBoard]) -> (name: String, gap: Int)? {
        var totals: [String: (name: String, done: Int, isMe: Bool)] = [:]
        for board in boards {
            for row in board.rows {
                let done = row.isComplete ? board.total : row.doneCount
                let existing = totals[row.userID]
                totals[row.userID] = (row.displayName, (existing?.done ?? 0) + done, row.isMe)
            }
        }
        guard let me = totals.values.first(where: \.isMe),
              let leader = totals.values.filter({ !$0.isMe }).max(by: { $0.done < $1.done }),
              leader.done > me.done else { return nil }
        return (leader.name, leader.done - me.done)
    }
}
