import Foundation

/// Le **mode étude** : pendant une session, le Mac et l'iPhone n'ouvrent que ce
/// qui sert à travailler — les sites de cours (Moodle, Courseware, Botafogo…),
/// Claude pour l'aide, GoodNotes pour écrire.
///
/// Il n'a pas d'état à lui : c'est une date (`FocusTimerState.studyUntil`) portée
/// par le chrono partagé. Démarré sur un appareil, il arrive sur l'autre par les
/// mêmes voies que « play » ; terminer la session le termine partout. Les
/// décisions sont ici, pures et testées ; le blocage lui-même est propre à
/// chaque système (fenêtres et activations sur le Mac, Temps d'écran sur
/// l'iPhone).
enum StudyMode {

    /// Les durées proposées au lancement, en minutes.
    static let durations = [25, 50, 90, 120]

    /// Les bornes d'une durée choisie à la main (5 min à 12 h).
    static let minuteRange = 5...720

    /// « Jusqu'à 18 h 30 » → la durée en minutes depuis maintenant. Une heure
    /// déjà passée aujourd'hui vise demain ; bornée à `minuteRange`.
    static func minutes(until time: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        var target = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) ?? now
        if target <= now { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target }
        let minutes = Int((target.timeIntervalSince(now) / 60).rounded(.up))
        return min(max(minutes, minuteRange.lowerBound), minuteRange.upperBound)
    }

    // MARK: Pendant la session

    /// Le mode étude est-il en vigueur à `now` ?
    static func isActive(_ state: FocusTimerState?, at now: Date = Date()) -> Bool {
        guard let until = state?.studyUntil else { return false }
        return now < until
    }

    // MARK: Sans fin

    /// L'échéance d'un mode étude **sans fin** : on s'arrête quand on veut.
    /// Une date lointaine plutôt qu'un champ de plus : un appareil plus ancien
    /// y voit une très longue session, et le reste (actif, blocage) suit.
    static let openEnd = Date.distantFuture

    /// Le mode étude n'a pas d'heure de fin.
    static func isOpenEnded(_ state: FocusTimerState?) -> Bool {
        guard let until = state?.studyUntil else { return false }
        return until.timeIntervalSinceReferenceDate > openEnd.timeIntervalSinceReferenceDate - 86_400 * 365
    }

    /// Le temps passé en mode étude (depuis `studySince`).
    static func elapsed(_ state: FocusTimerState?, at now: Date = Date()) -> TimeInterval {
        guard state?.studyUntil != nil else { return 0 }
        return max(0, now.timeIntervalSince(state?.studySince ?? state?.sessionStartedAt ?? now))
    }

    /// Ce que montre l'horloge : ce qui reste, ou, sans fin, le temps passé.
    static func clock(_ state: FocusTimerState?, at now: Date = Date()) -> TimeInterval {
        isOpenEnded(state) ? elapsed(state, at: now).rounded(.down) : remaining(state, at: now).rounded(.up)
    }

    /// L'origine des secondes de l'horloge (les vues s'y calent pour battre
    /// juste) : l'échéance, ou le début pour une session sans fin.
    static func tickAnchor(_ state: FocusTimerState?) -> Date {
        let anchor = isOpenEnded(state) ? (state?.studySince ?? Date()) : (state?.studyUntil ?? Date())
        return anchor.addingTimeInterval(0.05)
    }

    /// Ce qui reste, en secondes (zéro une fois passé).
    static func remaining(_ state: FocusTimerState?, at now: Date = Date()) -> TimeInterval {
        guard let until = state?.studyUntil else { return 0 }
        return max(0, until.timeIntervalSince(now))
    }

    /// La fraction écoulée du mode étude (0 → 1), depuis `studySince`.
    static func progress(_ state: FocusTimerState?, at now: Date = Date()) -> Double {
        progress(state, since: state?.studySince ?? state?.sessionStartedAt ?? now, at: now)
    }

    static func progress(_ state: FocusTimerState?, since start: Date, at now: Date = Date()) -> Double {
        guard let until = state?.studyUntil else { return 0 }
        // Sans fin : l'anneau fait le tour en une heure, puis recommence.
        if isOpenEnded(state) { return now.timeIntervalSince(start).truncatingRemainder(dividingBy: 3600) / 3600 }
        let total = until.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(start) / total))
    }

    /// Le mode étude a fini (la date est passée) mais la session tourne
    /// encore : on propose de terminer ou de prolonger.
    static func isOver(_ state: FocusTimerState?, at now: Date = Date()) -> Bool {
        guard let until = state?.studyUntil else { return false }
        return now >= until
    }

    /// Prolonger : à partir de la fin prévue si elle n'est pas passée, sinon de
    /// maintenant — prolonger après coup ne doit pas rendre des minutes déjà
    /// écoulées.
    static func extended(_ until: Date?, by minutes: Int, now: Date = Date()) -> Date {
        if let until, until >= openEnd.addingTimeInterval(-86_400 * 365) { return until }
        let base = max(until ?? now, now)
        return base.addingTimeInterval(TimeInterval(minutes * 60))
    }

    // MARK: Blocage par défaut

    /// Bloquer le reste se **choisit** : une nouvelle installation ouvre le mode
    /// étude sans rien bloquer — qui essaie l'app ne doit pas se retrouver
    /// l'iPhone fermé pour 1 h 45 en touchant « Suivre le cours ». Qui s'en
    /// servait avec l'ancien défaut (bloquer) le garde : la valeur est écrite une
    /// fois, au premier lancement de cette version, et un choix déjà fait n'est
    /// jamais touché.
    static func settleBlockingDefaults(_ keys: [String], existingUser: Bool, in defaults: UserDefaults = .standard) {
        for key in keys where defaults.object(forKey: key) == nil {
            defaults.set(existingUser, forKey: key)
        }
    }

    /// Entre en mode étude pour `minutes` à partir de `now` ; `nil` : sans fin.
    static func enter(_ state: inout FocusTimerState, minutes: Int?, locks: Bool = true, now: Date = Date()) {
        state.studySince = now
        state.studyUntil = minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) } ?? openEnd
        state.studyLocks = locks ? nil : false
    }

    /// Le mode étude est actif **et** bloque le reste. Sans blocage, c'est un
    /// écran de travail : aucune app fermée, aucun site refusé, l'iPhone libre.
    static func blocks(_ state: FocusTimerState?, at now: Date = Date()) -> Bool {
        isActive(state, at: now) && state?.studyLocks != false
    }

    /// Le **verrou** : le reste est bloqué et on ne sort pas avant l'heure
    /// (sauf par la sortie d'urgence). Une session sans fin bloque, mais ne
    /// verrouille pas — sans heure, on la termine quand on a fini.
    static func locks(_ state: FocusTimerState?, at now: Date = Date()) -> Bool {
        blocks(state, at: now) && !isOpenEnded(state)
    }

    /// Le bouclier de l'iPhone d'une session sans fin se lève de lui-même au
    /// bout de ce temps, si l'app ne s'est pas réveillée pour le lever.
    static let openEndedShieldSafety: TimeInterval = 12 * 3600

    // MARK: Verrou

    /// La sortie d'urgence : secondes à tenir pour lever un verrou avant
    /// l'heure. Assez long pour n'être jamais un réflexe.
    static let emergencyHold: Double = 8

    /// Peut-on terminer, abandonner ou sortir maintenant ? Libre sans verrou ;
    /// sous verrou, seulement une fois l'heure passée.
    static func canLeave(_ state: FocusTimerState?, at now: Date = Date()) -> Bool {
        !locks(state, at: now)
    }

    /// La note d'une session levée par la sortie d'urgence (une fois).
    static func emergencyNote(_ note: String) -> String {
        let mark = String(localized: "Sortie d'urgence")
        guard !note.contains(mark) else { return note }
        return note.isEmpty ? mark : note + " · " + mark
    }

    /// Lève le mode étude (la session continue).
    static func leave(_ state: inout FocusTimerState) {
        state.studyUntil = nil
        state.studySince = nil
        state.studyLocks = nil
    }

    // MARK: Sites permis

    /// Les sites ouverts par défaut. Un domaine couvre ses sous-domaines :
    /// `epfl.ch` laisse passer moodle, courseware, botafogo, mediaspace, la
    /// connexion Tequila… Les pages de connexion (Microsoft, Google, Apple)
    /// sont là pour que se connecter à Moodle ou à Claude reste possible.
    static var defaultSites: [String] { defaultSites(for: Institution.current) }

    /// Les sites de l'école (son profil : `epfl.ch`, Kaltura, Ed…), puis ceux de
    /// tout le monde (Claude, connexions, calcul).
    static func defaultSites(for institution: Institution) -> [String] {
        var sites = institution.studyDomains
        for site in ["claude.ai", "anthropic.com", "claudeusercontent.com",
                     "login.microsoftonline.com", "login.live.com", "msauth.net", "msftauth.net",
                     "accounts.google.com", "appleid.apple.com",
                     "geogebra.org", "desmos.com", "wolframalpha.com",
                     "speakup.info", "wooclap.com", "app.wooclap.com", "particify.de"] where !sites.contains(site) {
            sites.append(site)
        }
        return sites
    }

    /// La plomberie : pages de connexion (edu-ID, Microsoft, Google, Apple) et
    /// hébergeurs de contenu (vidéos Kaltura, pièces jointes d'Ed, fichiers de
    /// Claude). Sans eux Moodle ou Claude ne s'ouvrent pas, mais ce ne sont pas des
    /// sites où l'on va : les réglages les replient en une ligne au lieu de
    /// seize adresses que personne ne reconnaît.
    static let serviceSites: Set<String> = ["switch.ch", "kaltura.com", "edusercontent.com", "openlearnity.org",
                                            "login.microsoftonline.com", "login.live.com", "msauth.net", "msftauth.net",
                                            "accounts.google.com", "appleid.apple.com",
                                            "anthropic.com", "claudeusercontent.com", "app.wooclap.com"]

    /// La liste des réglages en deux : les sites qu'on reconnaît, dans leur
    /// ordre, et la plomberie. Rien n'est retiré de la liste elle-même.
    static func siteGroups(_ sites: [String]) -> (named: [String], service: [String]) {
        (sites.filter { !serviceSites.contains($0) }, sites.filter { serviceSites.contains($0) })
    }

    /// Les sites ajoutés à la liste par défaut après coup : ils rejoignent une
    /// liste déjà enregistrée (sans rétablir ceux qu'on a retirés).
    static let addedLater: Set<String> = ["geogebra.org", "desmos.com", "wolframalpha.com",
                                          "edstem.org", "edusercontent.com", "openlearnity.org",
                                          "speakup.info", "wooclap.com", "app.wooclap.com", "particify.de"]

    /// `https://www.Moodle.epfl.ch/my/` → `moodle.epfl.ch`. Ce que l'utilisateur·rice
    /// tape dans les réglages, ramené à un domaine ; `nil` si ce n'en est pas un.
    static func normalizedDomain(_ entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        while text.hasSuffix(".") { text.removeLast() }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard text.contains("."), !text.hasPrefix("."), !text.contains(".."),
              text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return text
    }

    /// Ce site est-il permis ? Un domaine permet ses sous-domaines, **à une
    /// frontière de point** : `epfl.ch` permet `moodle.epfl.ch`, pas `notepfl.ch`.
    static func isAllowed(host: String?, sites: [String]) -> Bool {
        guard let host = host.flatMap(normalizedDomain) else { return false }
        return sites.compactMap(normalizedDomain).contains { site in
            host == site || host.hasSuffix("." + site)
        }
    }

    /// Une adresse est-elle permise ? Les pages internes (`about:blank`, un PDF
    /// ouvert en mémoire) le sont toujours : elles ne mènent nulle part.
    static func isAllowed(url: URL?, sites: [String]) -> Bool {
        guard let url else { return false }
        switch url.scheme?.lowercased() {
        case "about", "data", "blob": return true
        case "http", "https": return isAllowed(host: url.host, sites: sites)
        default: return false
        }
    }

    // MARK: Apps permises (Mac)

    /// Les apps permises par défaut sur le Mac. GoodNotes et Claude ont leur
    /// app ; Aperçu ouvre les PDF des séries ; Finder, pour aller les chercher.
    static let defaultMacApps: [String] = [
        "com.goodnotesapp.x",
        "com.anthropic.claudefordesktop",
        "com.apple.Preview",
        "com.apple.calculator",
    ]

    /// Le Finder n'est plus permis d'office : ⌥⌘Espace y ouvrait une fenêtre de
    /// recherche, donc tout le disque. Il n'est pas non plus fermé (le Dock le
    /// relance aussitôt) : voir `hideOnlyApps`. Une seule fois, on le retire des
    /// listes déjà enregistrées ; ensuite, c'est le choix de l'utilisateur·rice.
    static let finderBundleID = "com.apple.finder"

    static func removingFinder(from apps: [String]) -> [String] {
        apps.filter { $0 != finderBundleID }
    }

    /// Ce qui fait marcher le Mac lui-même : jamais bloqué (fenêtre de
    /// connexion, Touch ID, économiseur, Dock, Spotlight, centre de contrôle…).
    static let systemBundles: Set<String> = [
        "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.coreautha",
        "com.apple.ScreenSaver.Engine", "com.apple.dock", "com.apple.Spotlight",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.systemuiserver",
        "com.apple.screencaptureui", "com.apple.PIPAgent", "com.apple.UserNotificationCenter",
        "com.apple.universalcontrol", "com.apple.WindowManager", "com.apple.accessibility.AXVisualSupportAgent",
    ]

    /// Les apps qui travaillent pour le mode étude **en arrière-plan** : Music
    /// joue la musique choisie dans l'écran d'étude. Bloquées, elles ne sont
    /// jamais fermées — seulement masquées si elles passent au premier plan.
    static let backgroundApps: Set<String> = ["com.apple.Music"]

    /// Les apps qu'on masque quand elles passent devant, sans jamais leur
    /// demander de quitter : Music (il joue) et le Finder (le système le
    /// relance aussitôt fermé, puis on le fermerait de nouveau, sans fin).
    static let hideOnlyApps: Set<String> = backgroundApps.union([finderBundleID])

    /// Les lanceurs (Raycast, Alfred, LaunchBar) : des apps « accessoires » sans
    /// icône dans le Dock, donc ignorées par la règle des apps ordinaires, mais
    /// qui ouvrent n'importe quoi d'un raccourci. Fermés comme les autres.
    static let launcherApps: Set<String> = [
        "com.raycast.macos", "com.runningwithcrayons.Alfred", "at.obdev.LaunchBar",
        // Les sélecteurs de fenêtres : ils sortent de l'app d'un raccourci (AltTab).
        "com.lwouis.alt-tab-macos", "com.contextsformac.Contexts", "com.manytricks.Witch",
    ]

    /// Ce qu'il faut faire d'une app qui passe au premier plan.
    enum Disposition: Equatable {
        /// Permise.
        case allowed
        /// Masquée, jamais fermée (Music, Finder).
        case hideOnly
        /// Couverte, puis fermée.
        case close
        /// Hors de portée : Polymestre, le système, les agents.
        case system
    }

    static func disposition(bundleID: String?, isRegular: Bool, own: String, allowed: [String]) -> Disposition {
        guard let bundleID, !bundleID.isEmpty else { return .system }
        if bundleID == own || systemBundles.contains(bundleID) { return .system }
        // Les assistants d'une app permise (« … .helper ») le sont avec elle.
        if allowed.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) { return .allowed }
        if launcherApps.contains(bundleID) { return .close }
        guard isRegular else { return .system }
        return hideOnlyApps.contains(bundleID) ? .hideOnly : .close
    }

    /// Une app qui passe au premier plan doit-elle être arrêtée (couverte,
    /// masquée ou fermée) ? Voir `disposition` pour savoir comment.
    static func shouldBlock(bundleID: String?, isRegular: Bool, own: String, allowed: [String]) -> Bool {
        let result = disposition(bundleID: bundleID, isRegular: isRegular, own: own, allowed: allowed)
        return result == .close || result == .hideOnly
    }

    // MARK: Outils

    /// Ce que l'écran du mode étude propose d'ouvrir.
    struct Tool: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Un site, ouvert dans le navigateur du mode étude.
            case web(URL)
            /// Une app, par son identifiant (Mac) et son adresse (iPhone).
            case app(bundleID: String, scheme: String)
        }
        var id: String
        var title: String
        var subtitle: String
        var icon: String
        var kind: Kind
    }

    /// Les outils de la session : d'abord les pages du cours travaillé (sa
    /// page Moodle, ses sites), puis les outils de toujours.
    static func tools(courseName: String?, courseLinks: [String]) -> [Tool] {
        var result: [Tool] = []
        var seen: Set<String> = []
        for link in courseLinks {
            guard let url = URL(string: link), url.scheme?.hasPrefix("http") == true,
                  let host = url.host?.lowercased(), !seen.contains(url.absoluteString) else { continue }
            seen.insert(url.absoluteString)
            let (title, icon) = siteLabel(host)
            result.append(Tool(id: "course:" + url.absoluteString, title: title,
                               subtitle: courseName ?? host, icon: icon, kind: .web(url)))
        }
        // Claude n'est plus un site : il est dans l'app (le bureau du Mac).
        // Les sites de l'école (Moodle, Courseware) viennent de son profil ;
        // l'ordre reste celui d'avant : Moodle, Claude, GoodNotes, Courseware.
        var base: [Tool] = []
        if let url = Institution.current.moodleURL("/my/") {
            base.append(Tool(id: "moodle", title: "Moodle", subtitle: String(localized: "Tes cours"), icon: "graduationcap", kind: .web(url)))
        }
        base.append(Tool(id: "claude-app", title: "Claude", subtitle: String(localized: "L'app"), icon: "sparkles",
                         kind: .app(bundleID: "com.anthropic.claudefordesktop", scheme: "claude://")))
        base.append(Tool(id: "goodnotes", title: "GoodNotes", subtitle: String(localized: "Écrire"), icon: "pencil.and.scribble",
                         kind: .app(bundleID: "com.goodnotesapp.x", scheme: "goodnotes://")))
        if let url = Institution.current.coursewareURL("/dashboard") {
            base.append(Tool(id: "courseware", title: "Courseware", subtitle: String(localized: "MOOC et vidéos"), icon: "play.rectangle", kind: .web(url)))
        }
        return result + base
    }

    /// Le nom et l'icône d'un site de cours connu.
    /// Les sites **du cours** (sa page Moodle, Courseware, Botafogo, ses vidéos,
    /// Explique), sans les outils de toujours : la page du cours les montre.
    static func courseSites(_ course: Course) -> [Tool] {
        let links = [course.moodleLink?.absoluteString].compactMap { $0 } + course.contentSources
        return tools(courseName: course.name, courseLinks: links).filter { $0.id.hasPrefix("course:") }
    }

    static func siteLabel(_ host: String) -> (String, String) {
        if host.hasPrefix("moodle.") { return ("Moodle du cours", "graduationcap") }
        if host.hasPrefix("courseware.") { return ("Courseware", "play.rectangle") }
        if host.hasPrefix("botafogo.") { return ("Botafogo", "book.pages") }
        if host.hasPrefix("mediaspace.") { return ("Vidéos du cours", "video") }
        if host.hasPrefix("explique.") { return ("Explique", "text.bubble") }
        return (host.replacingOccurrences(of: "www.", with: ""), "globe")
    }
}
