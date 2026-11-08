import Foundation

// MARK: - Un document Botafogo, lu comme le site le montre

/// Un morceau d'un document Botafogo (Nuxt Content, « minimark »), prêt à
/// dessiner : texte avec ses formules et ses liens, listes (en colonnes comme
/// sur le site), formules isolées, images, vidéos, figures, théorèmes
/// encadrés, exercices, indications et solutions repliées, quiz.
///
/// **Les emplacements.** Les composants du site (quiz, solution révélée,
/// preuve, encadré « Informel », bulle « pourquoi ? ») rangent leur titre dans
/// un `template` marqué `#title` et leur contenu dans `#default` (un choix de
/// quiz, dans `#text`). L'ancienne lecture prenait le premier `template` — le
/// titre — et perdait le reste : « Quiz 0.9 », « Solution », et rien dessous.
indirect enum BotafogoBlock: Equatable {
    /// Du Markdown léger : `**gras**`, `*italique*`, `$formule$`, `[lien](adresse)`.
    case paragraph(String)
    case heading(String, level: Int)
    /// Une liste ; `columns` > 1 quand le site la pose en colonnes (`multicols`).
    case list([[BotafogoBlock]], ordered: Bool, columns: Int)
    /// Une formule seule sur sa ligne.
    case math(String)
    case image(String, width: Double?)
    /// Une vidéo MediaSpace (Kaltura).
    case kaltura(id: String, title: String)
    /// Une vidéo du site (`video-player`, `animation` → `src.mp4`).
    case video(source: String, poster: String?, title: String)
    /// Une figure interactive (JSXGraph) : son script, et sa taille sur le site.
    case figure(String, width: Double?, height: Double?)
    /// Une animation courte (`animation` → `src.mp4`), jouée sur place, en boucle.
    case animation(source: String, title: String)
    /// Un énoncé encadré : théorème, définition, proposition, remarque…
    case theorem(kind: BotafogoTheoremKind, title: String, [BotafogoBlock])
    /// Un encadré à part (« Informel 3.5 »).
    case aside(title: String, [BotafogoBlock])
    case exercise(label: String, [BotafogoBlock])
    case folded(BotafogoFold, title: String, [BotafogoBlock])
    case quiz(title: String, prompt: [BotafogoBlock], choices: [BotafogoQuizChoice], columns: Int)
}

enum BotafogoFold: String, Equatable {
    case solution, hint, proof, aside
}

enum BotafogoTheoremKind: String, Equatable {
    case theorem, definition, proposition, lemma, corollary, remark, example, other

    /// `amsthm-theo`, `amsthm-def`… → le genre.
    static func from(classes: [String]) -> BotafogoTheoremKind {
        let joined = classes.joined(separator: " ").lowercased()
        if joined.contains("amsthm-theo") || joined.contains("amsthm-thm") { return .theorem }
        if joined.contains("amsthm-def") { return .definition }
        if joined.contains("amsthm-prop") { return .proposition }
        if joined.contains("amsthm-lem") { return .lemma }
        if joined.contains("amsthm-cor") { return .corollary }
        if joined.contains("amsthm-rem") || joined.contains("amsthm-remark") { return .remark }
        if joined.contains("amsthm-ex") { return .example }
        return .other
    }
}

struct BotafogoQuizChoice: Equatable {
    var text: String
    var correct: Bool
    var explanation: String?
}

enum BotafogoPage {
    /// Le schéma des liens vers une section du polycopié, interceptés par l'app.
    static let polyScheme = "polymestre-poly"

    /// `m_suites_Cauchy` → `/handout/matiere/m_suites_cauchy` (les chemins du site sont en minuscules).
    static func handoutPath(target: String) -> String {
        "/handout/matiere/" + target.lowercased()
    }

    /// L'adresse d'un lien vers le polycopié : `polymestre-poly:///handout/matiere/m_…`.
    static func polyLink(target: String) -> String {
        polyScheme + "://" + handoutPath(target: target)
    }

    /// Le chemin du polycopié derrière un lien de l'app, s'il en est un.
    static func handoutPath(link: URL) -> String? {
        // `studytrack-poly:` : les liens écrits avant le changement de nom (fiches, réponses gardées).
        guard link.scheme == polyScheme || link.scheme == "studytrack-poly" else { return nil }
        let path = link.path.isEmpty ? (link.host.map { "/" + $0 } ?? "") : link.path
        return path.hasPrefix("/handout/") ? path : nil
    }

