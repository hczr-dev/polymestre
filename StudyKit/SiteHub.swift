import CryptoKit
import Foundation
import Observation
import PDFKit

/// Les sites du cours, **les mêmes sur l'iPhone et le Mac** : les clients
/// (Moodle, Courseware, MediaSpace, Ed), ce qu'on en a déjà lu (pages de cours,
/// plans, fils), les PDF téléchargés, et la connexion. Les lecteurs natifs
/// (`StudyKit`) lisent ici ; le bureau du Mac et le mode étude de l'iPhone
/// aussi. Les adresses viennent du profil de l'école (`Institution`).
@MainActor
@Observable
final class SiteHub {
    static let shared = SiteHub()

    // MARK: Botafogo

    /// Un livre par site Botafogo, partagé par le cours, la série et le côte à
    /// côte : le programme, le sommaire et chaque document ne se chargent qu'une fois.
    @ObservationIgnored private var botafogoBooks: [String: BotafogoBook] = [:]

    func botafogo(_ site: URL) -> BotafogoBook {
        let key = BotafogoParser.courseRoot(of: site).absoluteString
        if let book = botafogoBooks[key] { return book }
        let book = BotafogoBook()
        botafogoBooks[key] = book
        return book
    }

    // MARK: Documents

    /// Les PDF ouverts (séries, documents du cours), par adresse.
    enum Load: Equatable {
        case loading
        case ready(URL)
        case needsLogin
        case failed(String)
    }

    private(set) var documents: [String: Load] = [:]
    /// Les documents déjà retentés après une reconnexion silencieuse.
    @ObservationIgnored private var retried: Set<String> = []

    func document(_ address: String) -> Load? { documents[address] }

    /// Télécharge un PDF dans la session de Moodle (gardé en cache) : la
    /// connexion faite une fois dans le navigateur du mode étude sert ici.
    func loadPDF(_ address: String) {
        // Un fichier déjà sur le Mac (un PDF glissé, l'essai de débogage).
        if let url = URL(string: address), url.isFileURL, PDFDocument(url: url) != nil {
            documents[address] = .ready(url)
            return
        }
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else {
            documents[address] = .failed(String(localized: "Pas de document."))
            return
        }
        if case .ready? = documents[address] { return }
        if case .loading? = documents[address] { return }
        let cached = Self.cacheURL(for: address)
        if FileManager.default.fileExists(atPath: cached.path), PDFDocument(url: cached) != nil {
            documents[address] = .ready(cached)
            return
        }
        documents[address] = .loading
        Task { @MainActor in
            do {
                let file = try await AuthenticatedDownloader.download(url)
                guard PDFDocument(url: file) != nil else {
                    throw URLError(.userAuthenticationRequired)
                }
                try? FileManager.default.removeItem(at: cached)
                try FileManager.default.copyItem(at: file, to: cached)
                documents[address] = .ready(cached)
            } catch {
                // Une page HTML à la place du PDF, sur un site EPFL : la session a
                // expiré. On se reconnecte sans rien afficher, puis on réessaie une fois.
                if Institution.current.owns(host: url.host), !retried.contains(address) {
                    retried.insert(address)
                    await SchoolConnect.shared.refresh(.moodle)
                    if SchoolConnect.shared.state(.moodle) == .connected {
                        documents[address] = nil
                        loadPDF(address)
                        return
                    }
                }
                documents[address] = Institution.current.owns(host: url.host) ? .needsLogin : .failed(String(localized: "Document introuvable."))
            }
        }
    }

    /// Le fichier d'un PDF, attendu (la fiche lit tout le cours d'un trait) :
    /// le cache, sinon un téléchargement dans la session. `nil` : illisible.
    func pdfFile(_ address: String) async -> URL? {
        if let url = URL(string: address), url.isFileURL { return PDFDocument(url: url) != nil ? url : nil }
        if case .ready(let file)? = documents[address] { return file }
        let cached = Self.cacheURL(for: address)
        if FileManager.default.fileExists(atPath: cached.path), PDFDocument(url: cached) != nil { return cached }
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true,
              let file = try? await AuthenticatedDownloader.download(url), PDFDocument(url: file) != nil else { return nil }
        try? FileManager.default.removeItem(at: cached)
        guard (try? FileManager.default.copyItem(at: file, to: cached)) != nil else { return file }
        documents[address] = .ready(cached)
        return cached
    }

