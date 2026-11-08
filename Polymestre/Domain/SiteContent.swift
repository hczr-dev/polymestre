import Foundation

/// Les sites du cours lus **en natif** dans le mode étude : une page Moodle,
/// un texte de Courseware, une vidéo MediaSpace. Ici, ce qui est pur — le HTML
/// découpé en blocs, l'aiguillage d'un lien, l'adresse d'une vidéo Kaltura ou
/// edX, les réponses des scripts Moodle. Testé dans `validate.sh`.

// MARK: - Blocs

/// Un morceau de page à afficher : du texte (Markdown léger, que `RichMarkup`
/// sait mettre en page, formules comprises), une image, un fichier, une vidéo,
/// un lien.
enum SiteBlock: Equatable {
    case markdown(String)
    case image(String)
    case file(title: String, url: String)
    case video(title: String, url: String)
    case link(title: String, url: String)
}

enum SiteHTML {

    /// Un texte brut qui est du Markdown : plusieurs lignes, dont au moins un
    /// titre, une liste, un bloc de code ou une citation.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }
        let structural = lines.filter {
            $0.range(of: #"^(#{1,6} |[-*+] |\d+[.)] |```|> )"#, options: .regularExpression) != nil
        }
        return !structural.isEmpty
    }

    /// Retire l'indentation commune (le texte est souvent indenté comme le HTML autour).
    static func dedent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.prefix { $0 == " " || $0 == "\t" }.count))) }
            .joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// Une page HTML → des blocs. `base` résout les adresses relatives.
    static func blocks(_ html: String, base: URL? = nil) -> [SiteBlock] {
        var parser = Parser(base: base)
        parser.run(html)
        return parser.finish()
    }

    private struct Parser {
        let base: URL?
        var blocks: [SiteBlock] = []
        var paragraph = ""
        /// Les éléments ouverts dont on ignore le contenu (script, style…).
        var skipping: [String] = []
        var lists: [(ordered: Bool, count: Int)] = []
        var link: (href: String, text: String)?
        var pendingLinks: [SiteBlock] = []
        var pre: String?
        var cells: [String]?
        var cell: String?
        var heading: Int?

        init(base: URL?) { self.base = base }

        mutating func run(_ html: String) {
            var index = html.startIndex
            while index < html.endIndex {
                if html[index] == "<" {
                    // Commentaire.
                    if html[index...].hasPrefix("<!--") {
                        if let end = html.range(of: "-->", range: index..<html.endIndex) { index = end.upperBound } else { break }
                        continue
                    }
                    guard let close = html[index...].firstIndex(of: ">") else { text(String(html[index...])); break }
                    tag(String(html[html.index(after: index)..<close]))
                    index = html.index(after: close)
                } else {
                    let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                    text(String(html[index..<next]))
                    index = next
                }
            }
        }

        mutating func finish() -> [SiteBlock] {
            flush()
            return blocks
        }

        // MARK: Texte

        mutating func text(_ raw: String) {
            guard skipping.isEmpty else { return }
            let decoded = BotafogoParser.decode(raw)
            if pre != nil { pre! += decoded; return }
            // Un texte écrit en Markdown (titres, listes, liens sur plusieurs
            // lignes) : ses retours à la ligne portent la mise en page, on le
            // garde tel quel au lieu de tout mettre bout à bout.
            if cell == nil, link == nil, heading == nil, SiteHTML.looksLikeMarkdown(decoded) {
                flush()
                blocks.append(.markdown(SiteHTML.dedent(decoded)))
                return
            }
            let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if cell != nil { cell! += collapsed; return }
            if link != nil { link!.text += collapsed }
            append(collapsed)
        }

        mutating func append(_ piece: String) {
            if paragraph.isEmpty || paragraph.hasSuffix(" ") || paragraph.hasSuffix("\n") {
                paragraph += piece.drop { $0 == " " }
            } else {
                paragraph += piece
            }
        }

        /// Le paragraphe en cours devient un bloc (avec ses liens, après lui).
        mutating func flush() {
            // Les balises vides (`<h3></h3>`, `<strong></strong>`, fréquentes sur
            // Courseware) ne laissent ni « #### » ni « **** » à l'écran.
            let lines = paragraph.components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: "****", with: "").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.range(of: #"^[#*_\s]+$"#, options: .regularExpression) == nil }
            if !lines.isEmpty {
                let text = lines.joined(separator: "\n")
                if case .markdown(let previous)? = blocks.last, isListLine(previous), isListLine(text) {
                    blocks[blocks.count - 1] = .markdown(previous + "\n" + text)
                } else {
                    blocks.append(.markdown(text))
                }
            }
            paragraph = ""
            blocks += pendingLinks
            pendingLinks = []
        }

        private func isListLine(_ text: String) -> Bool {
            let first = text.trimmingCharacters(in: .whitespaces)
            return first.hasPrefix("- ") || first.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        }

        // MARK: Balises

        mutating func tag(_ raw: String) {
            let closing = raw.hasPrefix("/")
            let body = closing ? String(raw.dropFirst()) : raw
            let name = body.prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }.lowercased()
            guard !name.isEmpty else { return }
            let attributes = closing ? [:] : Self.attributes(body)
            let ignored: Set<String> = ["script", "style", "head", "noscript", "button", "select", "textarea", "svg", "nav"]
            if name == "a", closing, skipping.last == "a" { skipping.removeLast(); return }
            if ignored.contains(name) {
                if closing { if let last = skipping.lastIndex(of: name) { skipping.remove(at: last) } }
                else if !raw.hasSuffix("/") { skipping.append(name) }
                return
            }
            guard skipping.isEmpty else { return }
            // Les formules MathJax rendues : on garde le TeX de la balise script, déjà ignorée ;
            // les spans de MathJax n'ajoutent que du texte en double.
            if !closing, (attributes["class"] ?? "").contains("MathJax") || attributes["aria-hidden"] == "true" {
                return
            }
            switch name {
            case "p", "div", "section", "article", "blockquote", "dl", "dt", "dd", "figure", "figcaption", "center", "main", "header", "footer":
                // `<li><p>texte</p></li>` : la puce attend son texte.
                if cell == nil, !paragraph.trimmingCharacters(in: .whitespaces).isBareListMarker { flush() }
            case "br":
                if pre != nil { pre! += "\n" } else if cell != nil { cell! += " " } else { paragraph += "\n" }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                if !closing {
                    let level = min(4, (Int(name.dropFirst()) ?? 2) + 1)
                    paragraph = String(repeating: "#", count: level) + " "
                    heading = level
                } else {
                    heading = nil
                    flush()
                }
            case "strong", "b":
                if heading == nil, cell == nil { paragraph += "**" }
            case "em", "i":
                if heading == nil, cell == nil, !(attributes["class"] ?? "").contains("icon"), !(attributes["class"] ?? "").contains("fa") {
                    paragraph += "*"
                }
            case "ul", "ol":
                flush()
                if closing { _ = lists.popLast() } else { lists.append((name == "ol", 0)) }
            case "li":
                flush()
                if !closing, !lists.isEmpty {
                    lists[lists.count - 1].count += 1
                    let current = lists[lists.count - 1]
                    paragraph = String(repeating: "  ", count: max(0, lists.count - 1)) + (current.ordered ? "\(current.count). " : "- ")
                }
            case "a":
                if closing {
                    if let open = link { finishLink(open) }
                    link = nil
                } else if let href = attributes["href"] {
                    // « Passer au contenu principal » et autres ancres de la page.
                    if href.hasPrefix("#") || (attributes["class"] ?? "").contains("skip") { skipping.append("a"); return }
                    link = (href, "")
                }
            case "img":
                guard !closing, let source = attributes["src"].flatMap(resolve) else { return }
                if (attributes["class"] ?? "").contains("icon") || source.contains("/theme/image.php") { return }
                flush()
                blocks.append(.image(source))
            case "iframe", "video", "source", "embed":
                guard !closing, let source = attributes["src"].flatMap(resolve) else { return }
                let route = SiteRouter.route(source)
                flush()
                switch route {
                case .mediaspace, .youtube, .video:
                    blocks.append(.video(title: attributes["title"] ?? String(localized: "Vidéo"), url: source))
                default:
                    blocks.append(.link(title: attributes["title"] ?? String(localized: "Contenu intégré"), url: source))
                }
            case "pre":
                if closing {
                    let code = (pre ?? "").trimmingCharacters(in: .newlines)
                    pre = nil
                    if !code.isEmpty { flush(); blocks.append(.markdown("```\n" + code + "\n```")) }
                } else {
                    flush()
                    pre = ""
                }
            case "tr":
                if closing {
                    if let row = cells, !row.isEmpty {
                        flush()
                        let line = "- " + row.joined(separator: " · ")
                        if case .markdown(let previous)? = blocks.last, previous.hasPrefix("- ") {
                            blocks[blocks.count - 1] = .markdown(previous + "\n" + line)
                        } else {
                            blocks.append(.markdown(line))
                        }
                    }
                    cells = nil
                } else {
                    flush()
                    cells = []
                }
            case "td", "th":
                if closing {
                    let value = (cell ?? "").trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { cells?.append(value) }
                    cell = nil
                } else {
                    cell = ""
                }
            default:
                break
            }
        }

        mutating func finishLink(_ open: (href: String, text: String)) {
            guard let url = resolve(open.href) else { return }
            let title = open.text.trimmingCharacters(in: .whitespaces)
            switch SiteRouter.route(url) {
            case .pdf, .file:
                pendingLinks.append(.file(title: title.isEmpty ? "Document" : title, url: url))
            case .mediaspace, .youtube, .video:
                pendingLinks.append(.video(title: title.isEmpty ? String(localized: "Vidéo") : title, url: url))
            case .web where title.isEmpty:
                break
            default:
                pendingLinks.append(.link(title: title.isEmpty ? url : title, url: url))
            }
        }

        func resolve(_ raw: String) -> String? {
            let value = BotafogoParser.decode(raw.trimmingCharacters(in: .whitespaces))
            guard !value.isEmpty, !value.hasPrefix("#"), !value.lowercased().hasPrefix("javascript:"),
                  !value.lowercased().hasPrefix("mailto:"), !value.hasPrefix("data:") else { return nil }
            if let base, let url = URL(string: value, relativeTo: base) { return url.absoluteString }
            return URL(string: value)?.scheme == nil ? nil : value
        }

        static func attributes(_ body: String) -> [String: String] {
            var result: [String: String] = [:]
            guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#) else { return result }
            let range = NSRange(body.startIndex..., in: body)
            for match in regex.matches(in: body, range: range) {
                guard let name = Range(match.range(at: 1), in: body) else { continue }
                let value = [2, 3, 4].compactMap { Range(match.range(at: $0), in: body) }.first.map { String(body[$0]) } ?? ""
                result[body[name].lowercased()] = value
            }
            return result
        }
    }
}

