import AppIntents
import Foundation

/// Une commande du chrono, déclenchée depuis l'écran verrouillé ou l'îlot.
enum FocusTimerCommand: String, Codable, Sendable {
    case pause
    case resume
    case finish
    /// Coche la prochaine sous-question de la cible.
    case nextQuestion
    /// Termine la pause Pomodoro et relance le travail.
    case skipBreak

    var label: String {
        switch self {
        case .pause: return String(localized: "Mettre en pause")
        case .resume: return String(localized: "Reprendre")
        case .finish: return String(localized: "Enregistrer la session")
        case .nextQuestion: return String(localized: "Question suivante")
        case .skipBreak: return String(localized: "Reprendre le travail")
        }
    }
}

/// Passerelle entre l'extension — qui affiche les boutons — et l'app, qui agit.
///
/// Les boutons d'une Live Activity s'exécutent dans le **processus de l'app**
/// (`LiveActivityIntent`), mais leur code est compilé dans **les deux cibles** : il
/// ne peut donc pas référencer les types de l'app. La commande passe par un dépôt
/// partagé, et l'app la consomme.
///
/// Deux chemins, pour ne rien perdre :
///   • l'app tourne → le gestionnaire est appelé tout de suite ;
///   • l'app était suspendue → la commande reste déposée et sera rejouée à la
///     prochaine activation.
enum FocusTimerBridge {

    static let pendingKey = "focus.pendingCommand"

    /// Domaine partagé : l'app et l'extension lisent le même.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: WidgetBridge.appGroupID) ?? .standard
    }

    /// Posé par l'app à son lancement.
    nonisolated(unsafe) static var handler: ((FocusTimerCommand) -> Void)?

    /// Dépose une commande, et prévient l'app si elle est vivante.
    static func request(_ command: FocusTimerCommand) {
        defaults.set(command.rawValue, forKey: pendingKey)
        if let handler {
            DispatchQueue.main.async { handler(command) }
        }
    }

    /// Retire et renvoie la commande en attente, s'il y en a une.
    static func takePending() -> FocusTimerCommand? {
        guard let raw = defaults.string(forKey: pendingKey),
              let command = FocusTimerCommand(rawValue: raw) else { return nil }
        defaults.removeObject(forKey: pendingKey)
        return command
    }

    static func clearPending() {
        defaults.removeObject(forKey: pendingKey)
    }
}

// MARK: - Intentions

/// Met le chrono en pause depuis l'écran verrouillé.
///
/// `isDiscoverable = false` : ces intentions ne s'adressent pas à Siri ni aux
/// Raccourcis, elles n'ont de sens que sur la Live Activity.
struct PauseFocusTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mettre en pause"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        FocusTimerBridge.request(.pause)
        return .result()
    }
}

/// Reprend le chrono depuis l'écran verrouillé.
struct ResumeFocusTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Reprendre"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        FocusTimerBridge.request(.resume)
        return .result()
    }
}

/// Termine et enregistre la session depuis l'écran verrouillé.
struct FinishFocusTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Enregistrer la session"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        FocusTimerBridge.request(.finish)
        return .result()
    }
}

/// Coche la sous-question en cours et passe à la suivante.
///
/// C'est le geste réel d'une série d'exercices : on finit (a), on passe à (b).
/// Sans ce bouton, il fallait déverrouiller le téléphone, ouvrir l'app et
/// retrouver l'exercice — pour cocher une case. La coche vit dans SwiftData, donc
/// l'intention ne fait que déposer la commande ; c'est l'app qui écrit.
struct NextQuestionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Question suivante"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        FocusTimerBridge.request(.nextQuestion)
        return .result()
    }
}

/// Termine la pause Pomodoro et relance le bloc suivant, depuis l'écran
/// verrouillé ou l'îlot.
struct SkipBreakIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Reprendre le travail"
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        FocusTimerBridge.request(.skipBreak)
        return .result()
    }
}

/// L'interrupteur du Centre de contrôle, de l'écran verrouillé et du bouton
/// Action : met le chrono en pause ou le relance, sans ouvrir l'app.
///
/// `LiveActivityIntent` pour la même raison que les boutons de l'îlot : l'intention
/// s'exécute dans le **processus de l'app**, qui applique la commande tout de
/// suite au lieu d'attendre sa prochaine activation.
@available(iOS 18.0, *)
struct ToggleFocusTimerIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause du chrono"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Chrono en marche")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        FocusTimerBridge.request(value ? .resume : .pause)
        return .result()
    }
}
