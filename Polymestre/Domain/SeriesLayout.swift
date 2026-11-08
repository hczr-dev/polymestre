import Foundation

/// Une ligne de PDF, avec ce que sa **mise en page** dit d'elle.
///
/// L'extraction précédente faisait `page.string` : tout le document devenait un
/// seul bloc de texte, et la distinction entre un titre et un énoncé disparaissait.
/// C'est de là que venaient « solution générale. » sous l'exercice 1 ou
/// « tions change. » sous le 3 — des morceaux de phrase pris pour des intitulés.
struct PDFLayoutLine: Equatable {
    var text: String
    /// Taille de police dominante de la ligne. `0` quand le PDF n'en expose pas.
    var fontSize: Double
    var isBold: Bool
    var pageIndex: Int
    /// Retrait depuis le bord gauche de la page, en points. `0` quand inconnu.
    ///
    /// C'est le signal qui distingue un exercice (aligné à gauche) de ses
    /// questions (décalées vers la droite) — et que l'IA ne pouvait pas voir tant
    /// que le texte lui arrivait aplati.
    var indent: Double
    /// La ligne **commence** en gras : un titre « en ligne », typique de LaTeX
    /// (« **Exercice 1.** Soit f… »), dont la police dominante reste celle du corps.
    var startsBold: Bool
    /// Position verticale sur la page, de 0 (haut) à 1 (bas). `nil` quand inconnue.
    ///
    /// L'ordre des lignes ne suffit pas à reconnaître un pied de page : PDFKit
    /// rend une seconde colonne **après** lui.
    var verticalPosition: Double?

    init(text: String, fontSize: Double = 0, isBold: Bool = false, pageIndex: Int = 0,
         indent: Double = 0, startsBold: Bool = false, verticalPosition: Double? = nil) {
        self.text = text
        self.fontSize = fontSize
        self.isBold = isBold
        self.pageIndex = pageIndex
        self.indent = indent
        self.startsBold = startsBold
        self.verticalPosition = verticalPosition
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmed.isEmpty }
}

/// Repère séries et exercices en s'appuyant sur la **taille de police**.
///
/// Le principe : dans un polycopié, un titre est plus gros que le corps du texte.
/// Un énoncé, non. C'est le signal qui manquait — les motifs seuls ne peuvent pas
/// distinguer « Exercice 1 » (titre) de « Exercice 1 solution générale. » (titre
/// suivi de la première phrase de l'énoncé).
///
/// Fonction **pure** : elle reçoit des lignes déjà extraites, donc elle se teste
/// sans PDF.
enum SeriesLayoutParser {

    /// Nombre de lignes explorées après un titre pour trouver « bonus », « facultatif ».
    static let bonusLookahead = 12

    // MARK: Corps de texte

    /// Taille du corps : la plus fréquente, **pondérée par le nombre de caractères**.
    ///
    /// Compter les lignes ne suffit pas — un document peut avoir trente titres
    /// courts et dix paragraphes longs. Ce qu'on lit, ce sont les caractères.
    static func bodyFontSize(_ lines: [PDFLayoutLine]) -> Double? {
        var weight: [Double: Int] = [:]
        for line in lines where line.fontSize > 0 {
            weight[line.fontSize, default: 0] += max(1, line.trimmed.count)
        }
        return weight.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }

    /// Le corps est-il en gras ? Sur un jeu de diapositives, tout l'est : le gras
    /// ne distingue alors plus rien et ne doit pas servir de signal.
    static func bodyIsBold(_ lines: [PDFLayoutLine]) -> Bool {
        let body = lines.filter { !$0.isEmpty }
        guard !body.isEmpty else { return false }
        let bold = body.filter(\.isBold).count
        return bold * 2 > body.count
    }

    /// La ligne se détache-t-elle du corps du texte ?
    static func isHeading(_ line: PDFLayoutLine, body: Double?, boldBody: Bool) -> Bool {
        guard !line.isEmpty else { return false }
        if let body, line.fontSize > 0 {
            if line.fontSize >= body * 1.06 { return true }
            // Tailles identiques : le gras prend le relais, s'il est rare.
            if !boldBody, line.isBold, line.fontSize >= body * 0.98 { return true }
            return false
        }
        return false
    }

    /// Un titre, ou un titre « en ligne » qui commence en gras.
    private static func isMarkedUp(_ line: PDFLayoutLine, body: Double?, boldBody: Bool) -> Bool {
        isHeading(line, body: body, boldBody: boldBody) || (!boldBody && line.startsBold)
    }

    // MARK: Analyse