// MARK: - Aiguillage

/// Où mène un lien, pour l'ouvrir en natif.
enum SiteRouter {
    enum Destination: Equatable {
        case pdf
        /// Un autre fichier (diapositives, archive, code) : aperçu natif.
        case file
        case moodle(module: String, id: Int)
        case botafogo
        /// Une vidéo MediaSpace (Kaltura), par son identifiant.
        case mediaspace(entryID: String)
        case courseware(courseKey: String)
        case youtube(id: String)
        /// Un fichier vidéo ou un flux (mp4, m3u8).
        case video
        case geogebra
        case web
    }

    static func route(_ address: String) -> Destination {
        guard let url = URL(string: address), let host = url.host?.lowercased() else { return .web }
        let path = url.path.lowercased()
        if path.hasSuffix(".pdf") { return .pdf }
        if path.hasSuffix(".mp4") || path.hasSuffix(".m3u8") || path.hasSuffix(".mov") || path.hasSuffix(".webm") { return .video }
        let school = Institution.current
        if let moodle = school.moodleHost, host.hasSuffix(moodle) {
            if path.contains("/pluginfile.php/") { return path.hasSuffix(".pdf") || !path.contains(".") ? .pdf : .file }
            if let module = path.range(of: #"/mod/([a-z]+)/view\.php"#, options: .regularExpression).map({ String(path[$0]) })?
                .split(separator: "/").dropFirst().first.map(String.init),
               let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init) {
                return module == "resource" ? .pdf : .moodle(module: module, id: id)
            }
            return .web
        }
        if let botafogo = school.extras["botafogo"].flatMap({ URL(string: $0)?.host }), host.hasSuffix(botafogo) { return .botafogo }
        let videoHosts = [school.video?.host, school.video.flatMap { URL(string: $0.kalturaAPI)?.host }].compactMap { $0 }
        if videoHosts.contains(where: { host.hasSuffix($0) }) || host.contains("kaltura") || host.hasSuffix("cast.switch.ch") {
            if let id = kalturaEntry(in: address) { return .mediaspace(entryID: id) }
            return .web
        }
        if school.coursewareHost.map({ host.hasSuffix($0) }) == true || host.hasSuffix("learning.edx.org") {
            if let key = MoocReference.courseKey(in: address) { return .courseware(courseKey: key) }
            return .web
        }
        if host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("youtube-nocookie.com") {
            if let id = youTubeID(url) { return .youtube(id: id) }
            return .web
        }
        if host.hasSuffix("geogebra.org") { return .geogebra }
        let documents = [".pptx", ".ppt", ".docx", ".doc", ".xlsx", ".zip", ".ipynb", ".py", ".m", ".txt", ".csv", ".key", ".pages"]
        if documents.contains(where: { path.hasSuffix($0) }) { return .file }
        return .web
    }

