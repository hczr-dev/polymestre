import Foundation

/// Une sous-question repérée sous un exercice : « 1. », « 2. », « (a) ».
///
/// Deux niveaux : « 1) » porte ses points « (a) (b) » dans `children`.
struct DetectedSubQuestion: Equatable, Identifiable {
    /// L'étiquette telle qu'elle apparaît : « 1 », « a », « ii ». Vide pour une
    /// partie sans numéro (« Ensuite, … »).
    var label: String
    /// L'énoncé court, s'il a pu être lu. Souvent vide : une sous-question est
    /// fréquemment une seule formule.
    var text: String
    var kind: SubQuestionKind = .question
    var children: [DetectedSubQuestion] = []

    /// Identité d'édition, propre à l'écran de relecture : deux parties sans
    /// étiquette doivent rester deux lignes distinctes. Hors de l'égalité.
    var id = UUID()

    init(label: String, text: String = "", kind: SubQuestionKind = .question,
         children: [DetectedSubQuestion] = []) {
        self.label = label
        self.text = text
        self.kind = kind
        self.children = children
    }

    static func == (lhs: DetectedSubQuestion, rhs: DetectedSubQuestion) -> Bool {
        lhs.label == rhs.label && lhs.text == rhs.text && lhs.kind == rhs.kind && lhs.children == rhs.children
    }

    /// Les cases réelles : une question à points compte par ses points.
    var leafCount: Int { children.isEmpty ? 1 : children.count }

    /// Arbre lisible pour les tests et le diagnostic : « 1(a,b),2,part ».
    static func outline(_ questions: [DetectedSubQuestion]) -> String {
        questions.map { question in
            let head = question.kind == .part ? "part" : question.label
            return question.children.isEmpty ? head : "\(head)(\(question.children.map(\.label).joined(separator: ",")))"
        }.joined(separator: ",")
    }
}

/// Un exercice repéré dans le texte d'un PDF de série.
struct DetectedExercise: Equatable, Identifiable {
    /// Numéro tel qu'il sera créé : « 2.1 ».
    var number: String
    /// Ce qui suit le numéro sur la même ligne, s'il y a quelque chose.
    var title: String
    var isBonus: Bool
    /// Ce que l'exercice demande, en une phrase — lu par le modèle.
    var statement: String = ""
    /// Les questions regroupées sous ce numéro, dans l'ordre du polycopié.
    ///
    /// Un polycopié qui écrit « Calculer : 1. … 2. … » ne propose pas deux
    /// exercices : il en propose un, en deux questions. Les séparer gonfle la
    /// liste et coupe le travail en morceaux qui se rendent ensemble.
    var subQuestions: [DetectedSubQuestion] = []
    /// Le repère était-il sans ambiguïté (« Exercice 3 », « Ex-02-01 ») ?
    ///
    /// Un numéro nu (« 1.2 ») peut être une section de cours ou une ligne de
    /// démonstration : quand l'IA ne le confirme pas, la fusion l'écarte.
    var isConfident: Bool = true
    /// Où l'exercice commence dans le PDF, pour l'aperçu de la relecture.
    /// Page (0…) et position verticale (0 = haut, 1 = bas).
    var pageIndex: Int?
    var verticalPosition: Double?

    var id: String { number }

    var hasSubQuestions: Bool { !subQuestions.isEmpty }
    var leafQuestionCount: Int { subQuestions.reduce(0) { $0 + $1.leafCount } }
}

/// Une série repérée, avec ses exercices.
struct DetectedSeries: Equatable, Identifiable {
    var number: Int
    /// Intitulé trouvé après « Série 3 », s'il y en a un.
    var title: String
    var exercises: [DetectedExercise]
    /// « b » pour « Série 5b » : deux séries de même numéro (`SeriesIdentity`).
    var label: String = ""

    init(number: Int, title: String, exercises: [DetectedExercise], label: String = "") {
        self.number = number
        self.title = title
        self.exercises = exercises
        self.label = SeriesIdentity.normalized(label)
    }

    var key: SeriesIdentity.Key { SeriesIdentity.Key(number, label) }
    var id: String { "\(number)|\(label)" }

