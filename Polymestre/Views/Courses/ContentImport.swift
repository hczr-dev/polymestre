import SwiftUI
import SwiftData
import WebKit

/// « Importer du contenu » : la théorie et les séries d'un cours, depuis le site
/// où elles vivent.
///
/// L'ancien parcours demandait, pour **chaque** cours : choisir la source, se
/// connecter, trouver le cours dans Moodle, l'ouvrir, puis toucher « Importer
/// cette page ». Cinq cours, cinq fois tout le chemin. Désormais :
///   • **un toucher** importe tous les cours suivis — l'app trouve chaque cours
///     Moodle par son code (la recherche de Moodle répond sans connexion), ne
///     demande de se connecter que si Moodle l'exige (la fenêtre se ferme
///     seule), et ne pose une question que lorsqu'un code a plusieurs sections
///     auxquelles on n'est pas inscrit·e ;
///   • une **seule** relecture, cours par cours, dépliable ;
///   • ensuite, la mise à jour est **automatique** (`ContentRefresher`) : la
///     série de la semaine arrive seule.
/// Le navigateur intégré reste là pour les cas où l'automatique échoue.
struct ContentImportView: View {
    /// Le cours à remplir ; `nil` = tous les cours suivis.
    var course: Course?

    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var path: [Route] = []
    @State private var model = MoodleImportModel()
    @State private var showingSeriesPDF = false
    @State private var showingFileImport = false

    enum Route: Hashable {
        case browser(ContentSource, URL?)
        case botafogo
        case courseware
        case review
    }

    private var targets: [Course] {
        if let course { return [course] }
        return courses.filter(\.isTracked)
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            List {
                moodleSection
                Section {
                    Button { path.append(.botafogo) } label: {
                        sourceRow(icon: ContentSource.botafogo.icon, title: "Botafogo",
                                  detail: botafogoDetail)
                    }
                    Button { path.append(.courseware) } label: {
                        sourceRow(icon: ContentSource.courseware.icon, title: "Courseware",
                                  detail: String(localized: "Tes cours Open edX : chapitres, leçons et vidéos"))
                    }
                } header: {
                    Text("Autres sites")
                }
                Section {
                    Button { showingSeriesPDF = true } label: {
                        sourceRow(icon: "doc.text.magnifyingglass", title: String(localized: "Une série en PDF"),
                                  detail: String(localized: "Exercices et sous-questions lus dans l'énoncé"))
                    }
                    Button { showingFileImport = true } label: {
                        sourceRow(icon: "square.and.arrow.down", title: String(localized: "Horaire ou fichier"),
                                  detail: String(localized: "Horaire .ics d'IS-Academia, sauvegarde JSON, CSV"))
                    }
                } header: {
                    Text("Fichiers")
                }
                Section {
                    Toggle("Mettre à jour tout seul", isOn: Binding(get: { app.settings.contentAutoRefresh },
                                                                   set: { app.settings.contentAutoRefresh = $0 }))
                } footer: {
                    if !refreshFooter.isEmpty { Text(refreshFooter) }
                }
            }
            .carnetBackground()
            .navigationTitle(course.map { String(localized: "Importer · \($0.displayCode)") } ?? "Importer du contenu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .browser(let source, let start):
                    WebImportBrowser(source: source, startURL: start, course: course, onDone: { dismiss() })
                case .botafogo:
                    BotafogoPicker(course: course, onDone: { dismiss() })
                case .courseware:
                    CoursewareImportView(course: course, onDone: { dismiss() })
                case .review:
                    BatchReviewView(model: model, onDone: { dismiss() })
                }
            }
            .sheet(isPresented: $model.needsLogin) {
                SiteLoginSheet(source: .moodle) {
                    model.needsLogin = false
                    Task { await model.run(courses: targets, term: termInfo) }
                }
            }
            .sheet(item: $model.question) { question in
                SectionChoiceSheet(question: question) { choice in
                    model.answer(question, with: choice)
                }
            }
            .onChange(of: model.phase) { _, phase in
                if phase == .ready, path.last != .review { path.append(.review) }
            }
            .sheet(isPresented: $showingSeriesPDF) {
                SeriesImportSheet(course: course)
            }
            .sheet(isPresented: $showingFileImport) {
                ImportSheet()
            }
            #if DEBUG
            .onAppear {
                guard path.isEmpty, let raw = PreviewLaunch.string(PreviewLaunch.contentImportFlag) else { return }
                // `-contentImport auto` : lance l'import Moodle automatique,
                // que `simctl` ne peut pas toucher.
                if raw == "auto" || raw == "autoapply" { Task { await model.run(courses: targets, term: termInfo) } }
                switch ContentSource(rawValue: raw) {
                case .botafogo: path.append(.botafogo)
                case .courseware: path.append(.courseware)
                case .moodle: path.append(.browser(.moodle, nil))
                case nil: break
                }
            }
            #endif
        }
    }

    // MARK: Moodle

    @ViewBuilder
    private var moodleSection: some View {
        Section {
            Button {
                Task { await model.run(courses: targets, term: termInfo) }
            } label: {
                HStack(spacing: Layout.block) {
                    ZStack {
                        Circle().fill(Theme.accent.badgeFill).frame(width: 40, height: 40)
                        if model.phase == .working {
                            ProgressView()
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent.badgeInk)
                        }
                    }
                    VStack(alignment: .leading, spacing: Layout.micro) {
                        Text(course == nil ? "Importer tous mes cours depuis Moodle" : "Importer \(course!.displayCode) depuis Moodle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.primary)
                        Text(model.phase == .working ? model.progress : String(localized: "Semaines, vidéos, supports et séries — trouvés par le code du cours"))
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Layout.tight)
                .contentShape(Rectangle())
            }
            .disabled(model.phase == .working || targets.isEmpty)

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.orange.accessibleInk)
            }

            ForEach(targets) { course in
                courseStatusRow(course)
            }

            Button {
                path.append(.browser(.moodle, MoodleCourseMatcher.linkedID(in: course?.contentSources ?? [])
                    .map { URL(string: Institution.current.moodleBase + "/course/view.php?id=\($0)")! }))
            } label: {
                Label("Ouvrir Moodle et choisir la page moi-même", systemImage: "safari")
                    .font(.subheadline)
            }
        } header: {
            Text("Moodle")
        }
    }

    private func courseStatusRow(_ course: Course) -> some View {
        HStack(spacing: Layout.control) {
            Circle().fill(Carnet.tint(course.colorHex).accessibleMark).frame(width: 8, height: 8)
            Text(course.displayCode).font(.subheadline.weight(.semibold))
            Text(course.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: Layout.inline)
            Text(model.status[course.id] ?? linkLabel(course))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func linkLabel(_ course: Course) -> String {
        let sources = course.contentSources.compactMap { URL(string: $0).flatMap { ContentSource.detect(host: $0.host) }?.label }
        return sources.isEmpty ? String(localized: "pas encore importé") : String(localized: "relié : ") + Array(Set(sources)).sorted().joined(separator: ", ")
    }

    private var termInfo: MoodleImportModel.TermInfo {
        let term = targets.compactMap(\.term).first
        return .init(start: term?.startDate, weeks: term?.totalWeeks ?? 14)
    }

    private var botafogoDetail: String {
        if let course, let suggestion = BotafogoSuggestion.hint(for: course) { return String(localized: "Suggéré pour \(course.displayCode) : \(suggestion)") }
        return String(localized: "Polycopiés en ligne (Analyse, Algèbre linéaire, ICS), avec leurs vidéos")
    }

    private var refreshFooter: String {
        guard let last = app.settings.contentLastRefresh else { return "" }
        return String(localized: "Mis à jour \(DateUtils.relativeLabel(last).lowercased()) à \(DateUtils.time.string(from: last)).")
    }

    private func sourceRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Layout.block) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Theme.accentInk)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Layout.micro) {
                // Couleurs explicites : dans une liste, un bouton teinte tout son
                // libellé à l'encre de l'app, et six lignes indigo ne se lisaient plus.
                Text(ui: title).font(.body).foregroundStyle(Color.primary)
                Text(ui: detail).font(.footnote).foregroundStyle(Color.secondary)
            }
            Spacer(minLength: Layout.inline)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Le modèle de l'import Moodle