    /// L'identifiant Kaltura d'une adresse (« 0_6y8w1d2s »), le dernier trouvé.
    static func kalturaEntry(in link: String) -> String? {
        let decoded = link.removingPercentEncoding ?? link
        guard let regex = try? NSRegularExpression(pattern: #"(?:[/=]|entry_?id[/=])([01]_[a-z0-9]{8})(?=[/?#&]|$)"#,
                                                   options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded))
        return matches.last.flatMap { Range($0.range(at: 1), in: decoded).map { String(decoded[$0]) } }
    }

    static func youTubeID(_ url: URL) -> String? {
        if url.host == "youtu.be" { return url.pathComponents.dropFirst().first }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "v" }), index + 1 < parts.count { return parts[index + 1] }
        return nil
    }
}

// MARK: - Kaltura (MediaSpace)

/// MediaSpace EPFL est un Kaltura hébergé par SWITCH (`api.cast.switch.ch`,
/// partenaire 113). Une vidéo publique se lit par son manifeste HLS ; une vidéo
/// réservée demande en plus la clé de session (`ks`) de la page MediaSpace,
/// lue dans la session de l'étudiant·e. Vérifié : le manifeste d'une vidéo
/// publique répond `#EXTM3U` sans clé.
enum Kaltura {
    /// Le partenaire et l'API de l'école (EPFL : 113 chez SWITCH).
    static var defaultPartner: Int { Institution.current.video?.kalturaPartner ?? 113 }
    static var host: String { Institution.current.video?.kalturaAPI ?? "https://api.cast.switch.ch" }

    static func manifestURL(entryID: String, partnerID: Int = defaultPartner, ks: String? = nil) -> URL? {
        var path = "\(host)/p/\(partnerID)/sp/\(partnerID)00/playManifest/entryId/\(entryID)/format/applehttp/protocol/https"
        if let ks, !ks.isEmpty { path += "/ks/\(ks)" }
        return URL(string: path + "/a.m3u8")
    }