    // MARK: Lire

    static func blocks(fromNodeJSON data: Data) -> [BotafogoBlock] {
        guard let body = BotafogoDocument.body(fromNodeJSON: data) else { return [] }
        return blocks(body)
    }

    /// L'arbre (`body` du nœud) → les blocs.
    static func blocks(_ node: [String: Any]) -> [BotafogoBlock] {
        var reader = Reader()
        reader.read(children(of: node))
        return groupingExercises(reader.finish())
    }

    /// Dans une séance, un exercice n'est pas un composant : un paragraphe
    /// « **Exercice.** (3) … », puis ses formules, figures et sa solution. On
    /// les rassemble en une carte, jusqu'à l'exercice ou au titre suivant.
    static func groupingExercises(_ blocks: [BotafogoBlock]) -> [BotafogoBlock] {
        var result: [BotafogoBlock] = []
        var current: (label: String, blocks: [BotafogoBlock])?
        func close() {
            if let current { result.append(.exercise(label: current.label, current.blocks)) }
            current = nil
        }
        for block in blocks {
            if case .paragraph(let text) = block, let (label, rest) = exerciseLead(text) {
                close()
                current = (label, rest.isEmpty ? [] : [.paragraph(rest)])
            } else if case .heading = block {
                close()
                result.append(block)
            } else if current != nil {
                current?.blocks.append(block)
            } else {
                result.append(block)
            }
        }
        close()
        return result
    }

    /// Un calcul aligné écrit entre `$…$` au fil du texte (« Par exemple,
    /// $\begin{align*}…$ ») : sur le site, MathJax le pose sur ses lignes.
    /// On le sort du paragraphe en formule isolée, avec le texte avant et après.
    static func liftingDisplayMath(_ text: String) -> [BotafogoBlock] {
        let pattern = #"\$(\\begin\{(?:align|aligned|alignat|gather|gathered|eqnarray|multline|equation|split|flalign)\*?\}[^$]*)\$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.paragraph(text)] }
        let ns = text as NSString
        var result: [BotafogoBlock] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = tidy(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            if !before.isEmpty { result.append(.paragraph(before)) }
            result.append(.math(ns.substring(with: match.range(at: 1))))
            cursor = match.range.location + match.range.length
        }
        guard !result.isEmpty else { return [.paragraph(text)] }
        let after = tidy(ns.substring(from: cursor))
        // « , » ou « . » qui suivait la formule : il reste avec elle.
        if !after.isEmpty, after.count > 2 { result.append(.paragraph(after)) }
        return result
    }

