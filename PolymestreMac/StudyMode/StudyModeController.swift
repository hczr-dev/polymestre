import AppKit
import SwiftUI
import SwiftData
import OSLog

/// Le mode étude sur le Mac : un écran plein, et le reste du Mac fermé.
///
/// **Comment le Mac est « bloqué ».** L'app est hors du bac à sable : au début
/// de la session, les apps non permises reçoivent « quitter », et une qui se
/// lance ensuite est fermée aussitôt. Ce qui passe quand même au premier plan
/// (une app qui refuse de quitter, le Finder, Music) est couvert par un
/// **voile** sur tous les écrans — « Safari est fermé pendant le mode étude »
/// — avec de quoi revenir à l'étude ou ouvrir un outil permis. Les apps permises
/// (GoodNotes, Claude, Aperçu…) passent au-dessus de l'écran du mode étude
/// comme d'habitude ; les sites de cours s'ouvrent dans son navigateur, qui ne
/// suit que les adresses permises.
///
/// Rien n'est retenu ici : l'état est `FocusTimerState.studyUntil`, publié par
/// le chrono partagé. Ce contrôleur ne fait que suivre (`update()`, appelé à
/// chaque changement du chrono) : l'iPhone qui lance le mode étude ouvre cet
/// écran sur le Mac, et terminer la session le ferme partout.
@MainActor
final class StudyModeController: NSObject, NSWindowDelegate {
    static let shared = StudyModeController()