    /// Le partenaire et la clé de session d'une page MediaSpace.
    static func config(html: String) -> (partnerID: Int?, ks: String?) {
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        let partner = first(#""partnerId"\s*:\s*"?(\d+)"#) ?? first(#"partnerId=(\d+)"#) ?? first(#"/p/(\d+)/"#)
        let ks = first(#""ks"\s*:\s*"([A-Za-z0-9_\-=]{20,})""#)
        return (partner.flatMap(Int.init), ks)
    }

    /// Un manifeste HLS lisible (et pas une page d'erreur).
    static func isPlayableManifest(_ text: String) -> Bool {
        text.hasPrefix("#EXTM3U") && text.contains("#EXT-X-")
    }
}

// MARK: - Courseware (Open edX)

/// Le plan d'un cours Open edX (`/api/courses/v2/blocks/`) : chapitres,
/// séquences, unités, et dans chaque unité ses blocs (vidéo, texte, problème).
struct EdXOutline: Equatable {
    struct Unit: Equatable, Identifiable {
        var id: String
        var title: String
        var blocks: [Block]
        /// Achevée selon Courseware (`completion` = 1).
        var completed: Bool = false
    }
    struct Sequence: Equatable, Identifiable {
        var id: String
        var title: String
        var units: [Unit]
    }
    struct Chapter: Equatable, Identifiable {
        var id: String
        var title: String
        var sequences: [Sequence]
    }
    struct Block: Equatable, Identifiable {
        enum Kind: Equatable { case video, html, problem, other(String) }
        var id: String
        var title: String
        var kind: Kind
        /// Le contenu seul du bloc (`student_view_url`).
        var viewURL: String?
        /// Vidéo : la meilleure source (HLS, puis mp4), ou YouTube.
        var videoURL: String?
        var youTubeID: String?
        /// Vidéo : ses transcriptions (la langue préférée d'abord).
        var transcripts: [String] = []
        /// Vidéo : sa durée en secondes, quand Courseware la donne.
        var duration: Double?
    }

    var chapters: [Chapter]

    /// Toutes les unités, dans l'ordre du cours (pour « précédente / suivante »).
    var units: [Unit] { chapters.flatMap { $0.sequences.flatMap(\.units) } }

    /// Où se trouve une unité : son chapitre et sa séquence.
    func place(of unitID: String) -> (chapter: Chapter, sequence: Sequence)? {
        for chapter in chapters {
            for sequence in chapter.sequences where sequence.units.contains(where: { $0.id == unitID }) { return (chapter, sequence) }
        }
        return nil
    }

    /// Où reprendre : la première unité non faite **après** la dernière faite
    /// (les pages d'accueil jamais « achevées » ne ramènent pas au début).
    var resumeUnit: Unit? {
        let all = units
        guard let last = all.lastIndex(where: \.completed) else { return all.first }
        return all[(last + 1)...].first { !$0.completed } ?? all.first { !$0.completed } ?? all.last
    }

    static func parse(json: Data) -> EdXOutline? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let root = object["root"] as? String,
              let blocks = object["blocks"] as? [String: [String: Any]] else { return nil }
        func children(_ id: String) -> [String] { blocks[id]?["children"] as? [String] ?? [] }
        func title(_ id: String) -> String { BotafogoParser.decode(blocks[id]?["display_name"] as? String ?? "") }
        func block(_ id: String) -> Block {
            let raw = blocks[id] ?? [:]
            let type = raw["type"] as? String ?? ""
            let kind: Block.Kind = type == "video" ? .video : type == "html" ? .html : type == "problem" ? .problem : .other(type)
            var video: String?
            var youTube: String?
            var transcripts: [String] = []
            var duration: Double?
            if let data = raw["student_view_data"] as? [String: Any] {
                video = bestVideo(data)
                transcripts = CoursewareTranscripts.transcriptURLs(data)
                duration = (data["duration"] as? Double).flatMap { $0 > 0 ? $0 : nil }
                youTube = (data["encoded_videos"] as? [String: Any])?["youtube"].flatMap { ($0 as? [String: Any])?["url"] as? String }
                    .flatMap(URL.init(string:)).flatMap(SiteRouter.youTubeID)
            }
            return Block(id: id, title: title(id), kind: kind, viewURL: raw["student_view_url"] as? String, videoURL: video, youTubeID: youTube,
                         transcripts: transcripts, duration: duration)
        }
        let chapters = children(root).map { chapterID in
            Chapter(id: chapterID, title: title(chapterID), sequences: children(chapterID).map { sequenceID in
                Sequence(id: sequenceID, title: title(sequenceID), units: children(sequenceID).map { unitID in
                    Unit(id: unitID, title: title(unitID), blocks: children(unitID).map(block),
                         completed: (blocks[unitID]?["completion"] as? Double ?? 0) >= 1)
                })
            })
        }
        return EdXOutline(chapters: chapters)
    }

    /// HLS d'abord (qualité adaptée), puis le mp4 le plus grand, puis le reste.
    static func bestVideo(_ data: [String: Any]) -> String? {
        let encoded = data["encoded_videos"] as? [String: Any] ?? [:]
        for key in ["hls", "desktop_mp4", "fallback", "mobile_high", "mobile_low"] {
            if let url = (encoded[key] as? [String: Any])?["url"] as? String, !url.isEmpty { return url }
        }
        let sources = data["all_sources"] as? [String] ?? []
        return sources.first { $0.contains(".m3u8") } ?? sources.first { $0.contains(".mp4") } ?? sources.first
    }
}

// MARK: - Moodle

/// Ce que les scripts de lecture d'une activité Moodle rendent (JSON).
struct MoodleActivityContent: Codable, Equatable {
    struct File: Codable, Equatable {
        var name: String
        var url: String
    }
    struct Post: Codable, Equatable {
        var subject: String
        var author: String
        var date: String
        var html: String
    }
    struct Discussion: Codable, Equatable {
        var id: Int
        var title: String
        var author: String
        var date: String
    }

    var module: String
    var title: String
    /// Le corps (page, consignes d'un devoir, description d'un dossier).
    var html: String = ""
    var files: [File] = []
    /// Devoir : « Ouvert le… », « À rendre le… ».
    var dates: [String] = []
    /// Devoir : l'état de la remise, ligne par ligne (« Statut : Aucune remise »).
    var status: [String] = []
    /// Lien : où il mène vraiment.
    var target: String?
    var discussions: [Discussion] = []
    var posts: [Post] = []
    /// Le script est tombé sur la page de connexion.
    var needsLogin: Bool = false
    /// Moodle refuse de montrer l'activité (pas encore ouverte, cachée) : il
    /// renvoie vers la page du cours. Sans ce drapeau, on lisait **la page du
    /// cours** comme si c'était l'activité — le titre du cours, la description
    /// de la première activité, son lien.
    var unavailable: Bool = false
    /// Ce que Moodle en dit (« Disponible à partir du 17 octobre »), s'il le dit.
    var notice: String?

    static func decode(_ json: String) -> MoodleActivityContent? {
        try? JSONDecoder().decode(MoodleActivityContent.self, from: Data(json.utf8))
    }

