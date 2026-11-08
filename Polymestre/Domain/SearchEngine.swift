import Foundation

/// Nature d'un résultat de recherche.
///
/// L'ordre des cas est celui de l'affichage : un cours avant une série, une série
/// avant un exercice. Chercher « algo » doit d'abord proposer le cours, pas le
/// vingtième exercice qui contient le mot.
enum SearchKind: String, CaseIterable, Identifiable, Comparable {
    case course
    case series
    case exercise
    case theory
    case exam
    case session
    case task
    case milestone
    case group

    var id: String { rawValue }

    var label: String {
        switch self {
        case .course: return String(localized: "Cours")
        case .series: return String(localized: "Séries")
        case .exercise: return String(localized: "Exercices")
        case .theory: return String(localized: "Théorie")
        case .exam: return String(localized: "Évaluations")
        case .session: return "Sessions de travail"
        case .task: return String(localized: "Tâches")
        case .milestone: return String(localized: "Vie de l'EPFL")
        case .group: return String(localized: "Groupes")
        }
    }

    var icon: String {
        switch self {
        case .course: return "books.vertical.fill"
        case .series: return "list.number"
        case .exercise: return "checklist"
        case .theory: return "play.rectangle.fill"
        case .exam: return "graduationcap.fill"
        case .session: return "timer"
        case .task: return "checkmark.circle"
        case .milestone: return "building.columns.fill"
        case .group: return "person.3.fill"
        }
    }

    /// Rang d'affichage : plus petit = plus haut.
    var rank: Int { SearchKind.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: SearchKind, rhs: SearchKind) -> Bool { lhs.rank < rhs.rank }
}

/// Ce sur quoi porte la correspondance — affiché pour expliquer le résultat.
enum SearchMatch: String {
    case title
    case detail
    case course

    var label: String {
        switch self {
        case .title: return String(localized: "intitulé")
        case .detail: return String(localized: "détail")
        case .course: return String(localized: "cours")
        }
    }
}

/// Un document indexable, indépendant de la persistance.
///
/// C'est ce qui rend la recherche testable sur des chaînes, sans base ni
/// interface — et c'est aussi ce qui permet de l'exécuter sur le fil principal
/// sans surprise : rien ici ne touche SwiftData.
struct SearchDocument: Equatable, Identifiable {
    var id: String
    var kind: SearchKind
    /// Ce qui s'affiche en gras dans la liste.
    var title: String
    /// La ligne secondaire : date, nature, contexte.
    var subtitle: String
    /// Tout le texte cherchable en plus du titre, déjà normalisé par le moteur.
    var detail: String
    /// Code du cours, pour rattacher le résultat et permettre d'y aller.
    var courseCode: String?
    /// Date, pour trier à égalité de score.
    var date: Date?

    init(id: String,
         kind: SearchKind,
         title: String,
         subtitle: String = "",
         detail: String = "",
         courseCode: String? = nil,
         date: Date? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.courseCode = courseCode
        self.date = date
    }
}

/// Un résultat, avec de quoi expliquer pourquoi il sort.
struct SearchHit: Identifiable, Equatable {
    var document: SearchDocument
    var score: Int
    var match: SearchMatch

    var id: String { document.id }
    var kind: SearchKind { document.kind }
}

/// Recherche dans tout ce que l'app contient.
///
/// Fonction **pure** : elle reçoit des documents et une requête. Aucun accès à
/// SwiftData, donc elle se teste sur des cas choisis — et notamment sur ce qui ne
/// doit **pas** ressortir.
enum SearchEngine {

    /// Nombre maximal de résultats rendus. Au-delà, la liste cesse d'aider.
    static let limit = 60

    /// Normalise pour comparer : sans accents, sans casse, ponctuation réduite.
    ///
    /// « Algèbre linéaire » et « algebre lineaire » doivent se trouver l'un
    /// l'autre : personne ne tape les accents dans une barre de recherche.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "fr_CH"))
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func tokens(_ query: String) -> [String] {
        normalize(query).split(separator: " ").map(String.init)
    }