    /// Repère les séries et leurs exercices.
    ///
    /// `defaultSeries` est la série que le **document** annonce ailleurs qu'en
    /// tête de ligne — un en-tête « Analyse I — Série 4 », le nom du fichier.
    /// Sans lui, un polycopié sans « Série N » en début de ligne rangeait tous ses
    /// exercices dans la série 1, et l'IA, qui lisait bien 4, en créait une seconde.
    ///
    /// Quand aucun PDF n'expose de police (texte collé, PDF sans fontes), on
    /// retombe sur `SeriesPDFParser` : le comportement précédent, sans régression.
    static func parse(_ lines: [PDFLayoutLine], defaultSeries: Int? = nil) -> [DetectedSeries] {
        guard lines.contains(where: { $0.fontSize > 0 }) else {
            return SeriesPDFParser.parse(lines.map(\.text).joined(separator: "\n"),
                                         defaultSeries: defaultSeries)
        }

        let body = bodyFontSize(lines)
        let boldBody = bodyIsBold(lines)
        let fallback = defaultSeries ?? 1
        // Le document écrit-il « Exercice » (ou « Exercise », « Problème »…) ?
        // Alors « Question 2 » ou un « 1. » en gras sont des **questions** de
        // l'exercice courant, pas des exercices.
        let usesKeywords = lines.contains { line in
            guard let marker = exerciseMarker(line.trimmed, fallbackSeries: 1) else { return false }
            return marker.kind == .keyword || marker.kind == .dashed
        }
        let leftMargin = lines.filter { !$0.isEmpty && $0.indent > 0 }.map(\.indent).min() ?? 0
        let plainHeadings = usesKeywords ? [] : plainNumberedHeadings(lines, leftMargin: leftMargin)
        // Des exercices titrés « Exercice » **sans numéro** : seulement dans un
        // document qui n'en numérote aucun, et qui en a au moins deux — un
        // « Exercice » isolé est plus souvent un intitulé de page.
        let unnumberedHeadings = !usesKeywords && plainHeadings.isEmpty
            && lines.filter { unnumberedHeading($0.trimmed) != nil && ($0.isBold || isHeading($0, body: body, boldBody: boldBody)) }.count >= 2

        // Une série = son numéro et son étiquette : « Série 5a » et « Série 5b »
        // dans un même PDF restent deux séries.
        typealias Key = SeriesIdentity.Key
        var seriesTitles: [Key: String] = [:]
        var groups: [Key: [DetectedExercise]] = [:]
        var seen = Set<String>()
        var currentSeries: Key?
        var order: [Key] = []
        /// Position de l'exercice en cours, pour y rattacher ses questions.
        var current: (series: Key, index: Int)?
        /// Les exercices titrés « Exercice » sans numéro, comptés dans l'ordre.
        var unnumberedCount: [Key: Int] = [:]
        /// Les lignes de l'exercice en cours, dans l'ordre : questions et texte.
        var events: [QuestionEvent] = []

        func closeExercise() {
            if let current {
                groups[current.series]?[current.index].subQuestions = questionTree(events)
            }
            current = nil
            events = []
        }

        for (index, line) in lines.enumerated() {
            let text = line.trimmed
            guard !text.isEmpty else { continue }

            // 1. En-tête de série.
            if let (number, label, remainder) = seriesHeaderWithLabel(text) {
                closeExercise()
                let number = Key(number, label)
                currentSeries = number
                if order.contains(number) == false { order.append(number) }
                if seriesTitles[number] == nil {
                    var title = SeriesPDFParser.cleanTitle(remainder)
                    // Un titre de série peut tenir sur la ligne suivante quand
                    // celle-ci est **du même niveau** que l'en-tête.
                    if title.isEmpty,
                       index + 1 < lines.count,
                       isHeading(lines[index + 1], body: body, boldBody: boldBody),
                       seriesHeader(lines[index + 1].trimmed) == nil,
                       exerciseMarker(lines[index + 1].trimmed, fallbackSeries: 1) == nil {
                        title = SeriesPDFParser.cleanTitle(lines[index + 1].trimmed)
                    }
                    seriesTitles[number] = SeriesPDFParser.looksLikeTitle(title) ? title : ""
                }
                continue
            }

            let markedUp = isMarkedUp(line, body: body, boldBody: boldBody)
            let nearMargin = line.indent <= leftMargin + 18

            // 2. Exercice.
            let seriesNow = currentSeries ?? Key(fallback)
            var found = exerciseMarker(text, fallbackSeries: seriesNow.number)
            var plainHeading = plainHeadings.contains(index)
            // « Exercice » sans numéro (« Exercice — Suites de Cauchy ») : un
            // titre mis en forme, numéroté dans l'ordre du document.
            if found == nil, unnumberedHeadings, let remainder = unnumberedHeading(text), markedUp || nearMargin && line.isBold {
                let next = (unnumberedCount[seriesNow] ?? 0) + 1
                unnumberedCount[seriesNow] = next
                found = ExerciseMarker(number: "\(seriesNow.number).\(next)", series: nil, remainder: remainder, kind: .keyword)
                plainHeading = true
            }
            if let marker = found,
               plainHeading
                || accepts(marker, markedUp: markedUp, nearMargin: nearMargin, usesKeywords: usesKeywords) {
                let resolvedSeries = marker.series.map { major in major == seriesNow.number ? seriesNow : Key(major) } ?? seriesNow
                guard seen.insert(resolvedSeries.label + "|" + marker.number).inserted else {
                    // Un doublon (corrigé à la suite de l'énoncé, rappel en pied de
                    // page) clôt l'exercice précédent sans en créer un nouveau.
                    closeExercise()
                    continue
                }
                closeExercise()
                if order.contains(resolvedSeries) == false { order.append(resolvedSeries) }

                groups[resolvedSeries, default: []].append(
                    DetectedExercise(number: marker.number,
                                     title: title(for: marker, line: line, next: nextLine(lines, after: index),
                                                  body: body, boldBody: boldBody),
                                     isBonus: bonus(lines, from: index, body: body, boldBody: boldBody),
                                     isConfident: marker.kind != .numeric || plainHeading,
                                     pageIndex: line.pageIndex,
                                     verticalPosition: line.verticalPosition))
                current = (resolvedSeries, groups[resolvedSeries]!.count - 1)
                events = [QuestionEvent(text: marker.remainder, nearMargin: true)]
                continue
            }

            // 3. Question d'un exercice : « a) », « (b) », « 1. » décalé — ou texte.
            guard current != nil else { continue }
            events.append(QuestionEvent(marks: questionMark(text, allowNumbers: usesKeywords || !plainHeadings.isEmpty,
                                                            indent: line.indent) ?? [],
                                        text: text, nearMargin: nearMargin))
        }
        closeExercise()

        var result = order.sorted().map { key in
            DetectedSeries(number: key.number,
                           title: seriesTitles[key] ?? "",
                           exercises: (groups[key] ?? []).sorted {
                               $0.number.localizedStandardCompare($1.number) == .orderedAscending
                           },
                           label: key.label)
        }

        // Une série annoncée sans exercice reconnu est **conservée** : mieux vaut
        // une carte vide à compléter à la main qu'un import qui ne trouve rien.
        for (key, title) in seriesTitles where groups[key] == nil && !order.contains(key) {
            result.append(DetectedSeries(number: key.number, title: title, exercises: [], label: key.label))
        }
        return DetectedSeries.withoutBlanketBonus(result.sorted { $0.key < $1.key })
    }

