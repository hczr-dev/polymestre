import Foundation

// MARK: - La fiche de révision

/// La fiche de révision d'un cours : tout ce qu'il faut savoir, chapitre par
/// chapitre — définitions, théorèmes, formules, méthodes, pièges.
///
/// Deux origines, une seule forme :
///   • **le polycopié** (Botafogo) : les énoncés encadrés du site, tels quels,
///     sans les preuves — rien n'est réécrit ;
///   • **le modèle** : pour un cours sans polycopié structuré, Claude lit tout
///     ce que le cours montre (diapositives, notes, séries et corrigés) et en
///     tire la fiche.
///
/// La même liste sert à « À savoir » dans une série : les entrées les plus
/// proches de l'exercice ouvert (`relevant`).
struct RevisionSheet: Codable, Equatable {
    enum Origin: String, Codable { case handout, ai }

    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable, CaseIterable {
            case definition, theorem, proposition, lemma, corollary, formula, method, pitfall, example, remark

            var label: String {
                switch self {
                case .definition: return String(localized: "Définition")
                case .theorem: return String(localized: "Théorème")
                case .proposition: return "Proposition"
                case .lemma: return String(localized: "Lemme")
                case .corollary: return String(localized: "Corollaire")
                case .formula: return "Formule"
                case .method: return String(localized: "Méthode")
                case .pitfall: return String(localized: "Piège")
                case .example: return String(localized: "Exemple")
                case .remark: return "Remarque"
                }
            }

            var icon: String {
                switch self {
                case .definition: return "character.book.closed"
                case .theorem, .proposition, .lemma, .corollary: return "seal"
                case .formula: return "function"
                case .method: return "list.bullet.clipboard"
                case .pitfall: return "exclamationmark.triangle"
                case .example: return "lightbulb"
                case .remark: return "text.bubble"
                }
            }

            /// Ce qu'un modèle écrit, ramené à un genre connu.
            static func parse(_ raw: String) -> Kind {
                let value = raw.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                if let exact = Kind(rawValue: value) { return exact }
                if value.hasPrefix("def") { return .definition }
                if value.hasPrefix("theo") || value.hasPrefix("thm") { return .theorem }
                if value.hasPrefix("prop") { return .proposition }
                if value.hasPrefix("lem") { return .lemma }
                if value.hasPrefix("cor") { return .corollary }
                if value.hasPrefix("form") { return .formula }
                if value.hasPrefix("meth") || value.contains("method") || value.contains("techni") { return .method }
                if value.hasPrefix("pi") || value.contains("erreur") || value.contains("pitfall") || value.contains("mistake") { return .pitfall }
                if value.hasPrefix("ex") { return .example }
                return .remark
            }
        }

