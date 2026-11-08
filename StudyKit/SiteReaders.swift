import AVKit
import SwiftUI
import WebKit
#if os(macOS)
import QuickLookUI
#else
import QuickLook
#endif

// MARK: - Se connecter

/// Les sites qui demandent une connexion EPFL (Tequila, Microsoft, SWITCH).
enum StudySite: String, Identifiable {
    case moodle, courseware, mediaspace, ed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .moodle: return "Moodle"
        case .courseware: return "Courseware"
        case .mediaspace: return "MediaSpace"
        case .ed: return "Ed"
        }
    }

    var start: URL {
        switch self {
        case .moodle: return MoodleClient.login
        case .courseware: return CoursewareClient.login
        case .mediaspace: return URL(string: "https://\(Institution.current.videoHostName)/user/login")!
        case .ed: return EdClient.login
        }
    }

    /// De retour sur le site, hors des pages de connexion : c'est fait.
    func isSignedIn(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        switch self {
        case .moodle: return host == Institution.current.moodleHostName && !path.hasPrefix("/login") && !path.contains("/auth/")
        case .courseware: return host == Institution.current.coursewareHostName && !path.hasPrefix("/login") && !path.hasPrefix("/auth") && !path.hasPrefix("/register")
        case .mediaspace: return host == Institution.current.videoHostName && !path.contains("login") && !path.contains("saml")
        case .ed: return host == "edstem.org" && path.hasPrefix("/\(Institution.current.edRegion)/") && !path.contains("login")
        }
    }
}

/// La seule page web du bureau : **une** connexion EPFL (Microsoft), dans
/// une petite feuille qui se ferme toute seule. On passe par la page de
/// Moodle et son bouton « EPFL – Entra ID » (cliqué pour toi) ; une fois de
/// retour sur Moodle, `SchoolConnect` ouvre les autres sites sans rien afficher.
struct SignInSheet: View {
    let site: StudySite
    var done: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site == .mediaspace ? "Vidéos du cours" : "Connexion EPFL").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                    Text(site == .mediaspace ? "Ton mot de passe SWITCH edu-ID, une fois."
                         : SchoolConnect.shared.needsYou ? "Microsoft demande de confirmer que c'est toi."
                         : "Une fois pour Moodle, Courseware et Ed.")
                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            SignInWebView(site: site) {
                done()
                dismiss()
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 680)
        #endif
    }
}

/// La page de connexion. Elle est surveillée à chaque chargement **et** chaque
/// seconde : les pages de Microsoft changent sans recharger.
@MainActor
private struct SignInWebView {
    let site: StudySite
    var finished: () -> Void

    private var start: URL {
        site == .mediaspace ? URL(string: "https://\(Institution.current.videoHostName)/user/login")!
                            : URL(string: Institution.current.moodleBase + "/my/")!
    }

    func makeCoordinator() -> Coordinator { Coordinator(site: site, finished: finished) }

    fileprivate func makeView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        view.navigationDelegate = coordinator
        coordinator.watch(view)
        view.load(URLRequest(url: start))
        return view
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let site: StudySite
        let finished: () -> Void
        private var timer: Timer?
        private weak var view: WKWebView?
        private var done = false

        init(site: StudySite, finished: @escaping () -> Void) {
            self.site = site
            self.finished = finished
        }

        func watch(_ view: WKWebView) {
            self.view = view
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }

        func stop() { timer?.invalidate() }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.check() }
        }

        private func check() {
            guard !done, let view, let url = view.url else { return }
            // Les étapes qu'on fait pour toi : choisir l'EPFL, remplir ton adresse.
            if url.host == Institution.current.video?.wayfHost { view.evaluateJavaScript(SchoolConnect.chooseWAYFEPFL); return }
            if let idp = Institution.current.video?.passwordIdPHost, url.host?.contains(idp) == true {
                Task { await SchoolConnect.answerEduID(view, email: SchoolConnect.shared.email) }
                return
            }
            let home = site == .mediaspace ? Institution.current.videoHostName : Institution.current.moodleHostName
            guard url.host == home else { return }
            // Déjà connecté·e (Moodle répond alors « déjà connecté, se
            // déconnecter ? » sur sa page de connexion) : c'est fini. Sinon,
            // sur la page de connexion, le bouton de l'école.
            let signedIn = site == .mediaspace ? SchoolConnect.mediaspaceSignedIn : SchoolConnect.moodleSignedIn
            let onLogin = site != .mediaspace && url.path.hasPrefix("/login")
            view.evaluateJavaScript(signedIn) { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.done else { return }
                    guard (value as? Bool) == true else {
                        if onLogin { view.evaluateJavaScript(SchoolConnect.clickEntra) }
                        return
                    }
                    self.done = true
                    self.stop()
                    self.finished()
                }
            }
        }
    }
}