    /// Cherche, tous types confondus.
    ///
    /// Tous les mots de la requête doivent correspondre : « algo exo 3 » ne doit pas
    /// ramener tout ce qui contient « algo ». C'est ce que fait une recherche
    /// paresseuse, et c'est ce qui la rend inutile.
    static func search(_ query: String, in documents: [SearchDocument]) -> [SearchHit] {
        let words = tokens(query)
        guard !words.isEmpty else { return [] }

        var hits: [SearchHit] = []
        for document in documents {
            guard let scored = score(document, words: words, query: normalize(query)) else { continue }
            hits.append(scored)
        }

        return Array(hits.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            // À score égal, le plus récent d'abord ; sinon l'ordre alphabétique,
            // pour que la liste ne bouge pas d'une frappe à l'autre.
            switch (lhs.document.date, rhs.document.date) {
            case let (l?, r?) where l != r: return l > r
            default: break
            }
            return lhs.document.title.localizedStandardCompare(rhs.document.title) == .orderedAscending
        }.prefix(limit))
    }

    /// Note un document, ou `nil` s'il ne correspond pas à **tous** les mots.
    static func score(_ document: SearchDocument, words: [String], query: String) -> SearchHit? {
        let title = normalize(document.title)
        let detail = normalize(document.detail)
        let subtitle = normalize(document.subtitle)
        let course = normalize(document.courseCode ?? "")
        // Formes **collées**. Personne ne tape « CS-250 » dans une barre de
        // recherche : on tape « cs250 ». Sans ça, le code de cours ne se trouvait
        // que ponctué — c'est-à-dire jamais.
        let titleCompact = title.replacingOccurrences(of: " ", with: "")
        let courseCompact = course.replacingOccurrences(of: " ", with: "")

        var total = 0
        var best: SearchMatch = .detail
        var bestScore = 0

        for word in words {
            var wordScore = 0
            var where_: SearchMatch = .detail

            // L'intitulé pèse le plus : c'est ce qu'on cherche.
            if title == query || titleCompact == query {
                wordScore = 120; where_ = .title
            } else if title.hasPrefix(word) || titleCompact.hasPrefix(word) {
                wordScore = 90; where_ = .title
            } else if title.split(separator: " ").contains(where: { $0.hasPrefix(word) }) {
                wordScore = 70; where_ = .title
            } else if title.contains(word) || titleCompact.contains(word) {
                wordScore = 45; where_ = .title
            } else if course.contains(word) || courseCompact.contains(word) {
                // Le code du cours est presque un intitulé : « cs250 » doit trouver
                // les exercices de CS-250.
                wordScore = 40; where_ = .course
            } else if subtitle.contains(word) {
                wordScore = 25; where_ = .detail
            } else if detail.contains(word) {
                wordScore = 15; where_ = .detail
            } else {
                return nil
            }

            total += wordScore
            if wordScore > bestScore {
                bestScore = wordScore
                best = where_
            }
        }

        // Un titre qui commence par la requête entière passe devant.
        if title.hasPrefix(query) { total += 25 }
        // Un intitulé court qui contient la requête vaut mieux qu'un long.
        if title.contains(query), document.title.count <= query.count + 12 { total += 10 }

        return SearchHit(document: document, score: total, match: best)
    }

    /// Groupe les résultats par nature, dans l'ordre d'affichage.
    static func grouped(_ hits: [SearchHit]) -> [(kind: SearchKind, hits: [SearchHit])] {
        var buckets: [SearchKind: [SearchHit]] = [:]
        for hit in hits { buckets[hit.kind, default: []].append(hit) }
        return SearchKind.allCases.compactMap { kind in
            guard let items = buckets[kind], !items.isEmpty else { return nil }
            return (kind, items)
        }
    }

    /// Une phrase qui dit ce qui a été trouvé, ou pourquoi rien ne l'a été.
    static func summary(_ hits: [SearchHit], query: String) -> String {
        guard !tokens(query).isEmpty else {
            return String(localized: "Tape un code de cours, un titre d'exercice, un mot d'un résumé…")
        }
        guard !hits.isEmpty else {
            return String(localized: "Rien trouvé pour « \(query.trimmingCharacters(in: .whitespaces)) ».")
        }
        let groups = grouped(hits)
        let parts = groups.map { "\($0.hits.count) \($0.kind.label.lowercased())" }
        return "\(Plural.count(hits.count, "\(hits.count) résultat", "\(hits.count) résultats")) · " + parts.joined(separator: " · ")
    }
}
