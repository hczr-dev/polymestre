import Foundation
import SwiftData

/// Groupe d'étude (cache local d'un groupe distant Supabase).
@Model
final class StudyGroup {
    var id: UUID = UUID()
    /// Identifiant côté Supabase (nil si le groupe n'est pas encore synchronisé).
    var remoteID: String?
    var name: String = ""
    var details: String = ""
    /// Ancien champ mono-matière, conservé pour ne pas perdre les groupes déjà
    /// enregistrés. `subjectCodes` reste la seule source de vérité à l'usage.
    var courseCode: String = ""
    /// Les matières que le groupe travaille. Un groupe d'entraide porte presque
    /// toujours sur **plusieurs** cours : c'est la même promo, pas la même matière.
    var courseCodes: [String] = []
    var inviteCode: String = ""
    var isAdmin: Bool = false
    var createdAt: Date = Date.now
    var lastSyncedAt: Date?

    @Relationship(deleteRule: .cascade, originalName: "members", inverse: \GroupMember.group)
    var membersStore: [GroupMember]? = []
    var members: [GroupMember] {
        get { membersStore ?? [] }
        set { membersStore = newValue }
    }

    @Relationship(deleteRule: .cascade, originalName: "completions", inverse: \GroupSeriesCompletion.group)
    var completionsStore: [GroupSeriesCompletion]? = []
    var completions: [GroupSeriesCompletion] {
        get { completionsStore ?? [] }
        set { completionsStore = newValue }
    }

    /// Avancement **exercice par exercice** des membres.
    @Relationship(deleteRule: .cascade, originalName: "itemCompletions", inverse: \GroupItemCompletion.group)
    var itemCompletionsStore: [GroupItemCompletion]? = []
    var itemCompletions: [GroupItemCompletion] {
        get { itemCompletionsStore ?? [] }
        set { itemCompletionsStore = newValue }
    }

    init(id: UUID = UUID(),
         remoteID: String? = nil,
         name: String,
         details: String = "",
         courseCode: String = "",
         courseCodes: [String] = [],
         inviteCode: String = "",
         isAdmin: Bool = true) {
        self.id = id
        self.remoteID = remoteID
        self.name = name
        self.details = details
        self.courseCode = courseCode
        self.courseCodes = courseCodes
        self.inviteCode = inviteCode.isEmpty ? StudyGroup.generateInviteCode() : inviteCode
        self.isAdmin = isAdmin
        self.createdAt = Date()
    }

    static func generateInviteCode() -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let suffix = String((0..<4).map { _ in alphabet.randomElement() ?? "A" })
        return "EPFL-\(suffix)"
    }

    /// Normalise un code saisi ou reçu par lien : majuscules, sans espaces.
    ///
    /// Un code collé depuis un message arrive souvent en minuscules ou entouré
    /// d'espaces ; le refuser pour ça serait incompréhensible.
    static func normalizeInviteCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
    }

    /// Lien d'invitation partageable, compris par l'app elle-même.
    var inviteLink: String {
        "polymestre://join?code=\(inviteCode)"
    }

    /// Message prêt à envoyer : le code **et** le lien.
    ///
    /// Le code seul oblige à un aller-retour (« et je le mets où ? ») ; le lien seul
    /// ne fonctionne pas partout. Les deux ensemble marchent dans tous les cas.
    var inviteMessage: String {
        var text = String(localized: "Rejoins « \(name) » sur Polymestre avec le code \(inviteCode).")
        if !subjectCodes.isEmpty {
            text += "\n" + String(localized: "Matières : \(subjectCodes.joined(separator: ", ")).")
        }
        text += "\n\(inviteLink)"
        return text
    }

    /// Les matières du groupe, sans doublon ni casse multiple.
    ///
    /// Repli sur l'ancien champ mono-matière : un groupe créé avant l'arrivée des
    /// matières multiples doit continuer à fonctionner sans réédition manuelle.
    var subjectCodes: [String] {
        get {
            var seen = Set<String>()
            var result: [String] = []
            for raw in courseCodes + (courseCode.isEmpty ? [] : [courseCode]) {
                let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard !code.isEmpty, seen.insert(code).inserted else { continue }
                result.append(code)
            }
            return result
        }
        set {
            // Le champ historique est **absorbé** par la liste définitive.
            //
            // Sans ça, `courseCode` restait renseigné et le getter le réinjectait :
            // une matière retirée de l'éditeur réapparaissait aussitôt.
            courseCode = ""
            courseCodes = Self.normalize(newValue)
        }
    }

    /// Nettoie une liste de codes : majuscules, sans doublon, ordre conservé.
    static func normalize(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in codes {
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !code.isEmpty, seen.insert(code).inserted else { continue }
            result.append(code)
        }
        return result
    }

    func addSubject(_ code: String) {
        subjectCodes = subjectCodes + [code]
    }

    func removeSubject(_ code: String) {
        let target = code.uppercased()
        subjectCodes = subjectCodes.filter { $0 != target }
        courseCode = courseCode.uppercased() == target ? "" : courseCode
        for member in members {
            member.courseCodes = member.courseCodes.filter { $0.uppercased() != target }
        }
    }

    /// Le groupe travaille-t-il cette matière ?
    func tracks(_ code: String) -> Bool {
        subjectCodes.contains(code.uppercased())
    }

    /// Mes matières communes : celles du groupe que je suis réellement.
    ///
    /// Un groupe peut travailler cinq matières dont je n'en suis que deux — les
    /// autres ne me concernent pas et n'ont pas à occuper l'écran.
    func mySubjectCodes(myTrackedCourses: Set<String>) -> [String] {
        subjectCodes.filter { myTrackedCourses.contains($0) }
    }

    var displayName: String { courseCode.isEmpty ? name : "\(courseCode) · \(name)" }
}

