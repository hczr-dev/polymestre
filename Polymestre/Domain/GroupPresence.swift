import Foundation

/// « Untel travaille sur CS-250 en ce moment » — la présence d'un membre.
///
/// Éphémère par nature : rien n'est conservé, la ligne vit le temps d'une session
/// de travail et le serveur la remplace à chaque battement. Un membre dont le
/// dernier battement est trop ancien est considéré hors ligne — c'est ce qui évite
/// de garder éternellement quelqu'un qui a fermé l'app sans arrêter le chrono.
struct PresenceEntry: Identifiable, Equatable, Sendable {
    var userID: String
    var displayName: String
    var courseCode: String
    /// Nature du travail (« Exercices », « Théorie »…).
    var taskLabel: String
    /// Numéro visé (« 3.2 »), vide si non précisé.
    var target: String
    var startedAt: Date
    /// Dernier battement reçu.
    var updatedAt: Date
    var isMe: Bool

    var id: String { userID }

    /// Durée écoulée depuis le début de la session de ce membre.
    func elapsed(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }

    /// Le membre est-il encore en train de travailler ?
    ///
    /// La fenêtre est volontairement plus large que le battement (`interval`) : un
    /// battement toutes les cinq minutes tolère deux battements manqués avant
    /// d'éteindre quelqu'un.
    func isLive(at now: Date, interval: TimeInterval = PresenceEntry.heartbeat) -> Bool {
        now.timeIntervalSince(updatedAt) < interval * 2.4
    }

    /// Bat un battement toutes les cinq minutes.
    static let heartbeat: TimeInterval = 300

    /// « 1 h 12 » — depuis combien de temps il travaille.
    func elapsedLabel(at now: Date) -> String {
        DateUtils.hoursLabel(seconds: Int(elapsed(at: now)))
    }

    /// « CS-250 · Exercices · Exercice 3.2 »
    var activityLabel: String {
        var parts: [String] = []
        if !courseCode.isEmpty { parts.append(courseCode) }
        if !taskLabel.isEmpty { parts.append(taskLabel) }
        if !target.isEmpty { parts.append(target) }
        return parts.isEmpty ? String(localized: "Travail en cours") : parts.joined(separator: " · ")
    }
}

/// Le filtre et le tri de la présence, isolés du réseau pour être testables.
enum PresenceBoard {

    /// Ne garde que les membres réellement en train de travailler, moi d'abord.
    ///
    /// Je suis toujours affiché·e en tête si je travaille : c'est mon propre état,
    /// et le chercher au milieu d'une liste est désagréable.
    static func live(_ entries: [PresenceEntry],
                     at now: Date = Date(),
                     interval: TimeInterval = PresenceEntry.heartbeat) -> [PresenceEntry] {
        entries
            .filter { $0.isLive(at: now, interval: interval) }
            .sorted { lhs, rhs in
                if lhs.isMe != rhs.isMe { return lhs.isMe }
                return lhs.startedAt < rhs.startedAt
            }
    }

    /// « Alice et Bob travaillent » — la phrase de la carte repliée.
    static func summary(_ entries: [PresenceEntry]) -> String {
        let others = entries.filter { !$0.isMe }
        guard !others.isEmpty else {
            return entries.contains { $0.isMe } ? String(localized: "Tu travailles en ce moment") : String(localized: "Personne ne travaille")
        }
        let names = others.map(\.displayName)
        if names.count == 1 { return String(localized: "\(names[0]) travaille en ce moment") }
        if names.count == 2 { return String(localized: "\(names[0]) et \(names[1]) travaillent") }
        let rest = names.count - 2
        return Plural.count(rest, "\(names[0]), \(names[1]) et \(rest) autre travaillent",
                            "\(names[0]), \(names[1]) et \(rest) autres travaillent")
    }
}

/// Pourquoi le direct ne peut pas fonctionner, en une phrase actionnable.
///
/// `nil` quand tout est en place. Sans ça, la carte « En direct » se contentait de
/// dire « personne ne travaille », ce qui est faux et n'aide personne.
enum PresenceAvailability: Equatable {
    case ready
    case notConfigured
    case notSignedIn
    case groupNotSynced
    case failing(String)

    var isReady: Bool { if case .ready = self { return true }; return false }

    var message: String? {
        switch self {
        case .ready:
            return nil
        case .notConfigured:
            return String(localized: "Cette version de l'app n'a pas de projet Supabase : le direct entre membres est indisponible.")
        case .notSignedIn:
            return String(localized: "Connecte-toi (Réglages › Compte et groupes) pour voir qui travaille.")
        case .groupNotSynced:
            return String(localized: "Ce groupe n'est pas encore synchronisé : lance une synchronisation depuis la liste des groupes.")
        case .failing(let detail):
            return detail
        }
    }

    /// Le diagnostic, dans l'ordre où les causes se présentent réellement.
    static func evaluate(isConfigured: Bool,
                         isSignedIn: Bool,
                         hasRemoteGroup: Bool,
                         lastError: String?) -> PresenceAvailability {
        if !isConfigured { return .notConfigured }
        if !isSignedIn { return .notSignedIn }
        if !hasRemoteGroup { return .groupNotSynced }
        if let lastError { return .failing(lastError) }
        return .ready
    }
}
