import Foundation

/// Notice de configuration de chaque fournisseur de tâches.
///
/// Écrite à part de l'interface, et testée : ajouter un fournisseur sans sa notice
/// doit se voir. Un jeton qu'on ne sait pas où trouver est un jeton qu'on n'utilise
/// pas — c'est le principal frein à l'usage des intégrations.
extension TaskProvider {

    /// Une phrase : ce que l'intégration fait réellement.
    var setupSummary: String {
        switch self {
        case .reminders:
            return String(localized: "Les listes de Rappels de ton appareil. Aucun compte, aucun jeton : c'est le système qui s'en charge.")
        case .todoist:
            return String(localized: "Lecture et création de tâches dans ton compte Todoist, via l'API v1.")
        case .things:
            return String(localized: "Création de tâches dans Things 3, par son schéma d'URL. Things n'expose aucune API de lecture : Polymestre ne verra jamais ce que tu y fais.")
        case .notion:
            return String(localized: "Lecture et création de tâches dans une base de données Notion.")
        case .webhook:
            return String(localized: "Chaque tâche créée est envoyée en JSON à l'URL de ton choix — Raccourcis, n8n, Zapier, Home Assistant. Rien n'est relu.")
        case .googleTasks:
            return String(localized: "Lecture et création de tâches dans Google Tasks. L'app renouvelle elle-même son accès grâce au refresh token.")
        case .tickTick:
            return String(localized: "Lecture et création de tâches dans TickTick, via son API ouverte.")
        }
    }

    /// Ce que l'intégration sait faire, en clair.
    var capabilityLabel: String {
        switch self {
        case .reminders, .todoist, .notion, .googleTasks, .tickTick:
            return String(localized: "Lecture et écriture")
        case .things, .webhook:
            return String(localized: "Écriture seule")
        }
    }

    /// Les étapes, dans l'ordre, telles qu'un étudiant doit les suivre.
    var setupSteps: [String] {
        switch self {
        case .reminders:
            return [
                String(localized: "Autorise l'accès aux Rappels quand l'app le demande."),
                String(localized: "Rien d'autre : les listes existantes sont reconnues automatiquement."),
                String(localized: "Les tâches créées depuis Polymestre arrivent dans ta liste par défaut.")
            ]

        case .todoist:
            return [
                String(localized: "Ouvre Todoist dans un navigateur et connecte-toi."),
                String(localized: "Va dans Réglages ▸ Intégrations ▸ Développeur."),
                String(localized: "Copie la valeur du champ « API token »."),
                String(localized: "Colle-la dans le champ ci-dessus. Elle reste sur ton appareil et n'est envoyée qu'à api.todoist.com.")
            ]

        case .things:
            return [
                String(localized: "Installe Things 3 sur cet appareil (Mac, iPhone ou iPad)."),
                String(localized: "Active l'interrupteur ci-dessus : il n'y a ni compte ni jeton à saisir."),
                String(localized: "Les tâches créées depuis Polymestre arrivent dans la boîte de réception de Things.")
            ]

        case .notion:
            return [
                String(localized: "Dans Notion, crée une base de données avec trois propriétés : Name (titre), Done (case à cocher) et Due (date)."),
                String(localized: "Va sur notion.so/my-integrations et crée une intégration interne."),
                String(localized: "Copie le « Internal Integration Secret » et colle-le ci-dessus."),
                String(localized: "Dans Notion, ouvre la base, puis ⋯ ▸ Connexions : ajoute ton intégration. Sans cette étape l'app n'a aucun droit sur la base."),
                String(localized: "Colle l'identifiant de la base : c'est la suite de 32 caractères dans l'URL de la base, entre la dernière barre oblique et le « ? ».")
            ]

        case .webhook:
            return [
                String(localized: "Prépare une URL qui accepte un POST JSON (Raccourci, n8n, Zapier, Home Assistant…)."),
                String(localized: "Colle-la ci-dessus."),
                String(localized: "À chaque tâche créée, Polymestre envoie un objet JSON avec le titre, les notes, l'échéance, la priorité et le code du cours.")
            ]

        case .googleTasks:
            return [
                String(localized: "Dans Google Cloud Console, crée un projet puis active l'API « Google Tasks »."),
                String(localized: "Crée un identifiant OAuth de type « Application de bureau » : tu obtiens un identifiant client et un secret."),
                String(localized: "Ouvre la page OAuth 2.0 Playground, autorise la portée Tasks, puis échange le code contre des jetons."),
                String(localized: "Colle l'identifiant client, le secret et le refresh token ci-dessus : l'app renouvelle ensuite l'accès toute seule.")
            ]

        case .tickTick:
            return [
                String(localized: "Va sur developer.ticktick.com et crée une application."),
                String(localized: "Récupère un jeton d'accès par le flux OAuth2 de TickTick, avec les portées tasks:read et tasks:write."),
                String(localized: "Colle le jeton ci-dessus."),
                String(localized: "Polymestre lit et crée alors des tâches dans ton projet par défaut.")
            ]
        }
    }

    /// Lien vers la page où trouver l'identifiant, quand elle existe.
    var setupURLString: String? {
        switch self {
        case .reminders, .things, .webhook:
            return nil
        case .todoist:
            return "https://todoist.com/app/settings/integrations/developer"
        case .notion:
            return "https://www.notion.so/my-integrations"
        case .googleTasks:
            return "https://console.cloud.google.com/apis/library/tasks.googleapis.com"
        case .tickTick:
            return "https://developer.ticktick.com/manage"
        }
    }

    /// Une mise en garde propre à certains fournisseurs.
    var setupCaveat: String? {
        switch self {
        case .reminders:
            return String(localized: "Polymestre ne lit que les listes auxquelles tu as donné accès ; retire l'autorisation dans Réglages ▸ Confidentialité à tout moment.")
        case .todoist:
            return String(localized: "Le jeton donne un accès complet à ton compte Todoist. Si tu le révoques, la synchronisation s'arrête sans rien casser : les tâches déjà importées restent locales.")
        case .things:
            return String(localized: "Écriture seule : une tâche terminée dans Things restera « à faire » dans Polymestre. Coche-la des deux côtés.")
        case .notion:
            return String(localized: "Un jeton d'intégration ne voit que les bases que tu lui as explicitement partagées.")
        case .webhook:
            return String(localized: "Écriture seule, et sans réessai : si l'URL est injoignable, la tâche n'est pas renvoyée plus tard.")
        case .googleTasks:
            return String(localized: "Le refresh token ne s'obtient qu'une fois. Si tu le révoques depuis ton compte Google, il faut refaire l'étape 3.")
        case .tickTick:
            return String(localized: "TickTick ne fournit de refresh token qu'aux applications enregistrées : sans lui, le jeton expire et il faut le recoller.")
        }
    }
}
