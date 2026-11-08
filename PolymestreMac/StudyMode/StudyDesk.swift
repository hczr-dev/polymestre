import AppKit
import CryptoKit
import Foundation
import Observation
import PDFKit
import SwiftUI

/// Le bureau du mode étude : un seul endroit pour tout ce qui sert à
/// travailler — la série, le cours (Polymestre, Moodle, Botafogo), Claude, la
/// calculatrice, et le navigateur en dernier recours.
@MainActor
@Observable
final class StudyDesk {
    /// Les outils du centre. Claude n'en est pas : il flotte, ou s'ancre à côté.
    enum Pane: String, CaseIterable, Identifiable {
        case desk, exercise, course, notes, calc, web, music
        var id: String { rawValue }

        var title: String {
            switch self {
            case .desk: return "Bureau"
            case .exercise: return String(localized: "Série")
            case .course: return String(localized: "Cours")
            case .notes: return "Notes"
            case .calc: return String(localized: "Calcul")
            case .web: return "Web"
            case .music: return String(localized: "Musique")
            }
        }

        var icon: String {
            switch self {
            case .desk: return "moon.stars"
            case .exercise: return "doc.text"
            case .course: return "books.vertical"
            case .notes: return "pencil.and.scribble"
            case .calc: return "function"
            case .web: return "globe"
            case .music: return "music.note"
            }
        }

        var shortcut: KeyEquivalent {
            KeyEquivalent(Character("\((Self.allCases.firstIndex(of: self) ?? 0) + 1)"))
        }
    }

    // MARK: Le centre

    /// L'outil au centre. Un outil ouvert une fois reste vivant, caché : on le
    /// retrouve tel qu'on l'a laissé (le document lu, la page, le cahier).
    var pane: Pane = .desk {
        didSet {
            opened.insert(pane)
            if !applying {
                pins.center = true
                // Barres flottantes : un outil choisi dans la colonne ramène le bureau devant.
                if StudyModeController.shared.screen.panels { StudyModeController.shared.present() }
            }
        }
    }

    // MARK: Le bureau s'arrange

    /// Ce que l'étudiant·e a déplacé à la main : le bureau n'y touche plus jusqu'au
    /// moment suivant (`DeskArrangement.pins`).
    var pins = DeskArrangement.Pins()
    /// La clé du dernier arrangement appliqué.
    var lastSignature: String?
    /// Vrai pendant qu'un arrangement s'applique : ce ne sont pas des gestes.
    var applying = false
    private(set) var opened: Set<Pane> = [.desk]

    // MARK: À côté

    /// Ce qu'on garde à côté du centre, en onglets : l'énoncé, un cahier, un
    /// PDF du cours, le corrigé, la fiche, Claude ancré…
    struct SideItem: Identifiable {
        enum Kind: Equatable {
            case series, claude, calc, courseNotes, sheet, poly
            case notebook(path: String)
            case reading(CoursePane.Reading)
        }
        let id = UUID()
        var kind: Kind
        var title: String
        var icon: String
        /// Le cours du document (`nil` : de tous les cours, comme Claude).
        var courseID: UUID?

        func same(_ other: SideItem) -> Bool { kind == other.kind && courseID == other.courseID }
    }

