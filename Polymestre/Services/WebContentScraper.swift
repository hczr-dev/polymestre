import Foundation
import WebKit
import PDFKit

/// Lit la page d'un cours dans le navigateur intégré.
///
/// Le script ne fait que **rapporter** ce qu'il voit — titres, liens, type de
/// module — sous la forme d'un `ScrapedCourse` en JSON. Aucune règle métier ici :
/// décider qu'un « Corrigé » s'ignore ou qu'une section datée tombe en semaine 3
/// est le travail de `ContentDraftBuilder`, en Swift pur et testé.
///
/// Le script tourne **dans la session de l'étudiant·e** : c'est ce qui rend la
/// lecture possible sans API. Rien ne quitte l'appareil.
enum WebContentScraper {

    enum ScrapeError: LocalizedError {
        case notACoursePage(ContentSource)
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .notACoursePage(.moodle):
                return String(localized: "Ouvre la page d'un cours Moodle (celle qui liste les semaines), puis réessaie.")
            case .notACoursePage(.courseware):
                return String(localized: "Ouvre un cours Courseware (son plan ou une leçon), puis réessaie.")
            case .notACoursePage:
                return String(localized: "Ouvre la page du cours, puis réessaie.")
            case .unreadable(let detail):
                return String(localized: "Lecture de la page impossible — \(detail)")
            case .empty:
                return String(localized: "La page ne contient ni théorie ni série reconnaissables.")
            }
        }
    }

    /// La page affichée est-elle celle d'un cours ?
    static func isCoursePage(_ url: URL?, source: ContentSource) -> Bool {
        guard let url else { return false }
        let text = url.absoluteString
        switch source {
        case .moodle: return text.contains("/course/view.php") || text.contains("/course/section.php")
        case .courseware: return text.contains("course-v1:") || text.contains("course-v1%3A")
        case .botafogo: return url.host?.contains("botafogo") == true && url.path.count > 1
        }
    }

    @MainActor
    static func scrape(_ webView: WKWebView, source: ContentSource) async throws -> ScrapedCourse {
        guard isCoursePage(webView.url, source: source) else { throw ScrapeError.notACoursePage(source) }
        if source == .botafogo, let url = webView.url {
            return try await BotafogoClient.course(at: BotafogoClient.courseRoot(of: url))
        }
        let raw: Any?
        do {
            if source == .courseware {
                guard let key = coursewareKey(in: webView.url) else { throw ScrapeError.notACoursePage(source) }
                raw = try await webView.callAsyncJavaScript(coursewareOutlineScript, arguments: ["key": key], contentWorld: .page)
            } else {
                raw = try await webView.callAsyncJavaScript(moodleScript, contentWorld: .defaultClient)
            }
        } catch let error as ScrapeError {
            throw error
        } catch {
            throw ScrapeError.unreadable(error.localizedDescription)
        }
        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw ScrapeError.unreadable(String(localized: "réponse vide"))
        }
        if let failure = try? JSONDecoder().decode([String: String].self, from: data), let message = failure["error"] {
            throw ScrapeError.unreadable(message)
        }
        do {
            let page = try JSONDecoder().decode(ScrapedCourse.self, from: data)
            guard page.sections.contains(where: { !$0.items.isEmpty }) else { throw ScrapeError.empty }
            return page
        } catch let error as ScrapeError {
            throw error
        } catch {
            throw ScrapeError.unreadable(error.localizedDescription)
        }
    }

    // MARK: Moodle

    /// Moodle 4 : une `li.section` (ou `.course-section`) par semaine ou thème,
    /// une `li.activity` par élément, le type dans la classe `modtype_…`.
    /// Les sous-sections (Moodle 4.5) sont des sections imbriquées : chaque
    /// activité n'est rattachée qu'à sa section la plus proche.
    static let moodleScript = #"""
    const clean = t => (t || '').replace(/\s+/g, ' ').trim();
    const heading = document.querySelector('.page-header-headings h1, #page-header h1, h1');
    const title = clean(heading ? heading.innerText : document.title);
    const sectionSelector = 'li.section, li.course-section';
    const sections = [];
    document.querySelectorAll(sectionSelector).forEach(sec => {
      const nameEl = sec.querySelector('.sectionname, .course-section-header h3, [data-for="section_title"], h3');
      let name = clean(nameEl ? nameEl.innerText : sec.getAttribute('aria-label'));
      const items = [];
      sec.querySelectorAll('li.activity').forEach(act => {
        if (act.closest(sectionSelector) !== sec) return;
        const type = ((act.className.match(/modtype_(\w+)/) || [])[1] || '');
        const nameNode = act.querySelector('.instancename, .activityname, [data-activityname]');
        let text = '';
        if (nameNode) {
          const copy = nameNode.cloneNode(true);
          copy.querySelectorAll('.accesshide, .sr-only, .visually-hidden').forEach(e => e.remove());
          text = clean(copy.innerText || copy.textContent);
        }
        if (!text) text = clean(act.getAttribute('data-activityname'));
        if (!text) return;
        const link = act.querySelector('a.aalink, a[href*="/mod/"]');
        items.push({ title: text, url: link ? link.href : '', type: type });
      });
      sections.push({ title: name, items: items });
    });
    if (sections.length === 0) return JSON.stringify({ error: "aucune section trouvée sur cette page" });
    return JSON.stringify({ source: 'moodle', title: title, url: location.href, sections: sections });
    """#

    // MARK: Courseware (Open edX)

    /// Open edX expose le plan du cours à l'étudiant·e connecté·e :
    /// `/api/course_home/outline/<clé>` (chapitres → leçons). Le nombre de vidéos
    /// par leçon vient de l'API des blocs, quand elle répond ; sinon on s'en passe.
    /// La clé Open edX d'une adresse : `course-v1:EPFL+analyse+2021`.
    static func coursewareKey(in url: URL?) -> String? {
        guard let text = url?.absoluteString.removingPercentEncoding,
              let range = text.range(of: #"course-v1:[^/?#]+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Reçoit la clé du cours en argument (`key`) : le navigateur intégré la lit
    /// dans l'adresse affichée, l'import direct dans la liste des inscriptions.
    static var coursewareOutlineScript: String {
        #"""
    const lms = '\#(Institution.current.coursewareBase)';
    const get = async (path) => {
      try {
        const r = await fetch(lms + path, { credentials: 'include', headers: { 'Accept': 'application/json' } });
        return r.ok ? await r.json() : null;
      } catch (e) { return null; }
    };
    const outline = await get('/api/course_home/outline/' + encodeURIComponent(key))
                 || await get('/api/course_home/v1/outline/' + encodeURIComponent(key));
    const blocks = outline && outline.course_blocks && outline.course_blocks.blocks;
    if (!blocks) return JSON.stringify({ error: "plan du cours illisible — es-tu connecté·e et inscrit·e à ce cours ?" });

    // L'arbre complet (API des blocs) : chaque leçon jusqu'à ses vidéos, pour
    // lier **la vidéo elle-même** et non le premier élément de la leçon
    // (`lms_web_url` d'une leçon ouvre son premier bloc, souvent un texte).
    let tree = null;
    const me = await get('/api/user/v1/me');
    if (me && me.username) {
      const q = '/api/courses/v2/blocks/?course_id=' + encodeURIComponent(key)
        + '&username=' + encodeURIComponent(me.username)
        + '&depth=all&block_counts=video&requested_fields=children,block_counts,display_name,type,lms_web_url,student_view_url';
      const t = await get(q);
      if (t && t.blocks) tree = t.blocks;
    }
    const descendants = (id) => {
      const out = [];
      const walk = (x) => { const b = tree && tree[x]; if (!b) return; (b.children || []).forEach(c => { out.push(c); walk(c); }); };
      walk(id);
      return out;
    };

    const all = Object.values(blocks);
    const root = all.find(b => b.type === 'course');
    const chapters = root ? (root.children || []).map(id => blocks[id]).filter(Boolean)
                          : all.filter(b => b.type === 'chapter');
    const sections = chapters.map(ch => ({
      id: ch.id,
      title: ch.display_name || '',
      items: (ch.children || []).map(id => blocks[id]).filter(Boolean).map(seq => {
        const inner = descendants(seq.id);
        const videos = inner.map(id => tree[id]).filter(b => b && b.type === 'video').map(v => ({
          title: v.display_name || '',
          url: v.student_view_url || v.lms_web_url || '',
          kind: 'video'
        })).filter(v => v.url);
        const node = tree && tree[seq.id];
        return {
          id: seq.id,
          blockIDs: inner,
          title: seq.display_name || '',
          url: seq.lms_web_url || '',
          type: 'sequential',
          videoCount: node && node.block_counts ? (node.block_counts.video || 0) : (tree ? videos.length : null),
          links: videos
        };
      })
    }));
    const title = (root && root.display_name) || document.title;
    return JSON.stringify({ source: 'courseware', title: title, url: location.href, sections: sections });
    """#
    }
}

// MARK: - Botafogo

/// Botafogo est public : ni navigateur ni connexion, on lit les pages.
///
/// Deux générations de sites cohabitent : Analyse I, en HTML statique (une page
/// de sommaire, une page par section avec ses vidéos), et les cinq autres —
/// Analyse I GM et classe inversée, Analyse B, ICS, Algèbre linéaire — des
/// applications Nuxt dont le sommaire est dans `__NUXT_DATA__`. Seule la
/// première était lue : les cinq autres donnaient « rien de reconnaissable ».
enum BotafogoClient {

    static var home: URL { BotafogoParser.home }

    /// Les polycopiés proposés sur la page d'accueil.
    static func catalog(session: URLSession = .shared) async throws -> [(title: String, url: URL)] {
        let html = try await text(at: home, session: session)
        return BotafogoParser.catalog(html: html, baseURL: home)
    }

    static func courseRoot(of url: URL) -> URL { BotafogoParser.courseRoot(of: url) }

    /// Le polycopié à cette adresse, quelle que soit sa génération.
    static func course(at url: URL, session: URLSession = .shared) async throws -> ScrapedCourse {
        var address = url
        var html = try await text(at: address, session: session)
        // `/ics/` n'est qu'une redirection `<meta refresh>` vers une section.
        for _ in 0..<2 {
            guard let next = BotafogoParser.metaRefresh(html: html, baseURL: address) else { break }
            address = next
            html = try await text(at: address, session: session)
        }

        if var page = BotafogoParser.parseNuxt(html: html, pageURL: address) {
            // Les sites de cours (GM, classe inversée) publient les
            // enregistrements, datés : ils deviennent de la théorie à la bonne
            // semaine.
            let root = BotafogoParser.siteRoot(html: html, pageURL: address)
            if let videos = BotafogoParser.videosPage(html: html, root: root),
               let body = try? await text(at: videos, session: session) {
                let recordings = BotafogoParser.recordings(html: body)
                if !recordings.isEmpty {
                    page.sections.insert(ScrapedSection(title: "Enregistrements des cours", items: recordings), at: 0)
                }
            }
            guard page.sections.contains(where: { !$0.items.isEmpty }) else { throw WebContentScraper.ScrapeError.empty }
            return page
        }

        // Génération HTML : le sommaire, puis chaque section pour y compter
        // les vidéos — huit pages à la fois, pour ne pas charger le serveur
        // d'un enseignant.
        var page = BotafogoParser.parseTOC(html: html, baseURL: BotafogoParser.courseRoot(of: address))
        guard !page.sections.isEmpty else { throw WebContentScraper.ScrapeError.empty }

        var targets: [(section: Int, item: Int, url: URL)] = []
        for (s, section) in page.sections.enumerated() {
            for (i, item) in section.items.enumerated() {
                if let itemURL = URL(string: item.url) { targets.append((s, i, itemURL)) }
            }
        }
        try await withThrowingTaskGroup(of: (Int, Int, Int).self) { group in
            var iterator = targets.makeIterator()
            func enqueue() {
                guard let next = iterator.next() else { return }
                group.addTask {
                    let body = (try? await text(at: next.url, session: session)) ?? ""
                    return (next.section, next.item, BotafogoParser.videoTitles(inSection: body).count)
                }
            }
            for _ in 0..<8 { enqueue() }
            while let (s, i, count) = try await group.next() {
                page.sections[s].items[i].videoCount = count
                enqueue()
            }
        }
        return page
    }

    // MARK: Programme hebdomadaire

    /// Le brouillon d'import d'un polycopié, **au programme de la semaine**
    /// quand le site en publie un.
    ///
    /// Les sites de cours (Analyse I GM, classe inversée) déclarent semaine par
    /// semaine les cours filmés, les sections du polycopié couvertes et la
    /// série, avec chaque exercice. L'import reprend ce programme tel quel : la
    /// théorie tombe à la semaine où elle est enseignée, pas à une semaine
    /// devinée. Les autres polycopiés, sans programme, sont étalés selon leur
    /// volume (`ContentDraftBuilder`).
    static func draft(at url: URL, fallbackTitle: String? = nil, termStart: Date?, totalWeeks: Int,
                      session: URLSession = .shared) async throws -> ContentDraft {
        var address = url
        var html = try await text(at: address, session: session)
        for _ in 0..<2 {
            guard let next = BotafogoParser.metaRefresh(html: html, baseURL: address) else { break }
            address = next
            html = try await text(at: address, session: session)
        }
        let root = BotafogoParser.siteRoot(html: html, pageURL: address)
        if html.contains("?cours="), let program = await program(html: html, root: root, session: session) {
            let handout = NuxtPayload(html: html)?.navigation().chapters ?? []
            var lectureURLs: [String] = []
            var seriesURLs: [String] = []
            for week in program where week.type == "week" {
                for child in week.children ?? [] {
                    guard let url = child.url else { continue }
                    switch child.type {
                    case "lecture", "weekContent", "session": lectureURLs.append(url)
                    case "series": seriesURLs.append(url)
                    default: break
                    }
                }
            }
            let documents = await nodes(lectureURLs + seriesURLs, root: root, session: session)
            var lectures: [String: BotafogoLectureContent] = [:]
            for url in lectureURLs { if let data = documents[url] { lectures[url] = BotafogoDocument.lecture(fromNodeJSON: data) } }
            var series: [String: [BotafogoExercise]] = [:]
            for url in seriesURLs { if let data = documents[url] { series[url] = BotafogoDocument.exercises(fromNodeJSON: data) } }
            // Le programme cite parfois plus d'exercices que la série n'en
            // montre : des pages en brouillon (« exercices corrigés 2022 »,
            // vides, jamais publiées). On ne lit les exercices un par un que
            // quand les comptes divergent.
            var unpublished = Set<String>()
            var listedByURL: [String: [String]] = [:]
            for week in program where week.type == "week" {
                for child in week.children ?? [] where child.type == "series" {
                    guard let url = child.url else { continue }
                    listedByURL[url] = (child.children ?? []).filter { $0.type == "exercise" }.compactMap(\.url)
                }
            }
            let suspicious = listedByURL.filter { url, listed in series[url].map { !$0.isEmpty && listed.count > $0.count } ?? false }
                .flatMap(\.value)
            if !suspicious.isEmpty {
                let pages = await nodes(suspicious, root: root, session: session)
                unpublished = Set(suspicious.filter { pages[$0].map(BotafogoDocument.isUnpublished(nodeJSON:)) ?? false })
            }
            let pageTitle = BotafogoParser.parseNuxt(html: html, pageURL: address)?.title
            return BotafogoProgramBuilder.draft(title: pageTitle ?? fallbackTitle ?? "Botafogo",
                                                program: program, root: root, handout: handout,
                                                lectures: lectures, series: series, unpublished: unpublished)
        }
        var page = try await course(at: url, session: session)
        if page.title == "Botafogo" || page.title.isEmpty, let fallbackTitle { page.title = fallbackTitle }
        return ContentDraftBuilder.draft(from: page, source: .botafogo, termStart: termStart, totalWeeks: totalWeeks)
    }

    /// Le fichier du site qui porte le programme, retenu d'une fois sur
    /// l'autre : il change à chaque publication du site, mais pas entre deux
    /// mises à jour de l'app.
    private static let chunkKey = "botafogo.programChunk."

    static func program(html: String, root: URL, session: URLSession) async -> [BotafogoNode]? {
        // `URL.path` perd la barre finale : « /analyse-1-GM » + « _nuxt/ ».
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let prefix = NSRegularExpression.escapedPattern(for: base)
        guard let regex = try? NSRegularExpression(pattern: prefix + #"_nuxt/[A-Za-z0-9_-]+\.js"#) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        var paths = Array(Set(regex.matches(in: html, range: range).compactMap { Range($0.range, in: html).map { String(html[$0]) } })).sorted()
        guard !paths.isEmpty else { return nil }
        let key = chunkKey + root.path
        if let cached = UserDefaults.standard.string(forKey: key), let index = paths.firstIndex(of: cached) {
            paths.swapAt(0, index)
            if let program = try? await programIn(paths[0], session: session) { return program }
        }
        // Huit fichiers à la fois ; on s'arrête au premier qui porte le programme.
        return await withTaskGroup(of: (String, [BotafogoNode]?).self) { group in
            var iterator = paths.makeIterator()
            for _ in 0..<8 {
                guard let path = iterator.next() else { break }
                group.addTask { (path, try? await programIn(path, session: session)) }
            }
            while let (path, found) = await group.next() {
                if let found {
                    UserDefaults.standard.set(path, forKey: key)
                    group.cancelAll()
                    return found
                }
                if let next = iterator.next() {
                    group.addTask { (next, try? await programIn(next, session: session)) }
                }
            }
            return nil
        }
    }

    private static func programIn(_ path: String, session: URLSession) async throws -> [BotafogoNode]? {
        guard let url = URL(string: path, relativeTo: home)?.absoluteURL else { return nil }
        let script = try await text(at: url, session: session)
        guard script.contains("type:`week`") else { return nil }
        return BotafogoProgram.extract(fromScript: script)
    }

    /// Les adresses d'un document, la plus récente d'abord : `api/content/node/<collection><chemin>.json`
    /// (le site depuis l'automne 2026 ; l'ancienne forme répond 404), puis `api/content/node?collection=…&path=…`.
    static func nodeURLs(root: URL, collection: String, path: String) -> [URL] {
        let base = root.absoluteString.hasSuffix("/") ? root.absoluteString : root.absoluteString + "/"
        let slashed = path.hasPrefix("/") ? path : "/" + path
        let encoded = slashed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slashed
        let query = slashed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? slashed
        return [URL(string: base + "api/content/node/" + collection + encoded + ".json"),
                URL(string: base + "api/content/node?collection=" + collection + "&path=" + query)].compactMap { $0 }
    }

    /// Les documents du site par l'API des contenus, huit à la fois.
    private static func nodes(_ urls: [String], root: URL, session: URLSession) async -> [String: Data] {
        await withTaskGroup(of: (String, Data?).self) { group in
            var iterator = Array(Set(urls)).makeIterator()
            func enqueue() {
                guard let url = iterator.next() else { return }
                let addresses = nodeURLs(root: root, collection: "content", path: BotafogoProgram.contentPath(url))
                group.addTask {
                    for address in addresses {
                        var request = URLRequest(url: address)
                        request.timeoutInterval = 20
                        if let (data, response) = try? await session.data(for: request),
                           (response as? HTTPURLResponse)?.statusCode == 200, BotafogoDocument.body(fromNodeJSON: data) != nil {
                            return (url, data)
                        }
                    }
                    return (url, nil)
                }
            }
            for _ in 0..<8 { enqueue() }
            var result: [String: Data] = [:]
            while let (url, data) = await group.next() {
                if let data { result[url] = data }
                enqueue()
            }
            return result
        }
    }

    private static func text(at url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebContentScraper.ScrapeError.unreadable(String(localized: "le serveur a répondu \(http.statusCode)"))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Téléchargement dans la session

/// Télécharge un fichier protégé (le PDF d'une série sur Moodle) avec les
/// cookies de la connexion faite dans le navigateur intégré.
enum AuthenticatedDownloader {

    @MainActor
    static func download(_ address: URL) async throws -> URL {
        try await fetch(address, depth: 0).file
    }

    /// N'importe quel fichier (image, diapositives, archive), avec les cookies
    /// des sites EPFL : ce que le mode étude du Mac affiche en natif.
    @MainActor
    static func file(_ address: URL) async throws -> (file: URL, type: String?) {
        let url = SiteLinks.normalize(address)
        let session = await authenticatedSession(for: url)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        let name = response.suggestedFilename ?? url.lastPathComponent
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return (destination, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"))
    }

    /// Les octets d'une adresse (une image d'une page Moodle), avec les cookies.
    @MainActor
    static func data(_ address: URL) async -> Data? {
        let session = await authenticatedSession(for: address)
        defer { session.finishTasksAndInvalidate() }
        return try? await session.data(from: address).0
    }

    /// L'adresse du **document** derrière un lien Moodle (page, dossier, lien,
    /// fichier) : ce que l'app enregistre à la place de la page d'activité.
    /// `nil` si la page ne désigne aucun document lisible.
    @MainActor
    static func resolve(_ address: URL) async -> (statement: URL, solution: URL?)? {
        guard MoodleLinks.activityModule(of: address) != nil else { return nil }
        let session = await authenticatedSession(for: address)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: MoodleLinks.workaroundPage(address)) else { return nil }
        let final = response.url ?? address
        if isPDF(response) || final.path.contains("/pluginfile.php/") { return (final, nil) }
        let html = String(decoding: data, as: UTF8.self)
        let found = MoodleLinks.statementLink(inHTML: html, baseURL: final)
        guard let statement = found.statement.flatMap(URL.init(string:)) else { return nil }
        return (statement, found.solution.flatMap(URL.init(string:)))
    }

    /// Télécharge ; une page d'activité Moodle (page, dossier, « cliquez
    /// ici ») est suivie jusqu'au PDF qu'elle désigne, deux sauts au plus.
    @MainActor
    private static func fetch(_ address: URL, depth: Int) async throws -> (file: URL, url: URL) {
        // `mod/resource/view.php` → `…&redirect=1` : le fichier, pas la page.
        let url = SiteLinks.normalize(address)
        let session = await authenticatedSession(for: url)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        guard isPDF(response) else {
            // Une page HTML : celle d'une activité Moodle qui porte le lien du
            // PDF (AICC), ou une page de connexion.
            let html = (try? String(contentsOf: temporary, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: temporary)
            let base = response.url ?? url
            if depth < 2, let next = MoodleLinks.statementLink(inHTML: html, baseURL: base).statement.flatMap(URL.init(string:)),
               next != url {
                return try await fetch(next, depth: depth + 1)
            }
            if depth == 0, MoodleLinks.activityModule(of: url) != nil, MoodleLinks.workaroundPage(url) != url {
                return try await fetch(MoodleLinks.workaroundPage(url), depth: depth + 1)
            }
            throw WebContentScraper.ScrapeError.unreadable(base.path.contains("/login")
                ? String(localized: "la connexion Moodle a expiré : reconnecte-toi dans l'onglet Moodle de l'import")
                : String(localized: "ce lien ne mène pas à un PDF"))
        }
        let name = response.suggestedFilename ?? "serie.pdf"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + name)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return (destination, response.url ?? url)
    }

    /// Le **texte** d'une page web ou d'un PDF (plan d'un cours), lu avec la
    /// session des sites EPFL. `nil` si illisible.
    @MainActor
    static func text(at address: URL) async -> String? {
        await document(at: address)?.body
    }

    /// Le texte d'une adresse et sa nature (PDF ou page). `pages` limite la
    /// lecture d'un PDF à ses premières pages (un aperçu) — et le
    /// téléchargement à `previewLimit` octets : un polycopié de 80 Mo n'était
    /// téléchargé en entier que pour en lire deux pages.
    @MainActor
    static func document(at address: URL, timeout: TimeInterval = 30, pages: Int? = nil) async -> (body: String, isPDF: Bool)? {
        let url = SiteLinks.normalize(address)
        let session = await authenticatedSession(for: url)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        if pages != nil {
            guard let (bytes, head) = try? await session.bytes(for: request) else { return nil }
            response = head
            if head.expectedContentLength > Int64(previewLimit) {
                // Trop gros pour un aperçu : on sait au moins ce que c'est.
                bytes.task.cancel()
                return isPDF(head) ? ("", true) : nil
            }
            var buffer = Data()
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count > previewLimit { bytes.task.cancel(); break }
                }
            } catch { return nil }
            data = buffer
        } else {
            guard let (body, head) = try? await session.data(for: request) else { return nil }
            data = body
            response = head
        }
        if isPDF(response) || data.starts(with: Data("%PDF".utf8)) {
            guard let pdf = PDFDocument(data: data) else { return ("", true) }
            let count = min(pdf.pageCount, pages ?? pdf.pageCount)
            let body = TextRepair.composeAccents((0..<count).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n"))
            return body.isEmpty ? nil : (body, true)
        }
        guard let body = Self.plainText(fromHTML: String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "") else { return nil }
        return (body, false)
    }

    /// Le texte lisible d'une page HTML, une ligne par bloc.
    static func plainText(fromHTML html: String) -> String? {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</(p|div|tr|li|h\d)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = MoodleLinks.decodeEntities(text).replacingOccurrences(of: "&eacute;", with: "é")
            .replacingOccurrences(of: "&egrave;", with: "è").replacingOccurrences(of: "&agrave;", with: "à")
        let lines = text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Un aperçu ne télécharge pas plus de 8 Mo.
    static let previewLimit = 8_000_000

    private static func isPDF(_ response: URLResponse) -> Bool {
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        return type.contains("pdf") || response.suggestedFilename?.lowercased().hasSuffix(".pdf") == true
    }

    /// Une session avec tous les cookies EPFL du navigateur intégré : une
    /// ressource Moodle redirige vers `pluginfile.php`, parfois via la page de
    /// connexion.
    @MainActor
    private static func authenticatedSession(for url: URL) async -> URLSession {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let relevant = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return Institution.current.owns(host: domain) || url.host?.hasSuffix(domain) == true
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage?.setCookies(relevant, for: url, mainDocumentURL: url)
        for cookie in relevant { configuration.httpCookieStorage?.setCookie(cookie) }
        return URLSession(configuration: configuration)
    }
}
