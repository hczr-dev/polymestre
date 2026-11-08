import Foundation

/// L'école de l'étudiant·e, **en données** : ses sites (Moodle, Open edX, vidéos
/// Kaltura, Ed Discussion, sites propres), sa chaîne de connexion, ses
/// domaines. Le code ne connaît que des sortes de plateformes ; ce qui est
/// propre à une école vit ici. L'EPFL est le profil intégré (`.epfl`) et reprend
/// exactement les valeurs observées — rien ne change pour un·e étudiant·e de
/// l'EPFL. Une autre école est un autre profil, sans nouveau code.
struct Institution: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    /// Les domaines des adresses électroniques (« epfl.ch ») : la détection.
    var emailDomains: [String]

    struct Moodle: Codable, Equatable {
        /// `https://moodle.epfl.ch`
        var base: String
        /// L'identifiant du bouton de connexion OAuth de la page de Moodle
        /// (`auth/oauth2/login.php?id=3`, « EPFL – Entra ID »). `nil` : formulaire classique.
        var oauthProviderID: Int?
    }

    struct OpenEdX: Codable, Equatable {
        /// `https://courseware.epfl.ch`
        var base: String
        /// La connexion : `/auth/login/<backend>/` (ici `edx-oauth2`, vers OpenLearnity).
        var loginBackend: String?
        /// Le fournisseur d'identité, si la connexion passe par un SSO
        /// intermédiaire (`id.openlearnity.org`, SAML `idp=epfl-ol`).
        var ssoHost: String?
        var ssoIdP: String?
    }

    struct Video: Codable, Equatable {
        /// `mediaspace.epfl.ch`
        var host: String
        /// L'API Kaltura qui sert les manifestes (`https://api.cast.switch.ch`).
        var kalturaAPI: String
        var kalturaPartner: Int
        /// Le service de découverte (WAYF) et l'IdP à y choisir.
        var wayfHost: String?
        var identityProvider: String?
        /// L'IdP qui demande son propre mot de passe (SWITCH edu-ID).
        var passwordIdPHost: String?
    }

    struct Ed: Codable, Equatable {
        /// `eu` (edstem.org/eu, eu.edstem.org/api).
        var region: String
    }

    var moodle: Moodle?
    var openEdX: OpenEdX?
    var video: Video?
    var ed: Ed?
    /// Les sites propres à l'école lus en natif (`botafogo`, `explique`).
    var extras: [String: String] = [:]
    /// Les domaines ouverts pendant le mode étude (en plus des sites ci-dessus).
    var studyDomains: [String] = []
    /// Le calendrier académique publié.
    var calendarURL: String?

    // MARK: Adresses dérivées

    var moodleHost: String? { moodle.flatMap { URL(string: $0.base)?.host } }
    var coursewareHost: String? { openEdX.flatMap { URL(string: $0.base)?.host } }
    var edAPI: String? { ed.map { "https://\($0.region).edstem.org/api" } }
    var edApp: String? { ed.map { "https://edstem.org/\($0.region)" } }

    func moodleURL(_ path: String) -> URL? { moodle.flatMap { URL(string: $0.base + path) } }
    func coursewareURL(_ path: String) -> URL? { openEdX.flatMap { URL(string: $0.base + path) } }
    func videoURL(entryID: String) -> URL? { video.map { URL(string: "https://\($0.host)/media/t/\(entryID)")! } }

    /// Les hôtes qui appartiennent à l'école (cookies à garder, liens à suivre).
    var hosts: [String] {
        var result: [String] = []
        if let moodleHost { result.append(moodleHost) }
        if let coursewareHost { result.append(coursewareHost) }
        if let video { result.append(video.host) }
        result += extras.values.compactMap { URL(string: $0)?.host ?? $0 }
        return result
    }

    /// Les domaines « racine » de l'école (`epfl.ch`), pour les cookies.
    var rootDomains: [String] { emailDomains }

    func owns(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return rootDomains.contains { host == $0 || host.hasSuffix("." + $0) } || hosts.contains(host)
    }

    // MARK: Profils intégrés

    static let epfl = Institution(
        id: "epfl", name: "EPFL", emailDomains: ["epfl.ch"],
        moodle: Moodle(base: "https://moodle.epfl.ch", oauthProviderID: 3),
        openEdX: OpenEdX(base: "https://courseware.epfl.ch", loginBackend: "edx-oauth2",
                         ssoHost: "id.openlearnity.org", ssoIdP: "epfl-ol"),
        video: Video(host: "mediaspace.epfl.ch", kalturaAPI: "https://api.cast.switch.ch", kalturaPartner: 113,
                     wayfHost: "wayf.switch.ch", identityProvider: "https://idp.epfl.ch/idp/shibboleth",
                     passwordIdPHost: "eduid.ch"),
        ed: Ed(region: "eu"),
        extras: ["botafogo": "https://botafogo.epfl.ch", "explique": "https://explique.epfl.ch"],
        studyDomains: ["epfl.ch", "kaltura.com", "switch.ch", "edstem.org", "edusercontent.com", "openlearnity.org",
                       "login.microsoftonline.com", "login.live.com", "msauth.net", "msftauth.net"],
        calendarURL: "https://www.epfl.ch/education/studies/reglement-et-procedure/calendrier-academique/")

    /// Une école sans rien de connu : le mode étude, le chrono, les notes, Claude
    /// marchent ; les sites se règlent dans les Réglages.
    static let generic = Institution(id: "generic", name: String(localized: "Mon école"), emailDomains: [])

    static let builtIn: [Institution] = [.epfl]

    /// L'école d'une adresse (« prenom.nom@epfl.ch » → EPFL).
    static func detect(email: String, among profiles: [Institution] = builtIn) -> Institution? {
        guard let domain = email.split(separator: "@").last?.lowercased() else { return nil }
        return profiles.first { $0.emailDomains.contains { domain == $0 || domain.hasSuffix("." + $0) } }
    }

    // MARK: L'école en cours

    /// L'école choisie (réglage partagé ; l'EPFL par défaut, comme avant).
    nonisolated(unsafe) static var current: Institution = loadCurrent()

    static let storageKey = "institution.profile"

    static func loadCurrent(defaults: UserDefaults = .standard) -> Institution {
        guard let data = defaults.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(Institution.self, from: data) else { return .epfl }
        return profile
    }

    static func save(_ profile: Institution, defaults: UserDefaults = .standard) {
        current = profile
        if let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: storageKey) }
    }
}

// MARK: - Raccourcis pour les clients

extension Institution {
    /// L'hôte de chaque plateforme (repli sur l'EPFL pour un profil incomplet :
    /// les clients ne sont appelés que pour les sites que l'école a).
    var moodleHostName: String { moodleHost ?? "moodle.epfl.ch" }
    var moodleBase: String { moodle?.base ?? "https://moodle.epfl.ch" }
    var coursewareHostName: String { coursewareHost ?? "courseware.epfl.ch" }
    var coursewareBase: String { openEdX?.base ?? "https://courseware.epfl.ch" }
    var videoHostName: String { video?.host ?? "mediaspace.epfl.ch" }
    var edRegion: String { ed?.region ?? "eu" }
    var expliqueBase: String { extras["explique"] ?? "https://explique.epfl.ch" }
}