/// Un cours prêt à importer : le cours de l'app, sa source, et le brouillon.
struct ContentImportPlan: Identifiable {
    let id = UUID()
    var course: Course
    var sourceLabel: String
    var draft: ContentDraft
    var isIncluded = true
}

/// Une question à poser : quelle section Moodle pour ce cours ?
struct SectionQuestion: Identifiable {
    let id = UUID()
    var course: Course
    var options: [MoodleCourseRef]
}

/// L'import Moodle, du premier toucher à la relecture.
@MainActor
@Observable
final class MoodleImportModel {
    struct TermInfo { var start: Date?; var weeks: Int }

    enum Phase: Equatable { case idle, working, ready }

    var phase: Phase = .idle
    var progress = ""
    var error: String?
    var needsLogin = false
    var question: SectionQuestion?
    /// « trouvé », « introuvable sur Moodle »… par cours.
    var status: [UUID: String] = [:]
    var plans: [ContentImportPlan] = []

    @ObservationIgnored private let client = MoodleClient.background
    @ObservationIgnored private var pendingQuestions: [SectionQuestion] = []
    @ObservationIgnored private var term = TermInfo(start: nil, weeks: 14)
    @ObservationIgnored private var enrolled: [MoodleCourseRef] = []

    /// Tout le parcours : connexion si besoin, puis chaque cours.
    func run(courses: [Course], term: TermInfo) async {
        guard phase != .working else { return }
        self.term = term
        phase = .working
        error = nil
        plans = []
        pendingQuestions = []
        progress = String(localized: "Connexion à Moodle…")
        guard await client.ensureSignedIn() else {
            phase = .idle
            needsLogin = true
            return
        }
        enrolled = (try? await client.enrolled()) ?? []
        for (index, course) in courses.enumerated() {
            progress = String(localized: "\(course.displayCode) · \(index + 1) sur \(courses.count)")
            status[course.id] = "recherche…"
            do {
                switch try await client.resolve(course, enrolled: enrolled) {
                case .unique(let ref):
                    await load(ref, for: course)
                case .ambiguous(let options):
                    status[course.id] = String(localized: "section à choisir")
                    pendingQuestions.append(SectionQuestion(course: course, options: options))
                case .none:
                    status[course.id] = String(localized: "introuvable sur Moodle")
                }
            } catch HiddenSiteSession.SiteError.notSignedIn {
                phase = .idle
                needsLogin = true
                return
            } catch {
                status[course.id] = String(localized: "erreur : \(error.localizedDescription)")
            }
        }
        askNextOrFinish()
    }

    /// La réponse à « quelle section ? » — retenue pour la prochaine fois
    /// (l'adresse du cours s'écrit dans ses sources à l'import).
    func answer(_ question: SectionQuestion, with choice: MoodleCourseRef?) {
        self.question = nil
        Task {
            if let choice {
                await load(choice, for: question.course)
            } else {
                status[question.course.id] = String(localized: "ignoré")
            }
            askNextOrFinish()
        }
    }

    private func askNextOrFinish() {
        if !pendingQuestions.isEmpty {
            question = pendingQuestions.removeFirst()
            return
        }
        if plans.isEmpty {
            phase = .idle
            if error == nil { error = String(localized: "Aucun cours n'a pu être lu sur Moodle. Essaie « Ouvrir Moodle et choisir la page moi-même ».") }
        } else {
            phase = .ready
        }
    }