    init(module: String, title: String, html: String = "", files: [File] = [], dates: [String] = [], status: [String] = [],
         target: String? = nil, discussions: [Discussion] = [], posts: [Post] = [], needsLogin: Bool = false,
         unavailable: Bool = false, notice: String? = nil) {
        self.module = module
        self.title = title
        self.html = html
        self.files = files
        self.dates = dates
        self.status = status
        self.target = target
        self.discussions = discussions
        self.posts = posts
        self.needsLogin = needsLogin
        self.unavailable = unavailable
        self.notice = notice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        module = try c.decodeIfPresent(String.self, forKey: .module) ?? ""
        title = BotafogoParser.decode(try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        html = try c.decodeIfPresent(String.self, forKey: .html) ?? ""
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        dates = try c.decodeIfPresent([String].self, forKey: .dates) ?? []
        status = try c.decodeIfPresent([String].self, forKey: .status) ?? []
        target = try c.decodeIfPresent(String.self, forKey: .target)
        discussions = try c.decodeIfPresent([Discussion].self, forKey: .discussions) ?? []
        posts = try c.decodeIfPresent([Post].self, forKey: .posts) ?? []
        needsLogin = try c.decodeIfPresent(Bool.self, forKey: .needsLogin) ?? false
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        notice = try c.decodeIfPresent(String.self, forKey: .notice).flatMap { $0.isEmpty ? nil : BotafogoParser.decode($0) }
    }
}

// MARK: - Botafogo

/// Les figures interactives de Botafogo (JSXGraph) : le site publie une image
/// fixe à côté de chaque script (`/media/jsxgraph/jsx_suite.js` →
/// `…/jsx_suite.png`, vérifié sur analyse-1-GM). On montre l'image, sans web.
enum BotafogoFigure {
    static func imagePath(script: String) -> String {
        let trimmed = script.split(separator: "?").first.map(String.init) ?? script
        guard trimmed.lowercased().hasSuffix(".js") else { return trimmed + ".png" }
        return String(trimmed.dropLast(3)) + ".png"
    }
}

// MARK: - Ed Discussion

/// Ed Discussion (edstem.org, région EU), lu en natif. Observé dans le code de
/// la page (`edcdn.net`) : l'API est `https://eu.edstem.org/api`, le jeton est
/// gardé dans le `localStorage` de la page (`authToken`) et envoyé dans l'en-tête
/// `X-Token` ; sans lui, `/api/user` répond 401. Les routes des fils
/// (`courses/<id>/threads`, `threads/<id>?view=1`) sont celles du client
/// public `edapi` — déduites, pas observées dans le code chargé à la connexion.
enum EdDiscussion {
    struct Course: Codable, Equatable, Identifiable {
        var id: Int
        var code: String
        var name: String
    }

    struct Thread: Codable, Equatable, Identifiable {
        var id: Int
        var number: Int?
        var title: String
        var category: String?
        var type: String?
        var isPinned: Bool?
        var isAnswered: Bool?
        var replyCount: Int?
        var createdAt: String?
        /// Le texte en clair (aperçu), sans mise en forme.
        var document: String?

        enum CodingKeys: String, CodingKey {
            case id, number, title, category, type, document
            case isPinned = "is_pinned", isAnswered = "is_answered", replyCount = "reply_count", createdAt = "created_at"
        }
    }

    /// Un message (le fil lui-même, une réponse, un commentaire), avec ses réponses.
    struct Post: Equatable {
        /// L'identifiant du fil (racine) ou du commentaire : pour y répondre.
        var id: Int = 0
        var author: String
        var date: String
        /// Le contenu au format d'Ed (XML `<document>`).
        var content: String
        var isAnswer: Bool
        var isEndorsed: Bool
        var replies: [Post]
    }

    /// `GET /api/user` → les cours où l'on est inscrit·e.
    static func courses(userJSON: Data) -> [Course] {
        guard let object = try? JSONSerialization.jsonObject(with: userJSON) as? [String: Any],
              let rows = object["courses"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let course = row["course"] as? [String: Any] ?? row
            guard let id = course["id"] as? Int else { return nil }
            return Course(id: id, code: course["code"] as? String ?? "", name: course["name"] as? String ?? "")
        }
    }

    /// `GET /api/courses/<id>/threads` → les fils.
    static func threads(json: Data) -> [Thread] {
        struct Reply: Decodable { var threads: [Thread] }
        return (try? JSONDecoder().decode(Reply.self, from: json))?.threads ?? []
    }

    /// `GET /api/threads/<id>?view=1` → le fil, ses réponses et leurs
    /// commentaires, avec le nom des auteurs (`users`).
    static func thread(json: Data) -> Post? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let thread = object["thread"] as? [String: Any] else { return nil }
        var names: [Int: String] = [:]
        for user in object["users"] as? [[String: Any]] ?? [] {
            if let id = user["id"] as? Int { names[id] = user["name"] as? String ?? "" }
        }
        func post(_ raw: [String: Any], answer: Bool) -> Post {
            let author = (raw["user_id"] as? Int).flatMap { names[$0] } ?? ((raw["is_anonymous"] as? Bool) == true ? String(localized: "Anonyme") : "")
            let replies = (raw["comments"] as? [[String: Any]] ?? []).map { post($0, answer: false) }
            return Post(id: raw["id"] as? Int ?? 0, author: author.isEmpty ? String(localized: "Anonyme") : author, date: raw["created_at"] as? String ?? "",
                        content: raw["content"] as? String ?? "", isAnswer: answer,
                        isEndorsed: (raw["is_endorsed"] as? Bool) == true, replies: replies)
        }
        var root = post(thread, answer: false)
        let answers = (thread["answers"] as? [[String: Any]] ?? []).map { post($0, answer: true) }
        root.replies = answers + root.replies
        return root
    }

    // MARK: Sondages (observé : `<poll id="3230"/>` dans le message,
    // `GET polls/<id>` → `{poll}`, `POST polls/<id>/responses {option_indices}`)

    /// Un sondage d'Ed (« Cochez les équations linéaires », les votes de la classe).
    struct Poll: Equatable {
        var id: Int
        /// La question, au format d'Ed.
        var question: String
        var options: [String]
        /// Les votes par option (absents tant qu'Ed ne les montre pas).
        var counts: [Int]
        var multipleChoice: Bool
        var isClosed: Bool
        /// Le nombre de personnes qui ont répondu.
        var voters: Int
        /// Ce que l'étudiant·e a coché (`nil` : pas encore répondu).
        var chosen: [Int]?
        /// `after_response`, `always`, `never`, `after_close`.
        var revealVotes: String

