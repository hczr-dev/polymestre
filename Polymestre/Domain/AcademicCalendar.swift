import Foundation

/// Nature d'une échéance du calendrier académique.
///
/// La nature décide de la couleur, de l'icône et de ce que l'app en fait : les
/// bornes d'enseignement pilotent les semaines, les vacances expliquent un creux
/// d'activité, les délais méritent un rappel.
enum MilestoneKind: String, Codable, CaseIterable, Identifiable {
    case teachingStart
    case teachingEnd
    case examStart
    case examEnd
    case `break`
    case holiday
    case deadline
    case opening
    case evaluation
    case publication
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .teachingStart: return String(localized: "Début des cours")
        case .teachingEnd: return String(localized: "Fin des cours")
        case .examStart: return String(localized: "Début des examens")
        case .examEnd: return String(localized: "Fin des examens")
        case .break: return "Interruption"
        case .holiday: return String(localized: "Jour férié")
        case .deadline: return String(localized: "Délai")
        case .opening: return String(localized: "Ouverture")
        case .evaluation: return String(localized: "Évaluation des cours")
        case .publication: return "Publication"
        case .other: return String(localized: "Autre")
        }
    }

    var icon: String {
        switch self {
        case .teachingStart: return "play.circle.fill"
        case .teachingEnd: return "stop.circle.fill"
        case .examStart: return "graduationcap.fill"
        case .examEnd: return "flag.checkered"
        case .break: return "pause.circle.fill"
        case .holiday: return "sun.max.fill"
        case .deadline: return "exclamationmark.circle.fill"
        case .opening: return "lock.open.fill"
        case .evaluation: return "checkmark.bubble.fill"
        case .publication: return "doc.text.fill"
        case .other: return "calendar"
        }
    }

    /// Une borne structurelle : elle décide du déroulement du semestre, pas d'une
    /// formalité.
    var isStructural: Bool {
        switch self {
        case .teachingStart, .teachingEnd, .examStart, .examEnd: return true
        default: return false
        }
    }

}

/// Une échéance du calendrier académique, indépendante de la persistance.
struct AcademicMilestoneValue: Equatable, Identifiable {
    var id: String
    var title: String
    var date: Date
    var kind: MilestoneKind
    /// Mise en évidence par l'EPFL lui-même (`<strong>` dans le tableau).
    var isImportant: Bool
    /// Date approximative : « Fin décembre », « Mi-novembre », « Début mars ».
    /// L'app le dit plutôt que de faire passer une approximation pour une date.
    var isApproximate: Bool
    var termLabel: String
    var sourceURL: String

    init(id: String,
         title: String,
         date: Date,
         kind: MilestoneKind,
         isImportant: Bool = false,
         isApproximate: Bool = false,
         termLabel: String = "",
         sourceURL: String = AcademicCalendarParser.sourceURL) {
        self.id = id
        self.title = title
        self.date = date
        self.kind = kind
        self.isImportant = isImportant
        self.isApproximate = isApproximate
        self.termLabel = termLabel
        self.sourceURL = sourceURL
    }

    var isPast: Bool { date < Date() }

    /// « dans 12 j », « aujourd'hui », « il y a 3 j ».
    func countdown(from reference: Date = Date()) -> String {
        let days = DateUtils.daysBetween(reference, date)
        if days == 0 { return "aujourd'hui" }
        if days == 1 { return "demain" }
        if days > 1 { return "dans \(days) j" }
        if days == -1 { return "hier" }
        return "il y a \(-days) j"
    }
}

/// Lit le calendrier académique de l'EPFL depuis sa page publique.
///
/// **Pourquoi un parseur et pas des dates en dur** : l'EPFL publie deux semestres
/// à la fois et fait glisser la fenêtre chaque année. Un tableau figé dans le code
/// serait périmé en quelques mois. On garde donc un **instantané** embarqué (pour
/// que l'app fonctionne hors ligne dès l'installation, et le jour de la rentrée)
/// **et** de quoi relire la page pour le rafraîchir.
///
/// Fonction **pure** : elle reçoit du HTML, donc elle se teste sur le vrai contenu.
enum AcademicCalendarParser {

    static var sourceURL: String { Institution.current.calendarURL ?? Institution.epfl.calendarURL! }

    /// Les noms de mois, sans accents et en minuscules.
    ///
    /// Un `DateFormatter` dépendrait de la locale de l'appareil : un téléphone en
    /// anglais ne lirait pas « décembre ». Ici la table est explicite.
    private static let months: [String: Int] = [
        "janvier": 1, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6,
        "juillet": 7, "aout": 8, "septembre": 9, "octobre": 10,
        "novembre": 11, "decembre": 12
    ]