    override init() {
        super.init()
        // « Ouvrir les Réglages » de Music pendant un blocage : les Réglages Système sont
        // permis un moment, sinon le voile les couvrirait aussitôt.
        settingsObserver = NotificationCenter.default.addObserver(forName: .studyAllowSystemSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.allowSystemSettings() }
        }
    }

    weak var timer: MacTimer?
    weak var settings: MacSettings?
    var container: ModelContainer?

    /// Ce que montre l'écran : le choix avant de commencer, ou la session.
    @MainActor
    @Observable
    final class Screen {
        enum Stage: Equatable { case setup, session }
        var stage: Stage = .setup {
            didSet { if stage != oldValue { StudyModeController.shared.stageChanged() } }
        }
        /// Ce que le choix propose d'abord (depuis une ligne « À faire »).
        var courseID: UUID?
        var taskType: TaskType = .exercise
        var targetID: UUID?
        var label = ""
        /// Bloquer le reste pendant cette session (le réglage, par défaut).
        var locks = true
        /// L'app arrêtée en dernier, pour le dire.
        /// La barre du haut et la colonne d'outils sont des fenêtres à part (`ChromePanel`).
        var panels = false
        /// Le volet d'à côté l'est aussi.
        var sideHosted = false
        var blockedName: String?
        var blockedAt: Date?
    }

    let screen = Screen()
    let browser = StudyBrowserModel()
    let desk = StudyDesk()

    private var window: NSWindow?
    private var shields: [NSWindow] = []
    private var activationObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    /// Les apps à qui l'on a demandé de quitter, et quand : pendant quelques
    /// secondes, on les laisse afficher « Enregistrer les modifications ? ».
    private var quitting: [pid_t: Date] = [:]
    private var blocking = false
    private var enforcer: Timer?
    /// Une app permise un moment (voir `allowSystemSettings`).
    private var temporary = TemporaryAllowance()
    private var settingsObserver: NSObjectProtocol?
    /// Les autres écrans pendant un blocage : calmes, sans rien à y faire.
    private var calmWindows: [NSWindow] = []
    /// La barre du haut et la colonne d'outils flottantes (mode « barres flottantes »).
    private var chromePanels: [NSPanel] = []
    /// Le volet d'à côté, en fenêtre à part (le centre n'en garde rien).
    private var sidePanel: NSPanel?
    private var screenObserver: NSObjectProtocol?
    /// Le dernier masquage que nous avons fait : macOS met alors le Finder devant
    /// (plus rien de visible), ce qui n'est pas un clic de l'étudiant·e.
    private var lastHideAt: Date?
    private let log = Logger(subsystem: "ch.polymestre.mac", category: "study")
    #if DEBUG
    /// `-studyPreview` : l'écran dans une fenêtre ordinaire, sans rien bloquer.
    private let previewOnly = CommandLine.arguments.contains("-studyPreview")
    #else
    private let previewOnly = false
    #endif

    // MARK: Ouvrir

    /// « Mode étude… » : l'écran s'ouvre sur le choix (ou sur la session si
    /// elle est déjà verrouillée).
    func presentSetup(courseID: UUID? = nil, taskType: TaskType? = nil, targetID: UUID? = nil, label: String = "") {
        guard let timer else { return }
        if timer.isStudying || timer.studyIsOver {
            present()
            return
        }
        screen.stage = .setup
        screen.courseID = courseID ?? timer.courseID
        screen.taskType = taskType ?? timer.taskType
        screen.targetID = targetID ?? (courseID == nil ? timer.targetID : nil)
        screen.label = label
        screen.locks = settings?.studyBlocking ?? false
        showWindowSoon()
    }

    /// La fenêtre se bâtit au tour suivant de la boucle, pas dans le geste qui l'ouvre : bâtir une
    /// vue pleine de requêtes SwiftData dans l'action d'un bouton, pendant qu'iCloud fusionne des
    /// changements, faisait échouer une vérification interne de SwiftUI (plantage juste après le clic).
    private func showWindowSoon() {
        DispatchQueue.main.async { [weak self] in self?.showWindow() }
    }

    /// Revenir à l'écran du mode étude.
    func present() {
        screen.stage = .session
        showWindowSoon()
    }

    /// Lancer : le chrono démarre (ou se verrouille), l'iPhone suit.
    /// `minutes` : `nil`, sans fin (on termine quand on a fini).
    func begin(minutes: Int?, pomodoro: Bool) {
        guard let timer else { return }
        // Ce qui n'est pas permis est masqué (une app peut refuser de quitter, pas
        // d'être masquée) ; fermé seulement si le réglage le demande. Les
        // lanceurs et sélecteurs de fenêtres (AltTab, Raycast) sont toujours fermés.
        let locks = screen.locks
        if timer.phase == .idle { timer.pomodoro = pomodoro }
        timer.enterStudy(minutes: minutes, courseID: screen.courseID, taskType: screen.taskType,
                         targetID: screen.targetID, label: screen.label, locks: locks)
        screen.stage = .session
        log.notice("mode étude : \(minutes.map { "\($0) min" } ?? "sans fin", privacy: .public)")
    }

    func cancelSetup() {
        guard screen.stage == .setup else { return }
        closeWindow()
    }

    // MARK: Suivre le chrono

    /// À chaque changement du chrono (geste ici, état adopté d'ailleurs,
    /// frontière de temps).
    func update() {
        guard let timer else { return }
        window?.appearance = (settings?.studyAlwaysDark ?? true) ? NSAppearance(named: .darkAqua) : nil
        MacKeepAwake.shared.update(mode: settings?.studyKeepAwake ?? .off, studying: timer.isStudying,
                                   running: timer.phase == .running, onBreak: timer.phase == .onBreak,
                                   // Sans fin : pas d'échéance (une date sentinelle lointaine) — un bail renouvelé.
                                   until: StudyMode.isOpenEnded(timer.state) ? nil : timer.state?.studyUntil)
        if timer.isStudying {
            if screen.stage != .session || window?.isVisible != true {
                // Lancé ailleurs (l'iPhone) : l'écran s'ouvre ici aussi.
                screen.stage = .session
                showWindow()
            }
            if timer.studyLocks { startBlocking() } else { stopBlocking() }
            applyPresentation()
        } else {
            stopBlocking()
            if timer.studyIsOver {
                // L'échéance est passée : l'écran reste, pour terminer ou prolonger.
                screen.stage = .session
            } else if screen.stage == .session {
                closeWindow()
            }
        }
    }

    // MARK: Fenêtre

    #if DEBUG
    /// `-snapshot <fichier.png>` (avec `-studyPreview`) : l'écran du mode étude
    /// rendu dans une image, puis l'app quitte. Pour vérifier une vue sans
    /// toucher à l'écran de personne.
    static let snapshotPath: String? = CommandLine.arguments.firstIndex(of: "-snapshot").flatMap {
        $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
    }.flatMap {
        // `-snapshot -advanced -captureView …` : le drapeau suivant n'est pas un
        // chemin (une image nommée « -advanced » s'écrivait à la racine du dépôt).
        $0.hasPrefix("-") ? nil : $0
    }
    private static let snapshotDelay = CommandLine.arguments.firstIndex(of: "-snapshotDelay").flatMap {
        $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil
    } ?? 8

    private func scheduleSnapshot(to path: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.snapshotDelay))
            guard let view = self?.window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
    #endif

    private func showWindow() {
        guard let timer, let settings else { return }
        if !HeadlessCapture.active { NSApp.setActivationPolicy(.regular) }
        if window == nil {
            let primary = NSScreen.screens.first ?? NSScreen.main
            let screenFrame = primary?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // Barres flottantes : le bureau ne garde que le centre et le volet d'à côté.
            screen.panels = (settings.studyPanels || Self.panelsForced) && primary != nil
            let realGeometry = !previewOnly || screen.panels
            // Le choix avant de commencer prend tout l'écran ; la session, seulement le
            // centre et le volet (les barres flottantes font le reste).
            screen.sideHosted = screen.panels && (settings.studySideWindow || Self.panelsForced)
            var frame = !realGeometry ? NSRect(x: 80, y: 80, width: 1440, height: 900)
                : (screen.panels && screen.stage == .session ? (panelFrames()?.desk ?? screenFrame) : screenFrame)
            #if DEBUG
            // `-snapshot` : hors de l'écran, rien ne passe devant ce qu'on fait.
            if Self.snapshotPath != nil {
                frame.origin = NSPoint(x: -6000, y: 0)
                // `-snapshotHeight 2600` : une page entière, sans défiler.
                if let index = CommandLine.arguments.firstIndex(of: "-snapshotHeight"), index + 1 < CommandLine.arguments.count,
                   let height = Double(CommandLine.arguments[index + 1]) { frame.size.height = height }
            }
            #endif
            let window = StudyWindow(contentRect: frame,
                                     styleMask: !realGeometry ? [.titled, .closable, .resizable] : [.borderless, .fullSizeContentView],
                                     backing: .buffered, defer: false)
            window.title = String(localized: "Mode étude")
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.collectionBehavior = blocking && !previewOnly ? [.canJoinAllSpaces, .fullScreenNone] : [.managed, .fullScreenNone]
            window.backgroundColor = NSColor(StudyPalette.ground)
            window.hasShadow = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.delegate = self
            var root = AnyView(StudyModeView(screen: screen, browser: browser, desk: desk)
                .environment(timer)
                .environment(settings))
            if let container { root = AnyView(root.modelContainer(container)) }
            window.contentView = NSHostingView(rootView: root)
            window.setFrame(frame, display: true)
            self.window = window
        }
        #if DEBUG
        if let path = Self.snapshotPath {
            // Transparente et hors de l'écran : dessinée, jamais vue.
            window?.alphaValue = 0
            window?.ignoresMouseEvents = true
            window?.orderFrontRegardless()
            scheduleSnapshot(to: path)
            return
        }
        #endif
        // Une fenêtre gardée d'une séance précédente (fermée, donc `stageChanged` l'a ignorée) porte
        // encore la taille du centre : le choix reprend tout l'écran, sans barres.
        if screen.panels, let primary = NSScreen.screens.first {
            if screen.stage == .session {
                window?.setFrame(panelFrames()?.desk ?? primary.frame, display: true)
            } else {
                hideChromePanels()
                window?.setFrame(primary.frame, display: true)
            }
        }
        window?.makeKeyAndOrderFront(nil)
        showChromePanels()
        NSApp.activate(ignoringOtherApps: true)
        applyPresentation()
    }

    // MARK: Barres flottantes

    /// La barre du haut et la colonne d'outils, au-dessus des apps permises : on peut
    /// y cliquer sans que le bureau repasse devant l'app posée au centre.
    private func showChromePanels() {
        guard screen.panels, screen.stage == .session, let timer, let settings, let frames = panelFrames() else { return }
        func host(_ view: some View) -> AnyView {
            var root = AnyView(view.environment(timer).environment(settings))
            if let container { root = AnyView(root.modelContainer(container)) }
            return root
        }
        if screen.sideHosted, sidePanel == nil {
            sidePanel = ChromePanel(content: host(StudySideHost()), frame: frames.side ?? .zero)
        }
        if chromePanels.isEmpty {
            chromePanels = [ChromePanel(content: host(StudyTopBarHost()), frame: frames.bar, level: StudyLevels.topBar),
                            ChromePanel(content: host(StudyRailHost()), frame: frames.rail)]
        } else {
            chromePanels[0].setFrame(frames.bar, display: true)
            chromePanels[1].setFrame(frames.rail, display: true)
        }
        for panel in chromePanels { panel.orderFrontRegardless() }
        relayout()
        MiniTimerPanel.shared.update()
    }

    private func hideChromePanels() {
        for panel in chromePanels { panel.orderOut(nil) }
        chromePanels.removeAll()
        sidePanel?.orderOut(nil)
        sidePanel = nil
    }

    /// Replace toutes les fenêtres : le centre (qui perd la place du volet), la barre, la
    /// colonne et le volet (montré ou rangé). Le Dock qui se cache ou se montre change `visibleFrame`.
    func relayout() {
        guard screen.panels, screen.stage == .session, let frames = panelFrames() else { return }
        window?.setFrame(frames.desk, display: true)
        if chromePanels.count == 2 {
            chromePanels[0].setFrame(frames.bar, display: true)
            chromePanels[1].setFrame(frames.rail, display: true)
        }
        if let sidePanel {
            if let side = frames.side, screen.sideHosted {
                sidePanel.setFrame(side, display: true)
                sidePanel.orderFrontRegardless()
            } else {
                sidePanel.orderOut(nil)
            }
        }
    }

    /// Le choix et la session n'ont pas la même mise en page : plein écran avant de
    /// commencer, puis le centre et le volet entre les barres flottantes.
    func stageChanged() {
        guard screen.panels, window?.isVisible == true, let primary = NSScreen.screens.first else { return }
        if screen.stage == .session {
            window?.setFrame(panelFrames()?.desk ?? primary.frame, display: true)
            showChromePanels()
        } else {
            hideChromePanels()
            window?.setFrame(primary.frame, display: true)
            MiniTimerPanel.shared.update()
        }
    }

    /// Les barres flottantes sont en place : le chrono flottant n'a rien à faire.
    var chromeUp: Bool { chromePanels.contains { $0.isVisible } }

    private func closeWindow() {
        window?.orderOut(nil)
        hideChromePanels()
        // Le bureau parti, la pilule reprend sa place si la session continue.
        defer { MiniTimerPanel.shared.update() }
        NSApp.presentationOptions = []
        browser.closeAll()
        desk.closeAll()
        // Pas un geste : rien n'est épinglé, et la prochaine session s'arrange comme neuve.
        desk.applying = true
        desk.pane = .desk
        desk.applying = false
        desk.pins = DeskArrangement.Pins()
        desk.lastSignature = nil
    }

    /// Dock et barre des menus cachés tant que Polymestre est au premier plan.
    /// Sous blocage, en plus : ni ⌘Tab, ni ⌘H, ni menu Pomme. Sous verrou
    /// encore : ni « Forcer à quitter » (⌥⌘⎋), ni fermeture de session ou
    /// redémarrage. Ces options
    /// ne valent que quand Polymestre est au premier plan ; ailleurs (une app
    /// permise), le voile et le gardien (`StudyGuard`) prennent le relais.
    private func applyPresentation() {
        guard window?.isVisible == true, !previewOnly else { return }
        var options: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar]
        // Bloquer, c'est ne plus pouvoir passer à une autre app — session sans fin
        // comprise ; le verrou (ne pas finir avant l'heure) ajoute ce qui ferme.
        if timer?.studyLocks == true {
            options.formUnion([.disableHideApplication, .disableAppleMenu])
            // Si ⌘Tab du système est bien éteint (relu après coup), c'est le nôtre qui
            // répond : l'option l'avalerait. Sinon, elle reste le seul frein.
            if !SystemLock.processSwitchingOff { options.insert(.disableProcessSwitching) }
        }
        if timer?.isLocked == true {
            options.formUnion([.disableForceQuit, .disableSessionTermination])
        }
        if NSApp.presentationOptions != options { NSApp.presentationOptions = options }
    }

    /// Le centre du bureau (la place des apps permises), mesuré dans la fenêtre : posé
    /// en repère de l'Accessibilité pour `AppPlacement`.
    func publishHole(_ local: CGRect) {
        guard let window, let primary = NSScreen.screens.first, local.width > 0 else { return }
        let frame = window.frame
        let rect = DeskGeometry.accessibilityRect(
            window: DeskGeometry.Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            local: DeskGeometry.Rect(x: local.minX, y: local.minY, width: local.width, height: local.height),
            primaryHeight: primary.frame.height)
        AppPlacement.shared.setHole(rect)
    }

    /// Un blocage est en cours (pour rattraper une fiche restée d'une session morte).
    var isBlocking: Bool { blocking }

    func windowDidBecomeKey(_ notification: Notification) {
        applyPresentation()
        MiniTimerPanel.shared.update()
    }

    /// Le bureau d'étude est devant : son bandeau montre déjà le chrono, la
    /// pilule flottante n'a rien à y faire.
    var deskIsFrontmost: Bool {
        guard let window, window.isVisible, !previewOnly else { return false }
        return NSApp.isActive && window.isKeyWindow
    }

    func windowDidResignKey(_ notification: Notification) {
        MiniTimerPanel.shared.update()
        // Une autre fenêtre de Polymestre (le cours, les réglages) : sous
        // blocage, rien ne se relâche.
        guard timer?.studyLocks != true else { return }
        NSApp.presentationOptions = []
    }

    /// Sous verrou, la fenêtre ne se ferme pas (⌘W) et ne se réduit pas (⌘M).
    func windowShouldClose(_ sender: NSWindow) -> Bool { timer?.isLocked != true }

    // MARK: Blocage

    private func startBlocking() {
        guard !blocking, !previewOnly else { return }
        blocking = true
        // Le verrou système (expérimental, `studySystemLock`) : sans lui, rien
        // n'est écrit dans les raccourcis du système ni dans `LaunchAgents`.
        let systemLock = settings?.studySystemLock ?? false
        // Tué de force depuis une app permise, Polymestre revient (`StudyGuard`).
        if systemLock { StudyGuard.arm() }
        // Les raccourcis du système (Spotlight, ⌘Tab, Mission Control…) éteints,
        // la fiche pour les rallumer écrite d'abord.
        SystemLock.engage(hideChrome: settings?.studyHideSystemChrome ?? true, blockGestures: settings?.studyBlockGestures ?? true,
                          shortcuts: systemLock)
        // ⌘Tab et ⌘Espace, éteints dans le système, reviennent en version d'étude.
        if systemLock, SystemHotKeys.isAvailable { StudyShell.shared.engage() }
        // Le Dock se cache (System Events) : la place libre change, les fenêtres se replacent.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            self?.relayout()
        }
        // Les apps permises dans le centre du bureau (si l'Accessibilité est accordée).
        if settings?.studyPlaceApps ?? true { AppPlacement.shared.start(allowed: settings?.studyApps ?? StudyMode.defaultMacApps) }
        // Sur tous les bureaux (Spaces) et sur tous les écrans : un balayage ou un
        // second écran n'est pas une porte de sortie.
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
        showCalmWindows()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.check(app) }
        }
        // Une app non permise qui se lance pendant la session se ferme aussitôt :
        // elle n'a encore rien à perdre.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.launched(app) }
        }
        // Les apps déjà ouvertes : masquées (fermées si le réglage le demande) ; les
        // lanceurs et sélecteurs de fenêtres, toujours fermés. Ici et non dans
        // `begin` : un blocage lancé depuis l'iPhone, relancé ou rétabli par le
        // gardien passe aussi par là.
        for app in runningBlockedApps() where !neverQuit(app) {
            if isLauncher(app) {
                ask(app, toQuit: true, force: true)
            } else if settings?.studyCloseApps ?? false {
                ask(app, toQuit: true, force: false)
            } else {
                app.hide()
            }
        }
        check(NSWorkspace.shared.frontmostApplication)
        // Une app qui s'est installée devant sans qu'on l'« active » (un sélecteur
        // de fenêtres qui la remonte) : on regarde aussi qui est devant, deux
        // fois par seconde, et on ne fait rien tant que le voile est là.
        enforcer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.blocking, !self.shields.contains(where: \.isVisible),
                      let front = NSWorkspace.shared.frontmostApplication, self.isBlocked(front) else { return }
                self.check(front)
            }
        }
        log.notice("mode étude : blocage actif")
    }

    private func stopBlocking() {
        guard blocking else { return }
        blocking = false
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        activationObserver = nil
        launchObserver = nil
        quitting.removeAll()
        enforcer?.invalidate()
        enforcer = nil
        hideShields()
        hideCalmWindows()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        window?.collectionBehavior = [.managed, .fullScreenNone]
        StudyShell.shared.disengage()
        AppPlacement.shared.stop()
        SystemLock.release()
        log.notice("mode étude : blocage levé")
    }

    /// Les apps ouvertes qui ne sont pas permises (pour les annoncer, puis les fermer).
    func runningBlockedApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isBlocked)
    }

    private func disposition(_ app: NSRunningApplication) -> StudyMode.Disposition {
        StudyMode.disposition(bundleID: app.bundleIdentifier,
                              isRegular: app.activationPolicy == .regular,
                              own: Bundle.main.bundleIdentifier ?? "",
                              allowed: (settings?.studyApps ?? StudyMode.defaultMacApps) + temporary.allowed())
    }

    /// Les Réglages Système, le temps de régler une permission : permis 90 secondes
    /// (« Ouvrir les Réglages » de Music), puis recouverts de nouveau.
    func allowSystemSettings(seconds: TimeInterval = 90) {
        temporary.allow("com.apple.systempreferences", for: seconds)
        guard let expiry = temporary.nextExpiry() else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, expiry.timeIntervalSinceNow + 0.5)))
            self?.check(NSWorkspace.shared.frontmostApplication)
        }
    }

    private func isBlocked(_ app: NSRunningApplication) -> Bool {
        let result = disposition(app)
        return result == .close || result == .hideOnly
    }

    private func isLauncher(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(StudyMode.launcherApps.contains) ?? false
    }

    /// Music et le Finder : masqués, jamais fermés.
    private func neverQuit(_ app: NSRunningApplication) -> Bool { disposition(app) == .hideOnly }

    /// Demande à une app de quitter ; `force` : la forcer si elle n'a pas
    /// quitté au bout de deux secondes (une app tout juste lancée).
    private func ask(_ app: NSRunningApplication, toQuit: Bool, force: Bool) {
        quitting[app.processIdentifier] = Date()
        app.terminate()
        guard force else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !app.isTerminated { app.forceTerminate() }
        }
    }

    private func launched(_ app: NSRunningApplication?) {
        // Music lancé pour jouer la musique du mode étude, le Finder que le Dock
        // relance : ils restent (masqués s'ils passent devant, voir `check`).
        guard blocking, let app, isBlocked(app), !neverQuit(app) else { return }
        screen.blockedName = app.localizedName
        screen.blockedAt = Date()
        log.notice("mode étude : \(app.bundleIdentifier ?? "?", privacy: .public) lancée, écartée")
        if isLauncher(app) || (settings?.studyCloseApps ?? false) {
            ask(app, toQuit: true, force: true)
        } else {
            app.hide()
        }
    }

    /// Une app vient au premier plan : permise, on la laisse ; sinon le voile.
    private func check(_ app: NSRunningApplication?) {
        guard blocking, let app else { return }
        guard isBlocked(app) else {
            hideShields()
            AppPlacement.shared.appActivated(app)
            return
        }
        // Music au premier plan : il joue pour le mode étude, on ne le ferme
        // pas — on le masque, et la musique se choisit dans l'onglet Musique.
        if Self.playsInBackground(app) {
            if app.hide() {
                desk.pane = .music
                present()
            } else {
                screen.blockedName = app.localizedName
                screen.blockedAt = Date()
                showShields()
            }
            return
        }
        // Le Finder qui vient devant parce que nous venons de masquer une app :
        // on le masque aussi et on revient à l'étude, sans voile ni bruit.
        if neverQuit(app), let last = lastHideAt, Date().timeIntervalSince(last) < 1.5 {
            _ = app.hide()
            present()
            return
        }
        // On vient de lui demander de quitter : elle demande peut-être
        // d'enregistrer un document — on la laisse répondre.
        if let asked = quitting[app.processIdentifier], Date().timeIntervalSince(asked) < 20 { return }
        screen.blockedName = app.localizedName
        screen.blockedAt = Date()
        DeskNotifications.shared.post(.blockedApp, "\(app.localizedName ?? String(localized: "Une app")) reste fermée pendant le mode étude", icon: "hand.raised.fill")
        log.notice("mode étude : \(app.bundleIdentifier ?? "?", privacy: .public) arrêtée")
        // Le voile d'abord : rien de l'app ne se voit, même une fraction de seconde.
        showShields()
        // Puis masquer l'app, quand le système le permet (ses fenêtres partent,
        // son icône reste), et revenir à l'écran d'étude, qui le dit. Sinon le
        // voile reste, jusqu'à ce qu'on choisisse quoi faire.
        if isLauncher(app) {
            ask(app, toQuit: true, force: true)
        } else if settings?.studyCloseApps ?? false, !neverQuit(app) {
            ask(app, toQuit: true, force: false)
        }
        if app.hide() {
            lastHideAt = Date()
            present()
        }
    }

    private static func playsInBackground(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(StudyMode.backgroundApps.contains) ?? false
    }

    private func showShields() {
        guard let timer, let settings else { return }
        if shields.isEmpty {
            for screenInfo in NSScreen.screens {
                let shield = StudyWindow(contentRect: screenInfo.frame, styleMask: [.borderless, .fullSizeContentView],
                                         backing: .buffered, defer: false)
                shield.isReleasedWhenClosed = false
                shield.level = .statusBar
                shield.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                shield.backgroundColor = .clear
                shield.isOpaque = false
                shield.hasShadow = false
                shield.appearance = NSAppearance(named: .darkAqua)
                var root = AnyView(StudyShieldView(screen: screen)
                    .environment(timer)
                    .environment(settings))
                if let container { root = AnyView(root.modelContainer(container)) }
                shield.contentView = NSHostingView(rootView: root)
                shield.setFrame(screenInfo.frame, display: true)
                shields.append(shield)
            }
        }
        for shield in shields { shield.orderFrontRegardless() }
    }

    private func hideShields() {
        for shield in shields { shield.orderOut(nil) }
    }

    // MARK: Autres écrans

    /// Un écran calme sur chaque écran qui n'est pas celui du bureau d'étude.
    private func showCalmWindows() {
        guard let timer, let settings, !previewOnly, settings.studyCalmDisplays, calmWindows.isEmpty else { return }
        for screenInfo in NSScreen.screens.dropFirst() {
            let calm = StudyWindow(contentRect: screenInfo.frame, styleMask: [.borderless, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            calm.isReleasedWhenClosed = false
            calm.level = .normal
            calm.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
            calm.backgroundColor = NSColor(StudyPalette.ground)
            calm.hasShadow = false
            calm.appearance = NSAppearance(named: .darkAqua)
            var root = AnyView(StudyCalmView(screenFrame: screenInfo.frame).environment(timer).environment(settings))
            if let container { root = AnyView(root.modelContainer(container)) }
            calm.contentView = NSHostingView(rootView: root)
            calm.setFrame(screenInfo.frame, display: true)
            calm.orderFront(nil)
            calmWindows.append(calm)
        }
    }

    private func hideCalmWindows() {
        for calm in calmWindows { calm.orderOut(nil) }
        calmWindows.removeAll()
    }

    /// Un écran branché ou débranché : tout est reposé à la bonne place. Les
    /// voiles, bâtis une fois pour les écrans d'alors, sont refaits au besoin.
    private func screensChanged() {
        guard blocking else { return }
        let showingShields = shields.contains { $0.isVisible }
        for shield in shields { shield.orderOut(nil) }
        shields.removeAll()
        hideCalmWindows()
        showCalmWindows()
        if let first = NSScreen.screens.first {
            window?.setFrame(screen.panels && screen.stage == .session ? (panelFrames()?.desk ?? first.frame) : first.frame, display: true)
            if screen.panels { showChromePanels(); relayout() }
        }
        if showingShields { showShields() }
    }

    /// « Revenir à l'étude » depuis le voile.
    func returnToStudy() {
        hideShields()
        present()
    }

    // MARK: Apps permises

    /// Ouvre une app permise (GoodNotes, Claude…).
    func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        hideShields()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Quitter

    /// ⌘Q pendant le mode étude : sous verrou, non — l'écran revient ; sans
    /// verrou, on demande.
    func confirmQuit() -> Bool {
        guard let timer, timer.isStudying else { return true }
        if timer.isLocked {
            present()
            return false
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quitter le mode étude ?")
        alert.informativeText = String(localized: "Ta session continue.")
        alert.addButton(withTitle: String(localized: "Rester"))
        alert.addButton(withTitle: "Quitter")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Une fenêtre sans bord qui accepte le clavier (champs, navigateur).
final class StudyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var locked: Bool { MainActor.assumeIsolated { StudyModeController.shared.timer?.isLocked == true } }

    override func performClose(_ sender: Any?) {
        guard !locked else { NSSound.beep(); return }
        super.performClose(sender)
    }

    override func performMiniaturize(_ sender: Any?) {
        guard !locked else { NSSound.beep(); return }
        super.performMiniaturize(sender)
    }

    override func miniaturize(_ sender: Any?) {
        guard !locked else { return }
        super.miniaturize(sender)
    }
}
