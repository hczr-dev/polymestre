import Foundation
import SwiftData

/// « X a fait l'exercice 3.2 (ou la vidéo 1.1) du cours Y » — au sein d'un groupe.
///
/// Le partage au niveau de la **série** ne dit pas où en est quelqu'un : deux
/// étudiants qui ont la même série peuvent être au premier ou au dernier exercice.
/// C'est ce détail qui rend un groupe utile pour travailler ensemble.
///
/// Comme l'EPFL publie une seule série par semaine et par matière, deux personnes
/// inscrites au même cours ont forcément les mêmes numéros — la comparaison est
/// donc toujours possible, sans rien demander de plus à l'utilisateur.
@Model
final class GroupItemCompletion {
    var id: UUID = UUID()
    var group: StudyGroup?
    var userID: String = ""
    var displayName: String = ""
    var courseCode: String = ""
    /// `exercise` ou `theory` — voir `GroupItemKind`.
    var kindRaw: String = ""
    /// Numéro affiché : « 3.2 », « 1.1 ».
    var itemNumber: String = ""
    var completedAt: Date = Date.now

    init(id: UUID = UUID(),
         group: StudyGroup? = nil,
         userID: String,
         displayName: String,
         courseCode: String,
         kind: GroupItemKind,
         itemNumber: String,
         completedAt: Date = Date()) {
        self.id = id
        self.group = group
        self.userID = userID
        self.displayName = displayName
        self.courseCode = courseCode
        self.kindRaw = kind.rawValue
        self.itemNumber = itemNumber
        self.completedAt = completedAt
    }

    var kind: GroupItemKind {
        get { GroupItemKind(rawValue: kindRaw) ?? .exercise }
        set { kindRaw = newValue.rawValue }
    }
}

/// Nature d'un élément partagé.
enum GroupItemKind: String, Codable, CaseIterable {
    case exercise
    case theory

    var label: String {
        switch self {
        case .exercise: return String(localized: "exercices")
        case .theory: return String(localized: "théorie")
        }
    }
}