    // MARK: Analyse

    static func parse(html: String, calendar: Calendar = .current, now: Date = Date()) -> [AcademicMilestoneValue] {
        var result: [AcademicMilestoneValue] = []
        var seen = Set<String>()

        for section in sections(in: html) {
            for row in rows(in: section.body) {
                guard let parsed = parseDate(row.date, calendar: calendar, now: now) else { continue }
                let title = row.title
                guard !title.isEmpty else { continue }
                let kind = kind(for: title)
                let id = identifier(date: parsed.date, title: title, calendar: calendar)
                guard seen.insert(id).inserted else { continue }
                result.append(AcademicMilestoneValue(id: id,
                                                     title: title,
                                                     date: parsed.date,
                                                     kind: kind,
                                                     isImportant: row.isImportant,
                                                     isApproximate: parsed.approximate,
                                                     termLabel: section.label))
            }
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Une section = un semestre, repérée par « Semestre automne 26-27 ».
    private struct Section {
        var label: String
        var body: String
    }

    private static func sections(in html: String) -> [Section] {
        let pattern = try? NSRegularExpression(pattern: #"Semestre\s+([A-Za-zéû]+)\s+(\d{2}-\d{2})"#)
        let ns = html as NSString
        let matches = pattern?.matches(in: html, options: [],
                                       range: NSRange(location: 0, length: ns.length)) ?? []
        guard !matches.isEmpty else {
            // Page sans en-tête reconnu : on tente quand même les tableaux, avec
            // un libellé vide plutôt que de tout perdre.
            return [Section(label: "", body: html)]
        }
        return matches.enumerated().map { index, match in
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let season = ns.substring(with: match.range(at: 1))
            let span = ns.substring(with: match.range(at: 2))
            return Section(label: "Semestre \(season) \(span)",
                           body: ns.substring(with: NSRange(location: start, length: end - start)))
        }
    }

    private struct Row {
        var date: String
        var title: String
        var isImportant: Bool
    }

    /// Une ligne de tableau : `<td>date</td><td>libellé</td>`.
    private static func rows(in html: String) -> [Row] {
        let rowPattern = try? NSRegularExpression(pattern: #"<tr[^>]*>(.*?)</tr>"#,
                                                 options: [.dotMatchesLineSeparators])
        let cellPattern = try? NSRegularExpression(pattern: #"<td[^>]*>(.*?)</td>"#,
                                                  options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        let rowMatches = rowPattern?.matches(in: html, options: [],
                                             range: NSRange(location: 0, length: ns.length)) ?? []

        return rowMatches.compactMap { match in
            let body = ns.substring(with: match.range(at: 1))
            let bodyNS = body as NSString
            let cells = cellPattern?.matches(in: body, options: [],
                                             range: NSRange(location: 0, length: bodyNS.length)) ?? []
            guard cells.count >= 2 else { return nil }
            let rawDate = bodyNS.substring(with: cells[0].range(at: 1))
            let rawTitle = bodyNS.substring(with: cells[1].range(at: 1))
            return Row(date: plainText(rawDate),
                       title: plainText(rawTitle),
                       isImportant: rawDate.lowercased().contains("<strong>")
                           || rawTitle.lowercased().contains("<strong>"))
        }
    }

    // MARK: Dates

    /// « 16 février 2026 », « Début mars 2026 », « Mi-novembre 2026 », « Fin décembre 2025 ».
    ///
    /// Les trois derniers sont **approximatifs** : l'EPFL ne donne pas de jour. On
    /// choisit le 1er, le 15 ou le dernier jour du mois, et on le signale à
    /// l'écran — une approximation assumée vaut mieux qu'une date fausse présentée
    /// comme exacte, ou qu'une ligne disparue.
    static func parseDate(_ raw: String, calendar: Calendar = .current, now: Date = Date())
        -> (date: Date, approximate: Bool)? {
        var text = fold(raw)
        var approximate = false
        var day: Int?

        let full = NSRange(location: 0, length: (text as NSString).length)
        if let match = prefixPattern.firstMatch(in: text, options: [], range: full) {
            approximate = true
            let prefix = (text as NSString).substring(with: match.range(at: 1))
            text = (text as NSString).substring(with: match.range(at: 2))
            switch prefix {
            case "mi": day = 15
            case "fin": day = nil          // dernier jour du mois
            default: day = 1               // « début »
            }
        }

        let ns = text as NSString
        let dateRange = NSRange(location: 0, length: (text as NSString).length)
        guard let match = datePattern.firstMatch(in: text, options: [], range: dateRange) else { return nil }
        let explicitDay = match.range(at: 1).location == NSNotFound
            ? nil : Int(ns.substring(with: match.range(at: 1)))
        let monthName = ns.substring(with: match.range(at: 2))
        guard let year = Int(ns.substring(with: match.range(at: 3))),
              let month = months[monthName] else { return nil }

        let resolvedDay: Int
        if let explicitDay {
            resolvedDay = explicitDay
        } else if let day {
            resolvedDay = day
        } else {
            resolvedDay = lastDay(ofMonth: month, year: year, calendar: calendar)
        }

        // Une année à deux chiffres n'existe pas ici : l'EPFL écrit « 2026 ».
        guard (2000...2100).contains(year), (1...12).contains(month) else { return nil }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: resolvedDay)) else {
            return nil
        }
        // Une section peut annoncer des dates de l'année précédente : on les garde,
        // elles racontent le semestre en cours.
        _ = now
        return (date, approximate)
    }

    private static func lastDay(ofMonth month: Int, year: Int, calendar: Calendar) -> Int {
        let components = DateComponents(year: year, month: month + 1, day: 0)
        return calendar.date(from: components).map { calendar.component(.day, from: $0) } ?? 28
    }

    private static let prefixPattern = try! NSRegularExpression(
        pattern: #"^(début|debut|mi|fin)[\s\-]+(.+)$"#)
    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(?:(\d{1,2})\s+)?([a-z]+)\s+(\d{4})$"#)

    // MARK: Nature

    static func kind(for label: String) -> MilestoneKind {
        let text = fold(label)
        if text.contains("jour ferie") { return .holiday }
        if text.contains("interruption des enseignements") { return .break }
        if text.contains("reprise des enseignements") { return .break }
        if text.hasPrefix("debut des enseignements") { return .teachingStart }
        if text.hasPrefix("fin des enseignements") { return .teachingEnd }
        if text.hasPrefix("debut des examens") { return .examStart }
        if text.hasPrefix("fin des examens") { return .examEnd }
        if text.contains("delai") { return .deadline }
        if text.contains("ouverture") { return .opening }
        if text.contains("evaluation approfondie") { return .evaluation }
        if text.contains("publication") || text.contains("envoi") || text.contains("bulletins") {
            return .publication
        }
        return .other
    }

    // MARK: Clé stable

    /// Identifiant stable d'une échéance, pour qu'un rafraîchissement **mette à
    /// jour** au lieu de dupliquer.
    static func identifier(date: Date, title: String, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d",
                           parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "epfl.\(stamp).\(slug(title))"
    }

    private static func slug(_ text: String) -> String {
        let folded = fold(text)
        let allowed = folded.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return allowed
            .split(separator: "-", omittingEmptySubsequences: true)
            .prefix(8)
            .joined(separator: "-")
    }

    // MARK: Texte

    /// Sans accents, sans casse, espaces normalisés. Rend la lecture insensible à
    /// la typographie de la page — l'EPFL écrit « é » tantôt en `&eacute;` tantôt
    /// en clair.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "fr_CH"))
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remplace `&#233;` et `&#xE9;` par le caractère correspondant.
    static func decodeNumericEntities(_ text: String) -> String {
        let pattern = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#)
        let ns = text as NSString
        let matches = pattern?.matches(in: text, options: [],
                                       range: NSRange(location: 0, length: ns.length)) ?? []
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            let full = match.range
            result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
            let isHex = ns.substring(with: match.range(at: 1)).lowercased() == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
            } else {
                result += ns.substring(with: full)
            }
            cursor = full.location + full.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Retire les balises, les entités et les espaces multiples.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ",
                                             options: .regularExpression)
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&eacute;": "é", "&egrave;": "è",
            "&agrave;": "à", "&ecirc;": "ê", "&ccedil;": "ç", "&ocirc;": "ô",
            "&ucirc;": "û", "&icirc;": "î", "&laquo;": "«", "&raquo;": "»",
            "&rsquo;": "’", "&euml;": "ë", "&#039;": "'", "&quot;": "\"",
            "&apos;": "'", "&times;": "×", "&hellip;": "…", "&mdash;": "—"
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement,
                                             options: .caseInsensitive)
        }
        // Entités **numériques** : `&#233;` pour « é », `&#xE9;` aussi. La page du
        // calendrier écrit ses accents en clair, mais d'autres pages de l'EPFL les
        // encodent — et un parseur qui ne lit pas « D&#233;but » rate une date.
        text = decodeNumericEntities(text)
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