    /// Un repère est-il crédible **à cet endroit** de la mise en page ?
    ///
    /// Un mot-clé (« Exercice 3 ») est presque toujours un titre, sauf quand il
    /// est cité (« Exercice 2 de la série précédente… »). Un numéro nu (« 1.5 »,
    /// « 2. ») ne l'est que s'il est **mis en forme** comme un titre : sans cette
    /// règle, la première ligne d'une démonstration numérotée devenait un
    /// exercice fantôme.
    private static func accepts(_ marker: ExerciseMarker, markedUp: Bool,
                                nearMargin: Bool, usesKeywords: Bool) -> Bool {
        switch marker.kind {
        case .dashed:
            return true
        case .keyword:
            return markedUp || !isReference(marker.remainder)
        case .question:
            // « Question 1 » n'est un exercice que dans un document qui n'en
            // nomme aucun autrement.
            return !usesKeywords && (markedUp || !isReference(marker.remainder))
        case .numeric:
            return markedUp && nearMargin && !usesKeywords
        }
    }

    /// Les titres « 1. Rotating space station » que la police ne distingue pas.
    ///
    /// Certains PDF LaTeX (PHYS-101) embarquent des polices que PDFKit ne sait pas
    /// nommer : tout sort en « Helvetica » corps 10, titres en gras compris. Un
    /// numéro nu n'était alors jamais « mis en forme », et l'import ne trouvait
    /// **aucun** exercice — l'IA restait seule, sans rien pour la contredire.
    ///
    /// La mise en page suffit pourtant : des lignes courtes, **exactement** sur la
    /// marge, numérotées 1, 2, 3… dans l'ordre, sans ponctuation de phrase. Les
    /// questions « 1. Find … », décalées de quelques points, n'en font pas partie.
    static func plainNumberedHeadings(_ lines: [PDFLayoutLine], leftMargin: Double) -> Set<Int> {
        guard leftMargin > 0 else { return [] }
        var candidates: [(index: Int, value: Int)] = []
        for (index, line) in lines.enumerated() where !line.isEmpty && abs(line.indent - leftMargin) <= 3 {
            let text = line.trimmed
            let ns = text as NSString
            guard let match = singleNumberPattern.firstMatch(in: text, options: [],
                                                             range: NSRange(location: 0, length: ns.length)),
                  let value = Int(ns.substring(with: match.range(at: 1))) else { continue }
            let remainder = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard (2...60).contains(remainder.count),
                  remainder.first?.isUppercase == true,
                  !remainder.hasSuffix("."), !remainder.hasSuffix(";"), !remainder.hasSuffix(",") else { continue }
            candidates.append((index, value))
        }
        // 1, 2, 3… sans trou ni retour en arrière : une liste de titres, pas des
        // lignes numérotées éparses.
        guard candidates.count >= 2,
              candidates.enumerated().allSatisfy({ $0.element.value == $0.offset + 1 }) else { return [] }
        return Set(candidates.map(\.index))
    }

    /// « Exercice 2 **de la série** précédente » : une citation, pas un titre.
    static func isReference(_ remainder: String) -> Bool {
        let value = remainder.trimmingCharacters(in: .whitespaces).lowercased()
        let prefixes = ["de la ", "du ", "de l'", "de l’", "des ", "et ", "à ", ", ", "ci-dessus", "précédent",
                        "of ", "from ", "in ", "and ", "above", "der ", "aus ", "und "]
        return prefixes.contains { value.hasPrefix($0) }
    }

    // MARK: Questions