/// Membre d'un groupe, avec ses statistiques agrégées.
@Model
final class GroupMember {
    var id: UUID = UUID()
    var group: StudyGroup?
    var userID: String = ""
    var displayName: String = ""
    var weeklySeconds: Int = 0
    var totalSeconds: Int = 0
    var completedSeriesCount: Int = 0
    var isMe: Bool = false
    var isAnonymous: Bool = false
    /// `admin` ou `member` — voir `GroupRole`.
    var roleRaw: String = GroupRole.member.rawValue
    /// Les matières du groupe que ce membre suit.
    var courseCodes: [String] = []

    init(id: UUID = UUID(),
         group: StudyGroup? = nil,
         userID: String,
         displayName: String,
         weeklySeconds: Int = 0,
         totalSeconds: Int = 0,
         completedSeriesCount: Int = 0,
         isMe: Bool = false,
         isAnonymous: Bool = false,
         role: GroupRole = .member,
         courseCodes: [String] = []) {
        self.id = id
        self.group = group
        self.userID = userID
        self.displayName = displayName
        self.weeklySeconds = weeklySeconds
        self.totalSeconds = totalSeconds
        self.completedSeriesCount = completedSeriesCount
        self.isMe = isMe
        self.isAnonymous = isAnonymous
        self.roleRaw = role.rawValue
        self.courseCodes = courseCodes
    }

    var role: GroupRole {
        get { GroupRole(rawValue: roleRaw) ?? .member }
        set { roleRaw = newValue.rawValue }
    }

    /// Ce membre administre-t-il le groupe ?
    ///
    /// Le second terme n'est pas une politesse : `roleRaw` est arrivé **après**
    /// `StudyGroup.isAdmin`. Pour un groupe créé avant, SwiftData a migré le nouvel
    /// attribut à sa valeur par défaut — « member » — y compris pour la personne qui
    /// avait créé le groupe. Elle se retrouvait donc sans droits sur son propre
    /// groupe, avec un message lui disant que seuls les administrateurs pouvaient
    /// agir. Le drapeau local du groupe tranche tant que le serveur n'a rien dit.
    var isAdmin: Bool {
        if role == .admin { return true }
        return isMe && (group?.isAdmin ?? false)
    }

    var shownName: String { isAnonymous ? String(localized: "Anonyme") : displayName }
    var weeklyLabel: String { DateUtils.hoursLabel(seconds: weeklySeconds) }
    var totalLabel: String { DateUtils.hoursLabel(seconds: totalSeconds) }
    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    /// Ce membre suit-il cette matière du groupe ?
    func follows(_ code: String) -> Bool {
        courseCodes.isEmpty || courseCodes.contains { $0.uppercased() == code.uppercased() }
    }
}

/// Rôle d'un membre dans un groupe. Les politiques RLS de Supabase utilisent
/// exactement ces deux chaînes (`admin`, `member`).
enum GroupRole: String, CaseIterable, Codable {
    case admin
    case member

    var label: String {
        switch self {
        case .admin: return "Admin"
        case .member: return String(localized: "Membre")
        }
    }

    var icon: String {
        switch self {
        case .admin: return "crown.fill"
        case .member: return "person.fill"
        }
    }
}