    private func load(_ ref: MoodleCourseRef, for course: Course) async {
        status[course.id] = String(localized: "lecture de \(ref.shortname)…")
        do {
            let snapshot = try await client.snapshot(of: ref)
            let termStart = course.term?.startDate ?? term.start
            let weeks = course.term?.totalWeeks ?? term.weeks
            // Tout ce que le cours donne (Moodle, plan du cours, MOOC, Explique,
            // MediaSpace), rangé avec l'IA si besoin.
            let outcome = await CourseImportPipeline.draft(from: snapshot, termStart: termStart, totalWeeks: weeks,
                                                           settings: AppRuntime.container?.settings) { [weak self] step in
                self?.status[course.id] = step
            }
            let draft = outcome.draft
            var label = "Moodle · \(ref.shortname)"
            let moocNote: String? = outcome.notes.isEmpty ? nil : outcome.notes.joined(separator: " · ")
            // Un cours vide sur Moodle a été lu sur Botafogo par la chaîne d'import.
            if let title = outcome.botafogoTitle {
                label = String(localized: "Botafogo · \(title) (vide sur Moodle)")
            }
            guard draft.theoryCount + draft.seriesCount + draft.deadlineCount > 0 else {
                status[course.id] = snapshot.activityCount == 0 ? String(localized: "vide sur Moodle") : String(localized: "rien à suivre (pas de théorie ni de séries)")
                return
            }
            plans.append(ContentImportPlan(course: course, sourceLabel: label, draft: draft))
            status[course.id] = [ContentDraftSummary.line(draft), moocNote].compactMap { $0 }.joined(separator: " · ")
        } catch {
            status[course.id] = String(localized: "erreur : \(error.localizedDescription)")
        }
    }

    func reset() {
        phase = .idle
        plans = []
    }
}

// MARK: - Connexion

/// La page de connexion du site, qui se **ferme seule** une fois connecté·e.
/// Un site où l'app a besoin d'une session : où se connecter, et comment
/// savoir que c'est fait.
enum LoginSite: String, Identifiable {
    case moodle, courseware, explique, mediaspace
    var id: String { rawValue }

    init(_ source: ContentSource) {
        self = source == .moodle ? .moodle : .courseware
    }

    var label: String {
        switch self {
        case .moodle: return "Moodle"
        case .courseware: return "Courseware"
        case .explique: return String(localized: "Explique")
        case .mediaspace: return "MediaSpace"
        }
    }

    var start: URL {
        switch self {
        case .moodle: return MoodleClient.login
        case .courseware: return CoursewareClient.login
        case .explique: return ExpliqueClient.home
        case .mediaspace: return URL(string: "https://\(Institution.current.videoHostName)/user/login")!
        }
    }

    var host: String {
        switch self {
        case .moodle: return Institution.current.moodleHostName
        case .courseware: return Institution.current.coursewareHostName
        case .explique: return ExpliqueImport.host
        case .mediaspace: return Institution.current.videoHostName
        }
    }

    var hint: String {
        switch self {
        case .mediaspace: return String(localized: "Choisis « EPFL » puis connecte-toi avec Switch edu-ID. Cette fenêtre se ferme toute seule.")
        default: return String(localized: "Connecte-toi avec ton compte EPFL. Cette fenêtre se ferme toute seule.")
        }
    }

    /// Exécuté dans la page, revenue sur le site : « true » si connecté·e.
    var check: String {
        switch self {
        case .moodle:
            return "return String(!!document.querySelector('#user-menu-toggle, .usermenu .userbutton'))"
        case .courseware:
            return "const r = await fetch('/api/user/v1/me', { credentials: 'include' }); return String(r.status === 200)"
        case .explique:
            // La page se remplit après connexion : on lui laisse quelques secondes.
            return """
            for (let i = 0; i < 12; i++) {
              if (location.pathname.startsWith('/login')) return 'false';
              if ([...document.querySelectorAll('h2')].some(h => /^Week \\d+$/.test(h.textContent.trim())) || /@epfl\\.ch/.test(document.body.innerText)) return 'true';
              await new Promise(r => setTimeout(r, 500));
            }
            return 'false';
            """
        case .mediaspace:
            return "return String(!!document.querySelector('a[href*=\"logout\"], [href*=\"/user/logout\"]') || /déconnexion|log ?out|sign ?out/i.test(document.body.innerText))"
        }
    }
}

/// La page de connexion du site, qui se **ferme seule** une fois connecté·e.
struct SiteLoginSheet: View {
    let site: LoginSite
    var onSignedIn: () -> Void

    init(source: ContentSource, onSignedIn: @escaping () -> Void) {
        self.site = LoginSite(source)
        self.onSignedIn = onSignedIn
    }

    init(site: LoginSite, onSignedIn: @escaping () -> Void) {
        self.site = site
        self.onSignedIn = onSignedIn
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserModel()
    @State private var checking = false
    /// Moodle et Courseware : d'abord la connexion de l'école sans rien
    /// afficher (`SchoolConnect`, comme le mode étude et le Mac) ; la page
    /// n'apparaît que si Microsoft attend la personne.
    @State private var trying = true

    private var school: SchoolConnect.Site? {
        switch site {
        case .moodle: return .moodle
        case .courseware: return .courseware
        default: return nil
        }
    }

    var body: some View {
        if let school {
            schoolSignIn(school)
        } else {
            sitePage
        }
    }

    @ViewBuilder
    private func schoolSignIn(_ school: SchoolConnect.Site) -> some View {
        Group {
            if trying {
                NavigationStack {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connexion à \(Institution.current.name)…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .carnetBackground()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    }
                }
            } else {
                SignInSheet(site: .moodle) {
                    // Microsoft fait, Moodle connecté : les autres sites suivent.
                    SiteHub.shared.signedIn(.moodle)
                    Task {
                        await SchoolConnect.shared.ensure(school, prompting: false)
                        signedIn()
                    }
                }
            }
        }
        .task {
            await SchoolConnect.shared.ensure(school, prompting: false)
            if SchoolConnect.shared.state(school) == .connected { signedIn() } else { trying = false }
        }
    }