    /// « **Exercice.** (3) (Théorème…) Expliquer… » → (« Exercice 3 », le reste).
    static func exerciseLead(_ text: String) -> (String, String)? {
        guard let lead = text.range(of: #"^\*\*Exercice\.?\*\*\s*"#, options: .regularExpression) else { return nil }
        var rest = String(text[lead.upperBound...])
        var label = String(localized: "Exercice")
        if let number = rest.range(of: #"^\((\d+)\)\s*"#, options: .regularExpression) {
            label += " " + rest[number].filter(\.isNumber)
            rest = String(rest[number.upperBound...])
        }
        return (label, rest)
    }

    /// Les exercices d'une série, dans l'ordre (l'exercice *k* est le *k*-ième).
    static func exercises(_ blocks: [BotafogoBlock]) -> [(label: String, blocks: [BotafogoBlock])] {
        blocks.compactMap { block in
            if case .exercise(let label, let content) = block { return (label, content) }
            return nil
        }
    }

    /// Les sections du polycopié citées par un document (la page d'une
    /// semaine liste ce qu'il faut lire), sans doublon, dans l'ordre.
    static func references(_ node: [String: Any]) -> [(target: String, title: String)] {
        var found: [(String, String)] = []
        var seen = Set<String>()
        func walk(_ node: [String: Any]) {
            if tag(node) == "latex-ref", let target = properties(node)["target"] as? String {
                let key = target.lowercased()
                if seen.insert(key).inserted { found.append((target, clean(plain(node)))) }
                return
            }
            for child in children(of: node) { walk(child) }
        }
        walk(node)
        return found
    }

    // MARK: Le lecteur

    private struct Reader {
        var blocks: [BotafogoBlock] = []
        var paragraph = ""

        mutating func flush() {
            let text = BotafogoPage.tidy(paragraph)
            if !text.isEmpty { blocks += BotafogoPage.liftingDisplayMath(text) }
            paragraph = ""
        }

        mutating func finish() -> [BotafogoBlock] {
            flush()
            return blocks
        }

        mutating func append(_ block: BotafogoBlock) {
            flush()
            blocks.append(block)
        }

        mutating func append(contentsOf more: [BotafogoBlock]) {
            flush()
            blocks += more
        }

        mutating func read(_ nodes: [[String: Any]]) {
            for node in nodes { read(node) }
        }

        // swiftlint:disable:next cyclomatic_complexity function_body_length
        mutating func read(_ node: [String: Any]) {
            if (node["type"] as? String) == "text" {
                paragraph += node["value"] as? String ?? ""
                return
            }
            let tag = BotafogoPage.tag(node)
            let props = BotafogoPage.properties(node)
            switch tag {
            // Dans la phrase.
            case "katex-renderer":
                let tex = props["content"] as? String ?? ""
                if props["displayMode"] != nil || props["display"] != nil {
                    // `displayMode: ""` : la présence vaut « oui » (ce n'est pas un booléen).
                    append(.math(tex))
                } else {
                    paragraph += "$" + tex + "$"
                }
            case "b", "strong":
                paragraph += BotafogoPage.wrap(BotafogoPage.inline(node), "**")
            case "em", "i":
                paragraph += BotafogoPage.wrap(BotafogoPage.inline(node), "*")
            case "code":
                paragraph += BotafogoPage.wrap(BotafogoPage.inline(node), "`")
            case "a":
                let text = BotafogoPage.inline(node)
                if let href = props["href"] as? String, !href.isEmpty {
                    paragraph += "[" + (text.isEmpty ? href : text) + "](" + href + ")"
                } else {
                    paragraph += text
                }
            case "latex-ref":
                let text = BotafogoPage.inline(node)
                if let target = props["target"] as? String, !target.isEmpty {
                    paragraph += "[" + (text.isEmpty ? "voir le polycopié" : text) + "](" + BotafogoPage.polyLink(target: target) + ")"
                } else {
                    paragraph += text
                }
            case "span", "u", "small", "sup", "sub":
                paragraph += BotafogoPage.inline(node)
            case "br":
                flush()

            // Des blocs.
            case "p":
                flush()
                read(BotafogoPage.children(of: node))
                flush()
            case "h1", "h2", "h3", "h4", "h5":
                let level = Int(tag.dropFirst()) ?? 3
                append(.heading(BotafogoPage.tidy(BotafogoPage.inline(node)), level: level))
            case "ul", "ol":
                append(list(node, ordered: tag == "ol", columns: 1))
            case "multicols":
                // Des sous-questions courtes, posées en colonnes.
                let columns = BotafogoPage.int(props["cols"]) ?? 2
                let inner = BotafogoPage.slot(node, "default")
                if inner.count(where: { BotafogoPage.tag($0) == "ul" || BotafogoPage.tag($0) == "ol" }) == 1,
                   let list = inner.first(where: { BotafogoPage.tag($0) == "ul" || BotafogoPage.tag($0) == "ol" }) {
                    var rest = inner
                    rest.removeAll { BotafogoPage.tag($0) == "ul" || BotafogoPage.tag($0) == "ol" }
                    read(rest.filter { !BotafogoPage.isBlank($0) })
                    append(self.list(list, ordered: BotafogoPage.tag(list) == "ol", columns: columns))
                } else {
                    read(inner)
                }
            case "img":
                if let source = props["src"] as? String {
                    let width = (props["dataDisplayWidth"] as? String).flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }
                    append(.image(source, width: width))
                }
            case "videokaltura":
                if let id = props["entryId"] as? String {
                    append(.kaltura(id: id, title: props["title"] as? String ?? String(localized: "Vidéo")))
                }
            case "video-player":
                if let source = props["videoSrc"] as? String {
                    append(.video(source: source, poster: props["thumbnailSrc"] as? String, title: props["title"] as? String ?? String(localized: "Vidéo")))
                }
            case "animation":
                if let source = props["src"] as? String {
                    append(.animation(source: source + ".mp4", title: props["title"] as? String ?? "Animation"))
                }
                read(BotafogoPage.slot(node, "default"))
            case "jsxgraph":
                if let script = props["url"] as? String {
                    append(.figure(script, width: BotafogoPage.double(props["width"]), height: BotafogoPage.double(props["height"])))
                }
            case "exercise":
                let (label, content) = BotafogoPage.labelled(BotafogoPage.slot(node, "default"))
                append(.exercise(label: label, content))
            case "solution":
                append(.folded(.solution, title: "Solution", BotafogoPage.blocks(slots: BotafogoPage.slot(node, "default"))))
            case "indication":
                append(.folded(.hint, title: "Indication", BotafogoPage.blocks(slots: BotafogoPage.slot(node, "default"))))
            case "proof", "preuve":
                let title = BotafogoPage.title(node) ?? String(localized: "Preuve")
                append(.folded(.proof, title: title == "Proof" ? String(localized: "Preuve") : title, BotafogoPage.blocks(slots: BotafogoPage.slot(node, "default"))))
            case "reveal":
                append(.folded(.solution, title: BotafogoPage.title(node) ?? "Solution", BotafogoPage.blocks(slots: BotafogoPage.slot(node, "default"))))
            case "inline-popover":
                append(.folded(.aside, title: BotafogoPage.title(node) ?? String(localized: "En savoir plus"), BotafogoPage.blocks(slots: BotafogoPage.slot(node, "default"))))
            case "info":
                append(.aside(title: BotafogoPage.title(node) ?? "", BotafogoPage.blocks(slots: BotafogoPage.slot(node, "default"))))
            case "quiz":
                append(quiz(node))
            case "div":
                let classes = BotafogoPage.classes(node)
                if classes.contains(where: { $0.hasPrefix("amsthm") }) {
                    let (title, content) = BotafogoPage.labelled(BotafogoPage.children(of: node))
                    // Un quiz posé dans un environnement sans titre : le quiz seul, pas une boîte dans une boîte.
                    if title.isEmpty, content.contains(where: { if case .quiz = $0 { return true }; return false }) {
                        append(contentsOf: content)
                    } else {
                        append(.theorem(kind: .from(classes: classes), title: title, content))
                    }
                } else {
                    read(BotafogoPage.children(of: node))
                }
            default:
                // Un conteneur (template, askable, mdframed…) : on lit dedans.
                read(BotafogoPage.slot(node, "default"))
            }
        }

        func list(_ node: [String: Any], ordered: Bool, columns: Int) -> BotafogoBlock {
            let items = BotafogoPage.children(of: node).filter { BotafogoPage.tag($0) == "li" }.map { BotafogoPage.blocks(slots: BotafogoPage.children(of: $0)) }
            return .list(items, ordered: ordered, columns: columns)
        }

        func quiz(_ node: [String: Any]) -> BotafogoBlock {
            let title = BotafogoPage.title(node) ?? "Quiz"
            let body = BotafogoPage.slot(node, "default")
            var choices: [BotafogoQuizChoice] = []
            var columns = 1
            var promptNodes: [[String: Any]] = []
            func collect(_ nodes: [[String: Any]]) {
                for child in nodes {
                    switch BotafogoPage.tag(child) {
                    case "choices":
                        columns = BotafogoPage.int(BotafogoPage.properties(child)["cols"]) ?? 1
                        collect(BotafogoPage.slot(child, "default"))
                    case "correct-choice", "wrong-choice":
                        let text = BotafogoPage.tidy(BotafogoPage.inlineSlot(child, "text"))
                        let fallback = BotafogoPage.properties(child)["text"] as? String ?? ""
                        choices.append(BotafogoQuizChoice(text: text.isEmpty ? fallback : text,
                                                          correct: BotafogoPage.tag(child) == "correct-choice"))
                    case "explanation":
                        // L'explication suit le choix qu'elle commente.
                        let text = BotafogoPage.tidy(BotafogoPage.inlineSlot(child, "text"))
                        if !choices.isEmpty, !text.isEmpty { choices[choices.count - 1].explanation = text }
                    case "template":
                        collect(BotafogoPage.slot(child, "default"))
                    default:
                        if choices.isEmpty { promptNodes.append(child) }
                    }
                }
            }
            collect(body)
            return .quiz(title: title, prompt: BotafogoPage.blocks(slots: promptNodes), choices: choices, columns: columns)
        }
    }