        var id: String
        var kind: Kind
        /// « Théorème 3.4 (des gendarmes) ».
        var title: String
        /// L'énoncé : Markdown léger, formules entre `$…$` et `$$…$$`.
        var body: String
        /// D'où il vient : « § 3.5 Les suites monotones », « Série 4 », « Cours 6 ».
        var source: String = ""
        /// Où le relire : le chemin d'une section du polycopié, ou une adresse.
        var link: String = ""
    }

    struct Chapter: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var entries: [Entry]
    }

    var origin: Origin
    var generatedAt: Date
    var chapters: [Chapter]

    var entries: [Entry] { chapters.flatMap(\.entries) }
    var isEmpty: Bool { chapters.allSatisfy { $0.entries.isEmpty } }

    // MARK: Garder

    static func decode(_ raw: String) -> RevisionSheet? {
        guard !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(RevisionSheet.self, from: Data(raw.utf8))
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: Relier à la semaine

    /// Les chapitres dont une entrée renvoie à cette section du polycopié (ou à l'une de ses
    /// sous-sections, ou à la section qui la contient) : « Fiche · chapitre » depuis la semaine.
    func chapters(forPath path: String) -> [Chapter] {
        let wanted = Self.normalizedPath(path)
        guard !wanted.isEmpty else { return [] }
        return chapters.filter { chapter in
            chapter.entries.contains { entry in
                let other = Self.normalizedPath(entry.link)
                return !other.isEmpty && (other == wanted || other.hasPrefix(wanted + "/") || wanted.hasPrefix(other + "/"))
            }
        }
    }

    /// Le chemin d'une section, qu'on l'ait écrit en chemin du site ou en lien de l'app.
    static func normalizedPath(_ link: String) -> String {
        guard !link.isEmpty else { return "" }
        if let url = URL(string: link), let path = BotafogoPage.handoutPath(link: url) { return path.lowercased() }
        return StudyLinkKey.handoutPath(link) ?? link.lowercased()
    }

    // MARK: Chercher

    /// La fiche réduite à ce qui contient tous les mots de la recherche (titre,
    /// énoncé, source), sans accents ni casse — l'index des théorèmes.
    func filtered(_ query: String) -> [Chapter] {
        let words = RevisionText.words(query, minimum: 1)
        guard !words.isEmpty else { return chapters }
        return chapters.compactMap { chapter in
            let kept = chapter.entries.filter { entry in
                let haystack = RevisionText.fold(entry.title + " " + entry.body + " " + entry.source + " " + chapter.title)
                return words.allSatisfy { haystack.contains($0) }
            }
            return kept.isEmpty ? nil : Chapter(id: chapter.id, title: chapter.title, entries: kept)
        }
    }

    // MARK: À savoir pour un exercice

    /// Les entrées les plus utiles pour un exercice : les mots qu'elles
    /// partagent avec son énoncé (pondérés par leur rareté dans la fiche), les
    /// numéros cités (« théorème 3.4 »), et les sections que l'exercice ou sa
    /// semaine renvoient (`preferred`). Définitions et théorèmes passent avant
    /// les exemples. Rien au-dessous d'un seuil : mieux vaut rien qu'un hasard.
    func relevant(to text: String, preferred: Set<String> = [], limit: Int = 6) -> [Entry] {
        let all = entries
        guard !all.isEmpty else { return [] }
        let exerciseWords = Set(RevisionText.words(text))
        let folded = RevisionText.fold(text)
        // La rareté d'un mot dans la fiche : « suite » est partout, « Cauchy » non.
        var frequency: [String: Int] = [:]
        let entryWords = all.map { Set(RevisionText.words($0.title + " " + $0.body)) }
        for words in entryWords { for word in words { frequency[word, default: 0] += 1 } }
        let count = Double(all.count)

        var scored: [(Entry, Double)] = []
        for (index, entry) in all.enumerated() {
            var score = 0.0
            for word in entryWords[index] where exerciseWords.contains(word) {
                score += log(1 + count / Double(frequency[word] ?? 1))
            }
            // « Théorème 3.4 » cité par l'exercice.
            if let number = RevisionText.number(in: entry.title), folded.contains(number) {
                score += 6
            }
            if !entry.link.isEmpty, preferred.contains(entry.link.lowercased()) { score += 2.5 }
            switch entry.kind {
            case .definition, .theorem, .proposition, .corollary, .lemma, .formula, .method: score *= 1.15
            case .example, .remark: score *= 0.7
            case .pitfall: break
            }
            scored.append((entry, score))
        }
        let threshold = 3.0
        return scored.filter { $0.1 >= threshold }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

// MARK: - Le texte, pour comparer

enum RevisionText {
    /// Sans accents ni casse.
    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
    }

    /// Les mots qui portent du sens : sans LaTeX, sans mots-outils.
    static func words(_ text: String, minimum: Int = 4) -> [String] {
        let cleaned = fold(text)
            .replacingOccurrences(of: #"\\[a-zA-Z]+"#, with: " ", options: .regularExpression)
        return cleaned.split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= minimum && !stopwords.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// « Théorème 3.4 » → « 3.4 » ; « Définition 2.1.3 » → « 2.1.3 ».
    static func number(in title: String) -> String? {
        guard let range = title.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(title[range])
    }

    static let stopwords: Set<String> = [
        "dans", "pour", "avec", "sans", "sont", "est", "une", "des", "les", "que", "qui", "par", "sur", "tout", "tous",
        "toute", "toutes", "cette", "ces", "son", "ses", "leur", "leurs", "elle", "elles", "nous", "vous", "alors",
        "donc", "ainsi", "comme", "mais", "plus", "moins", "tres", "bien", "etre", "avoir", "fait", "faire", "peut",
        "peuvent", "doit", "soit", "soient", "entre", "chaque", "aussi", "meme", "autre", "autres", "dont", "deux",
        "trois", "montrer", "calculer", "determiner", "trouver", "donner", "verifier", "justifier", "suivant",
        "suivante", "suivants", "suivantes", "ci-dessous", "dessous", "exercice", "question", "partie", "cas",
        "that", "this", "with", "from", "have", "which", "where", "when", "then", "there", "their", "show", "find",
        "compute", "prove", "following", "each", "such", "into", "only", "also", "some", "every",
    ]
}

// MARK: - Depuis le polycopié

enum RevisionSheetBuilder {

    /// Les genres repris d'un polycopié : ce qu'on doit savoir énoncer. Les
    /// exemples et remarques restent dans le cours.
    static let handoutKinds: Set<BotafogoTheoremKind> = [.definition, .theorem, .proposition, .lemma, .corollary]

    /// Les énoncés d'une section du polycopié, **sans leurs preuves**.
    static func entries(fromHandout blocks: [BotafogoBlock], section: String, path: String) -> [RevisionSheet.Entry] {
        var result: [RevisionSheet.Entry] = []
        func walk(_ blocks: [BotafogoBlock]) {
            for block in blocks {
                switch block {
                case .theorem(let kind, let title, let content):
                    guard handoutKinds.contains(kind) else { continue }
                    let body = BotafogoPage.text(statement(content)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { continue }
                    let entryKind = kind.sheetKind
                    let shown = title.isEmpty ? entryKind.label : title
                    result.append(.init(id: path + "#" + String(result.count), kind: entryKind,
                                        title: shown, body: body, source: section, link: path))
                case .aside(_, let content), .exercise(_, let content):
                    // Un énoncé posé dans un encadré reste un énoncé ; un exercice, non.
                    if case .aside = block { walk(content) }
                case .list(let items, _, _):
                    items.forEach(walk)
                default:
                    continue
                }
            }
        }
        walk(blocks)
        return result
    }

    /// Le contenu d'un énoncé sans ce qui se déplie (preuves, solutions,
    /// remarques repliées) : sur une fiche, on veut l'énoncé seul.
    static func statement(_ blocks: [BotafogoBlock]) -> [BotafogoBlock] {
        blocks.compactMap { block in
            switch block {
            case .folded, .quiz, .video, .kaltura, .animation, .figure: return nil
            case .list(let items, let ordered, let columns): return .list(items.map(statement), ordered: ordered, columns: columns)
            default: return block
            }
        }
    }

    /// La fiche d'un polycopié : un chapitre par chapitre du sommaire, ses
    /// énoncés dans l'ordre des sections. `pages` : les blocs de chaque section,
    /// par chemin (celles qui manquent sont sautées).
    static func sheet(chapters: [BotafogoSite.Chapter], pages: [String: [BotafogoBlock]], now: Date = Date()) -> RevisionSheet {
        let result: [RevisionSheet.Chapter] = chapters.compactMap { chapter in
            let entries = chapter.sections.flatMap { section in
                pages[section.path].map { entries(fromHandout: $0, section: MathMarkup.plain(section.title), path: section.path) } ?? []
            }
            return entries.isEmpty ? nil : .init(id: chapter.title, title: MathMarkup.plain(chapter.title), entries: entries)
        }
        return RevisionSheet(origin: .handout, generatedAt: now, chapters: result)
    }
}

extension BotafogoTheoremKind {
    var sheetKind: RevisionSheet.Entry.Kind {
        switch self {
        case .theorem: return .theorem
        case .definition: return .definition
        case .proposition: return .proposition
        case .lemma: return .lemma
        case .corollary: return .corollary
        case .example: return .example
        case .remark, .other: return .remark
        }
    }
}

// MARK: - Par le modèle

/// La fiche d'un cours sans polycopié structuré, écrite par Claude à partir de
/// tout ce que le cours montre. La consigne et la lecture de la réponse sont
/// ici (pures, testées) ; le lancement, sur le Mac.
enum RevisionSheetAI {

    static let instructions = """
    Tu écris la FICHE DE RÉVISION complète d'un cours EPFL, à partir de tout son matériel (diapositives, notes, séries d'exercices et corrigés).
    But : qu'un·e étudiant·e puisse réviser l'examen avec cette seule fiche. Sois exhaustif·ve sur ce qui est enseigné, et bref·ve dans chaque entrée.
    Réponds UNIQUEMENT avec un objet JSON :
    {"chapters":[{"title":"Applications linéaires","entries":[{"kind":"definition","title":"Noyau","body":"$\\\\ker T = \\\\{v \\\\in V : T(v) = 0\\\\}$, sous-espace de $V$.","source":"Cours 5"}]}]}
    • « kind » : definition, theorem, proposition, formula, method, pitfall ou example.
      – definition, theorem, proposition, formula : l'énoncé exact, avec ses hypothèses.
      – method : comment résoudre un type d'exercice des séries, en étapes courtes (« Pour montrer qu'une famille est libre : … »).
      – pitfall : une erreur classique ou une hypothèse qu'on oublie.
      – example : seulement un exemple-type qui revient à l'examen.
    • « title » : court, avec le numéro du cours s'il en a un (« Théorème 4.2 (rang) »).
    • « body » : Markdown léger ; formules en LaTeX entre $…$ (ou $$…$$ seules sur leur ligne). Pas de preuve.
    • « source » : d'où ça vient (« Cours 5 », « Série 3 », « Diapos semaine 2 »).
    • Chapitres dans l'ordre du cours, 5 à 40 entrées chacun. Chaque série doit avoir au moins une « method ».
    • Écris dans la langue du matériel. N'invente rien qui ne soit pas dans le matériel.
    """

    /// Pour un cours dont le polycopié donne déjà les énoncés : seulement ce
    /// qu'il ne dit pas — les méthodes des séries et les pièges.
    static let methodsInstructions = """
    Les énoncés de ce cours EPFL (définitions, théorèmes) sont déjà sur la fiche de révision. Tu ajoutes ce qui manque : les MÉTHODES et les PIÈGES, tirés des séries d'exercices et de leurs corrigés.
    Réponds UNIQUEMENT avec un objet JSON :
    {"chapters":[{"title":"Séries numériques","entries":[{"kind":"method","title":"Étudier la convergence d'une série","body":"1. Terme général → 0 ? …","source":"Séries 6 et 7"}]}]}
    • « kind » : method (comment résoudre un type d'exercice, en étapes courtes) ou pitfall (erreur classique, hypothèse oubliée).
    • Un chapitre par grand thème des séries, dans l'ordre du cours ; 3 à 15 entrées chacun.
    • Formules en LaTeX entre $…$. Écris dans la langue du matériel. N'invente rien qui ne soit pas dans le matériel.
    """

    /// Le message envoyé : le cours, puis chaque document, coupé pour tenir.
    static func prompt(course: String, documents: [(title: String, text: String)], budget: Int = 360_000) -> String {
        var parts = ["COURS : \(course)", ""]
        let cleaned = documents.map { ($0.title, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.1.isEmpty }
        let total = cleaned.reduce(0) { $0 + $1.1.count }
        // Au-delà du budget, chaque document est réduit en proportion, sans
        // descendre sous 1500 caractères : un long polycopié n'efface pas les séries.
        let ratio = total > budget ? Double(budget) / Double(total) : 1
        for (title, text) in cleaned {
            let keep = ratio < 1 ? max(1500, Int(Double(text.count) * ratio)) : text.count
            parts.append("=== \(title) ===")
            parts.append(String(text.prefix(keep)))
            parts.append("")
        }
        return parts.joined(separator: "\n")
    }

    /// La réponse du modèle (avec ou sans bloc de code, avec du texte autour).
    static func sheet(fromAnswer answer: String, now: Date = Date()) -> RevisionSheet? {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end else { return nil }
        let json = String(answer[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let chapters = object["chapters"] as? [[String: Any]] else { return nil }
        var result: [RevisionSheet.Chapter] = []
        for (c, chapter) in chapters.enumerated() {
            let title = (chapter["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = chapter["entries"] as? [[String: Any]] ?? []
            let entries: [RevisionSheet.Entry] = raw.enumerated().compactMap { e, entry in
                let body = (entry["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (entry["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty || !name.isEmpty else { return nil }
                let kind = RevisionSheet.Entry.Kind.parse(entry["kind"] as? String ?? "")
                return .init(id: "ai-\(c)-\(e)", kind: kind, title: name.isEmpty ? kind.label : name, body: body,
                             source: (entry["source"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !entries.isEmpty { result.append(.init(id: "ai-\(c)", title: title.isEmpty ? String(localized: "Chapitre \(c + 1)") : title, entries: entries)) }
        }
        return result.isEmpty ? nil : RevisionSheet(origin: .ai, generatedAt: now, chapters: result)
    }
}
