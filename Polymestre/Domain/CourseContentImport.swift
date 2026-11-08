import Foundation

// MARK: - Sources

/// Les sites d'où l'on importe le contenu d'un cours.
///
/// L'EPFL ne donne **aucun** accès API aux étudiant·e·s. Le contenu arrive donc
/// par la page elle-même : Moodle et Courseware s'ouvrent dans un navigateur
/// intégré où l'on se connecte avec son compte EPFL, puis l'app lit la page du
/// cours. Botafogo (le polycopié en ligne d'Analyse de S. Friedli) est public :
/// il se lit directement, sans connexion.
enum ContentSource: String, Codable, CaseIterable, Identifiable {
    case moodle, courseware, botafogo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .moodle: return "Moodle"
        case .courseware: return "Courseware"
        case .botafogo: return "Botafogo"
        }
    }

    /// Ce que la source apporte, en une ligne.
    var detail: String {
        switch self {
        case .moodle: return "Semaines, vidéos, supports et séries du cours"
        case .courseware: return "Chapitres et leçons d'un MOOC EPFL"
        case .botafogo: return "Polycopié d'Analyse en ligne (S. Friedli), avec ses vidéos"
        }
    }

    var icon: String {
        switch self {
        case .moodle: return "graduationcap"
        case .courseware: return "play.rectangle.on.rectangle"
        case .botafogo: return "function"
        }
    }

    /// La page d'arrivée du navigateur intégré.
    var homeURL: URL {
        switch self {
        case .moodle: return Institution.current.moodleURL("/my/courses.php") ?? URL(string: "https://moodle.epfl.ch/my/courses.php")!
        case .courseware: return Institution.current.coursewareURL("/dashboard") ?? URL(string: "https://courseware.epfl.ch/dashboard")!
        case .botafogo: return URL(string: (Institution.current.extras["botafogo"] ?? "https://botafogo.epfl.ch") + "/")!
        }
    }

    var requiresLogin: Bool { self != .botafogo }

    /// La source d'une adresse, d'après son hôte.
    static func detect(host: String?) -> ContentSource? {
        guard let host = host?.lowercased() else { return nil }
        if host.contains("moodle") { return .moodle }
        if host.contains("courseware") || host.contains("openedx") { return .courseware }
        if host.contains("botafogo") { return .botafogo }
        return nil
    }
}

// MARK: - Ce que la page a donné

/// Un élément tel que lu sur la page, avant toute interprétation.
///
/// Le script injecté dans la page ne décide de rien : il rapporte des titres, des
/// liens et un type technique (`resource`, `url`, `sequential`…). Tout ce qui
/// ressemble à une règle — « Série 3 » est une série, « Corrigé » s'ignore — vit
/// ici, en Swift pur et testé, pour que la même logique serve aux trois sources.
struct ScrapedItem: Codable, Equatable {
    var title: String
    var url: String = ""
    /// Type technique : module Moodle (`resource`, `url`, `page`, `kalvidres`…),
    /// bloc Open edX (`sequential`), `section` pour Botafogo.
    var type: String = ""
    /// Vidéos contenues, quand la source sait les compter.
    var videoCount: Int? = nil
    /// Identifiant du bloc Open edX (`block-v1:…+type@sequential+block@…`).
    var id: String? = nil
    /// Les blocs contenus (unités, vidéos) : un lien Moodle vers l'un d'eux
    /// désigne cette leçon.
    var blockIDs: [String]? = nil
    /// Les liens directs contenus : chaque vidéo d'une leçon Courseware.
    var links: [ContentLink]? = nil
}

struct ScrapedSection: Codable, Equatable {
    var title: String
    var items: [ScrapedItem]
    /// Identifiant du chapitre Open edX, quand la source en a un.
    var id: String? = nil
}

struct ScrapedCourse: Codable, Equatable {
    var source: String
    var title: String
    var url: String
    var sections: [ScrapedSection]
}

// MARK: - Brouillon à relire

enum ContentItemKind: String, CaseIterable, Identifiable {
    /// À suivre : de la matière, une série.
    case theory, series
    /// Une date à ne pas manquer : rendu noté, projet, examen.
    case deadline
    /// Un ancien examen, pour réviser.
    case pastExam
    /// Un document du cours, gardé comme lien mais pas suivi.
    case resource
    case ignore
    var id: String { rawValue }
    var label: String {
        switch self {
        case .theory: return "Théorie"
        case .series: return "Série"
        case .deadline: return "Échéance"
        case .pastExam: return "Annale"
        case .resource: return "Document"
        case .ignore: return "Ignorer"
        }
    }
}