    // MARK: Outils

    static func blocks(slots nodes: [[String: Any]]) -> [BotafogoBlock] {
        var reader = Reader()
        reader.read(nodes)
        return reader.finish()
    }

    static func tag(_ node: [String: Any]) -> String { node["tagName"] as? String ?? "" }
    static func properties(_ node: [String: Any]) -> [String: Any] { node["properties"] as? [String: Any] ?? [:] }

    static func classes(_ node: [String: Any]) -> [String] {
        let value = properties(node)["className"]
        if let list = value as? [String] { return list }
        if let text = value as? String { return text.split(separator: " ").map(String.init) }
        return []
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        if let number = value as? Double { return Int(number) }
        return nil
    }

    /// Les enfants d'un élément ; ceux d'un `template` sont dans `content`.
    static func children(of node: [String: Any]) -> [[String: Any]] {
        var result = node["children"] as? [[String: Any]] ?? []
        if let content = node["content"] as? [String: Any] { result += content["children"] as? [[String: Any]] ?? [] }
        return result
    }

    /// Le contenu d'un emplacement nommé (`#default`, `#title`, `#text`). Un
    /// élément sans gabarit est son propre contenu (emplacement par défaut).
    static func slot(_ node: [String: Any], _ name: String) -> [[String: Any]] {
        let direct = node["children"] as? [[String: Any]] ?? []
        let templates = direct.filter { tag($0) == "template" }
        if let match = templates.first(where: { properties($0)["#" + name] != nil }) {
            return children(of: match)
        }
        guard name == "default" else { return [] }
        if templates.isEmpty { return children(of: node) }
        // Des gabarits sans nom reconnu : tout sauf le titre.
        return templates.filter { properties($0)["#title"] == nil }.flatMap { children(of: $0) }
            + direct.filter { tag($0) != "template" }
    }