    private(set) var sideItems: [SideItem] = []
    var sideSelection: SideItem.ID?
    var sideOpen = UserDefaults.standard.bool(forKey: "desk.sideOpen") {
        didSet {
            UserDefaults.standard.set(sideOpen, forKey: "desk.sideOpen")
            if !applying { pins.side = true }
        }
    }
    var sideWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "desk.sideWidth")
        return saved > 0 ? saved : 460
    }() {
        didSet { UserDefaults.standard.set(Double(sideWidth), forKey: "desk.sideWidth") }
    }

    static let sideMinimum: CGFloat = 320
    /// Ce que le centre garde au moins quand on élargit le volet.
    static let centerMinimum: CGFloat = 520

    var selectedSide: SideItem? { sideItems.first { $0.id == sideSelection } }

    /// Ouvrir à côté (déjà là : on y va).
    func openSide(_ item: SideItem) {
        if let existing = sideItems.first(where: { $0.same(item) }) {
            sideSelection = existing.id
        } else {
            sideItems.append(item)
            sideSelection = item.id
        }
        sideOpen = true
    }

    func closeSide(_ id: SideItem.ID) {
        if !applying { pins.side = true }
        guard let index = sideItems.firstIndex(where: { $0.id == id }) else { return }
        let item = sideItems.remove(at: index)
        if item.kind == .claude { claudePlacement = .floating }
        if sideSelection == id {
            sideSelection = sideItems.indices.contains(index) ? sideItems[index].id : sideItems.last?.id
        }
    }

    /// Passer à l'onglet d'à côté suivant (⌃⇥).
    func cycleSide(by offset: Int, among items: [SideItem]) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == sideSelection } ?? 0
        sideSelection = items[(current + offset + items.count) % items.count].id
        sideOpen = true
    }

    // MARK: Claude, flottant ou ancré

    enum ClaudePlacement: String { case floating, docked }

    var claudePlacement: ClaudePlacement = ClaudePlacement(rawValue: UserDefaults.standard.string(forKey: "desk.claude") ?? "") ?? .floating {
        didSet { UserDefaults.standard.set(claudePlacement.rawValue, forKey: "desk.claude") }
    }
    /// Claude a répondu pendant qu'on ne le regardait pas (un point sur la colonne d'outils).
    var claudeUnread = false
    /// La fenêtre flottante, montrée ou rangée.
    var claudeShown = false {
        didSet { if claudeShown { claudeOpened = true } }
    }
    /// Ouverte une fois : elle reste vivante (le brouillon, les pièces jointes).
    private(set) var claudeOpened = false

    /// Où flotte Claude, dans le bureau (`nil` : en bas à droite).
    var claudeFrame: CGRect? = {
        let parts = (UserDefaults.standard.string(forKey: "desk.claudeFrame") ?? "").split(separator: ",").compactMap { Double($0) }
        return parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]) : nil
    }() {
        didSet {
            let value = claudeFrame.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }
            UserDefaults.standard.set(value, forKey: "desk.claudeFrame")
        }
    }

    private var claudeItem: SideItem { SideItem(kind: .claude, title: "Claude", icon: "sparkle", courseID: nil) }

    var claudeVisible: Bool {
        claudePlacement == .floating ? claudeShown : (sideOpen && selectedSide?.kind == .claude)
    }

    func showClaude() {
        claudeUnread = false
        if !applying { pins.claude = true }
        if claudePlacement == .docked { openSide(claudeItem) } else { claudeShown = true }
    }

    /// ⌘J, le rail : montrer ou ranger Claude, où qu'il soit.
    func toggleClaude() {
        if claudeVisible {
            if claudePlacement == .floating { claudeShown = false } else { sideOpen = false }
        } else {
            showClaude()
        }
    }

    func dockClaude() {
        claudeShown = false
        claudePlacement = .docked
        openSide(claudeItem)
    }

    func floatClaude() {
        if let item = sideItems.first(where: { $0.kind == .claude }) { closeSide(item.id) }
        claudePlacement = .floating
        claudeShown = true
    }

    // MARK: Claude

    /// Une conversation par série : on retrouve la sienne en y revenant, et
    /// Claude Code la garde d'un lancement de l'app à l'autre. Une conversation
    /// libre (`nil`) quand la session ne vise pas d'exercice.
    private(set) var chats: [UUID?: ClaudeChat] = [:]

    /// La configuration de Claude (projet, CLAUDE.md, connecteurs), prête
    /// d'avance : chaque fenêtre de Claude la reprend au lieu de la refaire.
    private var claudeSetup: (key: String, config: ClaudeChat.Config)?

    func claudeConfig(for key: String) -> ClaudeChat.Config? {
        claudeSetup?.key == key ? claudeSetup?.config : nil
    }

    func storeClaudeConfig(_ config: ClaudeChat.Config, for key: String) {
        claudeSetup = (key, config)
    }

    /// À l'entrée en mode étude, sans rien afficher.
    func prepareClaude(settings: MacSettings, courses: [Course]) async {
        let key = ClaudePane.configKey(settings: settings)
        guard claudeConfig(for: key) == nil else { return }
        storeClaudeConfig(await ClaudeProjectSetup.config(settings: settings, courses: courses), for: key)
    }

    func chat(series seriesID: UUID?, config: ClaudeChat.Config) -> ClaudeChat {
        // Le réglage « projet EPFL » a changé : une autre conversation.
        if let chat = chats[seriesID], chat.config == config { return chat }
        chats[seriesID]?.close()
        let chat = ClaudeChat(seriesID: seriesID, config: config)
        chats[seriesID] = chat
        return chat
    }

    /// Une question préparée ailleurs (« Demander à Claude » sur un exercice).
    var pendingQuestion: String?
    var pendingAttachSeries = false
    /// Une pièce jointe préparée avec la question (ta copie GoodNotes).
    var pendingAttachment: ClaudeTutor.Attachment?
    /// Montrer ta copie (GoodNotes) à la place de l'énoncé.
    var showingCopy = false

    /// Une question pour Claude, avec une pièce jointe (ta copie) ou le PDF de la série.
    func ask(_ question: String, attachment: ClaudeTutor.Attachment?) {
        pendingAttachment = attachment
        ask(question, attachSeries: attachment == nil)
    }

    /// Claude s'ouvre par-dessus ou à côté : l'énoncé reste là.
    func ask(_ question: String, attachSeries: Bool = true) {
        pendingQuestion = question
        pendingAttachSeries = attachSeries
        showClaude()
    }

    // MARK: Depuis l'iPhone

    /// Une copie arrivée de l'iPhone, à joindre au prochain message (sans l'envoyer).
    var pendingDraftAttachment: ClaudeTutor.Attachment?
    /// Une photo, un « je bloque », une question venus de l'iPhone.
    func receive(_ drop: DeskDrop) {
        let attachment = drop.document.map {
            ClaudeTutor.Attachment(kind: drop.isPDF ? .pdf : .image(mime: "image/jpeg"), data: $0,
                                   name: drop.isPDF ? "Copie (iPhone).pdf" : "Photo (iPhone).jpg")
        }
        switch drop.intent {
        case .copy:
            pendingDraftAttachment = attachment
            showClaude()
            DeskNotifications.shared.post(.iPhone, String(localized: "Ta copie, depuis l'iPhone : jointe à la conversation"), icon: "iphone.and.arrow.forward")
        case .stuck:
            ask(drop.question ?? "Je bloque. Voici ma tentative (photo prise à l'iPhone) : dis-moi où ça décroche et donne-moi l'indice du niveau minimal suffisant, sans la solution.",
                attachment: attachment)
            DeskNotifications.shared.post(.iPhone, String(localized: "« Je bloque », depuis l'iPhone"), icon: "iphone.and.arrow.forward")
        case .ask:
            if let question = drop.question, !question.isEmpty {
                if let attachment { ask(question, attachment: attachment) } else { ask(question) }
                DeskNotifications.shared.post(.iPhone, String(localized: "Ta question, depuis l'iPhone"), icon: "iphone.and.arrow.forward")
            }
        }
    }

    // MARK: Calcul

    /// La calculatrice (partagée avec l'iPhone : `StudyKit/CalcPane.swift`).
    let calc = CalcModel()

    // MARK: Sites (partagés avec l'iPhone : `StudyKit/SiteHub.swift`)

    let sites = SiteHub.shared
    typealias Load = SiteHub.Load
    var documents: [String: Load] { sites.documents }
    func document(_ address: String) -> Load? { sites.document(address) }
    func loadPDF(_ address: String) { sites.loadPDF(address) }
    func retry(_ address: String) { sites.retry(address) }
    var openedDocument: (title: String, address: String)? {
        get { sites.openedDocument }
        set { sites.openedDocument = newValue }
    }
    var moodle: MoodleClient { sites.moodle }
    var moodleOutlines: [Int: MoodleCourseSnapshot] { get { sites.moodleOutlines } set { sites.moodleOutlines = newValue } }
    var moodlePages: [Int: MoodleCoursePage] { get { sites.moodlePages } set { sites.moodlePages = newValue } }
    var moodleError: [Int: String] { get { sites.moodleError } set { sites.moodleError = newValue } }
    var courseware: CoursewareClient { sites.courseware }
    var ed: EdClient { sites.ed }
    var edCourses: [EdDiscussion.Course]? { get { sites.edCourses } set { sites.edCourses = newValue } }
    var edNeedsLogin: Bool { get { sites.edNeedsLogin } set { sites.edNeedsLogin = newValue } }
    var edThreads: [Int: [EdDiscussion.Thread]] { get { sites.edThreads } set { sites.edThreads = newValue } }
    var edLessons: [Int: [EdDiscussion.Lesson]] { get { sites.edLessons } set { sites.edLessons = newValue } }
    func loadEdCourses() async { await sites.loadEdCourses() }
    var mediaspace: MediaSpaceClient { sites.mediaspace }
    var edxOutlines: [String: EdXOutline] { get { sites.edxOutlines } set { sites.edxOutlines = newValue } }
    var signIn: StudySite? { get { sites.signIn } set { sites.signIn = newValue } }
    var signInRevision: Int { sites.signInRevision }
    func signedIn(_ site: StudySite) { sites.signedIn(site) }

    func closeAll() {
        for chat in chats.values { chat.close() }
    }
}