    private func signedIn() {
        Haptics.success()
        Task { await CookieKeeper.save() }
        if site == .moodle {
            Task { await SchoolConnect.shared.refresh(.moodle, prompting: false) }
            SeriesAutoReader.shared.retryAll()
        }
        onSignedIn()
    }

    private var sitePage: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WebView(model: browser, initialURL: site.start)
                    .overlay(alignment: .top) {
                        if browser.isLoading {
                            ProgressView(value: browser.progress).progressViewStyle(.linear).tint(Theme.accent)
                        }
                    }
                Label(site.hint, systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(Layout.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            .carnetBackground()
            .navigationTitle("Connexion à \(site.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                // Si la page ne se ferme pas seule (un site qui change), on
                // peut toujours finir à la main : la session est gardée.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { onSignedIn() }
                }
            }
            .onChange(of: browser.isLoading) { _, loading in
                if !loading { Task { await check() } }
            }
        }
        .interactiveDismissDisabled(checking)
    }

    /// Revenu·e sur le site, hors des pages de connexion : c'est gagné.
    private func check() async {
        guard let url = browser.url, let host = url.host, host.hasSuffix(site.host),
              !url.path.hasPrefix("/login"), !url.path.hasPrefix("/auth"), !url.path.hasPrefix("/user/login") else { return }
        checking = true
        defer { checking = false }
        let result = try? await browser.webView?.callAsyncJavaScript(site.check, contentWorld: .page) as? String
        if result == "true" {
            Haptics.success()
            Task { await CookieKeeper.save() }
            if site == .moodle {
                Task { await SchoolConnect.shared.refresh(.moodle, prompting: false) }
                // Ce qui avait échoué faute de session est retenté.
                SeriesAutoReader.shared.retryAll()
            }
            onSignedIn()
        }
    }
}

/// « Quelle section de MATH-101 suis-tu ? »
struct SectionChoiceSheet: View {
    let question: SectionQuestion
    var onChoose: (MoodleCourseRef?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(question.options) { option in
                        Button {
                            onChoose(option)
                        } label: {
                            VStack(alignment: .leading, spacing: Layout.micro) {
                                Text(option.shortname).font(.body.weight(.semibold)).foregroundStyle(Color.primary)
                                Text(option.fullname).font(.footnote).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Choisis ta section.")
                }
            }
            .carnetBackground()
            .navigationTitle("\(question.course.displayCode) : quelle section ?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Passer") { onChoose(nil) }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }
}

// MARK: - Relecture groupée

/// Tous les cours lus, une ligne chacun ; chaque ligne se déplie en relecture
/// détaillée. Un seul bouton importe le tout.
struct BatchReviewView: View {
    @Bindable var model: MoodleImportModel
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @State private var result: String?

    var body: some View {
        list
            #if DEBUG
            // `-contentImport autoapply` : applique l'import sans toucher l'écran
            // (vérification sur l'appareil).
            .task {
                if PreviewLaunch.string(PreviewLaunch.contentImportFlag) == "autoapply" {
                    try? await Task.sleep(for: .seconds(1))
                    apply()
                }
            }
            #endif
    }

