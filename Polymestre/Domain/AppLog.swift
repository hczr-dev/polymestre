import Foundation

/// Une ligne du journal de l'app.
struct LogEntry: Codable, Equatable, Identifiable {
    enum Level: String, Codable, CaseIterable {
        case info
        case warning
        case error

        var label: String {
            switch self {
            case .info: return "info"
            case .warning: return "avertissement"
            case .error: return "erreur"
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "exclamationmark.octagon"
            }
        }
    }

    var id: UUID
    var date: Date
    var level: Level
    /// D'où vient la ligne : `sync`, `import`, `anki`, `ia`, `stockage`.
    var category: String
    var message: String
    var detail: String?

    init(id: UUID = UUID(),
         date: Date = Date(),
         level: Level,
         category: String,
         message: String,
         detail: String? = nil) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
        self.detail = detail
    }
}

/// Le tampon circulaire du journal, **pur** : ajouter, borner, filtrer, formater.
///
/// Séparé du stockage pour être testable sans toucher au disque — c'est là que se
/// trouvent les règles qui comptent : ne pas grossir sans fin, garder les erreurs
/// plus longtemps que les informations.
enum LogBuffer {

    /// Nombre maximal de lignes conservées.
    static let limit = 400

    /// Ajoute une ligne en tête et borne la taille.
    ///
    /// Les plus **anciennes** partent en premier, et parmi elles les informations
    /// avant les erreurs : quand la place manque, on garde ce qui explique un
    /// problème plutôt que ce qui raconte une journée ordinaire.
    static func append(_ entry: LogEntry, to entries: [LogEntry]) -> [LogEntry] {
        var updated = entries
        updated.insert(entry, at: 0)
        guard updated.count > limit else { return updated }

        // On retire d'abord des informations, de la plus ancienne à la plus
        // récente ; s'il n'y en a plus, on retire les avertissements.
        var overflow = updated.count - limit
        for level in [LogEntry.Level.info, .warning] {
            guard overflow > 0 else { break }
            var index = updated.count - 1
            while index >= 0, overflow > 0 {
                if updated[index].level == level {
                    updated.remove(at: index)
                    overflow -= 1
                }
                index -= 1
            }
        }
        return Array(updated.prefix(limit))
    }

    static func filtered(_ entries: [LogEntry], level: LogEntry.Level?) -> [LogEntry] {
        guard let level else { return entries }
        return entries.filter { $0.level == level }
    }

    static func count(_ entries: [LogEntry], level: LogEntry.Level) -> Int {
        entries.filter { $0.level == level }.count
    }

    /// Le journal en texte, pour le partager ou le coller dans un message.
    static func text(_ entries: [LogEntry], formatter: ISO8601DateFormatter = .init()) -> String {
        guard !entries.isEmpty else { return String(localized: "Journal vide.") }
        return entries.map { entry in
            var line = "[\(formatter.string(from: entry.date))] \(entry.level.label.uppercased()) \(entry.category) — \(entry.message)"
            if let detail = entry.detail, !detail.isEmpty {
                line += "\n    \(detail.replacingOccurrences(of: "\n", with: "\n    "))"
            }
            return line
        }
        .joined(separator: "\n")
    }
}

/// Le journal, persisté.
///
/// Il existe parce qu'un défaut signalé par un utilisateur n'a **rien** à
/// consulter : une synchronisation qui échoue, un import qui ne trouve rien, une
/// carte Anki refusée ne laissent aucune trace. Sans journal, la seule réponse
/// possible est « réessaie et dis-moi ».
enum AppLog {

    static let key = "diagnostics.log"

    /// La catégorie, en clair, pour filtrer l'écran.
    enum Category {
        static let sync = "synchronisation"
        static let importSeries = "import"
        static let ai = "analyse IA"
        static let anki = "anki"
        static let storage = "stockage"
        static let calendar = "calendrier"
        static let claude = "Claude Code"
    }

    static func load(defaults: UserDefaults = .standard) -> [LogEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LogEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [LogEntry], defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    /// Consigne une ligne. Volontairement tolérant : un journal ne doit jamais
    /// faire échouer ce qu'il observe.
    static func record(_ level: LogEntry.Level,
                       _ category: String,
                       _ message: String,
                       detail: String? = nil,
                       defaults: UserDefaults = .standard) {
        let entry = LogEntry(level: level, category: category, message: message, detail: detail)
        save(LogBuffer.append(entry, to: load(defaults: defaults)), defaults: defaults)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