    /// Le titre d'un composant : son emplacement `#title`, sinon sa propriété.
    static func title(_ node: [String: Any]) -> String? {
        let fromSlot = tidy(slot(node, "title").map(inline).joined())
            .replacingOccurrences(of: "**", with: "")
        if !fromSlot.isEmpty { return fromSlot }
        return (properties(node)["title"] as? String).map(tidy).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Un exercice ou un théorème commence par son étiquette en gras
    /// (« Ex-5-3: », « Théorème 3.4 (Deux gendarmes) ») : on la sépare.
    static func labelled(_ nodes: [[String: Any]]) -> (String, [BotafogoBlock]) {
        var rest = nodes
        while let first = rest.first, isBlank(first) { rest.removeFirst() }
        guard let first = rest.first, ["b", "strong"].contains(tag(first)) else { return ("", blocks(slots: nodes)) }
        rest.removeFirst()
        var label = tidy(inline(first)).replacingOccurrences(of: "**", with: "")
        while label.hasSuffix(":") || label.hasSuffix(".") { label.removeLast() }
        // « Théorème 3.4. » puis le texte : le point qui suit l'étiquette part avec elle.
        if let next = rest.first, (next["type"] as? String) == "text",
           let value = next["value"] as? String, value.trimmingCharacters(in: .whitespaces).hasPrefix(".") {
            var trimmed = value.trimmingCharacters(in: .whitespaces)
            trimmed.removeFirst()
            rest[0]["value"] = trimmed
        }
        return (label.trimmingCharacters(in: .whitespaces), blocks(slots: rest))
    }

    /// Le texte d'un élément dans la phrase (gras, italique, formules, liens).
    static func inline(_ node: [String: Any]) -> String {
        inline(children: children(of: node))
    }

    static func inlineSlot(_ node: [String: Any], _ name: String) -> String {
        inline(children: slot(node, name))
    }

    private static func inline(children nodes: [[String: Any]]) -> String {
        var reader = Reader()
        for node in nodes { reader.read(node) }
        // Une phrase : les blocs éventuels sont remis bout à bout.
        let blocks = reader.finish()
        return blocks.map { block -> String in
            switch block {
            case .paragraph(let text): return text
            case .math(let tex): return "$" + tex + "$"
            case .heading(let text, _): return text
            default: return ""
            }
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func plain(_ node: [String: Any]) -> String {
        if (node["type"] as? String) == "text" { return node["value"] as? String ?? "" }
        return children(of: node).map(plain).joined()
    }

    static func isBlank(_ node: [String: Any]) -> Bool {
        (node["type"] as? String) == "text" && (node["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func wrap(_ text: String, _ marker: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        // Les espaces restent dehors : `**gras** suite`, pas `** gras**`.
        let leading = text.hasPrefix(" ") ? " " : ""
        let trailing = text.hasSuffix(" ") ? " " : ""
        return leading + marker + trimmed + marker + trailing
    }

    static func clean(_ text: String) -> String { tidy(text) }

    /// Les espaces du HTML ramenés à un seul.
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - En texte, pour Claude

extension BotafogoPage {
    /// Un document en Markdown léger (formules entre `$…$` et `$$…$$`), pour le
    /// contexte de Claude : l'énoncé tel que le site le montre. Les solutions
    /// et indications du site y sont, marquées : Claude s'en sert pour
    /// vérifier, sans les révéler en mode tuteur.
    static func text(_ blocks: [BotafogoBlock]) -> String {
        var lines: [String] = []
        func walk(_ blocks: [BotafogoBlock], indent: String) {
            for block in blocks {
                switch block {
                case .paragraph(let text): lines.append(indent + text)
                case .heading(let text, _): lines.append(indent + "## " + text)
                case .math(let tex): lines.append(indent + "$$" + tex + "$$")
                case .list(let items, let ordered, _):
                    for (index, item) in items.enumerated() {
                        let marker = ordered ? "\(index + 1). " : "- "
                        var sub: [String] = []
                        let saved = lines
                        lines = []
                        walk(item, indent: "")
                        sub = lines
                        lines = saved
                        if let first = sub.first { lines.append(indent + marker + first) }
                        lines += sub.dropFirst().map { indent + "   " + $0 }
                    }
                case .image: lines.append(indent + "[figure]")
                case .figure: lines.append(indent + "[figure interactive]")
                case .video(_, _, let title), .kaltura(_, let title): lines.append(indent + "[vidéo : \(title)]")
                case .animation(_, let title): lines.append(indent + "[animation : \(title)]")
                case .theorem(_, let title, let content), .aside(let title, let content):
                    if !title.isEmpty { lines.append(indent + "**" + title + "**") }
                    walk(content, indent: indent)
                case .exercise(let label, let content):
                    lines.append(indent + "**" + label + "**")
                    walk(content, indent: indent)
                case .folded(let fold, let title, let content):
                    let tag: String
                    switch fold {
                    case .solution: tag = "Solution officielle (ne pas révéler en mode tuteur)"
                    case .hint: tag = "Indication du site"
                    case .proof: tag = title.isEmpty ? "Preuve" : title
                    case .aside: tag = title.isEmpty ? "Remarque" : title
                    }
                    lines.append(indent + "<" + tag + ">")
                    walk(content, indent: indent + "  ")
                    lines.append(indent + "</" + tag + ">")
                case .quiz(let title, let prompt, let choices, _):
                    lines.append(indent + "**" + (title.isEmpty ? "Quiz" : title) + "**")
                    walk(prompt, indent: indent)
                    for choice in choices {
                        lines.append(indent + "- " + choice.text + (choice.correct ? " (juste)" : ""))
                    }
                }
            }
        }
        walk(blocks, indent: "")
        return lines.joined(separator: "\n")
    }
}

extension BotafogoPage {
    /// Un quiz d'un document, avec ce qui le précède dans son exercice.
    struct Quiz: Equatable {
        var title: String
        var prompt: [BotafogoBlock]
        var choices: [BotafogoQuizChoice]
        var columns: Int
    }

    /// Tous les quiz d'un document, où qu'ils soient (dans un exercice, un encadré).
    static func quizzes(_ blocks: [BotafogoBlock]) -> [Quiz] {
        blocks.flatMap { block -> [Quiz] in
            switch block {
            case .quiz(let title, let prompt, let choices, let columns):
                return choices.isEmpty ? [] : [Quiz(title: title, prompt: prompt, choices: choices, columns: columns)]
            case .exercise(_, let inner), .theorem(_, _, let inner), .aside(_, let inner), .folded(_, _, let inner):
                return quizzes(inner)
            case .list(let items, _, _):
                return items.flatMap(quizzes)
            default:
                return []
            }
        }
    }
}