struct ContentDraftItem: Identifiable, Equatable {
    var id = UUID()
    var kind: ContentItemKind
    /// « 3.2 » pour la théorie ; le numéro de série est `seriesNumber`.
    var number: String
    var title: String
    var url: String
    var videoCount: Int
    var seriesNumber: Int?
    var theoryKind: TheoryKind
    /// L'étiquette d'une série (« b », « mardi ») quand deux séries partagent
    /// un numéro — souvent celui de la semaine, pour une série sans numéro.
    var seriesLabel: String = ""
    /// La semaine **de l'élément**, quand elle diffère de celle de sa section :
    /// un chapitre de quatorze sections s'étale sur plusieurs semaines, et un
    /// enregistrement de cours tombe la semaine de sa date. `nil` = celle de la
    /// section.
    var week: Int? = nil
    /// Les exercices d'une série, quand la source les publie (Botafogo) ou
    /// qu'ils ont été lus dans le PDF (Moodle) : énoncé, questions, liens.
    var exercises: [ContentExerciseDraft] = []
    /// Le PDF d'une série Moodle, à télécharger et lire à l'import.
    var pdfURL: String = ""
    /// Quand le corrigé est publié, et où.
    var solutionsAt: Date? = nil
    var solutionURL: String = ""
    /// Tout ce qui va avec l'élément : l'enregistrement d'un cours, ses
    /// transparents et ses notes ; l'énoncé et le corrigé d'une série.
    var links: [ContentLink] = []
    /// La date d'une échéance.
    var date: Date? = nil
    var examKind: ExamKind = .assignment
    /// La section d'origine d'un document (« Ressources et références »).
    var group: String = ""

    /// La semaine à écrire.
    func plannedWeek(in section: ContentDraftSection) -> Int { week ?? section.week }
}

struct ContentDraftSection: Identifiable, Equatable {
    var id = UUID()
    var title: String
    /// Semaine du semestre ; `0` = non planifié.
    var week: Int
    /// La semaine vient-elle de la page (« Semaine 3 », une plage de dates) ou
    /// d'une supposition ? La relecture le dit, pour qu'on sache quoi vérifier.
    var weekIsInferred: Bool
    var isIncluded: Bool
    var items: [ContentDraftItem]

    var theoryCount: Int { items.filter { $0.kind == .theory }.count }
    var deadlineCount: Int { items.filter { $0.kind == .deadline }.count }
    var resourceCount: Int { items.filter { $0.kind == .resource || $0.kind == .pastExam }.count }

    /// « Semaine 3 », ou « Semaines 3–5 » quand les éléments s'étalent.
    var weekRange: ClosedRange<Int>? {
        let weeks = items.filter { $0.kind != .ignore }.map { $0.plannedWeek(in: self) }.filter { $0 > 0 }
        guard let low = weeks.min(), let high = weeks.max() else { return nil }
        return low...high
    }

    /// Décale la section **et** ses éléments : corriger la semaine d'un chapitre
    /// étalé ne doit pas écraser son étalement.
    mutating func shiftWeeks(by delta: Int, totalWeeks: Int) {
        guard delta != 0 else { return }
        for index in items.indices {
            if let own = items[index].week {
                items[index].week = min(max(1, own + delta), max(totalWeeks, 1))
            }
        }
    }
    var seriesCount: Int { items.filter { $0.kind == .series }.count }
    var videoCount: Int { items.filter { $0.kind == .theory }.reduce(0) { $0 + $1.videoCount } }
}

struct ContentDraft: Equatable {
    var source: ContentSource
    var courseTitle: String
    var url: String
    var sections: [ContentDraftSection]
    /// Ce qu'il faut faire chaque semaine, en une phrase (« Regarder le
    /// chapitre 3 du MOOC, lire les transparents, faire la série 3 »).
    var weekGuide: [Int: String] = [:]

    var includedSections: [ContentDraftSection] { sections.filter(\.isIncluded) }
    var theoryCount: Int { includedSections.reduce(0) { $0 + $1.theoryCount } }
    var seriesCount: Int { includedSections.reduce(0) { $0 + $1.seriesCount } }
    var videoCount: Int { includedSections.reduce(0) { $0 + $1.videoCount } }
    var deadlineCount: Int { includedSections.reduce(0) { $0 + $1.deadlineCount } }
    var resourceCount: Int { includedSections.reduce(0) { $0 + $1.resourceCount } }
    var isEmpty: Bool { theoryCount == 0 && seriesCount == 0 && deadlineCount == 0 && resourceCount == 0 }
}