    /// Toute une série « bonus », ce n'est pas une série : c'est une note de
    /// page (« les exercices étoilés sont facultatifs ») lue sous chaque titre,
    /// ou un modèle qui a généralisé. Les 20 exercices de la série 6 d'algèbre
    /// linéaire arrivaient tous en bonus — rien n'était plus à faire.
    static func withoutBlanketBonus(_ series: [DetectedSeries]) -> [DetectedSeries] {
        series.map { item in
            guard item.exercises.count >= 3, item.exercises.allSatisfy(\.isBonus) else { return item }
            var copy = item
            for index in copy.exercises.indices { copy.exercises[index].isBonus = false }
            return copy
        }
    }
}

/// Repère les séries et les exercices dans le texte d'un PDF EPFL.
///
/// Fonction **pure** : elle ne lit aucun fichier et ne touche à aucun modèle, donc
/// elle se teste sur de vrais extraits de texte sans PDF ni simulateur.
///
/// Trois formats réels sont reconnus, relevés sur des polycopiés de l'EPFL :
///   • `Ex-02-01:` — Analyse 1 inversée, série et exercice dans le numéro ;
///   • `Exercice 3 Type : … Défi : ⋆⋆` — Algèbre linéaire inversée, où le
///     numéro est qualifié par sa série (« Exercice 1 » en Série 2 → « 2.1 ») ;
///   • `1.2` ou `Exercice 1.2` — le format historique du projet.
///
/// La détection ne sera jamais parfaite — un PDF scanné ne contient aucun texte, et
/// l'extraction aplatit la mise en page, collant parfois deux exercices sur une
/// ligne. C'est pourquoi l'import passe **toujours** par un écran de relecture :
/// le parseur propose, l'étudiant·e dispose.
enum SeriesPDFParser {

    // MARK: Motifs

    /// `Ex-02-01:` — le numéro porte la série **et** l'exercice.
    ///
    /// Le titre s'arrête avant l'exercice suivant : l'extraction aplatit la mise en
    /// page et colle parfois deux exercices sur une ligne
    /// (« Ex-02-08: Ex-02-09: Montrer que… »). Sans la borne, le premier match
    /// consommait toute la ligne et le second n'était jamais vu.
    private static let dashed = try! NSRegularExpression(
        pattern: #"(?m)\bEx[ .\-]?(\d{1,2})[.\-](\d{1,2})\b[ \t]*[:.\-–—]?[ \t]*([^\n]*?)(?=\s*Ex[ .\-]?\d{1,2}[.\-]\d{1,2}\b|$)"#,
        options: []
    )