        /// Ed ne montre les votes qu'après sa propre réponse (ou selon le réglage).
        var showsResults: Bool {
            guard counts.count == options.count, voters > 0 else { return false }
            switch revealVotes {
            case "never": return false
            case "always": return true
            case "after_close": return isClosed
            default: return chosen != nil || isClosed
            }
        }

        /// La part des votants qui ont coché une option (0…1).
        func share(_ index: Int) -> Double {
            guard counts.indices.contains(index), voters > 0 else { return 0 }
            return min(1, Double(counts[index]) / Double(voters))
        }
    }

    /// Les sondages d'un message, dans l'ordre.
    static func pollIDs(in document: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: #"<poll\b[^>]*\bid="(\d+)""#) else { return [] }
        let range = NSRange(document.startIndex..., in: document)
        return regex.matches(in: document, range: range).compactMap { match in
            Range(match.range(at: 1), in: document).flatMap { Int(document[$0]) }
        }
    }

    static func poll(json: Data) -> Poll? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let poll = object["poll"] as? [String: Any], let id = poll["id"] as? Int else { return nil }
        let data = poll["data"] as? [String: Any] ?? [:]
        let options = data["options"] as? [[String: Any]] ?? []
        let counts = options.compactMap { $0["response_count"] as? Int }
        let response = (poll["response"] as? [String: Any])?["data"] as? [String: Any]
        return Poll(id: id, question: poll["content"] as? String ?? "",
                    options: options.map { $0["content"] as? String ?? "" },
                    counts: counts.count == options.count ? counts : [],
                    multipleChoice: (data["multiple_choice"] as? Bool) == true,
                    isClosed: (poll["is_closed"] as? Bool) == true,
                    voters: poll["response_count"] as? Int ?? 0,
                    chosen: response?["option_indices"] as? [Int],
                    revealVotes: poll["reveal_votes"] as? String ?? "after_response")
    }

    /// Le cours Ed d'un cours de l'app : le code (« CS-101 ») dans le code Ed
    /// (« CS-101 Fall 2026 », « cs101 »), le plus récent s'il y en a plusieurs.
    static func match(code: String, in courses: [Course]) -> Course? {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let base = key(code.split(separator: "(").first.map(String.init) ?? code)
        guard !base.isEmpty else { return nil }
        return courses.filter { key($0.code).hasPrefix(base) || key($0.name).contains(base) }.max { $0.id < $1.id }
    }