    private static let questionPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:\(([a-hA-H]|[ivx]{1,4}|\d{1,2})\)|([a-hA-H]|[ivx]{1,4})\)|([a-h])\.[ \t]|(\d{1,2})([.)])[ \t])"#,
        options: [])

    /// Les questions d'une ligne, avec leur texte et leur ponctuation.
    ///
    /// Une ligne peut en porter plusieurs quand le polycopié les met côte à côte
    /// (« 1) aₙ = … 2) aₙ = … 3) aₙ = … ») : on les sépare, mais seulement si
    /// elles **se suivent** et ont la même ponctuation — « (aₙ) » au milieu d'une
    /// phrase n'est pas une question.
    static func questionMark(_ text: String, allowNumbers: Bool, indent: Double) -> [QuestionMark]? {
        // Une puce (« • », « – », « ◦ ») : une question **sans étiquette**, numérotée
        // plus tard dans l'ordre (`resolvingBullets`).
        if let bullet = bulletRemainder(text) {
            return [QuestionMark(label: bulletLabel, indent: indent, delimiter: bulletLabel, text: bullet)]
        }
        let ns = text as NSString
        guard let match = questionPattern.firstMatch(in: text, options: [],
                                                     range: NSRange(location: 0, length: ns.length)),
              let label = questionLabel(text, allowNumbers: allowNumbers) else { return nil }
        let delimiter: String
        if match.range(at: 1).location != NSNotFound { delimiter = "()" }
        else if match.range(at: 2).location != NSNotFound { delimiter = ")" }
        else if match.range(at: 3).location != NSNotFound { delimiter = "." }
        else { delimiter = ns.substring(with: match.range(at: 5)) }
        let rest = ns.substring(from: match.range.location + match.range.length)
            .trimmingCharacters(in: .whitespaces)

        var marks = [QuestionMark(label: label, indent: indent, delimiter: delimiter, text: rest)]
        // Suivantes sur la même ligne : « 2) », « 3) »… dans l'ordre.
        guard let first = Int(label), delimiter == ")" else { return marks }
        var expected = first + 1
        var remaining = rest
        while let range = remaining.range(of: #"(?:^|\s)"# + "\(expected)" + #"\)\s"#, options: .regularExpression) {
            let before = String(remaining[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            marks[marks.count - 1].text = before
            remaining = String(remaining[range.upperBound...])
            marks.append(QuestionMark(label: String(expected), indent: indent, delimiter: ")", text: remaining))
            expected += 1
        }
        return marks
    }

    /// L'étiquette d'une question en tête de ligne : « a) », « (ii) », « 3. ».
    static func questionLabel(_ text: String, allowNumbers: Bool) -> String? {
        let ns = text as NSString
        guard let match = questionPattern.firstMatch(in: text, options: [],
                                                     range: NSRange(location: 0, length: ns.length)) else { return nil }
        for group in 1...4 {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { continue }
            let label = ns.substring(with: range).lowercased()
            if label.first?.isNumber == true, !allowNumbers, group == 4 { return nil }
            return label
        }
        return nil
    }

    /// L'étiquette provisoire d'une puce, avant sa numérotation.
    static let bulletLabel = "•"

    /// Le texte après une puce de liste (`itemize` de LaTeX, listes Word), ou `nil`.
    /// « - » et « * » demandent une espace : « -1 » est un nombre.
    static func bulletRemainder(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, "•◦▪‣∙●○■□–—-*·".contains(first) else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let value = rest.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Les puces numérotées dans l'ordre, comme les exercices sans numéro.
    ///
    /// Sans autre étiquette dans l'exercice, les puces du premier retrait sont les
    /// questions (1, 2, 3) et les puces plus à droite leurs points (a, b, c). Sous
    /// des questions étiquetées (« 1) … • … • »), les puces sont les points de la
    /// question au-dessus, dans un style qui n'est pas le sien. Une puce avant toute
    /// question étiquetée reste du texte.
    static func resolvingBullets(_ events: [QuestionEvent]) -> [QuestionEvent] {
        let all = events.flatMap(\.marks)
        guard all.contains(where: { $0.delimiter == bulletLabel }) else { return events }
        let labeled = all.filter { $0.delimiter != bulletLabel }
        let topIndent = all.filter { $0.delimiter == bulletLabel }.map(\.indent).min() ?? 0
        let romans = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"]
        func letter(_ n: Int) -> String { String(UnicodeScalar(UInt8(96 + min(n, 26)))) }
        // Sous des questions étiquetées, les points prennent un autre style que le leur.
        let topStyle = labeled.first.map { style(of: $0.label) }
        func child(_ n: Int) -> String {
            topStyle == .letter ? romans[min(n, romans.count) - 1] : letter(n)
        }
        var top = 0, children = 0, sawLabeled = false
        return events.map { event in
            var copy = event
            copy.marks = event.marks.compactMap { mark in
                guard mark.delimiter == bulletLabel else {
                    sawLabeled = true
                    children = 0
                    return mark
                }
                var resolved = mark
                if labeled.isEmpty, mark.indent <= topIndent + 6 {
                    top += 1
                    children = 0
                    resolved.label = "\(top)"
                    resolved.delimiter = bulletLabel
                } else if labeled.isEmpty ? top > 0 : sawLabeled {
                    children += 1
                    resolved.label = child(children)
                    resolved.delimiter = bulletLabel + "·"
                } else {
                    return nil
                }
                return resolved
            }
            return copy
        }
    }

    /// Une étiquette de question, avec le retrait de sa ligne.
    struct QuestionMark: Equatable {
        var label: String
        var indent: Double
        /// « ) », « . », « () » : « 1. » et « 1) » ne sont pas la même liste.
        var delimiter: String = ""
        /// Ce qui suit l'étiquette sur la ligne.
        var text: String = ""
    }

    enum LabelStyle { case number, letter, roman }

    static func style(of label: String) -> LabelStyle {
        if label.allSatisfy(\.isNumber) { return .number }
        if label.count > 1 || ["i", "v", "x"].contains(label), label.allSatisfy({ "ivx".contains($0) }) {
            // « i » seul est ambigu : c'est un romain s'il ouvre la liste, une
            // lettre s'il suit « h ». On tranche au niveau de la liste.
            return .roman
        }
        return .letter
    }

    /// Les étiquettes du premier niveau, dans l'ordre de leur numéro.
    static func topLevelQuestions(_ marks: [QuestionMark]) -> [String] {
        questionTree(marks).filter { $0.kind == .question }.map(\.label)
    }

    private static func order(of label: String, style: LabelStyle) -> Int {
        switch style {
        case .number: return Int(label) ?? 0
        case .letter: return Int(label.unicodeScalars.first?.value ?? 0)
        case .roman:
            let values: [Character: Int] = ["i": 1, "v": 5, "x": 10]
            var total = 0
            var previous = 0
            for character in label.reversed() {
                let value = values[character] ?? 0
                total += value < previous ? -value : value
                previous = max(previous, value)
            }
            return total
        }
    }

    /// Une ligne sous un exercice : des étiquettes de question, ou du texte.
    struct QuestionEvent: Equatable {
        var marks: [QuestionMark] = []
        var text: String
        /// Alignée sur la marge gauche du document.
        var nearMargin: Bool
    }

    /// L'arbre des questions à partir des seules étiquettes (tests, texte collé).
    static func questionTree(_ marks: [QuestionMark]) -> [DetectedSubQuestion] {
        questionTree(marks.map { QuestionEvent(marks: [$0], text: $0.label, nearMargin: false) })
    }

    /// L'arbre des questions d'un exercice : premier niveau, et ses points.
    ///
    /// « 1) … (a) (b) 2) … (a) (b) (c) » donne 1(a,b) et 2(a,b,c) — la version
    /// précédente ne gardait que 1 et 2, et les cases réelles disparaissaient.
    /// S'y ajoutent les **parties sans numéro** : une consigne d'ouverture suivie de
    /// « Ensuite » (« Calculer lim aₙ. Ensuite, … calculer : 1) 2) 3) »), et un
    /// « Ensuite, … » après la liste. Une liste de **conditions** (« satisfait les
    /// conditions suivantes : 1) … 2) … ») n'est pas une liste de questions.
    static func questionTree(_ events: [QuestionEvent]) -> [DetectedSubQuestion] {
        let events = resolvingBullets(events)
        let marks = events.flatMap(\.marks)
        guard let first = marks.first else { return [] }

        // Le premier niveau : l'étiquette la plus à gauche, et sa ponctuation.
        let hasLayout = marks.contains { $0.indent > 0 }
        let minIndent = marks.map(\.indent).min() ?? 0
        let anchor = hasLayout ? (marks.first { $0.indent <= minIndent + 6 } ?? first) : first
        var topStyle = style(of: anchor.label)
        if topStyle == .roman, marks.contains(where: { style(of: $0.label) == .letter && $0.label != "i" }) {
            topStyle = .letter
        }
        var childStyle: LabelStyle?

        func resolved(_ mark: QuestionMark) -> LabelStyle {
            let raw = style(of: mark.label)
            // « i » après « h » reste une lettre.
            if raw == .roman, mark.label.count == 1, topStyle == .letter || childStyle == .letter { return .letter }
            return raw
        }
        func isTop(_ mark: QuestionMark) -> Bool {
            resolved(mark) == topStyle && (mark.delimiter == anchor.delimiter || anchor.delimiter.isEmpty)
        }

        var intro = ""
        var trailing: [String] = []
        var extendsTrailing = false
        var questions: [DetectedSubQuestion] = []
        for event in events {
            if questions.isEmpty {
                // Avant la liste : tout est consigne, y compris une étiquette qui
                // n'est pas du premier niveau (« n ⩾ 1. Calculer » lu « 1. Calculer »).
                if let top = event.marks.firstIndex(where: isTop) {
                    for mark in event.marks[..<top] { intro = joinLines(intro, mark.text) }
                } else {
                    intro = joinLines(intro, event.marks.isEmpty ? event.text : (event.marks.first?.text ?? event.text))
                    continue
                }
            }
            if event.marks.isEmpty {
                if event.nearMargin, startsWithTransition(event.text) {
                    trailing.append(event.text)
                    extendsTrailing = true
                } else if extendsTrailing, let last = trailing.indices.last, trailing[last].count < 160 {
                    // La suite de la phrase « Ensuite, … » sur la ligne d'après.
                    trailing[last] = joinLines(trailing[last], event.text)
                }
                continue
            }
            // Une question interrompt la phrase « Ensuite » — mais ne l'annule pas :
            // PDFKit rend la seconde colonne **après** le texte qui suit la liste.
            extendsTrailing = false
            for mark in event.marks {
                if isTop(mark) {
                    guard !questions.contains(where: { $0.label == mark.label }) else { continue }
                    questions.append(DetectedSubQuestion(label: mark.label, text: shortText(mark.text)))
                } else if resolved(mark) != topStyle, !questions.isEmpty {
                    let markStyle = resolved(mark)
                    if childStyle == nil { childStyle = markStyle }
                    guard markStyle == childStyle else { continue }
                    // Les points vont à la dernière question **dans l'ordre de lecture**.
                    let last = questions.count - 1
                    guard !questions[last].children.contains(where: { $0.label == mark.label }) else { continue }
                    questions[last].children.append(DetectedSubQuestion(label: mark.label, text: shortText(mark.text)))
                }
            }
        }

        if introListsConditions(intro) { return [] }

        // Deux colonnes arrivent dans le désordre : on remet l'ordre du numéro.
        questions.sort { order(of: $0.label, style: topStyle) < order(of: $1.label, style: topStyle) }
        for index in questions.indices {
            let style = childStyle ?? .letter
            questions[index].children.sort { order(of: $0.label, style: style) < order(of: $1.label, style: style) }
            if !isQuestionSequence(questions[index].children.map(\.label)) {
                questions[index].children = []
            }
        }
        guard isQuestionSequence(questions.map(\.label)) else { return [] }

        if let lead = leadingTask(intro) {
            questions.insert(DetectedSubQuestion(label: "", text: lead, kind: .part), at: 0)
        }
        for text in trailing {
            questions.append(DetectedSubQuestion(label: "", text: shortText(text), kind: .part))
        }
        return questions
    }

    private static let transitionPattern = try! NSRegularExpression(
        pattern: #"^(Ensuite|Puis|Enfin|Finalement|De plus|Then|Next|Finally|Afterwards)\b"#,
        options: [.caseInsensitive])

    static func startsWithTransition(_ text: String) -> Bool {
        let ns = text as NSString
        return transitionPattern.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static let imperativePattern = try! NSRegularExpression(
        pattern: #"\b(Calculer|Montrer|Démontrer|Déterminer|Prouver|Trouver|Étudier|Donner|Résoudre|Vérifier|Compute|Show|Prove|Find|Determine|Solve)\b[^.]*?(?=[.;]?\s*(Ensuite|Puis|Then|Next)\b)"#,
        options: [.caseInsensitive])

    /// Une tâche demandée **avant** la liste, et séparée d'elle par « Ensuite ».
    static func leadingTask(_ intro: String) -> String? {
        let ns = intro as NSString
        guard let match = imperativePattern.firstMatch(in: intro, options: [],
                                                       range: NSRange(location: 0, length: ns.length)) else { return nil }
        let text = ns.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? nil : shortText(text)
    }

    /// « …qui satisfait les deux conditions suivantes : » — la liste qui suit est
    /// l'énoncé, pas du travail à cocher.
    static func introListsConditions(_ intro: String) -> Bool {
        let tail = String(intro.lowercased().suffix(160))
        let patterns = [#"(conditions?|hypoth[eè]ses?|propri[eé]t[eé]s?|axiomes?)\s+suivant"#,
                        #"following\s+(conditions?|properties|assumptions)"#,
                        #"satisf\w*\s.*suivant"#]
        return patterns.contains { tail.range(of: $0, options: .regularExpression) != nil }
    }

    /// Recolle deux lignes, sans l'espace d'une césure (« li- » + « mite »).
    static func joinLines(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces)
        let b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if a.hasSuffix("-") { return String(a.dropLast()) + b }
        return a + " " + b
    }

    /// Un énoncé court : la ligne lue, bornée. Le texte d'un PDF LaTeX perd ses
    /// symboles mathématiques ; il sert de repère, pas de copie.
    static func shortText(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > 90 ? String(clean.prefix(89)) + "…" : clean
    }

    /// Des étiquettes forment-elles une vraie liste de questions ?
    ///
    /// Deux au moins, et une liste qui **commence** au début (a, 1 ou i) : une
    /// ligne isolée « c) » au milieu d'un énoncé n'est pas une question.
    static func isQuestionSequence(_ labels: [String]) -> Bool {
        guard labels.count >= 2, let first = labels.first else { return false }
        return ["a", "1", "i"].contains(first)
    }

    // MARK: Titres

    /// L'intitulé d'un exercice — **jamais** la première ligne de l'énoncé.
    ///
    /// Deux sources seulement : la fin de la ligne du titre, et la ligne suivante
    /// **si et seulement si** elle est du même niveau typographique que le titre
    /// (un intitulé sur deux lignes). Une ligne de corps de texte n'est jamais un
    /// intitulé, c'est ce qui produisait les faux titres.
    private static func title(for marker: ExerciseMarker,
                              line: PDFLayoutLine,
                              next: PDFLayoutLine?,
                              body: Double?,
                              boldBody: Bool) -> String {
        let sameLine = SeriesPDFParser.cleanTitle(marker.remainder)
        if SeriesPDFParser.looksLikeTitle(sameLine) { return sameLine }

        guard let next, !next.isEmpty,
              isHeading(next, body: body, boldBody: boldBody),
              next.fontSize <= line.fontSize * 1.02,
              exerciseMarker(next.trimmed, fallbackSeries: 1) == nil,
              seriesHeader(next.trimmed) == nil else { return "" }
        let continuation = SeriesPDFParser.cleanTitle(next.trimmed)
        return SeriesPDFParser.looksLikeTitle(continuation) ? continuation : ""
    }

    private static func nextLine(_ lines: [PDFLayoutLine], after index: Int) -> PDFLayoutLine? {
        guard index + 1 < lines.count else { return nil }
        return lines[index + 1]
    }

    // MARK: Bonus

    /// Cherche « bonus », « facultatif », « optionnel » ou une étoile **dans le
    /// corps de l'exercice**.
    ///
    /// L'ancienne version ne regardait que la ligne du titre et la suivante. Sur un
    /// vrai polycopié, la mention est souvent deux ou trois lignes plus bas, après
    /// l'énoncé — elle était donc manquée.
    private static func bonus(_ lines: [PDFLayoutLine], from index: Int,
                              body: Double?, boldBody: Bool) -> Bool {
        for offset in 0...bonusLookahead {
            let position = index + offset
            guard position < lines.count else { break }
            let line = lines[position]
            // Un nouveau titre clôt l'exercice : au-delà, la mention appartient à
            // quelqu'un d'autre.
            if offset > 0, isHeading(line, body: body, boldBody: boldBody) { break }
            if offset > 0, exerciseMarker(line.trimmed, fallbackSeries: 1)?.kind == .keyword { break }
            if SeriesPDFParser.containsBonusMarker(line.trimmed) { return true }
        }
        return false
    }

    // MARK: Motifs

    /// Les mots qui annoncent un exercice, en français, anglais et allemand : les
    /// cours de master sont souvent en anglais, et un polycopié « Exercise 3 »
    /// n'était tout simplement pas vu.
    static let exerciseKeywords = #"exercices?|exercises?|exo|ex|probl[eè]mes?|problems?|aufgabe"#

    private static let seriesPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*s[ée]rie[ \t]*(?:n[°o][ \t]*)?(\d{1,2})(?:(?:[ \t]*[-.(][ \t]*)?([a-f])\)?)?\b[ \t]*[–—:.\-]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    /// « Exercice », « Exercise — Titre », « Exercice (Rosen 1.2) » : le mot
    /// seul, sans numéro. Le reste de la ligne (le titre) est rendu.
    private static let unnumberedPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:exercice|exercise|probl[eè]me|problem|aufgabe)[ \t]*\*?[ \t]*(?:[:.\-–—][ \t]*(.*)|\(([^)]*)\)[ \t]*(.*)|)$"#,
        options: [.caseInsensitive])

    static func unnumberedHeading(_ text: String) -> String? {
        let ns = text as NSString
        guard let match = unnumberedPattern.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        let parts = (1..<match.numberOfRanges).compactMap { index -> String? in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    private static let dashedPattern = try! NSRegularExpression(
        pattern: #"\bEx[ .\-]?(\d{1,2})[.\-](\d{1,2})\b[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [])

    private static let barePattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:"# + exerciseKeywords + #")[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*\*?[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    private static let keywordNumberedPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:"# + exerciseKeywords + #")[ \t]*\.?[ \t]*(?:n[°o][ \t]*)?(\d{1,2})[.\-·](\d{1,2})\b[ \t]*\*?[ \t]*[–—:.\-)]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    private static let questionHeadingPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*question[ \t]*(?:n[°o][ \t]*)?(\d{1,2})\b(?!\.\d)[ \t]*[:.\-–—]?[ \t]*(.*)$"#,
        options: [.caseInsensitive])

    private static let numberedPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(\d{1,2})[.\-·](\d{1,2})\b(?![.,]\d)[ \t]*[–—:.\-)]?[ \t]*(.*)$"#,
        options: [])

    /// « 3. Titre » ou « 3) » : un numéro seul, qui n'est un exercice que mis en forme.
    private static let singleNumberPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(\d{1,2})[.)](?!\d)[ \t]*(.*)$"#,
        options: [])

    struct ExerciseMarker {
        enum Kind { case dashed, keyword, question, numeric }
        var number: String
        /// Série déduite du numéro lui-même (« Ex-02-04 » → 2), sinon `nil`.
        var series: Int?
        var remainder: String
        var kind: Kind
    }

    static func seriesHeader(_ text: String) -> (number: Int, remainder: String)? {
        seriesHeaderWithLabel(text).map { ($0.number, $0.remainder) }
    }

    /// « Série 5b — Suites » → (5, « b », « Suites ») ; « Série 5 — mardi » →
    /// (5, « mardi », « mardi »). Une lettre suivie d'un mot (« Série 5 à rendre »)
    /// n'est pas une étiquette.
    static func seriesHeaderWithLabel(_ text: String) -> (number: Int, label: String, remainder: String)? {
        let ns = text as NSString
        guard let match = seriesPattern.firstMatch(in: text, options: [],
                                                   range: NSRange(location: 0, length: ns.length)),
              let number = Int(ns.substring(with: match.range(at: 1))), (1...60).contains(number) else { return nil }
        let letter = match.range(at: 2).location == NSNotFound ? "" : ns.substring(with: match.range(at: 2))
        var remainder = ns.substring(with: match.range(at: 3))
        let label = letter.isEmpty ? SeriesIdentity.label(in: text) : letter
        // « Série 5.2 — Suites » : le « 2 » est l'étiquette, pas le titre.
        if !label.isEmpty, label.allSatisfy(\.isNumber), remainder.hasPrefix(label),
           !(remainder.dropFirst(label.count).first?.isNumber ?? false) {
            remainder = String(remainder.dropFirst(label.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t–—:.-"))
        }
        return (number, SeriesIdentity.normalized(label), remainder)
    }

    static func exerciseMarker(_ text: String, fallbackSeries: Int) -> ExerciseMarker? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        func int(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return Int(ns.substring(with: range))
        }
        func string(_ match: NSTextCheckingResult, _ group: Int) -> String {
            let range = match.range(at: group)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }

        if let match = dashedPattern.firstMatch(in: text, options: [], range: full),
           let major = int(match, 1), let minor = int(match, 2), minor > 0 {
            return ExerciseMarker(number: "\(major).\(minor)", series: major,
                                  remainder: string(match, 3), kind: .dashed)
        }
        if let match = keywordNumberedPattern.firstMatch(in: text, options: [], range: full),
           let major = int(match, 1), let minor = int(match, 2), minor > 0 {
            return ExerciseMarker(number: "\(major).\(minor)", series: major,
                                  remainder: string(match, 3), kind: .keyword)
        }
        if let match = barePattern.firstMatch(in: text, options: [], range: full),
           let value = int(match, 1), value > 0 {
            return ExerciseMarker(number: "\(fallbackSeries).\(value)", series: nil,
                                  remainder: string(match, 2), kind: .keyword)
        }
        if let match = questionHeadingPattern.firstMatch(in: text, options: [], range: full),
           let value = int(match, 1), value > 0 {
            return ExerciseMarker(number: "\(fallbackSeries).\(value)", series: nil,
                                  remainder: string(match, 2), kind: .question)
        }
        if let match = numberedPattern.firstMatch(in: text, options: [], range: full),
           let major = int(match, 1), let minor = int(match, 2), minor > 0, major > 0 {
            return ExerciseMarker(number: "\(major).\(minor)", series: major,
                                  remainder: string(match, 3), kind: .numeric)
        }
        if let match = singleNumberPattern.firstMatch(in: text, options: [], range: full),
           let value = int(match, 1), value > 0 {
            return ExerciseMarker(number: "\(fallbackSeries).\(value)", series: nil,
                                  remainder: string(match, 2), kind: .numeric)
        }
        return nil
    }
}