    private var list: some View {
        List {
            Section {
                ForEach($model.plans) { $plan in
                    HStack(spacing: Layout.control) {
                        Toggle(isOn: $plan.isIncluded) { EmptyView() }
                            .toggleStyle(CheckToggleStyle())
                            .frame(width: 32)
                        NavigationLink {
                            ContentDraftEditor(draft: $plan.draft,
                                               totalWeeks: plan.course.term?.totalWeeks ?? 14,
                                               title: plan.course.displayCode)
                        } label: {
                            VStack(alignment: .leading, spacing: Layout.micro) {
                                Text("\(plan.course.displayCode) · \(plan.course.name)")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(ContentDraftSummary.line(plan.draft))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(plan.sourceLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .carnetBackground()
        .navigationTitle("Relecture")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            let count = model.plans.filter(\.isIncluded).count
            Button {
                apply()
            } label: {
                Text(count == 0 ? "Rien à importer" : "Importer \(count) cours")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Layout.control)
            }
            .buttonStyle(.carnetPrimary)
            .disabled(count == 0)
            .padding(Layout.gutter)
            .background(.bar)
        }
        .alert("Import terminé", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil; onDone() } })) {
            Button("OK") { result = nil; onDone() }
        } message: {
            Text(result ?? "")
        }
    }

    private func apply() {
        var lines: [String] = []
        var touched: [Course] = []
        for plan in model.plans where plan.isIncluded {
            let outcome = ContentDraftWriter.apply(plan.draft, to: plan.course, context: context)
            lines.append("\(plan.course.displayCode) — \(outcome.message)")
            touched.append(plan.course)
        }
        try? context.save()
        Haptics.success()
        model.reset()
        result = lines.joined(separator: "\n") + String(localized: "\n\nLes énoncés des séries se lisent maintenant en arrière-plan.")
        SeriesAutoReading.start(courses: touched, context: context, settings: app.settings)
    }
}

/// « 24 éléments de théorie · 12 vidéos · 13 séries ».
enum ContentDraftSummary {
    static func line(_ draft: ContentDraft) -> String {
        var parts: [String] = []
        if draft.theoryCount > 0 { parts.append(String(localized: "\(Plural.count(draft.theoryCount, "\(draft.theoryCount) élément", "\(draft.theoryCount) éléments")) de théorie")) }
        if draft.videoCount > 0 { parts.append(Plural.count(draft.videoCount, "\(draft.videoCount) vidéo", "\(draft.videoCount) vidéos")) }
        if draft.seriesCount > 0 { parts.append(Plural.count(draft.seriesCount, "\(draft.seriesCount) série", "\(draft.seriesCount) séries")) }
        if draft.deadlineCount > 0 { parts.append(Plural.count(draft.deadlineCount, "\(draft.deadlineCount) échéance", "\(draft.deadlineCount) échéances")) }
        if draft.resourceCount > 0 { parts.append(Plural.count(draft.resourceCount, "\(draft.resourceCount) document", "\(draft.resourceCount) documents")) }
        return parts.isEmpty ? String(localized: "rien de reconnaissable") : parts.joined(separator: " · ")
    }
}

// MARK: - Courseware

/// Courseware : la liste de **tes** cours, puis l'import en un toucher.
struct CoursewareImportView: View {
    var course: Course?
    var onDone: () -> Void

    @Query private var terms: [AcademicTerm]
    @State private var enrollments: [CoursewareClient.Enrollment] = []
    @State private var client = CoursewareClient()
    @State private var loading = true
    @State private var needsLogin = false
    @State private var reading: String?
    @State private var errorMessage: String?
    @State private var draft: ContentDraft?

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Lecture de tes cours…").foregroundStyle(.secondary) }
            }
            if !enrollments.isEmpty {
                Section {
                    ForEach(enrollments) { enrollment in
                        Button {
                            Task { await read(enrollment) }
                        } label: {
                            HStack {
                                Text(enrollment.name).foregroundStyle(Color.primary)
                                Spacer()
                                if reading == enrollment.key { ProgressView() }
                            }
                        }
                        .disabled(reading != nil)
                    }
                } header: {
                    Text("Tes cours Courseware")
                }
            } else if !loading, !needsLogin {
                Text("Aucun cours Courseware actif sur ton compte.")
                    .foregroundStyle(.secondary)
            }
            if needsLogin {
                Section {
                    Button("Se connecter à Courseware") { needsLogin = true }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange.accessibleInk)
            }
            Section {
                NavigationLink {
                    WebImportBrowser(source: .courseware, startURL: nil, course: course, onDone: onDone)
                } label: {
                    Label("Ouvrir Courseware et choisir la page moi-même", systemImage: "safari")
                }
            }
        }
        .carnetBackground()
        .navigationTitle("Courseware")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $needsLogin) {
            SiteLoginSheet(source: .courseware) {
                needsLogin = false
                Task { await load() }
            }
        }
        .navigationDestination(item: $draft) { draft in
            ContentReviewView(draft: draft, course: course, onDone: onDone)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard await client.isSignedIn() else {
            needsLogin = true
            return
        }
        do {
            enrollments = try await client.enrollments()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func read(_ enrollment: CoursewareClient.Enrollment) async {
        reading = enrollment.key
        errorMessage = nil
        defer { reading = nil }
        do {
            let page = try await client.content(of: enrollment.key)
            let term = course?.term ?? AcademicTerm.resolve(from: terms)
            draft = ContentDraftBuilder.draft(from: page, source: .courseware,
                                              termStart: term?.startDate,
                                              totalWeeks: term?.totalWeeks ?? 14)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Navigateur intégré (repli)

/// Moodle ou Courseware, affiché : pour une page que l'import automatique n'a
/// pas su trouver.
///
/// Les cookies vivent dans le magasin **persistant** de WebKit : on se connecte
/// une fois, les imports suivants — et la mise à jour automatique — en profitent.
/// La page d'un cours est lue **dès qu'elle s'affiche** : plus besoin de
/// chercher le bouton « Importer cette page ».
struct WebImportBrowser: View {
    let source: ContentSource
    var startURL: URL?
    var course: Course?
    var onDone: () -> Void

    @StateObject private var model = BrowserModel()
    @Query private var terms: [AcademicTerm]
    @State private var isReading = false
    @State private var errorMessage: String?
    @State private var draft: ContentDraft?
    /// La page déjà lue : revenir en arrière ne relance pas la lecture.
    @State private var lastRead: URL?

    var body: some View {
        VStack(spacing: 0) {
            WebView(model: model, initialURL: startURL ?? source.homeURL)
                .overlay(alignment: .top) {
                    if model.isLoading {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                    }
                }
            bottomBar
        }
        .carnetBackground()
        .navigationTitle(source.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { model.webView?.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("Page précédente")
                Button { model.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Recharger")
            }
        }
        .onChange(of: model.isLoading) { _, loading in
            // Lecture automatique d'une page de cours, une fois chargée.
            guard !loading, isCoursePage, model.url != lastRead, draft == nil else { return }
            Task { await read() }
        }
        .navigationDestination(item: $draft) { draft in
            ContentReviewView(draft: draft, course: course, onDone: onDone)
        }
    }

    private var isCoursePage: Bool { WebContentScraper.isCoursePage(model.url, source: source) }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Layout.inline) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.orange.accessibleInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(isCoursePage
                     ? "Page de cours : lecture automatique."
                     : (source.requiresLogin ? String(localized: "Connecte-toi si besoin, puis ouvre la page du cours : elle sera lue toute seule.") : String(localized: "Ouvre le cours à importer.")))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await read() }
            } label: {
                HStack {
                    if isReading { ProgressView().tint(.white) }
                    Text(isReading ? "Lecture de la page…" : "Importer cette page")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.control)
            }
            .buttonStyle(.carnetPrimary)
            .disabled(!isCoursePage || isReading)
        }
        .padding(Layout.gutter)
        .background(.bar)
    }

    @MainActor
    private func read() async {
        guard let webView = model.webView, !isReading else { return }
        isReading = true
        errorMessage = nil
        lastRead = model.url
        defer { isReading = false }
        do {
            let page = try await WebContentScraper.scrape(webView, source: source)
            let term = course?.term ?? AcademicTerm.resolve(from: terms)
            let built = ContentDraftBuilder.draft(from: page,
                                                  source: source,
                                                  termStart: term?.startDate,
                                                  totalWeeks: term?.totalWeeks ?? 14)
            guard !built.isEmpty else { throw WebContentScraper.ScrapeError.empty }
            Haptics.success()
            draft = built
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
        }
    }
}

/// L'état du `WKWebView`, observé par SwiftUI.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    private(set) weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    /// Une page d'activité Moodle (page, dossier, « cliquez ici ») ouverte
    /// pour lire un document saute au PDF qu'elle porte — une fois : revenir en
    /// arrière montre la page. Désactivé dans le navigateur de l'import, où
    /// l'on parcourt Moodle.
    var followsDocumentLinks = false
    private var hasFollowed = false