extension ContentDraft {
    /// Le brouillon en quelques lignes, pour le modèle : chaque semaine, sa
    /// théorie et ses séries (une autre source du cours, comme Botafogo).
    var outline: String {
        var lines = ["# \(courseTitle) (\(source.label))"]
        for section in sections where section.isIncluded {
            lines.append("## \(section.title)" + (section.week > 0 ? " [semaine \(section.week)]" : ""))
            for item in section.items.prefix(30) {
                let what: String
                switch item.kind {
                case .series: what = "série \(item.seriesNumber ?? 0)" + (item.exercises.isEmpty ? "" : " (\(item.exercises.count) exercices)")
                case .theory: what = item.videoCount > 0 ? "théorie, \(item.videoCount) vidéo(s)" : "théorie"
                default: what = "\(item.kind)"
                }
                lines.append("- \(item.number.isEmpty ? "" : item.number + " ")\(item.title) [\(what)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Ce que ce brouillon n'a pas, pris dans un autre : les séries absentes,
    /// et la théorie des semaines qui n'en ont pas.
    func completed(with other: ContentDraft) -> ContentDraft {
        var result = self
        let series = Set(sections.flatMap(\.items).compactMap { $0.kind == .series ? $0.seriesNumber : nil })
        let theoryWeeks = Set(sections.filter { $0.week > 0 && $0.theoryCount > 0 }.map(\.week))
        for section in other.sections where section.week > 0 {
            let extra = section.items.filter { item in
                (item.kind == .series && !series.contains(item.seriesNumber ?? -1))
                    || (item.kind == .theory && !theoryWeeks.contains(section.week))
            }
            guard !extra.isEmpty else { continue }
            if let index = result.sections.firstIndex(where: { $0.week == section.week }) {
                result.sections[index].items.append(contentsOf: extra)
            } else {
                var copy = section
                copy.items = extra
                result.sections.append(copy)
            }
        }
        result.sections.sort { lhs, rhs in
            if lhs.week == 0 || rhs.week == 0 { return lhs.week != 0 && rhs.week == 0 }
            return lhs.week < rhs.week
        }
        return result
    }
}

// MARK: - Interprétation

enum ContentDraftBuilder {

    /// Transforme une page lue en brouillon : types, numéros, semaines.
    ///
    /// - Parameters:
    ///   - termStart: début du semestre, pour lire les sections Moodle datées
    ///     (« 16 septembre - 22 septembre »).
    ///   - totalWeeks: durée du semestre ; aucune semaine devinée ne la dépasse.
    static func draft(from page: ScrapedCourse,
                      source: ContentSource,
                      termStart: Date?,
                      totalWeeks: Int = 14,
                      calendar: Calendar = .current) -> ContentDraft {
        var sections: [ContentDraftSection] = []
        var seriesSeen: Set<Int> = []
        var nextSeries = 1
        var chapterIndex = 0

        for scraped in page.sections {
            let sectionTitle = cleanTitle(scraped.title)
            let explicitWeek = week(fromTitle: sectionTitle, termStart: termStart, calendar: calendar)
            // Une section datée (« 7 septembre - 13 septembre ») n'a pas de
            // numéro de chapitre : son « 7 » est un jour.
            let chapter = explicitWeek == nil ? leadingNumber(in: sectionTitle).flatMap { Int($0.number) } : nil
            var items: [ContentDraftItem] = []
            var theoryIndex = 0
            let isContentChapter = chapter != nil || explicitWeek != nil

            if isContentChapter || !scraped.items.isEmpty { chapterIndex += 1 }
            let chapterLabel = chapter ?? explicitWeek ?? chapterIndex

            for raw in scraped.items {
                let title = cleanTitle(raw.title)
                guard !title.isEmpty else { continue }
                let kind = classify(raw, title: title, source: source)
                switch kind {
                case .series:
                    var number = seriesNumber(in: title) ?? nextSeries
                    // Un même numéro vu deux fois (« Série 3 », « Série 3 (PDF) ») :
                    // c'est la même série, gardée une fois.
                    if seriesSeen.contains(number) {
                        if seriesNumber(in: title) != nil { continue }
                        while seriesSeen.contains(number) { number += 1 }
                    }
                    seriesSeen.insert(number)
                    nextSeries = max(nextSeries, number + 1)
                    items.append(ContentDraftItem(kind: .series,
                                                  number: String(number),
                                                  title: title,
                                                  url: raw.url,
                                                  videoCount: 0,
                                                  seriesNumber: number,
                                                  theoryKind: .reading))
                default:
                    theoryIndex += 1
                    if raw.type == "recording" {
                        // L'enregistrement d'un cours : sa semaine est celle de
                        // sa date (« Cours 03 AN - GM - 16 sept 2026 »).
                        let index = firstMatch(fold(title), #"^cours\s*0*(\d{1,3})\b"#).flatMap(Int.init) ?? theoryIndex
                        items.append(ContentDraftItem(kind: .theory,
                                                      number: "C\(index)",
                                                      title: title,
                                                      url: raw.url,
                                                      videoCount: 1,
                                                      seriesNumber: nil,
                                                      theoryKind: .video,
                                                      week: week(fromTitle: title, termStart: termStart, calendar: calendar)
                                                        .map { min($0, max(totalWeeks, 1)) }))
                        continue
                    }
                    let lead = leadingNumber(in: title)
                    let number = lead?.number ?? "\(chapterLabel).\(theoryIndex)"
                    let videos = raw.videoCount ?? (isVideo(raw) ? 1 : 0)
                    var item = ContentDraftItem(kind: kind,
                                                number: number,
                                                title: lead.map { $0.rest.isEmpty ? title : $0.rest } ?? title,
                                                url: raw.url,
                                                videoCount: videos,
                                                seriesNumber: nil,
                                                theoryKind: theoryKind(for: raw, title: title, videos: videos))
                    // Chaque vidéo d'une leçon Courseware, liée directement.
                    item.links = (raw.links ?? []).map { link in
                        ContentLink(title: link.title.isEmpty ? title : cleanTitle(link.title), url: link.url, kind: link.kind)
                    }
                    items.append(item)
                }
            }

            guard !items.isEmpty else { continue }
            let useful = items.contains { $0.kind != .ignore }
            let dated = !items.isEmpty && items.allSatisfy { $0.week != nil }
            sections.append(ContentDraftSection(title: sectionTitle,
                                                week: explicitWeek ?? (dated ? (items.compactMap(\.week).min() ?? 0) : 0),
                                                weekIsInferred: explicitWeek == nil && !dated,
                                                isIncluded: useful && !isFrontMatter(sectionTitle),
                                                items: items))
        }

        if source == .botafogo {
            // Un polycopié n'a pas de semaines : ses chapitres vont de deux à
            // quatorze sections. « Un chapitre par semaine » mettait le chapitre
            // 3 (quatorze sections) en une semaine et le 14 (trois) dans une
            // autre. On étale plutôt la matière **à proportion de son volume**
            // sur le semestre.
            spreadByVolume(&sections, totalWeeks: totalWeeks)
        } else if !sections.contains(where: { !$0.weekIsInferred }) {
            // Aucune semaine lue sur la page : on propose une section par
            // semaine, dans l'ordre. C'est une **proposition** — la relecture la
            // montre comme telle et chaque semaine se corrige d'un geste.
            var week = 0
            for index in sections.indices where sections[index].isIncluded {
                week += 1
                sections[index].week = min(week, max(totalWeeks, 1))
            }
        }

        return ContentDraft(source: source,
                            courseTitle: cleanTitle(page.title),
                            url: page.url,
                            sections: sections)
    }

    /// Répartit les éléments de théorie des sections incluses sur `totalWeeks`
    /// semaines, chacun pesant `1 + vidéos`. Les éléments déjà datés (les
    /// enregistrements) gardent leur semaine.
    static func spreadByVolume(_ sections: inout [ContentDraftSection], totalWeeks: Int) {
        let weeks = max(totalWeeks, 1)
        var slots: [(section: Int, item: Int, weight: Double)] = []
        for (s, section) in sections.enumerated() where section.isIncluded && section.weekIsInferred {
            for (i, item) in section.items.enumerated() where item.kind == .theory && item.week == nil {
                slots.append((s, i, 1 + Double(item.videoCount)))
            }
        }
        let total = slots.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return }
        var cumulative = 0.0
        for slot in slots {
            let week = min(weeks, Int(cumulative / total * Double(weeks)) + 1)
            sections[slot.section].items[slot.item].week = week
            cumulative += slot.weight
        }
        for index in sections.indices where sections[index].isIncluded && sections[index].weekIsInferred {
            sections[index].week = sections[index].weekRange?.lowerBound ?? 0
        }
    }

    // MARK: Règles

    private static let ignoredTypes: Set<String> = [
        "forum", "label", "choice", "feedback", "questionnaire", "attendance",
        "zoom", "chat", "wiki", "glossary", "survey", "data", "lti", "bigbluebuttonbn",
        "quiz", "workshop", "subsection"
    ]

    /// Théorie, série, ou rien.
    static func classify(_ item: ScrapedItem, title: String, source: ContentSource) -> ContentItemKind {
        let lower = fold(title)
        let type = item.type.lowercased()
        if ignoredTypes.contains(type) { return .ignore }
        if matches(lower, #"\b(annonces?|announcements?|news|forum|discussion|sondage|feedback|informations? generales?)\b"#) {
            return .ignore
        }
        // Un corrigé accompagne une série ; ce n'est pas une série de plus.
        if matches(lower, #"\b(corrige|corriges|correction|corrections|solutions?|loesung|answers?)\b"#) {
            return .ignore
        }
        if matches(lower, #"\b(series?|exercices?|exercises?|problem ?sets?|td|homeworks?|devoirs?|assignments?|feuilles? d'exercices)\b"#)
            && !matches(lower, #"\b(series (numeriques|entieres|de fourier|de taylor|telescopiques|geometriques?))\b"#)
            && source != .botafogo {
            return .series
        }
        if type == "assign" { return .series }
        return .theory
    }

    static func isVideo(_ item: ScrapedItem) -> Bool {
        let type = item.type.lowercased()
        if ["kalvidres", "mediaspace", "video", "kalturavideo", "hvp"].contains(type) { return true }
        let haystack = fold(item.title + " " + item.url)
        return matches(haystack, #"(youtube|youtu\.be|vimeo|mediaspace|tube\.switch|kaltura|\bvideos?\b)"#)
    }

    static func theoryKind(for item: ScrapedItem, title: String, videos: Int) -> TheoryKind {
        let lower = fold(title)
        if matches(lower, #"\b(slides?|diapos?|diapositives?|transparents?)\b"#) { return .slides }
        if videos > 0 || isVideo(item) { return .video }
        if matches(lower, #"\b(chapitre|chapter)\b"#) { return .chapter }
        return .reading
    }

    /// Préface, avant-propos, outils : pas de la matière à planifier.
    static func isFrontMatter(_ title: String) -> Bool {
        // Par les mots, pas par la numérotation romaine : « II. Notions
        // élémentaires » est de la matière (sommes, fonctions, récurrence).
        let lower = fold(title)
        return matches(lower, #"\b(preface|avant-propos|foreword|generalites du cours|informations generales|general|outils graphiques)\b"#)
    }

    // MARK: Numéros

    /// Le numéro de série d'un titre : « Série 3 », « Serie_03 », « Exercise set 4 ».
    static func seriesNumber(in title: String) -> Int? {
        let lower = fold(title)
        let pattern = #"(?:series?|(?:exercices?|exercises?)(?:\s+sets?)?|problem ?sets?|td|homeworks?|devoirs?|assignments?|feuilles?)[\s_#.:-]*(?:n[o°]?\s*)?0*(\d{1,2})\b"#
        guard let match = firstMatch(lower, pattern) else { return nil }
        return Int(match)
    }

    /// Le numéro en tête d'un titre : « 3.2 Limite » → (3.2, Limite),
    /// « II.4 Trigonométrie » → (II.4, …), « Chapitre 3 : Suites » → (3, Suites).
    static func leadingNumber(in title: String) -> (number: String, rest: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let patterns = [
            #"^(?:chapitre|chapter|ch\.|section|lecon|leçon|lesson|module|partie|part|cours|lecture|vid[ée]o|video|th[ée]orie)\s*(\d+(?:\.\d+)*)\s*[:.\-–—]?\s*(.*)$"#,
            #"^(\d+(?:\.\d+)+|\d+)[.)]?\s+(.*)$"#,
            #"^([IVX]+\.\d+)\s+(.*)$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let numberRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let rest = Range(match.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
            let number = String(trimmed[numberRange]).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // « 2025 Examen » n'est pas un chapitre 2025.
            if let value = Int(number), value > 60 { return nil }
            return (number, rest.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Semaines

    private static let months: [String: Int] = [
        "janvier": 1, "janv": 1, "january": 1, "jan": 1,
        "fevrier": 2, "fevr": 2, "february": 2, "feb": 2,
        "mars": 3, "march": 3, "mar": 3,
        "avril": 4, "april": 4, "apr": 4, "avr": 4,
        "mai": 5, "may": 5,
        "juin": 6, "june": 6, "jun": 6,
        "juillet": 7, "july": 7, "jul": 7, "juil": 7,
        "aout": 8, "august": 8, "aug": 8,
        "septembre": 9, "september": 9, "sept": 9, "sep": 9,
        "octobre": 10, "october": 10, "oct": 10,
        "novembre": 11, "november": 11, "nov": 11,
        "decembre": 12, "december": 12, "dec": 12
    ]

    /// La semaine qu'un titre de section annonce.
    ///
    /// Deux formes : explicite (« Semaine 3 », « Week 3 », « S3 ») et datée — le
    /// format hebdomadaire de Moodle titre chaque section par sa plage
    /// (« 16 septembre - 22 septembre »), qu'on rapporte au début du semestre.
    static func week(fromTitle title: String, termStart: Date?, calendar: Calendar = .current) -> Int? {
        let lower = fold(title)
        if let value = firstMatch(lower, #"\b(?:semaine|week|sem\.?|wk)\s*0*(\d{1,2})\b"#), let week = Int(value), week > 0 {
            return week
        }
        if let value = firstMatch(lower, #"^s0*(\d{1,2})\b"#), let week = Int(value), week > 0 {
            return week
        }
        guard let termStart,
              let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})\.?\s+([a-z]+)\.?"#) else { return nil }
        let range = NSRange(lower.startIndex..., in: lower)
        for match in regex.matches(in: lower, range: range) {
            guard let dayRange = Range(match.range(at: 1), in: lower),
                  let monthRange = Range(match.range(at: 2), in: lower),
                  let day = Int(lower[dayRange]),
                  let month = months[String(lower[monthRange])] else { continue }
            let startYear = calendar.component(.year, from: termStart)
            let startMonth = calendar.component(.month, from: termStart)
            // Un semestre d'automne déborde sur janvier de l'année suivante.
            let year = month < startMonth - 2 ? startYear + 1 : startYear
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { continue }
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: termStart),
                                               to: calendar.startOfDay(for: date)).day ?? 0
            guard days > -7 else { return nil }
            // La semaine d'enseignement, pause d'automne déduite.
            return DateUtils.weekNumber(from: termStart, to: date)
        }
        return nil
    }

    // MARK: Texte

    /// Espaces normalisés, délimiteurs LaTeX retirés (`\(\mathbb{R}\)` → `\mathbb{R}`,
    /// que `MathText` sait afficher), suffixes techniques de Moodle ôtés.
    static func cleanTitle(_ raw: String) -> String {
        // Les macros d'ensembles de Botafogo : « Nombres \bR » → « Nombres ℝ ».
        var raw = raw
        for (macro, symbol) in ["\\bR": "ℝ", "\\bC": "ℂ", "\\bN": "ℕ", "\\bZ": "ℤ", "\\bQ": "ℚ"] {
            raw = raw.replacingOccurrences(of: macro, with: symbol)
        }
        // Un saut de ligne LaTeX (`\\`) dans un titre sépare deux parties.
        var text = raw.replacingOccurrences(of: #"\\"#, with: " · ")
        for token in [#"\("#, #"\)"#, #"\["#, #"\]"#, "$"] { text = text.replacingOccurrences(of: token, with: "") }
        // Le code dans les titres du polycopié d'ICS :
        // `\htmlTag{code}{\htmlAttr{language}{"text"}plt.plot}` → `plt.plot`.
        text = text.replacingOccurrences(of: #"\\htmlTag\{[^}]*\}\{\\htmlAttr\{[^}]*\}\{[^}]*\}([^}]*)\}"#,
                                         with: "$1", options: .regularExpression)
        for suffix in [" Fichier", " File", " URL", " Page", " Dossier", " Folder", " Devoir", " Assignment"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Minuscules sans accents : « Série » et « serie » sont le même mot.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CH"))
            .lowercased()
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }
}

// MARK: - Botafogo

/// Le polycopié en ligne de S. Friedli : une table des matières statique, puis
/// une page par section, qui contient les vidéos du cours.
enum BotafogoParser {

    /// Les cours listés sur la page d'accueil : (titre, adresse de la version en ligne).
    static func catalog(html: String, baseURL: URL) -> [(title: String, url: URL)] {
        let pattern = #"<span class="link-description">([^<]+)</span>\s*<a href="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: html),
                  let hrefRange = Range(match.range(at: 2), in: html),
                  let url = URL(string: String(html[hrefRange]), relativeTo: baseURL)?.absoluteURL else { return nil }
            let title = ContentDraftBuilder.cleanTitle(decode(String(html[titleRange])))
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return (title, url)
        }
    }

    /// La table des matières : un chapitre par `had-nav-toplevel`, une section
    /// par `had-nav-link-secondlevel`. Le PDF du chapitre n'est pas un élément.
    static func parseTOC(html: String, baseURL: URL) -> ScrapedCourse {
        let title = firstCapture(html, #"<title>\s*([^<|]+)"#).map { ContentDraftBuilder.cleanTitle(decode($0)) } ?? "Botafogo"
        var sections: [ScrapedSection] = []
        let chapters = html.components(separatedBy: #"<li class="had-nav-toplevel">"#).dropFirst()
        for chunk in chapters {
            guard let chapterTitle = firstCapture(chunk, ##"<a href="#[^"]*"[^>]*>([^<]+)</a>"##) else { continue }
            var items: [ScrapedItem] = []
            let pattern = #"<li class="had-nav-link-secondlevel"[^>]*><a href="([^"]+)">(.*?)</a></li>"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(chunk.startIndex..., in: chunk)
                for match in regex.matches(in: chunk, range: range) {
                    guard let hrefRange = Range(match.range(at: 1), in: chunk),
                          let textRange = Range(match.range(at: 2), in: chunk) else { continue }
                    let href = String(chunk[hrefRange])
                    let url = URL(string: href, relativeTo: baseURL)?.absoluteString ?? href
                    items.append(ScrapedItem(title: decode(stripTags(String(chunk[textRange]))),
                                             url: url,
                                             type: "section"))
                }
            }
            sections.append(ScrapedSection(title: decode(chapterTitle), items: items))
        }
        return ScrapedCourse(source: ContentSource.botafogo.rawValue,
                             title: title,
                             url: baseURL.absoluteString,
                             sections: sections)
    }

    static let home = URL(string: "https://botafogo.epfl.ch/")!

    /// `…/analyse-1/resources/sections/x.html` → `…/analyse-1/`.
    static func courseRoot(of url: URL) -> URL {
        let parts = url.path.split(separator: "/")
        guard let first = parts.first else { return home }
        return URL(string: "/\(first)/", relativeTo: home)?.absoluteURL ?? home
    }

    // MARK: Polycopiés Nuxt

    /// La page redirige-t-elle ailleurs (`<meta http-equiv="refresh" …>`) ?
    ///
    /// `/ics/`, `/analyse-b/` et `/algebre-lineaire-geometrie/` ne sont que
    /// cela : une redirection vers leur première section. `URLSession` ne suit
    /// pas ces redirections-là, et l'import tombait sur une page vide.
    static func metaRefresh(html: String, baseURL: URL) -> URL? {
        guard html.count < 4000,
              let target = firstCapture(html, #"http-equiv="refresh"[^>]*url=([^"'>]+)"#) else { return nil }
        return URL(string: target.trimmingCharacters(in: .whitespaces), relativeTo: baseURL)?.absoluteURL
    }

    /// La table des matières d'un polycopié Nuxt (analyse-b, ICS, algèbre
    /// linéaire, Analyse I GM et classe inversée).
    ///
    /// Deux façons d'adresser une section : un chemin (`/analyse-b/matiere/…`)
    /// ou, pour les sites de cours qui encadrent le polycopié, un paramètre
    /// (`/analyse-1-GM/?polycopie=matiere/…`, voir `BotafogoLinks`).
    static func parseNuxt(html: String, pageURL: URL) -> ScrapedCourse? {
        guard let payload = NuxtPayload(html: html) else { return nil }
        let navigation = payload.navigation()
        let chapters = navigation.chapters
        guard !chapters.isEmpty else { return nil }
        let root = siteRoot(html: html, pageURL: pageURL)
        let queryRouted = html.contains("?cours=")
        func link(_ path: String) -> String {
            if queryRouted {
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
                return BotafogoLinks.polycopieURL(root: root, path: encoded)
            }
            let trimmedRoot = root.absoluteString.hasSuffix("/") ? String(root.absoluteString.dropLast()) : root.absoluteString
            return trimmedRoot + (path.hasPrefix("/") ? path : "/" + path)
        }
        let sections = chapters.map { chapter in
            ScrapedSection(title: decode(chapter.title),
                           items: chapter.children.map { child in
                               ScrapedItem(title: decode(child.title), url: link(child.path), type: "section")
                           })
        }
        // Le titre de la page est celui de la **section** affichée
        // (« 1.1 Introduction ») : le nom du polycopié vient du nœud racine du
        // sommaire, sinon du titre de la page.
        let pageTitle = firstCapture(html, #"<title>\s*([^<|]+)"#).map { ContentDraftBuilder.cleanTitle(decode($0)) }
        let title = navigation.title.map { ContentDraftBuilder.cleanTitle(decode($0)) }
            ?? pageTitle.flatMap { ContentDraftBuilder.leadingNumber(in: $0) == nil ? $0 : nil }
            ?? "Botafogo"
        return ScrapedCourse(source: ContentSource.botafogo.rawValue, title: title,
                             url: root.absoluteString, sections: sections)
    }

    /// La racine du site : `baseURL` de la configuration Nuxt, sinon le
    /// premier segment du chemin.
    static func siteRoot(html: String, pageURL: URL) -> URL {
        if let base = firstCapture(html, #"baseURL:"([^"]+)""#) {
            let path = base.hasSuffix("/") ? base : base + "/"
            if let url = URL(string: path, relativeTo: pageURL)?.absoluteURL { return url }
        }
        return courseRoot(of: pageURL)
    }

    /// La page « vidéos » d'un site de cours (`?cours=sections/videos_an_gm_2026`),
    /// quand il en a une.
    static func videosPage(html: String, root: URL) -> URL? {
        guard let section = firstCapture(html, #"\?cours=(sections/[A-Za-z0-9_-]*vid[A-Za-z0-9_-]*)"#) else { return nil }
        return URL(string: BotafogoLinks.coursURL(root: root, path: section))
    }

    /// Les enregistrements des cours, avec leur date : `0_8coayv4h` suivi de
    /// « Cours 01 AN - GM - 09 sept 2026 (SG1) ». Les directs (« Streaming »)
    /// n'ont pas de date : ce ne sont pas des éléments à travailler.
    static func recordings(html: String) -> [ScrapedItem] {
        guard let payload = NuxtPayload(html: html) else { return [] }
        let strings = payload.strings
        var items: [ScrapedItem] = []
        var seen: Set<String> = []
        for (index, value) in strings.enumerated() where index + 1 < strings.count {
            guard value.range(of: #"^[01]_[a-z0-9]{8}$"#, options: .regularExpression) != nil else { continue }
            let title = decode(strings[index + 1]).trimmingCharacters(in: .whitespaces)
            let folded = ContentDraftBuilder.fold(title)
            guard !folded.contains("streaming"),
                  folded.range(of: #"\b\d{1,2}\.?\s+[a-z]+\.?\s+\d{4}\b"#, options: .regularExpression) != nil,
                  seen.insert(value).inserted else { continue }
            items.append(ScrapedItem(title: title, url: "https://\(Institution.current.video?.host ?? "mediaspace.epfl.ch")/media/\(value)",
                                     type: "recording", videoCount: 1))
        }
        return items
    }

    /// Les vidéos de cours d'une page de section (pas les petites animations,
    /// qui sont des `anim-video-plyr`).
    static func videoTitles(inSection html: String) -> [String] {
        let parts = html.components(separatedBy: #"<div class="video">"#).dropFirst()
        return parts.compactMap { part in
            guard part.contains("video-plyr") else { return nil }
            return firstCapture(part, #"class="video-button"[^>]*>([^<]+)</a>"#).map { decode($0) } ?? "Vidéo"
        }
    }

    // MARK: Outils

    private static func firstCapture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decode(_ text: String) -> String {
        var result = text
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&#x27;": "'", "&apos;": "'", "&nbsp;": " ", "&#x2F;": "/", "&rsquo;": "'"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        // Le reste des entités (`&eacute;`, `&#233;`, `&#039;`), un texte relu
        // en Latin-1 en route (« SÃ©rie ») et les accents détachés : les titres
        // de Moodle et du polycopié passent tous par ici.
        return TextRepair.clean(result)
    }
}
