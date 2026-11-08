import SwiftUI
import CoreSpotlight
import SwiftData

/// Navigation principale. Tant que l'accueil n'est pas terminé, l'onboarding
/// remplace l'app : plus aucun cours fictif n'est injecté en douce.
struct RootTabView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var debugBrowse: BrowsedLink?

    var body: some View {
        @Bindable var router = app.router

        Group {
            if app.settings.hasCompletedOnboarding {
                tabs
                // Focus, bilan et agenda s'ouvrent depuis **n'importe quel**
                // onglet : une seule présentation, pilotée par le routeur.
                .sheet(item: rootSheet) { sheet in
                    switch sheet {
                    case .focus:
                        FocusView(onClose: { app.router.showingFocus = false })
                    case .agenda:
                        AgendaView()
                            .carnetPageSheet()
                    case .me:
                        MeView(onClose: { app.router.showingProfile = false })
                            #if DEBUG
                            // `-personalize` : la page des réglages ouverte d'emblée, pas
                            // « Moi ». Une feuille qui ouvre sa page **pendant** sa
                            // présentation la perd (SwiftUI présente la pile du moment) :
                            // ouvrir le lien d'abord, la feuille ensuite, marche.
                            .navigationDestination(isPresented: Binding(
                                get: { app.router.debugSettingsPage != nil },
                                set: { if !$0 { app.router.debugSettingsPage = nil } })) {
                                if app.router.debugSettingsPage == "personalize" { PersonalizeView() }
                            }
                            #endif
                    case .stats:
                        NavigationStack {
                            StatsView()
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button("Fermer") { app.router.showingStats = false }
                                    }
                                }
                        }
                        .carnetPageSheet()
                    }
                }
            } else {
                OnboardingView()
            }
        }
        // L'import de contenu s'ouvre de partout (accueil, cours, onboarding
        // terminé) : une présentation, portée par la racine.
        .sheet(item: $router.contentImport) { route in
            ContentImportView(course: route.courseID.flatMap { id in
                try? context.fetch(FetchDescriptor<Course>(predicate: #Predicate { $0.id == id })).first
            })
        }
        .task {
            // Les sessions des sites de cours (Moodle, MediaSpace, Switch
            // edu-ID…) d'abord : tout ce qui suit peut en avoir besoin.
            await CookieKeeper.restore()
            // Raccord au lancement : aucune activité d'îlot ne doit survivre à un
            // chrono éteint. Sans ça, une Live Activity laissée par une exécution
            // précédente restait affichée indéfiniment.
            app.focus.reload()
            StudyActivityController.reconcile(with: app.focus.state)
            // Même raccord pour le jour d'examen : une activité laissée par une
            // épreuve passée doit disparaître, et une épreuve qui arrive dans les
            // douze heures doit s'afficher sans attendre un passage en arrière-plan.
            ExamActivityController.reconcileFromStore(context: context)
            // Le travail de fond (doublons iCloud, horaire), hors du fil
            // principal et après le premier écran.
            await app.settleAfterLaunch()
            #if DEBUG
            if let address = PreviewLaunch.string(PreviewLaunch.browseFlag), let url = URL(string: address) {
                try? await Task.sleep(for: .milliseconds(400))
                debugBrowse = BrowsedLink(title: "Test", url: url, icon: "globe")
            }
            if PreviewLaunch.isSet(PreviewLaunch.contentImportFlag) {
                let code = PreviewLaunch.string(PreviewLaunch.courseFlag)
                let course = (try? context.fetch(FetchDescriptor<Course>()))?.first { $0.code == code }
                try? await Task.sleep(for: .milliseconds(400))
                app.router.openContentImport(courseID: course?.id)
            }
            #endif
        }
        .sheet(item: $debugBrowse) { link in InAppBrowser(link: link) }
        // Le mode étude, lancé ici ou sur le Mac : l'écran plein s'ouvre,
        // et se ferme avec la session.
        .fullScreenCover(isPresented: $router.showingStudyMode) {
            NavigationStack { StudyModeScreen() }
        }
        .onChange(of: app.focus.isStudying) { _, studying in
            if studying { app.router.showingStudyMode = true }
        }
        .onChange(of: app.focus.hasSession) { _, open in
            if !open { app.router.showingStudyMode = false }
        }
        .onOpenURL { url in
            handle(url)
        }
        // Un résultat Spotlight (cours, série, exercice, théorie, notes) : le cours.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let destination = SpotlightIndexer.destination(of: identifier) else { return }
            app.router.openCourse(destination.courseID, section: identifier.hasPrefix("theory:") ? .theory : .exercises,
                                  targetID: destination.targetID)
        }
        .onChange(of: app.router.focusRequest) { _, request in
            if let request { startInPlace(request) }
        }
        // « Ouvrir le chrono » de partout (mini-lecteur, widgets, raccourcis) :
        // sur iOS 26, c'est l'onglet.
        .onChange(of: app.router.showingFocus) { _, showing in
            guard showing, Self.chronoIsTab else { return }
            app.router.showingFocus = false
            app.router.selectedTab = .focus
        }
        .onChange(of: app.router.lectureRequest) { _, courseID in
            if let courseID { followLecture(courseID) }
        }
        // Les widgets suivent **chaque** enregistrement — une question cochée, une
        // série importée —, pas seulement le passage en arrière-plan.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            WidgetSnapshotWriter.scheduleRefresh(context: context, settings: app.settings)
            // Cocher (a) dans la liste des exercices doit faire passer l'îlot de
            // « 3/9 » à « 4/9 ». Le contrôleur ne republie que si le compte change
            // vraiment : `didSave` se déclenche à chaque écriture, et ActivityKit
            // limite les mises à jour.
            StudyActivityController.refreshQuestions(container: app)
            // L'assistant lit ce qu'on vient de cocher, sans attendre.
            AssistantSync.scheduleSync(context: context, settings: app.settings)
            // Spotlight suit les cours, séries, exercices et notes.
            SpotlightIndexer.schedule(container: app.modelContainer)
        }
        // Un autre appareil a écrit (iCloud) : doublons fusionnés, widgets à jour.
        .onReceive(NotificationCenter.default.publisher(for: CloudSyncMonitor.remoteChange)) { _ in
            CloudSyncMonitor.remoteChangeArrived(container: app)
        }
        .onReceive(NotificationCenter.default.publisher(for: FocusTimerStore.didSave)) { _ in
            WidgetSnapshotWriter.scheduleRefresh(context: context, settings: app.settings)
        }
        .onChange(of: scenePhase) { _, phase in
            // Alimente le widget quand l'app passe au premier plan ou en arrière-plan.
            if phase == .active || phase == .background {
                WidgetSnapshotWriter.refresh(context: context, settings: app.settings)
            }
            // Les rappels suivent les données : une évaluation ajoutée ou une
            // session planifiée a son rappel dès que l'app passe en arrière-plan,
            // sans passer par un bouton dans les réglages.
            if phase == .background, !app.settings.assistantToken.isEmpty {
                Task { await AssistantSync.sync(context: context, settings: app.settings, force: false) }
            }
            if phase == .background {
                // La liaison instantanée du chrono se ferme : iOS la couperait de
                // toute façon, et une connexion ouverte pour rien compte dans le
                // quota Supabase. Elle se rouvre au retour (`resume`).
                TimerLink.shared.suspend()
                Task { await CookieKeeper.save() }
                MoodleWatcher.schedule(settings: app.settings)
            }
            if phase == .background, AnkiWebSync.shared.isSignedIn {
                // Des révisions pas encore envoyées partent avant que l'app ne
                // s'endorme : iOS laisse quelques secondes pour finir.
                let task = UIApplication.shared.beginBackgroundTask(withName: "AnkiWeb")
                Task { @MainActor in
                    await AnkiWebSync.shared.syncNow()
                    UIApplication.shared.endBackgroundTask(task)
                }
            }
            if phase == .background, app.settings.hasCompletedOnboarding {
                Task { await app.notifications.rescheduleFromStore(context: context, settings: app.settings) }
            }
            if phase == .active {
                // Une commande venue de l'écran verrouillé pendant que l'app
                // dormait attend dans le dépôt partagé : on la rejoue ici.
                // Même principe pour un fichier partagé depuis une autre app.
                // La socket temps réel des groupes a pu être coupée par la veille.
                app.social.realtime?.resume()
                app.groupSessions.resume()
                Task { @MainActor in
                    // Le chrono rattrape ce qui s'est passé app fermée : une fin
                    // de bloc, une pause écoulée.
                    app.focus.reload()
                    NSUbiquitousKeyValueStore.default.synchronize()
                    TimerLink.shared.resume()
                    app.focus.applyRemote()
                    FocusTimerCommandHandler.consumePending(container: app)
                    // Un PDF partagé depuis une autre app : l'accueil ouvre
                    // l'import. Il était auparavant retiré du dépôt… et jeté.
                    if let shared = PendingImportBridge.take() {
                        app.router.selectedTab = .today
                        app.router.pendingImport = shared
                    }
                    // Indépendants, menés de front : le temps passé dans Anki,
                    // ce que l'assistant a demandé pendant que l'app dormait…
                    // (sur le fil principal, comme le contexte qu'ils écrivent).
                    let anki = Task { @MainActor in _ = await AnkiReviewSync.syncIfDue(context: context, settings: app.settings) }
                    let assistant = Task { @MainActor in _ = await AssistantSync.sync(context: context, settings: app.settings) }
                    // …et la série de la semaine publiée sur Moodle, puis ses
                    // énoncés gardés pour le métro (qui en dépendent).
                    await ContentRefresher.refreshIfDue(context: context, settings: app.settings)
                    await OfflineLibrary.shared.sync(context: context, settings: app.settings)
                    _ = await (anki.value, assistant.value)
                }
            }
        }
    }

    enum RootSheet: String, Identifiable {
        case focus, agenda, stats, me
        var id: String { rawValue }
    }

    /// Les drapeaux du routeur, vus comme une seule feuille. Fermer la feuille
    /// remet le drapeau à faux — sinon le bouton ne rouvrirait plus rien.
    private var rootSheet: Binding<RootSheet?> {
        Binding(get: {
            if app.router.showingFocus, !Self.chronoIsTab { return .focus }
            if app.router.showingAgenda { return .agenda }
            if app.router.showingStats { return .stats }
            if app.router.showingProfile { return .me }
            return nil
        }, set: { value in
            if value == nil {
                app.router.showingFocus = false
                app.router.showingAgenda = false
                app.router.showingStats = false
                app.router.showingProfile = false
            }
        })
    }

    /// iOS 26 : le chrono est un onglet. Avant : notre barre, où « Chrono »
    /// ouvre Focus en feuille.
    private var tabSelection: Binding<AppRouter.Tab> {
        Binding(get: { app.router.selectedTab }, set: { tab in
            if tab == .focus, !Self.chronoIsTab {
                app.router.openFocus()
                Haptics.tap()
            } else {
                app.router.selectedTab = tab
            }
        })
    }

    static var chronoIsTab: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// La barre **système** (Liquid Glass d'iOS 26) : quatre vrais onglets, le
    /// chrono compris — une page, comme les autres, plus un faux onglet qui
    /// ouvrait une feuille par-dessus. Pendant une session, le chrono **flotte**
    /// au-dessus de la barre (son accessoire) sur les autres onglets ; le
    /// toucher mène à l'onglet. La recherche est dans « Cours » (la barre de la
    /// liste). La barre se replie au défilement.
    ///
    /// Avant iOS 26 : notre barre (`CarnetTabBar`) sur matière translucide.
    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: tabSelection) {
                ForEach(CarnetTabBar.tabs, id: \.self) { tab in
                    Tab(tab.title, systemImage: tab.icon, value: tab) {
                        tabContent(tab)
                    }
                }
                Tab(AppRouter.Tab.focus.title, systemImage: AppRouter.Tab.focus.icon, value: AppRouter.Tab.focus) {
                    FocusView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .modifier(FocusAccessory())
        } else {
            TabView(selection: tabSelection) {
                ForEach(CarnetTabBar.tabs, id: \.self) { tab in
                    tabContent(tab)
                        .toolbar(.hidden, for: .tabBar)
                        .tag(tab)
                }
            }
            .modifier(CarnetTabBarInset())
        }
    }

    /// Un « Démarrer » venu d'un écran : le chrono part sans quitter l'écran.
    /// Une session en cours sur autre chose ouvre Focus, qui demande quoi en
    /// faire (la remplacer, ou la continuer).
    private func startInPlace(_ request: FocusRequest) {
        guard request.autoStart else { app.router.showingFocus = true; return }
        var resolved = request
        if resolved.courseID == nil, !request.courseCode.isEmpty {
            let code = request.courseCode
            resolved.courseID = ((try? context.fetch(FetchDescriptor<Course>())) ?? []).first {
                $0.code.caseInsensitiveCompare(code) == .orderedSame
                    || $0.displayCode.caseInsensitiveCompare(code) == .orderedSame
            }?.id
        }
        let focus = app.focus
        if focus.hasSession,
           resolved.courseID != focus.state?.courseID || resolved.taskType != focus.state?.taskType {
            app.router.focusRequest = resolved
            app.router.showingFocus = true
            return
        }
        app.router.focusRequest = nil
        focus.start(courseID: resolved.courseID, taskType: resolved.taskType,
                    targetID: resolved.targetID, label: resolved.label)
        Haptics.success()
    }

    /// Suivre un cours : le mode étude jusqu'à la fin du créneau, bureau « En
    /// cours ». Une session déjà ouverte passe dessus (son temps reste).
    private func followLecture(_ courseID: UUID) {
        app.router.lectureRequest = nil
        let classes = DeskSchedule.today(context: context)
        let klass = DeskSchedule.current(in: classes).flatMap { $0.slot.courseID == courseID ? $0 : nil }
            ?? classes.first { $0.slot.courseID == courseID && $0.slot.end > Date() }
        let minutes = klass.map { LectureClock.studyMinutes(for: $0.slot, now: Date()) } ?? 105
        let blocking = StudyLock.isAvailable && UserDefaults.standard.object(forKey: "studyMode.blocking") as? Bool ?? false
        if app.focus.isLocked {
            app.focus.updateContext(courseID: .some(courseID), taskType: .lecture, targetID: .some(nil))
        } else {
            app.focus.enterStudy(minutes: minutes, courseID: courseID, taskType: .lecture, locks: blocking)
        }
        app.router.showingStudyMode = true
        Haptics.success()
    }

    /// Liens profonds : `polymestre://focus?course=CS-250&type=exercise`.
    /// `studytrack://` aussi : les liens d'invitation et raccourcis faits avant le
    /// changement de nom restent valables.
    private func handle(_ url: URL) {
        guard ["polymestre", "studytrack"].contains(url.scheme?.lowercased() ?? "") else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch (url.host ?? "").lowercased() {
        case "focus":
            if items.isEmpty {
                app.router.openFocus()
                return
            }
            let type = TaskType(rawValue: value("type") ?? "") ?? .exercise
            let code = value("course") ?? ""
            let label = value("label") ?? (code.isEmpty ? String(localized: "Session libre") : "\(code) · \(type.label)")
            app.router.startFocus(courseID: nil,
                                  courseCode: code,
                                  taskType: type,
                                  label: label)
        case "course":
            // `polymestre://course?id=…` — depuis le widget « Cours de la semaine ».
            if let id = value("id").flatMap(UUID.init(uuidString:)) {
                app.router.openCourse(id)
            } else {
                app.router.selectedTab = .courses
            }
        case "tasks":
            app.router.selectedTab = .today
            app.router.showingTasks = true
        case "stats":
            app.router.showingStats = true
        case "today":
            app.router.selectedTab = .today
        case "agenda":
            app.router.openAgenda()
        case "courses":
            app.router.selectedTab = .courses
        case "groups":
            app.router.selectedTab = .groups
        case "lecture":
            // `polymestre://lecture?id=…` — suivre le cours (widget, raccourci).
            if let id = value("id").flatMap(UUID.init(uuidString:)) { app.router.openLectureDesk(courseID: id) }
        case "join":
            // `polymestre://join?code=EPFL-XXXX` — le lien partagé par un camarade.
            let code = value("code") ?? ""
            guard !code.isEmpty else {
                app.router.selectedTab = .groups
                return
            }
            app.router.startJoin(code: code)
        default:
            app.router.selectedTab = .today
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppRouter.Tab) -> some View {
        switch tab {
        case .today: TodayView()
        case .courses: CoursesView()
        case .groups: GroupsView()
        case .focus: EmptyView()
        }
    }
}

/// Le profil — réglages, bilan, compte — **en haut à droite de chaque onglet**,
/// toujours à la même place, toujours le dernier bouton de la barre.
///
/// Un avatar plutôt qu'une silhouette générique : ce sont tes initiales, on
/// reconnaît « moi » sans lire. La barre de chaque onglet suit une seule règle :
/// à gauche le grand titre, à droite l'action de l'onglet (« + ») puis l'avatar.
struct ProfileButton: View {
    @Environment(AppContainer.self) private var app
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    var body: some View {
        Button {
            app.router.showingProfile = true
        } label: {
            ZStack {
                Circle().fill(Theme.accent.badgeFill)
                if initials.isEmpty {
                    Image(systemName: "person.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent.badgeInk)
                } else {
                    Text(initials)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent.badgeInk)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profil, réglages et bilan")
    }

    private var initials: String {
        app.settings.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
    }
}