    func attach(_ view: WKWebView) {
        webView = view
        view.navigationDelegate = self
        observations = [
            view.observe(\.url) { [weak self] view, _ in Task { @MainActor in self?.url = view.url } },
            view.observe(\.isLoading) { [weak self] view, _ in Task { @MainActor in self?.isLoading = view.isLoading } },
            view.observe(\.estimatedProgress) { [weak self] view, _ in Task { @MainActor in self?.progress = view.estimatedProgress } },
            view.observe(\.canGoBack) { [weak self] view, _ in Task { @MainActor in self?.canGoBack = view.canGoBack } }
        ]
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard followsDocumentLinks, !hasFollowed, let url = webView.url,
              MoodleLinks.activityModule(of: url) != nil else { return }
        hasFollowed = true
        let script = #"""
        (function () {
          const main = document.querySelector('#region-main') || document;
          const isSolution = (a) => /(corrig|solution|\bsol\b|_sol\b|-sol\b|loesung|answers?\b|reponses|réponses)/i.test((a.innerText || '') + ' ' + a.href);
          const work = main.querySelector('.urlworkaround a, .resourceworkaround a');
          if (work) return work.href;
          const embedded = main.querySelector('.resourcecontent iframe[src], .resourcecontent object[data], .resourcecontent embed[src]');
          if (embedded) return embedded.src || embedded.data || '';
          const docs = Array.from(main.querySelectorAll('a[href]')).filter(a => /\/pluginfile\.php\//.test(a.href) || /\.pdf($|[?#])/i.test(a.href));
          const statement = docs.find(a => !isSolution(a)) || docs[0];
          return statement ? statement.href : '';
        })();
        """#
        webView.evaluateJavaScript(script) { value, _ in
            guard let href = value as? String, let target = URL(string: href), target.scheme?.hasPrefix("http") == true else { return }
            webView.load(URLRequest(url: target))
        }
    }
}

struct WebView: UIViewRepresentable {
    let model: BrowserModel
    let initialURL: URL
    var followsDocumentLinks = false

    func makeUIView(context: Context) -> WKWebView {
        model.followsDocumentLinks = followsDocumentLinks
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        model.attach(view)
        if initialURL.isFileURL {
            view.loadFileURL(initialURL, allowingReadAccessTo: initialURL.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: SiteLinks.normalize(initialURL)))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Botafogo

/// Quel polycopié proposer d'abord pour un cours.
enum BotafogoSuggestion {
    /// Mots qui relient un cours à un polycopié : le nom de l'app et celui du site.
    static func score(course: Course, title: String, sectionCode: String) -> Int {
        let courseWords = words(course.name + " " + course.code)
        let titleWords = words(title)
        var score = courseWords.intersection(titleWords).count * 2
        // « Analyse I » et « Analyse B » : le chiffre ou la lettre départagent.
        if courseWords.contains("b"), titleWords.contains("b") { score += 2 }
        if courseWords.contains("i") || courseWords.contains("1"), titleWords.contains("1") || titleWords.contains("i") { score += 1 }
        // Les versions « GM » et « classe inversée » sont celles de leur section.
        let section = sectionCode.lowercased()
        if titleWords.contains("gm") { score += section == "gm" ? 3 : -2 }
        if titleWords.contains("inversee") { score -= 1 }
        return score
    }

    static func hint(for course: Course) -> String? {
        let name = ContentDraftBuilder.fold(course.name)
        if name.contains("analyse b") { return "Analyse B" }
        if name.contains("analyse") || course.code.uppercased().hasPrefix("MATH-101") { return "Analyse I" }
        if name.contains("algebre") { return "Algèbre linéaire" }
        if name.contains("calcul scientifique") || name.contains("ics") { return "ICS" }
        return nil
    }

    private static func words(_ text: String) -> Set<String> {
        Set(ContentDraftBuilder.fold(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["de", "d", "l", "le", "la", "et", "mon", "cours", "pour", "polycopie", "en", "ligne"].contains($0) })
    }
}

/// Les polycopiés de Botafogo, lus directement : pas de connexion.
struct BotafogoPicker: View {
    var course: Course?
    var onDone: () -> Void

    @Environment(AppContainer.self) private var app
    @Query private var terms: [AcademicTerm]
    @State private var catalog: [(title: String, url: URL)] = []
    @State private var loadingURL: URL?
    @State private var isLoadingCatalog = true
    @State private var errorMessage: String?
    @State private var draft: ContentDraft?

    /// Le catalogue, le polycopié le plus probable pour ce cours en tête.
    private var ranked: [(title: String, url: URL, suggested: Bool)] {
        guard let course else { return catalog.map { ($0.title, $0.url, false) } }
        let scored = catalog.map { entry in
            (entry, BotafogoSuggestion.score(course: course, title: entry.title + " " + entry.url.path,
                                             sectionCode: app.settings.sectionCode))
        }
        let best = scored.map(\.1).max() ?? 0
        return scored
            .sorted { $0.1 > $1.1 }
            .map { ($0.0.title, $0.0.url, best > 0 && $0.1 == best) }
    }

    var body: some View {
        List {
            Section {
                if isLoadingCatalog {
                    HStack { ProgressView(); Text("Lecture de \(URL(string: Institution.current.extras["botafogo"] ?? "")?.host ?? "Botafogo")…").foregroundStyle(.secondary) }
                }
                ForEach(ranked, id: \.url) { entry in
                    Button {
                        Task { await open(entry.url, title: entry.title) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Layout.micro) {
                                HStack(spacing: Layout.snug) {
                                    Text(entry.title).foregroundStyle(Color.primary)
                                    if entry.suggested { Pill(text: String(localized: "suggéré"), color: Theme.accent) }
                                }
                                Text(entry.url.path).font(.footnote).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if loadingURL == entry.url { ProgressView() }
                        }
                    }
                    .disabled(loadingURL != nil)
                }
            } header: {
                Text("Polycopiés en ligne")
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange.accessibleInk)
                }
            }
        }
        .carnetBackground()
        .navigationTitle("Botafogo")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadCatalog() }
        .navigationDestination(item: $draft) { draft in
            ContentReviewView(draft: draft, course: course, onDone: onDone)
        }
    }

    private func loadCatalog() async {
        guard catalog.isEmpty else { return }
        defer { isLoadingCatalog = false }
        do {
            catalog = try await BotafogoClient.catalog()
            if catalog.isEmpty { errorMessage = String(localized: "Aucun polycopié trouvé sur la page d'accueil.") }
            #if DEBUG
            if let index = PreviewLaunch.string(PreviewLaunch.botafogoCourseFlag).flatMap(Int.init),
               catalog.indices.contains(index) {
                await open(catalog[index].url, title: catalog[index].title)
            }
            #endif
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ url: URL, title: String) async {
        loadingURL = url
        errorMessage = nil
        defer { loadingURL = nil }
        do {
            // Sans cours choisi, le semestre en cours : c'est lui qui date ce
            // qui ne vient pas d'un programme.
            let term = course?.term ?? AcademicTerm.resolve(from: terms)
            draft = try await BotafogoClient.draft(at: url, fallbackTitle: title,
                                                   termStart: term?.startDate,
                                                   totalWeeks: term?.totalWeeks ?? 14)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ContentDraft: Hashable, Identifiable {
    var id: String { url + courseTitle }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Relecture d'un cours

/// Les sections d'un brouillon, semaine par semaine, à corriger.
///
/// Partagé par la relecture d'un cours et par la relecture groupée.
struct ContentDraftEditor: View {
    @Binding var draft: ContentDraft
    var totalWeeks: Int
    var title: String

    var body: some View {
        List {
            ContentDraftSections(draft: $draft, totalWeeks: totalWeeks)
        }
        .carnetBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ContentDraftSections: View {
    @Binding var draft: ContentDraft
    var totalWeeks: Int

    var body: some View {
        ForEach($draft.sections) { $section in
            sectionView($section)
        }
    }

    private func sectionView(_ section: Binding<ContentDraftSection>) -> some View {
        Section {
            if section.wrappedValue.isIncluded {
                ForEach(section.items) { $item in
                    itemRow($item, in: section.wrappedValue)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: Layout.snug) {
                Toggle(isOn: section.isIncluded) {
                    MathText(section.wrappedValue.title.isEmpty ? String(localized: "Sans titre") : section.wrappedValue.title,
                             font: .subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
                .toggleStyle(CheckToggleStyle())
                if section.wrappedValue.isIncluded {
                    weekMenu(section)
                }
            }
            .padding(.vertical, Layout.tight)
        }
    }

    /// La semaine d'une section — ou sa plage, quand ses éléments s'étalent.
    /// La changer **décale** tout le chapitre, étalement compris.
    private func weekMenu(_ section: Binding<ContentDraftSection>) -> some View {
        let value = section.wrappedValue
        let range = value.weekRange
        let label: String = {
            guard let range else { return String(localized: "Non planifié") }
            return range.lowerBound == range.upperBound ? String(localized: "Semaine \(range.lowerBound)") : String(localized: "Semaines \(range.lowerBound)–\(range.upperBound)")
        }()
        return Menu {
            Picker("Semaine", selection: Binding(get: { value.week }, set: { newWeek in
                let delta = newWeek - value.week
                section.wrappedValue.shiftWeeks(by: delta, totalWeeks: totalWeeks)
                section.wrappedValue.week = newWeek
                section.wrappedValue.weekIsInferred = false
            })) {
                Text("Non planifié").tag(0)
                ForEach(1...max(totalWeeks, value.week, 1), id: \.self) { week in
                    Text("Commence en semaine \(week)").tag(week)
                }
            }
        } label: {
            HStack(spacing: Layout.tight) {
                Image(systemName: "calendar")
                Text(label)
                if value.weekIsInferred {
                    Text("proposée").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.footnote.weight(.medium))
            .textCase(nil)
        }
    }

    private func itemRow(_ item: Binding<ContentDraftItem>, in section: ContentDraftSection) -> some View {
        let value = item.wrappedValue
        return HStack(spacing: Layout.block) {
            Image(systemName: value.kind == .series ? TaskType.exercise.icon : value.theoryKind.icon)
                .foregroundStyle(value.kind == .ignore ? Color.secondary : (value.kind == .series ? TaskType.exercise.tint : TaskType.theory.tint).accessibleMark)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Layout.micro) {
                MathText(value.kind == .series ? "Série \(value.number)" : "\(value.number) · \(value.title)",
                         font: .subheadline)
                    .foregroundStyle(value.kind == .ignore ? .secondary : .primary)
                    .lineLimit(2)
                let details = [
                    value.kind == .series && value.title != "Série \(value.number)" ? value.title : nil,
                    value.kind == .series && !value.exercises.isEmpty ? String(localized: "\(value.exercises.count) exercices, \(value.exercises.reduce(0) { $0 + max($1.questions.count, 1) }) questions") : nil,
                    value.kind == .series && !value.pdfURL.isEmpty && value.exercises.isEmpty ? String(localized: "PDF à lire") : nil,
                    value.solutionsAt.map { String(localized: "corrigé le \(DateUtils.shortDay.string(from: $0))") },
                    value.kind == .theory && value.videoCount > 0 ? Plural.count(value.videoCount, "\(value.videoCount) vidéo", "\(value.videoCount) vidéos") : nil,
                    value.week != nil && value.week != section.week && value.kind != .ignore ? String(localized: "semaine \(value.plannedWeek(in: section))") : nil
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Layout.inline)
            Menu {
                Picker("Type", selection: item.kind) {
                    ForEach(ContentItemKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
            } label: {
                Text(value.kind.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, Layout.inline)
                    .padding(.vertical, Layout.tight)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .onChange(of: item.wrappedValue.kind) { _, kind in
                if kind == .series, item.wrappedValue.seriesNumber == nil {
                    item.wrappedValue.seriesNumber = ContentDraftBuilder.seriesNumber(in: item.wrappedValue.title)
                        ?? Int(item.wrappedValue.number.split(separator: ".").last ?? "") ?? 1
                    item.wrappedValue.number = String(item.wrappedValue.seriesNumber ?? 1)
                }
            }
        }
    }
}

/// Le plan proposé pour **un** cours, à corriger avant d'écrire.
struct ContentReviewView: View {
    @State var draft: ContentDraft
    var course: Course?
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    /// Le cours cible ; `nil` = en créer un à partir du titre de la page.
    @State private var targetID: UUID?
    @State private var hasPickedTarget = false
    @State private var result: ContentImportResult?

    private var totalWeeks: Int { target?.term?.totalWeeks ?? course?.term?.totalWeeks ?? 14 }
    private var target: Course? { courses.first { $0.id == targetID } }

    var body: some View {
        List {
            summarySection
            if course == nil { targetSection }
            ContentDraftSections(draft: $draft, totalWeeks: totalWeeks)
        }
        .carnetBackground()
        .navigationTitle("Relecture")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { importBar }
        .onAppear(perform: pickTarget)
        .alert("Import terminé", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil; onDone() } })) {
            Button("OK") { result = nil; onDone() }
        } message: {
            Text(result?.message ?? "")
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text(draft.courseTitle.isEmpty ? draft.source.label : draft.courseTitle)
                    .font(.headline)
                Text(ContentDraftSummary.line(draft))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, Layout.tight)
        } footer: {
            if draft.sections.contains(where: { $0.isIncluded && $0.weekIsInferred }) {
                Text("Vérifie les semaines marquées « proposée ».")
            }
        }
    }

    private var importTitle: String {
        let total = draft.theoryCount + draft.seriesCount
        return String(localized: "Importer \(Plural.count(total, "\(total) élément", "\(total) éléments"))")
    }

    private var targetSection: some View {
        Section("Dans le cours") {
            Picker("Cours (au singulier)", selection: $targetID) {
                Text("Nouveau cours « \(shortTitle) »").tag(UUID?.none)
                ForEach(courses.filter(\.isTracked)) { course in
                    Text("\(course.displayCode) — \(course.name)").tag(UUID?.some(course.id))
                }
            }
        }
    }

    private var shortTitle: String {
        let title = draft.courseTitle
        return title.count > 32 ? String(title.prefix(30)) + "…" : title
    }

    private var importBar: some View {
        Button {
            apply()
        } label: {
            Text(draft.isEmpty ? String(localized: "Rien à importer") : importTitle)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Layout.control)
        }
        .buttonStyle(.carnetPrimary)
        .disabled(draft.isEmpty)
        .padding(Layout.gutter)
        .background(.bar)
    }

    private func pickTarget() {
        guard !hasPickedTarget else { return }
        hasPickedTarget = true
        if let course { targetID = course.id; return }
        // Le code EPFL écrit dans le titre de la page (« MATH-101 »), sinon le nom.
        let title = ContentDraftBuilder.fold(draft.courseTitle)
        targetID = courses.first { course in
            title.contains(ContentDraftBuilder.fold(course.code))
                || (!course.name.isEmpty && title.contains(ContentDraftBuilder.fold(course.name)))
        }?.id
    }

    private func apply() {
        let destination: Course
        if let target {
            destination = target
        } else if let course {
            destination = course
        } else {
            let code = draft.courseTitle.range(of: #"[A-Z]{2,5}-\d{3}"#, options: .regularExpression)
                .map { String(draft.courseTitle[$0]) } ?? ""
            let name = draft.courseTitle.replacingOccurrences(of: code, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ()-–·|"))
            let palette = Theme.coursePalette
            let created = Course(code: code.isEmpty ? String(name.prefix(8)).uppercased() : code,
                                 name: name.isEmpty ? draft.courseTitle : name,
                                 colorHex: palette[courses.count % palette.count],
                                 term: courses.compactMap(\.term).first)
            context.insert(created)
            destination = created
        }
        let outcome = ContentDraftWriter.apply(draft, to: destination, context: context)
        try? context.save()
        Haptics.success()
        result = outcome
        SeriesAutoReading.start(courses: [destination], context: context, settings: app.settings)
    }
}

/// Une case à cocher de liste, plutôt qu'un interrupteur : on coche des
/// sections à importer, on n'allume pas un réglage.
struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
            Haptics.soft()
        } label: {
            HStack(spacing: Layout.inline) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(configuration.isOn ? Theme.accentInk : Color.secondary)
                    .font(.title3)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "incluse" : "exclue")
    }
}