/// « X a terminé la série N du cours Y » — alimente la matrice d'avancement.
@Model
final class GroupSeriesCompletion {
    var id: UUID = UUID()
    var group: StudyGroup?
    var userID: String = ""
    var displayName: String = ""
    var courseCode: String = ""
    var seriesNumber: Int = 0
    var totalSeries: Int = 0
    var completedAt: Date = Date.now

    init(id: UUID = UUID(),
         group: StudyGroup? = nil,
         userID: String,
         displayName: String,
         courseCode: String,
         seriesNumber: Int,
         totalSeries: Int = 4,
         completedAt: Date = Date()) {
        self.id = id
        self.group = group
        self.userID = userID
        self.displayName = displayName
        self.courseCode = courseCode
        self.seriesNumber = seriesNumber
        self.totalSeries = totalSeries
        self.completedAt = completedAt
    }
}

/// Données de démonstration pour les groupes.
///
/// **Debug uniquement**, et seulement sur demande explicite (`-seedSampleData`) :
/// cette fonction a déjà créé un faux groupe « Buddies BA4 » chez de vrais
/// utilisateurs, parce qu'elle était appelée sans condition à l'ouverture de
/// l'onglet Groupes.
enum GroupDemoData {
    static func seedIfNeeded(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<StudyGroup>())) ?? 0
        guard existing == 0 else { return }

        let group = StudyGroup(name: "Buddies BA4",
                               details: "Groupe d'entraide pour le semestre.",
                               courseCode: "",
                               courseCodes: ["CS-250", "MATH-101", "PHYS-101"],
                               inviteCode: "EPFL-4F2A",
                               isAdmin: true)
        context.insert(group)

        let members: [(String, String, Int, Int, Int, Bool, GroupRole)] = [
            ("me", "Moi", 9 * 3600 + 1800, 74 * 3600, 3, true, .admin),
            ("u-alice", "Alice Moreau", 12 * 3600, 96 * 3600, 5, false, .admin),
            ("u-bob", "Bob Favre", 7 * 3600 + 900, 61 * 3600, 4, false, .member),
            ("u-chloe", "Chloé Dupraz", 6 * 3600, 58 * 3600, 4, false, .member),
            ("u-dan", "Dan Rossier", 4 * 3600 + 1200, 41 * 3600, 2, false, .member)
        ]
        for member in members {
            let entry = GroupMember(group: group,
                                    userID: member.0,
                                    displayName: member.1,
                                    weeklySeconds: member.2,
                                    totalSeconds: member.3,
                                    completedSeriesCount: member.4,
                                    role: member.6,
                                    courseCodes: group.subjectCodes)
            entry.isMe = member.5
            context.insert(entry)
        }

        let completions: [(String, String, String, Int)] = [
            ("u-alice", "Alice Moreau", "CS-250", 1),
            ("u-alice", "Alice Moreau", "CS-250", 2),
            ("u-alice", "Alice Moreau", "MATH-101", 1),
            ("u-bob", "Bob Favre", "CS-250", 1),
            ("u-bob", "Bob Favre", "CS-250", 2),
            ("u-chloe", "Chloé Dupraz", "MATH-101", 1),
            ("me", "Moi", "CS-250", 1)
        ]
        for completion in completions {
            let entry = GroupSeriesCompletion(group: group,
                                              userID: completion.0,
                                              displayName: completion.1,
                                              courseCode: completion.2,
                                              seriesNumber: completion.3)
            context.insert(entry)
        }

        let items: [(String, String, String, GroupItemKind, String)] = [
            ("me", "Moi", "CS-250", .exercise, "3.1"),
            ("me", "Moi", "CS-250", .exercise, "3.2"),
            ("me", "Moi", "CS-250", .theory, "3.1"),
            // Des numéros qui existent réellement dans les cours d'exemple :
            // un numéro inconnu du référentiel est ignoré au calcul, et la
            // démonstration paraîtrait alors incohérente.
            ("u-alice", "Alice Moreau", "CS-250", .exercise, "3.1"),
            ("u-alice", "Alice Moreau", "CS-250", .exercise, "3.2"),
            ("u-alice", "Alice Moreau", "CS-250", .exercise, "1.1"),
            ("u-alice", "Alice Moreau", "CS-250", .theory, "3.1"),
            ("u-alice", "Alice Moreau", "CS-250", .theory, "3.2"),
            ("u-bob", "Bob Favre", "CS-250", .exercise, "3.1")
        ]
        for item in items {
            let entry = GroupItemCompletion(group: group,
                                            userID: item.0,
                                            displayName: item.1,
                                            courseCode: item.2,
                                            kind: item.3,
                                            itemNumber: item.4)
            context.insert(entry)
        }

        try? context.save()
    }
}