    /// Le document a changé à la source : la prochaine lecture le retélécharge.
    func forget(_ address: String) {
        documents[address] = nil
        try? FileManager.default.removeItem(at: Self.cacheURL(for: address))
    }

    func retry(_ address: String) {
        documents[address] = nil
        try? FileManager.default.removeItem(at: Self.cacheURL(for: address))
        loadPDF(address)
    }

    static func cacheURL(for address: String) -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Polymestre/pdf", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(address.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".pdf")
    }

    /// Un PDF ouvert hors série (un document du cours, un fichier Moodle).
    var openedDocument: (title: String, address: String)?

    // MARK: Moodle et Botafogo

    let moodle = MoodleClient()
    var moodleOutlines: [Int: MoodleCourseSnapshot] = [:]
    var moodlePages: [Int: MoodleCoursePage] = [:]
    var moodleError: [Int: String] = [:]

    /// La page du cours d'abord (texte des semaines, achèvement) ; le plan seul
    /// en secours ; une reconnexion silencieuse si Moodle demande la connexion.
    /// Le bureau (onglet Cours, accueil « En cours ») et l'iPhone la partagent.
    func loadMoodlePage(_ id: Int, title: String) async {
        moodleError[id] = nil
        await SchoolConnect.shared.ensure(.moodle)
        try? await moodle.prepare(force: true)
        for attempt in 0..<2 {
            do {
                moodlePages[id] = try await moodle.coursePage(courseID: id)
                return
            } catch HiddenSiteSession.SiteError.notSignedIn where attempt == 0 {
                await SchoolConnect.shared.refresh(.moodle)
                try? await moodle.prepare(force: true)
                continue
            } catch {
                if let outline = try? await moodle.outline(courseID: id, title: title) {
                    moodlePages[id] = MoodleCoursePage(snapshot: outline)
                    return
                }
                moodleError[id] = String(localized: "Connecte-toi à Moodle.")
                return
            }
        }
        moodleError[id] = String(localized: "Connecte-toi à Moodle.")
    }

    /// Ce qu'un autre écran demande d'ouvrir dans l'onglet Cours (l'accueil
    /// « En cours » : les diapositives, l'enregistrement à un repère, Ed).
    struct Request: Equatable {
        var courseID: UUID
        var source: CoursePane.Source
        var reading: CoursePane.Reading?
    }
    var request: Request?

    // MARK: Courseware et MediaSpace

    let courseware = CoursewareClient()
    let ed = EdClient()
    /// Les cours Ed de l'étudiant·e (`nil` : pas encore lus).
    var edCourses: [EdDiscussion.Course]?
    var edNeedsLogin = false
    var edThreads: [Int: [EdDiscussion.Thread]] = [:]
    var edLessons: [Int: [EdDiscussion.Lesson]] = [:]

    /// Lit les cours Ed une fois (et après une connexion).
    func loadEdCourses() async {
        guard edCourses == nil else { return }
        await SchoolConnect.shared.ensure(.ed)
        do {
            edCourses = try await ed.courses()
            edNeedsLogin = false
        } catch HiddenSiteSession.SiteError.notSignedIn {
            edNeedsLogin = true
        } catch {}
    }
    let mediaspace = MediaSpaceClient()
    var edxOutlines: [String: EdXOutline] = [:]

    // MARK: Connexion

    /// Le site où se connecter (la feuille de connexion, seule page web du bureau).
    var signIn: StudySite?
    /// Augmente à chaque connexion réussie : les lecteurs réessaient.
    private(set) var signInRevision = 0

    func signedIn(_ site: StudySite) {
        if site == .mediaspace {
            Task { await SchoolConnect.shared.connect(.mediaspace); signInRevision += 1 }
            return
        }
        // Connecté·e à Microsoft par Moodle : les autres sites suivent, sans rien
        // afficher (`SchoolConnect`).
        moodleError = [:]
        for (address, load) in documents where load == .needsLogin { documents[address] = nil }
        Task {
            try? await moodle.prepare(force: true)
            signInRevision += 1
            await SchoolConnect.shared.connectAll(prompting: true, force: true)
            ed.reset()
            edCourses = nil
            edNeedsLogin = false
            edThreads = [:]
            await loadEdCourses()
            signInRevision += 1
        }
    }

}