    /// « Exercice 1.2 », ou simplement « 1.2 », avec un intitulé facultatif.
    private static let numbered = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:(?:exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe|question)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?)?(\d{1,2})[.\-·](\d{1,2})\b[ \t]*[–—:.\-)]?[ \t]*(.*)$"#,
        options: [.caseInsensitive]
    )

    /// « Exercice 3 » — seul, ou suivi d'un intitulé sur la même ligne.
    ///
    /// `(?!\.\d)` est essentiel : sans lui, « Exercice 3.1 » serait aussi lu comme
    /// l'exercice « 3 », et un exercice fantôme apparaîtrait dans la série.
    private static let bare = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe|question)[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [.caseInsensitive]
    )

    /// « Série 3 », « Série n° 3 », « Série 02 (Nombres R) ».
    private static let header = try! NSRegularExpression(
        pattern: #"(?im)^[ \t]*s[ée]rie[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b[ \t]*[–—:.\-]?[ \t]*(.*)$"#,
        options: []
    )

    private static let bonus = try! NSRegularExpression(
        pattern: #"(?i)\bbonus\b|\bétoile\b|\bfacultatif\b|\boptionnel\b|\boptional\b|\bfreiwillig\b"#,
        options: []
    )

    /// Métadonnées de mise en page EPFL qui se retrouvent collées au titre.
    private static let metadata = try! NSRegularExpression(
        pattern: #"(?i)\s*(?:Type|Défi|Objectifs?|Rubrique)\s*:"#,
        options: []
    )

    /// Un exercice suivant, sur la même ligne (l'extraction aplatit la mise en page).
    /// `\s*` et non `\s+` : le séparateur a déjà été consommé par le motif appelant.
    private static let nextExercise = try! NSRegularExpression(
        pattern: #"\s*Ex[ .\-]?\d{1,2}[.\-]\d{1,2}\b"#,
        options: []
    )

    // MARK: Analyse

    static func parse(_ text: String, defaultSeries: Int? = nil) -> [DetectedSeries] {
        let fallback = defaultSeries ?? 1
        let normalized = normalize(text)
        let ns = normalized as NSString
        let full = NSRange(location: 0, length: ns.length)

        var headers: [(location: Int, number: Int)] = []
        var titles: [Int: String] = [:]
        for match in header.matches(in: normalized, options: [], range: full) {
            guard let number = intValue(ns, match.range(at: 1)) else { continue }
            headers.append((match.range.location, number))
            if titles[number] == nil {
                titles[number] = cleanTitle(ns.substring(with: match.range(at: 2)))
            }
        }

        // L'ordre du document compte : c'est lui qui donne l'ordre des exercices.
        // `series` vaut `nil` quand le numéro ne dit pas la série (voir plus bas).
        var entries: [(location: Int, exercise: DetectedExercise, series: Int?)] = []
        var seen = Set<String>()

        /// Ajoute un exercice si son numéro n'a pas déjà été vu.
        func append(number: String, title: String, context: String, series: Int?, at location: Int,
                    confident: Bool = true) {
            guard seen.insert(number).inserted else { return }
            entries.append((location,
                            DetectedExercise(number: number,
                                             title: exerciseTitle(title),
                                             isBonus: isBonus(context),
                                             isConfident: confident),
                            series))
        }

        // 1. « Ex-02-01: » — série et exercice dans le numéro.
        for match in dashed.matches(in: normalized, options: [], range: full) {
            guard let major = intValue(ns, match.range(at: 1)),
                  let minor = intValue(ns, match.range(at: 2)) else { continue }
            let number = "\(major).\(minor)"
            append(number: number,
                   title: ns.substring(with: match.range(at: 3)),
                   context: lineContext(ns, around: match.range),
                   series: major,
                   at: match.range.location)
        }

        // 2. « 1.2 » ou « Exercice 1.2 ».
        for match in numbered.matches(in: normalized, options: [], range: full) {
            let major = ns.substring(with: match.range(at: 1))
            let minor = ns.substring(with: match.range(at: 2))
            let number = "\(major).\(minor)"
            // Sans mot-clé, « 1.2 » peut aussi être une section ou une valeur :
            // le repère est gardé, mais marqué comme incertain.
            let line = ns.substring(with: ns.lineRange(for: match.range)).lowercased()
            let hasKeyword = line.range(of: #"^\s*(exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe|question)"#,
                                        options: .regularExpression) != nil
            append(number: number,
                   title: ns.substring(with: match.range(at: 3)),
                   context: lineContext(ns, around: match.range),
                   series: majorComponent(of: number),
                   at: match.range.location,
                   confident: hasKeyword)
        }

        // 3. « Exercice 3 » — un numéro simple est un numéro d'**exercice**, pas de
        //    série : « Exercice 1 » et « Exercice 2 » appartiennent à la même série.
        //    C'est l'en-tête précédent qui la donne, à défaut la série 1.
        //
        //    Le numéro est **qualifié par sa série** : « Exercice 1 » dans la
        //    Série 2 devient « 2.1 ». Sans ça l'exercice s'appelait « 1 », ce qui
        //    ne correspond ni à la convention EPFL, ni au numéro utilisé par
        //    l'analyse par mise en page, ni à celui que partagent les groupes —
        //    et réimporter le même document par les deux chemins créait des
        //    doublons.
        for match in bare.matches(in: normalized, options: [], range: full) {
            let value = ns.substring(with: match.range(at: 1))
            let resolved = headers.last(where: { $0.location < match.range.location })?.number ?? fallback
            append(number: "\(resolved).\(value)",
                   title: ns.substring(with: match.range(at: 2)),
                   context: lineContext(ns, around: match.range),
                   series: resolved,
                   at: match.range.location)
        }

        var groups: [Int: [DetectedExercise]] = [:]
        for entry in entries.sorted(by: { $0.location < $1.location }) {
            let series = entry.series
                ?? headers.last(where: { $0.location < entry.location })?.number
                ?? fallback
            groups[series, default: []].append(entry.exercise)
        }

        var result = groups.keys.sorted().map { series in
            DetectedSeries(number: series,
                           title: titles[series] ?? "",
                           exercises: sorted(groups[series] ?? []))
        }

        // Une série **annoncée** mais dont aucun exercice n'a été reconnu est
        // conservée, avec une liste vide. C'est ce qui rend le parseur robuste à une
        // mise en page inconnue : au lieu d'un import qui ne trouve rien et laisse
        // l'étudiant·e sans recours, la série apparaît dans l'écran de relecture et
        // les exercices s'ajoutent à la main.
        for (number, title) in titles where groups[number] == nil {
            result.append(DetectedSeries(number: number, title: title, exercises: []))
        }
        return result.sorted { $0.number < $1.number }
    }

    // MARK: Outils

    /// Numéro de série d'un numéro d'exercice : « 2.3 » → 2.
    static func majorComponent(of number: String) -> Int? {
        guard let first = number.split(separator: ".").first else { return nil }
        return Int(first)
    }

    private static func sorted(_ exercises: [DetectedExercise]) -> [DetectedExercise] {
        exercises.sorted { lhs, rhs in
            lhs.number.localizedStandardCompare(rhs.number) == .orderedAscending
        }
    }

    /// L'intitulé d'un exercice, ou rien.
    ///
    /// L'extraction d'un PDF aplatit la mise en page : « Exercice 1 solution
    /// générale. » n'est presque jamais « l'exercice 1, intitulé *solution
    /// générale* » — c'est le numéro suivi de la **première phrase de l'énoncé**.
    /// Afficher ça sous l'exercice invente une information, et c'est exactement ce
    /// que l'étudiant·e voit de travers dans l'écran de relecture.
    ///
    /// On ne garde donc que ce qui a la forme d'un intitulé. Dans le doute, on
    /// préfère **rien** : le numéro suffit à identifier l'exercice, et un titre
    /// absent ne trompe personne.
    static func exerciseTitle(_ raw: String) -> String {
        let value = cleanTitle(raw)
        guard !value.isEmpty else { return "" }
        return looksLikeTitle(value) ? value : ""
    }

    /// Un intitulé est court, ne ponctue pas comme une phrase, et commence par une
    /// majuscule — un fragment coupé au milieu d'un mot commence par une minuscule.
    static func looksLikeTitle(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        // Au-delà, c'est une phrase d'énoncé recopiée sur une seule ligne.
        guard value.count <= 60 else { return false }
        // Ponctuation finale de phrase.
        guard !value.hasSuffix("."), !value.hasSuffix(";"), !value.hasSuffix(":") else { return false }
        // Un fragment de mot (« tions change. »), une suite d'énoncé
        // (« ou contre-exemple. ») ou une énumération (« 1) Si x alors y ») ne
        // commence pas par une majuscule.
        guard let first = value.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return false }
        // Une consigne commence par son verbe ou par « Soit » : c'est la première
        // phrase de l'énoncé, même sans point final (« Soit f une fonction… »).
        let firstWord = value.split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "’" })
            .first.map { $0.lowercased() } ?? ""
        if statementOpeners.contains(firstWord) { return false }
        // « Ex-03-01 », « Exercice 3 », « Problem 2 » : le numéro, pas un intitulé.
        // Le modèle le renvoie volontiers comme titre quand le PDF n'en a pas.
        if let marker = SeriesLayoutParser.exerciseMarker(value, fallbackSeries: 1),
           cleanTitle(marker.remainder).isEmpty {
            return false
        }
        return true
    }

    /// Un intitulé **proposé par le modèle**, jugé moins sévèrement.
    ///
    /// La consigne lui demande de nommer la tâche en 2 à 6 mots : « Calculer les
    /// sommes » est alors un bon titre, et le PDF lui-même en donne qui
    /// commencent par un verbe (« Find the error: Sliding block »). Le filtre
    /// des lignes de PDF les effaçait. On ne rejette ici que l'énoncé recopié :
    /// long, ponctué comme une phrase, ouvert par « Soit » / « Let », ou réduit
    /// au numéro.
    static func looksLikeGeneratedTitle(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 60 else { return false }
        guard !value.hasSuffix("."), !value.hasSuffix(";"), !value.hasSuffix(":") else { return false }
        let words = value.split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "’" })
        guard words.count <= 8 else { return false }
        let firstWord = words.first.map { $0.lowercased() } ?? ""
        if hypothesisOpeners.contains(firstWord) { return false }
        if let marker = SeriesLayoutParser.exerciseMarker(value, fallbackSeries: 1),
           cleanTitle(marker.remainder).isEmpty {
            return false
        }
        return true
    }

    /// Les ouvertures d'une hypothèse : jamais un titre, même court.
    private static let hypothesisOpeners: Set<String> = ["soit", "soient", "let", "sei", "seien", "on", "étant"]

    /// Les mots qui ouvrent un énoncé, jamais un intitulé.
    private static let statementOpeners: Set<String> = [
        "soit", "soient", "montrer", "démontrer", "calculer", "déterminer", "trouver", "résoudre",
        "prouver", "vérifier", "considérons", "considérer", "on", "étant", "supposons", "écrire",
        "let", "show", "prove", "compute", "determine", "find", "consider", "suppose", "given", "assume",
        "sei", "seien", "zeigen", "berechnen", "bestimmen"
    ]

    private static func intValue(_ ns: NSString, _ range: NSRange) -> Int? {
        guard range.location != NSNotFound else { return nil }
        return Int(ns.substring(with: range))
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// La ligne du numéro **et la suivante** : « (bonus) » ou « facultatif » est
    /// souvent en dessous.
    private static func lineContext(_ ns: NSString, around range: NSRange) -> String {
        let lineRange = ns.lineRange(for: range)
        let after = lineRange.location + lineRange.length
        let nextRange = after < ns.length ? ns.lineRange(for: NSRange(location: after, length: 0)) : nil
        guard let nextRange else { return ns.substring(with: lineRange) }
        return ns.substring(with: lineRange) + "\n" + ns.substring(with: nextRange)
    }

    /// Vrai si le texte contient une mention de bonus, d'étoile ou de caractère
    /// facultatif. Exposé pour que l'analyse par mise en page applique exactement
    /// les mêmes règles que l'analyse par motifs.
    static func containsBonusMarker(_ text: String) -> Bool {
        isBonus(text)
    }

    private static func isBonus(_ context: String) -> Bool {
        bonus.firstMatch(in: context, options: [],
                         range: NSRange(location: 0, length: (context as NSString).length)) != nil
    }

    /// Nettoie un titre : séparateurs de tête, parenthèses d'en-tête, métadonnées
    /// EPFL, et l'exercice suivant quand l'extraction les a collés.
    static func cleanTitle(_ raw: String) -> String {        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // « (Nombres R) » → « Nombres R »
        if value.hasPrefix("("), value.hasSuffix(")"), value.count > 2 {
            value = String(value.dropFirst().dropLast())
        }
        // Retirer les séparateurs de tête.
        while let first = value.first, "–—:-.·)»".contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }

        let ns = value as NSString
        // Couper avant l'exercice suivant collé sur la même ligne.
        if let match = nextExercise.firstMatch(in: value, options: [],
                                               range: NSRange(location: 0, length: ns.length)) {
            value = ns.substring(to: match.range.location)
        }
        // Couper avant les métadonnées de mise en page (« Type : Technique »).
        let trimmed = value as NSString
        if let match = metadata.firstMatch(in: value, options: [],
                                           range: NSRange(location: 0, length: trimmed.length)) {
            value = trimmed.substring(to: match.range.location)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