// MARK: - Vidéo

/// Une vidéo, lue en natif (AVKit) : MediaSpace (manifeste Kaltura), un flux
/// HLS ou un mp4 de Courseware. YouTube n'a pas de flux lisible sans son
/// lecteur : une carte qui l'ouvre ailleurs.
struct NativeVideo: View {
    let title: String
    let address: String
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    /// Commencer à cette seconde (un passage trouvé dans la transcription).
    var start: Double? = nil
    /// Ce que « vu » coche (une unité Courseware) ; l'adresse par défaut.
    var studiedKey: String? = nil
    /// Lancer sans attendre un clic (la vidéo suivante d'une liste).
    var autoplay = false
    /// La vidéo est finie (la liste passe à la suivante).
    var onEnd: (() -> Void)? = nil

    @Environment(\.markStudied) private var markStudied
    @State private var player: AVPlayer?
    @State private var failed: String?
    @State private var playing = false
    @State private var rate: Float = ReadingMemory.videoRate
    @State private var observer: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var counted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onDisappear { stop(player) }
                HStack(spacing: 10) {
                    Menu {
                        ForEach([1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { value in
                            Button { setRate(value, on: player) } label: {
                                if value == rate { Label(Self.rateLabel(value), systemImage: "checkmark") } else { Text(Self.rateLabel(value)) }
                            }
                        }
                    } label: {
                        Label(Self.rateLabel(rate), systemImage: "gauge.with.dots.needle.67percent")
                    }
                    .fixedSize()
                    .help("Vitesse de lecture (gardée pour toutes les vidéos)")
                    Spacer()
                    if counted {
                        Label("Vue", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Carnet.correct)
                    }
                }
                .font(.callout)
            } else if case .youtube(let id) = SiteRouter.route(address) {
                Button {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") { openWeb(url, title) }
                } label: { Label("\(title) · YouTube", systemImage: "play.rectangle") }
                .buttonStyle(.paper)
            } else {
                Button {
                    playing = true
                    Task { await resolve() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: playing && failed == nil ? "hourglass" : "play.circle.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).lineLimit(2)
                            if start == nil, let resume = ReadingMemory.video(address) {
                                Text("Reprendre à \(Self.clock(resume.position))").font(.caption).foregroundStyle(Carnet.inkSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(Carnet.ink)
                }
                .buttonStyle(.plain)
                .disabled(playing && failed == nil)
                if let failed {
                    HStack {
                        Text(failed).font(.caption).foregroundStyle(Carnet.inkSecondary)
                        Button("Se connecter") { desk.signIn = .mediaspace }.buttonStyle(.paper)
                    }
                }
            }
        }
        .onChange(of: desk.signInRevision) { _, _ in
            if failed != nil { failed = nil; Task { await resolve() } }
        }
        .task(id: address) {
            if autoplay, player == nil { playing = true; await resolve() }
        }
    }

    static func rateLabel(_ value: Float) -> String {
        value == 1 ? "1×" : String(format: "%g×", value)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func resolve() async {
        switch SiteRouter.route(address) {
        case .mediaspace(let entry):
            if let url = await desk.mediaspace.playbackURL(entryID: entry) { play(url) } else { failed = String(localized: "Vidéo réservée.") }
        default:
            if let url = URL(string: address) { play(url) } else { failed = String(localized: "Adresse illisible.") }
        }
    }

    private func play(_ url: URL) {
        let player = AVPlayer(url: url)
        self.player = player
        // Un repère de cours, un passage cherché, sinon là où l'on s'était arrêté.
        if let start = start ?? LectureMarks.startOffset(in: address) ?? ReadingMemory.video(address)?.position {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 1))
        }
        // Toutes les cinq secondes : la place, et « vue » passé 90 %.
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { time in
            MainActor.assumeIsolated { progress(player, at: time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated {
                count()
                onEnd?()
            }
        }
        player.defaultRate = rate
        player.play()
        player.rate = rate
    }

    private func setRate(_ value: Float, on player: AVPlayer) {
        rate = value
        ReadingMemory.videoRate = value
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
    }

    private func progress(_ player: AVPlayer, at seconds: Double) {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
        ReadingMemory.setVideo(address, position: seconds, duration: duration)
        if seconds / duration >= 0.9 { count() }
    }

    private func count() {
        guard !counted else { return }
        counted = true
        markStudied?(studiedKey ?? address)
    }

    private func stop(_ player: AVPlayer) {
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            ReadingMemory.setVideo(address, position: player.currentTime().seconds, duration: duration)
        }
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
    }
}

// MARK: - Fichiers

/// Un fichier qui n'est pas un PDF (diapositives, image, code) : l'aperçu du
/// système, dans le bureau.
#if os(macOS)
struct QuickLookPane: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
#else
struct QuickLookPane: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
#endif

struct FileReader: View {
    let title: String
    let address: String
    var desk: SiteHub

    @State private var file: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let file {
                QuickLookPane(url: file)
            } else if failed {
                ContentUnavailableView {
                    Label("Fichier introuvable", systemImage: "doc")
                } actions: {
                    Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.paper)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(address)|\(desk.signInRevision)") {
            guard let url = URL(string: address) else { failed = true; return }
            failed = false
            if let result = try? await AuthenticatedDownloader.file(url), !(result.type ?? "").contains("text/html") {
                file = result.file
            } else {
                failed = true
            }
        }
    }
}

/// Une image d'un site du cours, avec les cookies EPFL (Moodle en demande).
struct SiteImage: View {
    let address: String
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFit().frame(maxHeight: 420)
            } else if !failed {
                ProgressView().frame(height: 60)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: address) {
            guard let url = URL(string: address) else { failed = true; return }
            if let data = await AuthenticatedDownloader.data(url), let loaded = PlatformImage(data: data) { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Blocs

/// Une page de site, mise en page nativement.
struct SiteBlocksView: View {
    let blocks: [SiteBlock]
    var desk: SiteHub
    /// Un lien : le lecteur choisit où l'ouvrir (`SiteRouter`).
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .markdown(let text):
                    RichTextView(text: text, size: 15)
                case .image(let source):
                    SiteImage(address: source)
                case .video(let title, let url):
                    NativeVideo(title: title, address: url, desk: desk, openWeb: openWeb)
                case .file(let title, let url):
                    Button { open(url, title) } label: { Label(title, systemImage: "doc.richtext") }
                        .buttonStyle(.paper)
                case .link(let title, let url):
                    Button { open(url, title) } label: {
                        Label(title, systemImage: SiteRouter.route(url) == .web || SiteRouter.route(url) == .geogebra ? "arrow.up.right" : "arrow.right")
                    }
                    .buttonStyle(.paper)
                }
            }
        }
    }
}

