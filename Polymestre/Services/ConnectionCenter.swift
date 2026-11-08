import Foundation
import Observation

/// L'état des comptes dont l'app dépend, en un seul endroit — et la règle pour
/// redemander une connexion : **seulement quand c'est nécessaire**.
///
/// Avant, chaque service gérait sa connexion dans son coin : une session
/// Moodle expirée se découvrait au détour d'un import (« Connecte-toi
/// d'abord »), une coupure réseau déconnectait des groupes, et AnkiWeb
/// échouait sans dire qu'il fallait se reconnecter. Désormais :
///   • chaque service **tente d'abord de se reconnecter seul** (session Moodle
///     rejouée par la connexion EPFL mémorisée, jeton Supabase rafraîchi) ;
///   • il ne signale `expired` que si cette tentative a échoué, ou si le
///     serveur a explicitement refusé l'identité ;
///   • l'accueil montre alors **une** bannière, que « Plus tard » fait taire
///     un jour entier.
@MainActor
@Observable
final class ConnectionCenter {
    static let shared = ConnectionCenter()

    enum Account: String, CaseIterable, Identifiable {
        case moodle, groups, ankiweb
        var id: String { rawValue }

        var label: String {
            switch self {
            case .moodle: return "Moodle"
            case .groups: return String(localized: "Compte Polymestre")
            case .ankiweb: return "AnkiWeb"
            }
        }

        /// Ce qui ne marche plus tant que le compte est déconnecté.
        var consequence: String {
            switch self {
            case .moodle: return String(localized: "nouvelles séries et énoncés en pause")
            case .groups: return String(localized: "groupes et entraide en pause")
            case .ankiweb: return String(localized: "cartes et statistiques Anki en pause")
            }
        }

        var icon: String {
            switch self {
            case .moodle: return "graduationcap"
            case .groups: return "person.2"
            case .ankiweb: return "rectangle.stack"
            }
        }
    }

    enum State: String {
        case unknown, connected, expired
    }

    private(set) var states: [Account: State] = [:]

    private let defaults = UserDefaults.standard
    private static func stateKey(_ account: Account) -> String { "connection.\(account.rawValue).state" }
    private static func snoozeKey(_ account: Account) -> String { "connection.\(account.rawValue).snoozedUntil" }

    private init() {
        for account in Account.allCases {
            states[account] = defaults.string(forKey: Self.stateKey(account)).flatMap(State.init(rawValue:)) ?? .unknown
        }
    }

    /// Moodle se lit dans la connexion de l'école (`SchoolConnect`), la seule
    /// qui s'y connecte ; les autres comptes, dans ce qu'ils ont signalé.
    func state(of account: Account) -> State {
        if account == .moodle {
            switch SchoolConnect.shared.state(.moodle) {
            case .connected: return .connected
            case .needsYou, .failed: return .expired
            case .unknown, .connecting: return .unknown
            }
        }
        return states[account] ?? .unknown
    }

    /// Un service dit ce qu'il a constaté. Une reconnexion efface le « plus tard ».
    func report(_ account: Account, _ state: State) {
        guard account != .moodle, states[account] != state else { return }
        states[account] = state
        defaults.set(state.rawValue, forKey: Self.stateKey(account))
        if state == .connected { defaults.removeObject(forKey: Self.snoozeKey(account)) }
        if state == .expired {
            AppLog.record(.warning, "connexion", "\(account.label) : reconnexion nécessaire", detail: account.consequence)
        }
    }

    /// « Plus tard » : la bannière se tait 24 h.
    func snooze(_ account: Account, now: Date = Date()) {
        defaults.set(now.addingTimeInterval(86_400), forKey: Self.snoozeKey(account))
        // `states` est observé : on le réécrit pour que la bannière disparaisse.
        states[account] = states[account]
    }

    /// Les comptes à reconnecter **maintenant** : expirés, et pas mis de côté.
    func needingAttention(now: Date = Date()) -> [Account] {
        Account.allCases.filter { account in
            guard state(of: account) == .expired else { return false }
            if let until = defaults.object(forKey: Self.snoozeKey(account)) as? Date, until > now { return false }
            return true
        }
    }
}