extension SeriesLayoutParser {
    /// Le texte de chaque exercice : les lignes entre son titre et le suivant,
    /// lues dans l'ordre de la page.
    ///
    /// La lecture par la mise en page trouve les numéros mais laisse l'énoncé
    /// vide (c'est le modèle de langage qui le résume). Sans texte, une série
    /// révisée ne pouvait retrouver ses exercices que par leur numéro — qui
    /// est justement ce qui a bougé. Un énoncé vide reçoit ici sa première
    /// phrase.
    static func fillingStatements(_ detected: [DetectedSeries], from lines: [PDFLayoutLine]) -> [DetectedSeries] {
        let placed = lines.filter { $0.verticalPosition != nil && !$0.isEmpty }
            .sorted { ($0.pageIndex, $0.verticalPosition ?? 0) < ($1.pageIndex, $1.verticalPosition ?? 0) }
        guard !placed.isEmpty else { return detected }
        return detected.map { series in
            var series = series
            let anchors = series.exercises.map { exercise in
                exercise.pageIndex.flatMap { page in exercise.verticalPosition.map { (page, $0) } }
            }
            for index in series.exercises.indices where series.exercises[index].statement.isEmpty {
                guard let start = anchors[index] else { continue }
                let end = anchors[(index + 1)...].compactMap { $0 }.first
                let body = placed.filter { line in
                    let at = (line.pageIndex, line.verticalPosition ?? 0)
                    return at >= (start.0, start.1 - 0.001) && (end.map { at < ($0.0, $0.1 - 0.001) } ?? true)
                }
                .map(\.trimmed).joined(separator: " ")
                series.exercises[index].statement = firstSentence(of: body)
            }
            return series
        }
    }

    /// « Exercise 5. Adapt the bubble sort… (when the list is sorted). Express… »
    /// → « Adapt the bubble sort… (when the list is sorted). »
    static func firstSentence(of body: String) -> String {
        var text = body
        if let heading = text.range(of: #"^\s*(Exercise|Exercice|Exercices?|Problem|Problème|Ex\.?)\s*[\d.]+\s*[.:)]?\s*"#,
                                    options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(heading)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let stop = text.range(of: #"(?<=[a-z\)])\.\s+(?=[A-Z])"#, options: .regularExpression),
           text.distance(from: text.startIndex, to: stop.lowerBound) >= 25 {
            text = String(text[..<stop.lowerBound]) + "."
        }
        return String(text.prefix(240))
    }
}