    /// Le format des messages d'Ed (`<document><paragraph>…<math>…</math>`) →
    /// des blocs, par le même chemin que le HTML (formules gardées en `\( \)`).
    static func blocks(_ document: String) -> [SiteBlock] {
        var text = document
        // Les formules d'abord : leur contenu ne doit pas passer pour des balises.
        text = replace(text, #"<math>(.*?)</math>"#) { "\\(" + $0[1] + "\\)" }
        text = replace(text, #"<heading level="(\d)">"#) { "<h\($0[1])>" }
        text = replace(text, #"</heading>"#) { _ in "</h3>" }
        text = replace(text, #"<list style="number"[^>]*>"#) { _ in "<ol>" }
        text = replace(text, #"<list(\s[^>]*)?>"#) { _ in "<ul>" }
        text = replace(text, #"</list>"#) { _ in "</ul>" }
        text = replace(text, #"<snippet[^>]*>"#) { _ in "<pre>" }
        text = replace(text, #"</snippet>"#) { _ in "</pre>" }
        text = replace(text, #"<web-snippet[^>]*>.*?</web-snippet>"#) { _ in "" }
        text = replace(text, #"<poll\b[^>]*/>"#) { _ in "" }
        text = replace(text, #"<link(\s[^>]*)>"#) { "<a\($0[1])>" }
        text = text.replacingOccurrences(of: "</link>", with: "</a>")
        let tags = [("paragraph", "p"), ("bold", "b"), ("italic", "i"), ("underline", "span"), ("list-item", "li"),
                    ("callout", "blockquote"), ("spoiler", "div"), ("document", "div"), ("pre", "pre")]
        for (ed, html) in tags {
            text = replace(text, "<\(ed)(\\s[^>]*)?>") { _ in "<\(html)>" }
            text = text.replacingOccurrences(of: "</\(ed)>", with: "</\(html)>")
        }
        return SiteHTML.blocks(text, base: URL(string: "https://edstem.org/"))
    }

    // MARK: Écrire sur Ed (observé : `POST courses/<id>/threads {thread: …}`,
    // `POST threads/<id>/comments {comment: {type, content, …}}`, le contenu au
    // format `<document version="2.0">`)

    /// Ce qu'on tape (Markdown léger, formules entre `$…$`) → le document d'Ed.
    static func document(fromMarkdown text: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func inline(_ s: String) -> String {
            var out = ""
            for piece in RichMarkup.inlines(s) {
                switch piece {
                case .text(let t): out += escape(t)
                case .bold(let t): out += "<bold>" + escape(t) + "</bold>"
                case .italic(let t): out += "<italic>" + escape(t) + "</italic>"
                case .code(let t): out += "<code>" + escape(t) + "</code>"
                case .math(let t): out += "<math>" + escape(t) + "</math>"
                case .link(let t, let url): out += "<link href=\"" + escape(url) + "\">" + escape(t) + "</link>"
                }
            }
            return out
        }
        var body = ""
        var list: (ordered: Bool, items: [String])?
        func closeList() {
            guard let open = list else { return }
            let style = open.ordered ? "number" : "bullet"
            body += "<list style=\"\(style)\">" + open.items.map { "<list-item><paragraph>\($0)</paragraph></list-item>" }.joined() + "</list>"
            list = nil
        }
        for block in RichMarkup.blocks(text) {
            switch block {
            case .bullet(let t, _):
                if list?.ordered == true { closeList() }
                if list == nil { list = (false, []) }
                list?.items.append(inline(t))
            case .numbered(let t, _):
                if list?.ordered == false { closeList() }
                if list == nil { list = (true, []) }
                list?.items.append(inline(t))
            default:
                closeList()
                switch block {
                case .heading(let t, let level): body += "<heading level=\"\(min(max(level, 1), 3))\">" + inline(t) + "</heading>"
                case .paragraph(let t): body += "<paragraph>" + inline(t) + "</paragraph>"
                case .math(let t): body += "<paragraph><math>" + escape(t) + "</math></paragraph>"
                case .code(let t): body += "<snippet language=\"none\" runnable=\"false\" line-numbers=\"true\">" + escape(t) + "</snippet>"
                case .rule: body += "<paragraph>—</paragraph>"
                default: break
                }
            }
        }
        closeList()
        return "<document version=\"2.0\">" + body + "</document>"
    }

    /// Les catégories du forum d'un cours (`GET courses/<id>` → `settings.discussion.categories`).
    static func categories(courseJSON: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: courseJSON) as? [String: Any],
              let course = object["course"] as? [String: Any],
              let settings = course["settings"] as? [String: Any],
              let discussion = settings["discussion"] as? [String: Any],
              let categories = discussion["categories"] as? [[String: Any]] else { return [] }
        return categories.compactMap { $0["name"] as? String }
    }

    // MARK: Leçons et quiz (routes observées : `courses/<id>/lessons`,
    // `lessons/<id>?view=1`, `lessons/slides/<id>/questions`,
    // `POST lessons/slides/questions/<id>/responses`). La forme d'une réponse
    // (indices pour un choix multiple, texte sinon) est déduite du code d'Ed.

    struct Lesson: Equatable, Identifiable {
        var id: Int
        var title: String
        var module: String?
        var status: String?
    }

    struct Slide: Equatable, Identifiable {
        var id: Int
        var type: String
        var title: String
        /// Le contenu d'une diapositive « document » (format d'Ed).
        var content: String
        var isCompleted: Bool
    }

    struct Question: Equatable, Identifiable {
        enum Kind: Equatable { case choice(multiple: Bool), text, number, other(String) }
        var id: Int
        var kind: Kind
        /// L'énoncé (format d'Ed).
        var content: String
        /// Les choix (format d'Ed), pour un choix multiple ou vrai/faux.
        var answers: [String]
    }

    static func lessons(json: Data) -> [Lesson] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        var modules: [Int: String] = [:]
        for module in object["modules"] as? [[String: Any]] ?? [] {
            if let id = module["id"] as? Int { modules[id] = module["name"] as? String }
        }
        return (object["lessons"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? Int else { return nil }
            return Lesson(id: id, title: raw["title"] as? String ?? String(localized: "Leçon"),
                          module: (raw["module_id"] as? Int).flatMap { modules[$0] }, status: raw["status"] as? String)
        }
    }

    static func slides(lessonJSON: Data) -> [Slide] {
        guard let object = try? JSONSerialization.jsonObject(with: lessonJSON) as? [String: Any],
              let lesson = object["lesson"] as? [String: Any] else { return [] }
        return (lesson["slides"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? Int else { return nil }
            return Slide(id: id, type: raw["type"] as? String ?? "", title: raw["title"] as? String ?? "",
                         content: raw["content"] as? String ?? "", isCompleted: (raw["status"] as? String) == "completed")
        }
    }

    static func questions(json: Data) -> [Question] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        return (object["questions"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let id = raw["id"] as? Int else { return nil }
            let data = raw["data"] as? [String: Any] ?? raw
            let type = data["type"] as? String ?? raw["type"] as? String ?? ""
            let kind: Question.Kind
            switch type {
            case "multiple-choice": kind = .choice(multiple: (data["multiple_selection"] as? Bool) == true)
            case "true-false": kind = .choice(multiple: false)
            case "short-answer": kind = .text
            case "numerical": kind = .number
            default: kind = .other(type)
            }
            let answers = (data["answers"] as? [Any] ?? []).map { ($0 as? String) ?? (($0 as? [String: Any])?["content"] as? String ?? "") }
            return Question(id: id, kind: kind, content: data["content"] as? String ?? "",
                            answers: type == "true-false" && answers.isEmpty ? ["Vrai", "Faux"] : answers)
        }
    }

    /// La réponse à envoyer : les indices choisis pour un choix, le texte sinon.
    static func response(choices: Set<Int>, text: String, for kind: Question.Kind) -> Any {
        switch kind {
        case .choice: return choices.sorted()
        case .number: return Double(text.replacingOccurrences(of: ",", with: ".")) ?? text
        default: return text
        }
    }

    private static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return text }
        var result = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            result += transform(groups)
            cursor = range.upperBound
        }
        return result + text[cursor...]
    }
}

private extension String {
    /// « - » ou « 3. » seuls : une puce sans encore de texte.
    var isBareListMarker: Bool {
        self == "-" || range(of: #"^\d+\.$"#, options: .regularExpression) != nil
    }
}

// MARK: - Moodle : la page du cours

/// La page d'un cours Moodle (`/course/view.php`), lue dans la session : ce que
/// le plan (`core_courseformat_get_state`) n'a pas — le texte de chaque
/// section, les étiquettes, la description des activités, l'achèvement, la
/// semaine en cours. Observé sur PHYS-101 (format `topics`) et MATH-111
/// (format `weeks`, 16 sections résumées, 139 marques d'achèvement).
struct MoodleCoursePage: Codable, Equatable {
    struct Activity: Codable, Equatable, Identifiable {
        var id: Int
        var module: String
        var name: String
        var url: String
        /// La description affichée sous l'activité, ou le contenu d'une étiquette.
        var html: String = ""
        var dates: [String] = []
        var completed: Bool = false

        init(id: Int, module: String, name: String, url: String, html: String = "", dates: [String] = [], completed: Bool = false) {
            self.id = id; self.module = module; self.name = name; self.url = url; self.html = html; self.dates = dates; self.completed = completed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            module = try c.decodeIfPresent(String.self, forKey: .module) ?? ""
            name = BotafogoParser.decode(try c.decodeIfPresent(String.self, forKey: .name) ?? "")
            url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
            html = try c.decodeIfPresent(String.self, forKey: .html) ?? ""
            dates = try c.decodeIfPresent([String].self, forKey: .dates) ?? []
            completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        }

        /// Ce qu'on montre sous le nom (« PDF », « Vidéo », « Devoir »…).
        var kindLabel: String {
            switch module {
            case "resource": return "Document"
            case "folder": return "Dossier"
            case "url": return "Lien"
            case "page": return "Page"
            case "assign": return "Devoir"
            case "forum": return "Forum"
            case "quiz": return "Quiz"
            case "lti": return String(localized: "Outil externe")
            case "label": return ""
            default: return module.capitalized
            }
        }

        /// Une série d'exercices (ou son corrigé), d'après le nom.
        var isSeries: Bool {
            let n = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return ["serie", "series", "problem set", "exercice", "exercise", "corrige", "solution"].contains { n.contains($0) }
        }

        var isVideo: Bool {
            let n = name.lowercased()
            return n.contains("recording") || n.contains("vidéo") || n.contains("video") || n.contains("enregistrement")
                || url.contains("mediaspace") || url.contains("kaltura")
        }
    }

    struct Section: Codable, Equatable, Identifiable {
        var id: Int { number }
        var number: Int
        var title: String
        var summary: String = ""
        var isCurrent: Bool = false
        var activities: [Activity] = []

        init(number: Int, title: String, summary: String = "", isCurrent: Bool = false, activities: [Activity] = []) {
            self.number = number; self.title = title; self.summary = summary; self.isCurrent = isCurrent; self.activities = activities
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
            title = BotafogoParser.decode(try c.decodeIfPresent(String.self, forKey: .title) ?? "")
            summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            isCurrent = try c.decodeIfPresent(Bool.self, forKey: .isCurrent) ?? false
            activities = try c.decodeIfPresent([Activity].self, forKey: .activities) ?? []
        }
    }

    var title: String
    var sections: [Section]

    static func decode(_ json: String) -> MoodleCoursePage? {
        guard let page = try? JSONDecoder().decode(MoodleCoursePage.self, from: Data(json.utf8)), !page.sections.isEmpty else { return nil }
        return page
    }

    /// La section à ouvrir d'abord : celle que Moodle marque « en cours »,
    /// sinon celle dont les dates (« 12 October - 18 October ») contiennent
    /// aujourd'hui, sinon la première qui a du contenu.
    func currentSection(today: Date = Date(), calendar: Calendar = .current) -> Section? {
        if let marked = sections.first(where: \.isCurrent) { return marked }
        if let dated = sections.first(where: { Self.range(of: $0.title, year: calendar.component(.year, from: today), calendar: calendar)?.contains(today) == true }) {
            return dated
        }
        return sections.first { !$0.activities.isEmpty }
    }

    /// « 12 October- 18 October », « 7 septembre - 13 septembre » → l'intervalle.
    static func range(of title: String, year: Int, calendar: Calendar = .current) -> ClosedRange<Date>? {
        let months = ["january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6, "july": 7, "august": 8,
                      "september": 9, "october": 10, "november": 11, "december": 12,
                      "janvier": 1, "fevrier": 2, "mars": 3, "avril": 4, "mai": 5, "juin": 6, "juillet": 7, "aout": 8,
                      "septembre": 9, "octobre": 10, "novembre": 11, "decembre": 12]
        let text = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})\s*([a-z]+)"#) else { return nil }
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> DateComponents? in
            guard let d = Range(match.range(at: 1), in: text), let m = Range(match.range(at: 2), in: text),
                  let month = months[String(text[m])], let day = Int(text[d]) else { return nil }
            return DateComponents(year: year, month: month, day: day)
        }
        guard found.count >= 2, let start = calendar.date(from: found[0]), var end = calendar.date(from: found[1]) else { return nil }
        if end < start { end = calendar.date(byAdding: .year, value: 1, to: end) ?? end }
        end = calendar.date(byAdding: .day, value: 1, to: end).map { $0.addingTimeInterval(-1) } ?? end
        return start...end
    }
}

// MARK: - Courseware : un problème

/// Un problème Open edX (`problem` xblock), lu dans la session : son énoncé,
/// ses groupes de réponses (cases, boutons, listes, champs), le score. Les
/// réponses partent à `<url>/problem_check` (formulaire, jeton CSRF) — observé
/// sur CS-107 : `data-url`, `data-content`, `input_<id>_2_1[]`.
struct EdXProblem: Codable, Equatable {
    struct Option: Codable, Equatable { var value: String; var label: String; var checked: Bool? }
    struct Group: Codable, Equatable {
        var name: String
        var type: String
        var options: [Option] = []
        var value: String?
    }
    var url: String
    var title: String
    var prompt: String
    var groups: [Group]
    var score: Double
    var total: Double
    var attempts: Int

    static func decode(_ json: String) -> EdXProblem? { try? JSONDecoder().decode(EdXProblem.self, from: Data(json.utf8)) }

    /// Le corps du formulaire envoyé : chaque groupe, une ou plusieurs valeurs.
    static func formBody(_ answers: [String: [String]]) -> String {
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? text
        }
        return answers.keys.sorted().flatMap { name in answers[name, default: []].map { encode(name) + "=" + encode($0) } }
            .joined(separator: "&")
    }

    /// La réponse de `problem_check` : « correct », « incorrect », « partially-correct ».
    struct Result: Equatable {
        var verdict: String
        var score: Double?
        var total: Double?
        var isCorrect: Bool { verdict == "correct" }
    }

    static func result(json: Data) -> Result? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let verdict = (object["success"] as? String) ?? ((object["success"] as? Bool) == true ? "correct" : "incorrect")
        return Result(verdict: verdict, score: object["current_score"] as? Double, total: object["total_possible"] as? Double)
    }
}