// MARK: - Moodle

/// Une activité Moodle lue en natif : page, dossier, devoir, lien, forum.
struct MoodleActivityReader: View {
    let module: String
    let id: Int
    let title: String
    var desk: SiteHub
    var open: (String, String) -> Void
    var openWeb: (URL, String) -> Void

    @State private var content: MoodleActivityContent?
    @State private var error: String?
    @State private var needsLogin = false
    @State private var discussion: MoodleActivityContent?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Kicker(Self.kind(module))
                // Le titre de la liste fait foi : c'est ce qu'on a choisi.
                Text(title.isEmpty ? (content?.title ?? "") : title).font(Carnet.serif(28)).foregroundStyle(Carnet.ink)
                if let content, content.unavailable {
                    unavailable(content)
                } else if let content {
                    details(content)
                } else if needsLogin {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connecte-toi à Moodle.").foregroundStyle(Carnet.inkSecondary)
                        Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.ink)
                    }
                } else if let error {
                    Text(error).foregroundStyle(Carnet.inkSecondary)
                } else {
                    ProgressView()
                }
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: "\(module)\(id)|\(desk.signInRevision)") { await load() }
    }

    private func load() async {
        error = nil
        needsLogin = false
        do {
            let loaded = try await desk.moodle.activity(module: module, id: id)
            content = loaded
            // Un lien : on suit sa cible, en natif si on sait la lire.
            if module == "url", !loaded.unavailable, let target = loaded.target, !target.isEmpty, SiteRouter.route(target) != .web {
                open(target, loaded.title.isEmpty ? title : loaded.title)
            }
        } catch HiddenSiteSession.SiteError.notSignedIn {
            needsLogin = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Moodle ne montre pas encore l'activité (une solution avant la date, une activité cachée).
    private func unavailable(_ content: MoodleActivityContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(content.notice ?? String(localized: "Moodle ne montre pas encore cette activité."), systemImage: "lock")
                .foregroundStyle(Carnet.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "\(Institution.current.moodleBase)/mod/\(module)/view.php?id=\(id)") {
                Button("Ouvrir dans Moodle") { openWeb(url, title) }
                    .buttonStyle(.paper)
            }
        }
        .paperSheet(padding: 14)
    }

    @ViewBuilder
    private func details(_ content: MoodleActivityContent) -> some View {
        if !content.dates.isEmpty || !content.status.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.dates, id: \.self) { Label($0, systemImage: "calendar").foregroundStyle(Carnet.ink) }
                ForEach(content.status, id: \.self) { Text($0).font(.callout).foregroundStyle(Carnet.inkSecondary) }
            }
            .paperSheet(padding: 14)
        }
        if !content.html.isEmpty {
            SiteBlocksView(blocks: SiteHTML.blocks(content.html, base: URL(string: Institution.current.moodleBase + "/")), desk: desk,
                           open: open, openWeb: openWeb)
        }
        if let target = content.target, !target.isEmpty {
            Button { open(target, content.title) } label: { Label(URL(string: target)?.host ?? target, systemImage: "arrow.right") }
                .buttonStyle(.ink)
        }
        if !content.files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Kicker("Fichiers")
                ForEach(content.files, id: \.url) { file in
                    Button { open(file.url, file.name) } label: { Label(file.name, systemImage: "doc.richtext") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Carnet.ink)
                }
            }
        }
        if module == "forum" {
            forum(content)
        }
        if content.html.isEmpty && content.files.isEmpty && content.discussions.isEmpty && content.target == nil && content.dates.isEmpty {
            Text("Rien à lire ici.").foregroundStyle(Carnet.inkSecondary)
        }
    }

    @ViewBuilder
    private func forum(_ content: MoodleActivityContent) -> some View {
        if let discussion {
            Button { self.discussion = nil } label: { Label("Toutes les annonces", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Carnet.inkSecondary)
            ForEach(Array(discussion.posts.enumerated()), id: \.offset) { _, post in
                VStack(alignment: .leading, spacing: 8) {
                    Text(post.subject).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                    Text([post.author, post.date].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Carnet.inkSecondary)
                    SiteBlocksView(blocks: SiteHTML.blocks(post.html, base: URL(string: Institution.current.moodleBase + "/")), desk: desk,
                                   open: open, openWeb: openWeb)
                }
                .paperSheet(padding: 16)
            }
        } else if content.discussions.isEmpty {
            Text("Pas d'annonce.").foregroundStyle(Carnet.inkSecondary)
        } else {
            VStack(spacing: 0) {
                ForEach(content.discussions, id: \.id) { item in
                    Button {
                        Task { discussion = try? await desk.moodle.discussion(id: item.id) }
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title).foregroundStyle(Carnet.ink).lineLimit(2)
                            Spacer()
                            Text(item.date).font(.caption).foregroundStyle(Carnet.inkSecondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Carnet.rule).frame(height: 1)
                }
            }
        }
    }

    static func kind(_ module: String) -> String {
        switch module {
        case "page": return "Page"
        case "folder": return "Dossier"
        case "assign": return "Devoir"
        case "url": return "Lien"
        case "forum": return String(localized: "Annonces")
        case "quiz": return "Quiz"
        default: return "Moodle"
        }
    }
}


// MARK: - Plateformes

#if os(macOS)
typealias PlatformImage = NSImage
extension Image { init(platformImage: NSImage) { self.init(nsImage: platformImage) } }
extension SignInWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#else
typealias PlatformImage = UIImage
extension Image { init(platformImage: UIImage) { self.init(uiImage: platformImage) } }
extension SignInWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.stop() }
}
#endif
