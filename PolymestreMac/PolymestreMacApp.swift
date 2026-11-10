import CloudKit
import SwiftUI
import SwiftData
import UserNotifications
import WidgetKit

/// Polymestre sur Mac : le chrono dans la barre des menus, et une fenêtre pour
/// voir ses cours, cocher ses exercices et relire son bilan. Les données sont
/// celles de l'iPhone, par iCloud ; le chrono aussi.
/// Lancé par `PolymestreMacEntry` (`StudyGuard.swift`), qui dirige vers le
/// gardien du verrou quand c'est lui qu'on lance.
struct PolymestreMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate
    @State private var store: MacStore
    @State private var settings: MacSettings
    @State private var timer: MacTimer
    @State private var menuClock: MenuBarClock

    init() {
        // Les captures (`-snapshot`) ne lisent ni n'écrivent les vraies préférences.
        HeadlessCapture.isolatePreferences()
        // Avant tout : ce que StudyTrack (l'ancienne identité) a laissé — réglages,
        // trousseau, fichiers, base — copié une fois, l'ancien n'est pas touché.
        #if DEBUG
        // Les essais et les outils iCloud ne touchent jamais à la reprise.
        let trial = !Set(CommandLine.arguments).isDisjoint(with: ["-memoryStore", "-cloudCheck", "-initCloudKitSchema"])
        #else
        let trial = false
        #endif
        if !trial {
            IdentityMigration.runBeforeStore(newStoreURL: MacSandboxMigration.storeURL,
                                             cloud: MacStore.hasICloudEntitlement && !MacSandboxMigration.isSandboxed)
            StudyGuard.retireLegacyAgent()
        }
        let existingUser = UserDefaults.standard.object(forKey: "cloudRelay.device") != nil
            || UserDefaults.standard.object(forKey: "mac.epflEmail") != nil
        AppLanguage.settle(existingUser: existingUser)
        // Avant `MacSettings`, qui lit ces clés.
        StudyMode.settleBlockingDefaults(["mac.studyBlocking", "mac.studySystemLock"], existingUser: existingUser)
        #if DEBUG
        // `-cloudCheck` : iCloud marche-t-il hors du bac à sable ? Une base
        // jetable, le premier événement CloudKit, puis on quitte.
        if CommandLine.arguments.contains("-cloudCheck") { CloudCheck.run() }
        // `-initCloudKitSchema` : tout le schéma dans Development, avant de le
        // déployer en Production (voir `CloudSchemaInit`).
        if CommandLine.arguments.contains("-initCloudKitSchema") { CloudSchemaInit.run() }
        #endif
        // Avant tout : les réglages et la base du bac à sable, repris une fois.
        MacSandboxMigration.run()
        let settings = MacSettings()
        let store = MacStore(preferences: settings.shared)
        #if DEBUG
        // `-isolatedTimer` : un chrono qui ne publie rien (essais, captures) —
        // l'iPhone n'en voit rien.
        let timer = MacTimer(settings: settings, isolated: CommandLine.arguments.contains("-isolatedTimer"))
        #else
        let timer = MacTimer(settings: settings)
        #endif
        let menuClock = MenuBarClock()
        menuClock.timer = timer
        menuClock.settings = settings
        // Le mode étude suit le chrono : lancé sur l'iPhone, il s'ouvre ici.
        StudyModeController.shared.timer = timer
        StudyModeController.shared.settings = settings
        StudyModeController.shared.container = store.container
        // La synchronisation Supabase (éteinte tant qu'on ne l'a pas demandée).
        // Le compte Polymestre : le même client pour la synchronisation et les groupes.
        MacGroups.shared.timer = timer
        MacGroups.shared.settings = settings
        MacGroups.shared.container = store.container
        SupabaseSync.shared = SupabaseSync(container: store.container, client: MacGroups.shared.social.client)
        SupabaseSync.shared?.start()
        // La fiche de révision des cours sans polycopié : Claude, par l'abonnement.
        RevisionSheetMaker.shared.writer = { try await RevisionSheetClaude.write(instructions: $0, prompt: $1) }
        // Une fiche par cours : celles qui manquent se font seules, au calme
        // après le lancement (le menu Fichier › Faire les fiches les refait).
        if !HeadlessCapture.active {
            let container = store.container
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25))
                let courses = (try? container.mainContext.fetch(FetchDescriptor<Course>())) ?? []
                await RevisionSheetMaker.shared.makeMissing(courses, hub: .shared)
            }
        }
        // Les widgets du bureau, le chrono flottant, la barre des menus et le
        // mode étude suivent le chrono.
        let refreshWidgets = {
            WidgetSnapshotWriter.scheduleRefresh(context: ModelContext(store.container), settings: store.preferences)
            SpotlightIndexer.schedule(container: store.container)
        }
        timer.onChange = {
            refreshWidgets()
            MiniTimerPanel.shared.update()
            menuClock.update()
            StudyModeController.shared.update()
            // Avec mesure : le mode étude et le chrono changent ce que Claude Code permet.
            ClaudeMeasureService.shared.contextChanged()
        }
        timer.attach(store.container)
        ClaudeMeasureService.shared.start(timer: timer, container: store.container, settings: settings)
        MiniTimerPanel.shared.timer = timer
        MiniTimerPanel.shared.settings = settings
        MiniTimerPanel.shared.container = store.container
        store.onDataChange = {
            refreshWidgets()
            ClaudeMeasureService.shared.contextChanged()
        }
        refreshWidgets()
        _settings = State(initialValue: settings)
        _store = State(initialValue: store)
        _timer = State(initialValue: timer)
        _menuClock = State(initialValue: menuClock)
        menuClock.update()
        MacAppDelegate.timer = timer
        // La voie instantanée du chrono partagé (moins d'une seconde).
        if store.isCloudSynced, !CommandLine.arguments.contains("-isolatedTimer") {
            // Chaque geste du Mac emporte l'état de l'îlot : le relais le pousse
            // à l'écran verrouillé de l'iPhone, même app fermée.
            TimerLink.shared.livePayload = { [container = store.container] snapshot in
                MacLivePayload.make(snapshot, container: container, settings: settings.pomodoro)
            }
            // Un seul lecteur pour le Mac et l'iPhone, par le même lien.
            TimerLink.shared.onMusic = { StudyMusic.shared.receive($0) }
            TimerLink.shared.onConnect = { StudyMusic.shared.linkConnected() }
            // L'iPhone, compagnon du bureau : photo de la copie, « je bloque », question dictée.
            TimerLink.shared.onDrop = { StudyModeController.shared.desk.receive($0) }
            TimerLink.shared.startFromBundle(containerID: MacStore.cloudContainerID)
            // Music annonce ses changements : suivre ne coûte rien au repos.
            if StudyMusic.sharingEnabled { StudyMusic.shared.attach() }
        }
        MacAppDelegate.settings = settings
        MacAppDelegate.store = store
        // Le serveur MCP local des fichiers (réglage « Fichiers pour Claude », éteint par défaut).
        Task { @MainActor in await MacLocalMCP.shared.apply(settings: settings, container: store.container) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #if DEBUG
        MacDebugLaunch.apply(timer: timer, store: store)
        #endif
    }

    #if DEBUG
    @MainActor private static var preview: MacTimer?
    /// Un chrono à part pour regarder le panneau au repos, sans toucher au vrai.
    @MainActor static func previewTimer(_ settings: MacSettings) -> MacTimer {
        if let preview { return preview }
        let timer = MacTimer(settings: settings, isolated: true)
        preview = timer
        return timer
    }
    #endif

    var body: some Scene {
        Window("Polymestre", id: "main") {
            MacRootView()
                .environment(timer)
                .environment(store)
                .environment(settings)
                .environment(settings.shared)
                .frame(minWidth: 900, minHeight: 580)
        }
        .modelContainer(store.container)
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands {
            MacCommands(timer: timer, settings: settings)
            // « Importer depuis l'iPhone » (photo, numérisation) : Continuity Camera.
            ImportFromDevicesCommands()
        }

        MenuBarExtra(isInserted: .constant(!HeadlessCapture.active)) {
            MenuBarTimerView()
                .environment(timer)
                .environment(settings)
                .modelContainer(store.container)
        } label: {
            MenuBarLabel()
                .environment(timer)
                .environment(settings)
                .environment(menuClock)
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        // Le panneau de la barre des menus dans une fenêtre, pour le regarder.
        Window("Panneau", id: "debugPanel") {
            MenuBarTimerView()
                .environment(Self.previewTimer(settings))
                .environment(settings)
                .modelContainer(store.container)
        }
        .windowResizability(.contentSize)
        #endif

        Settings {
            MacSettingsView()
                .environment(settings)
                .environment(timer)
                .environment(settings.shared)
                .environment(store)
                .modelContainer(store.container)
        }
    }
}

/// La barre des menus de l'app : Chrono, Aller, la palette, l'aide.
struct MacCommands: Commands {
    let timer: MacTimer
    let settings: MacSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("À propos de Polymestre") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .credits: NSAttributedString(
                        string: String(localized: "Tes cours, tes séries, ton temps."),
                        attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                ])
            }
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Chrono") {
            Button(timer.phase == .running ? "Pause" : (timer.phase == .idle ? String(localized: "Démarrer") : String(localized: "Reprendre"))) {
                if timer.phase == .onBreak { timer.skipBreak() } else { timer.toggle() }
            }
            .keyboardShortcut("t", modifiers: [.command])
            Button("Terminer") { timer.finish() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(timer.phase == .idle || timer.isLocked)
            Button("Écourter la pause") { timer.skipBreak() }
                .disabled(timer.phase != .onBreak)
            Divider()
            Toggle("Chrono flottant", isOn: Binding(get: { settings.floatingTimer }, set: {
                settings.floatingTimer = $0
                MiniTimerPanel.shared.update()
            }))
            .keyboardShortcut("m", modifiers: [.command, .option])
            Divider()
            Button(timer.isStudying ? "Revenir au mode étude" : "Mode étude…") {
                StudyModeController.shared.presentSetup()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Abandonner", role: .destructive) { timer.discard() }
                .disabled(timer.phase == .idle || timer.isLocked)
        }
        CommandGroup(after: .newItem) {
            Button("Note rapide…") { NotificationCenter.default.post(name: .macQuickNote, object: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            // Une fiche par cours : le polycopié, ou Claude qui lit tout le cours.
            Button(RevisionSheetMaker.shared.batch.map { String(localized: "Fiches de révision… \($0.done)/\($0.total)") } ?? "Faire les fiches de révision") {
                guard let context = StudyModeController.shared.container?.mainContext,
                      let courses = try? context.fetch(FetchDescriptor<Course>(sortBy: [SortDescriptor(\.code)])) else { return }
                Task { await RevisionSheetMaker.shared.makeAll(courses, hub: .shared) }
            }
            .disabled(RevisionSheetMaker.shared.batch != nil)
        }
        CommandMenu("Aller") {
            Button("Aujourd'hui") { go("today") }.keyboardShortcut("1", modifiers: [.command])
            Button("Chrono") { go("focus") }.keyboardShortcut("2", modifiers: [.command])
            Button("Agenda") { go("agenda") }.keyboardShortcut("3", modifiers: [.command])
            Button("Bilan") { go("stats") }.keyboardShortcut("4", modifiers: [.command])
            Divider()
            Button("Rechercher…") {
                NotificationCenter.default.post(name: .macFocusSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Rechercher…") {
                NotificationCenter.default.post(name: .macFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
        }
        CommandGroup(replacing: .help) {
            Button("Raccourcis") {
                let alert = NSAlert()
                alert.messageText = String(localized: "Raccourcis")
                alert.informativeText = """
                ⌃⌥Espace — démarrer ou mettre en pause, depuis n'importe quelle app
                ⌘T — démarrer / pause · ⇧⌘T — terminer
                ⌘K ou ⌘F — chercher, ouvrir, chronométrer (⌘↩)
                ⌘1 ⌘2 ⌘3 ⌘4 — Aujourd'hui, Chrono, Agenda, Bilan
                ⇧⌘E — mode étude (plein écran, Mac et iPhone fermés au reste)
                ⌥⌘M — chrono flottant
                Dans un cours : Espace coche, ↩ chronomètre l'exercice choisi
                """
                alert.runModal()
            }
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }

    private func go(_ page: String) {
        NotificationCenter.default.post(name: .macGoTo, object: page)
    }
}

extension Notification.Name {
    static let macFocusSearch = Notification.Name("mac.focusSearch")
    static let macGoTo = Notification.Name("mac.goTo")
    /// La note rapide (⇧⌘N, barre des menus) : la fenêtre l'ouvre.
    static let macQuickNote = Notification.Name("mac.quickNote")
}

/// Le raccourci global et les widgets : ce qui vit hors des fenêtres.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var timer: MacTimer?
    @MainActor static var settings: MacSettings?
    @MainActor private var hotKey: GlobalHotKey?

    @MainActor static var store: MacStore?

    /// Relit les cours (Moodle, Botafogo) s'il est temps : la même chaîne que
    /// l'iPhone (`ContentRefresher`), sur l'appareil qui la réclame le premier.
    @MainActor static func refreshContent(force: Bool = false) {
        guard let store else { return }
        Task { @MainActor in
            await ContentRefresher.refreshIfDue(context: store.container.mainContext, settings: store.preferences, force: force)
        }
    }

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        HeadlessCapture.begin()
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Une capture : rien d'autre que la vue à capturer (pas de connexion,
        // pas de raccourci global volé à la session en cours).
        if HeadlessCapture.active { StudyModeController.shared.update(); return }
        // Les sites de l'EPFL, sans rien afficher : la session Microsoft garde
        // la connexion, mais celle de chaque site s'efface à la fermeture.
        if !CommandLine.arguments.contains("-epflConnect") {
            Task { @MainActor in
                await SchoolConnect.shared.connectAll()
                // Une série publiée sur Moodle depuis la dernière fois.
                Self.refreshContent(force: CommandLine.arguments.contains("-refreshContent"))
            }
        }
        MiniTimerPanel.shared.update()
        MacUpdater.shared.checkIfDue()
        // Au réveil du Mac, la socket du chrono partagé est morte : on la relance.
        // À l'endormissement, on la ferme : pas de tentatives de reconnexion
        // pendant la veille.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                TimerLink.shared.resume()
                StudyModeController.shared.update()
                Self.refreshContent()
                MacUpdater.shared.checkIfDue()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TimerLink.shared.suspend() }
        }
        StudyModeController.shared.update()
        // Une fiche restée d'une session morte (plantage, redémarrage) et aucun
        // blocage en cours : tout est rétabli.
        if !StudyModeController.shared.isBlocking { SystemLock.release() }
        hotKey = GlobalHotKey { Self.timer?.toggle() }
        updateHotKey()
        withObservationTracking({ _ = Self.settings?.globalShortcut }, onChange: { [weak self] in
            Task { @MainActor in self?.observeHotKey() }
        })
    }

    @MainActor
    private func observeHotKey() {
        updateHotKey()
        withObservationTracking({ _ = Self.settings?.globalShortcut }, onChange: { [weak self] in
            Task { @MainActor in self?.observeHotKey() }
        })
    }

    @MainActor
    private func updateHotKey() {
        if Self.settings?.globalShortcut ?? true { hotKey?.register() } else { hotKey?.unregister() }
    }

    /// Clic droit sur l'icône du Dock : le chrono.
    @MainActor
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let timer = Self.timer else { return nil }
        let menu = NSMenu()
        let title: String
        switch timer.phase {
        case .idle: title = String(localized: "Démarrer le chrono")
        case .running: title = "Pause"
        case .paused: title = String(localized: "Reprendre")
        case .onBreak: title = String(localized: "Écourter la pause")
        }
        menu.addItem(DockItem(title: title) { timer.phase == .onBreak ? timer.skipBreak() : timer.toggle() })
        if timer.phase != .idle, !timer.isLocked {
            menu.addItem(DockItem(title: String(localized: "Terminer et enregistrer")) { timer.finish() })
        }
        return menu
    }

    /// Fermer la fenêtre ne quitte pas : le chrono reste dans la barre des menus.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// ⌘Q, « Quitter » du Dock, la fermeture de session, un redémarrage :
    /// sous verrou, Polymestre ne quitte pas (et le Mac ne s'éteint pas sans
    /// forcer). Sans verrou, en mode étude, on demande d'abord.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        StudyModeController.shared.confirmQuit() ? .terminateNow : .terminateCancel
    }

    /// L'app s'en va (permis : pas de verrou) : les raccourcis du système sont rallumés.
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        SystemLock.release()
    }
}

/// Un élément de menu qui exécute une fermeture.
private final class DockItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @MainActor @objc private func fire() { handler() }
}

/// L'état de l'îlot de l'iPhone, construit par le Mac à chaque geste.
enum MacLivePayload {
    @MainActor
    static func make(_ snapshot: CloudRelay.TimerSnapshot, container: ModelContainer, settings: PomodoroSettings) -> Data? {
        guard let state = snapshot.state else {
            return LiveActivityBuilder.push(event: "end", state: ActivityTimerState(countingSince: nil, frozenTotal: 0),
                                            attributes: nil)
        }
        let course = TimerEngine.course(state.courseID, in: ModelContext(container))
        let exercise = LiveActivityBuilder.exercise(for: state, course: course)
        let content = LiveActivityBuilder.state(timer: state, settings: settings, exercise: exercise, course: course)
        return LiveActivityBuilder.push(event: "update", state: content,
                                        attributes: LiveActivityBuilder.attributes(for: state, course: course))
    }
}

#if DEBUG
import CoreData

/// Pousse **tout** le schéma — chaque entité, chaque champ — dans
/// l'environnement Development du conteneur, avant de le déployer en
/// Production (console CloudKit › Deploy Schema Changes).
///
/// CloudKit ne crée un champ qu'à la première fiche qui le remplit : un champ
/// resté vide dans nos propres données manquerait en Production, et la première
/// fiche d'un·e ami·e qui le remplit y serait refusée — sa synchronisation
/// bloquée sans un mot. `initializeCloudKitSchema` envoie des fiches d'exemple
/// complètes, puis CloudKit les supprime. Base jetable : la vraie n'est pas
/// touchée. Une build Debug **signée** (Development) ; rien ne s'affiche.
enum CloudSchemaInit {
    static func run() -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func say(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("schema-init-\(UUID().uuidString).store")
        defer { for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models) else {
            say("SCHEMA modèle introuvable"); exit(1)
        }
        let description = NSPersistentStoreDescription(url: url)
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: MacStore.cloudContainerID)
        description.shouldAddStoreAsynchronously = false
        let container = NSPersistentCloudKitContainer(name: "Polymestre", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { say("SCHEMA ouverture échouée : \(loadError)"); exit(1) }
        // D'abord la mise en place du miroir (zone, abonnement) **et** la première
        // importation (la base jetable reçoit toutes les fiches du compte) :
        // lancé pendant l'une ou l'autre, l'appel attend la file du miroir et
        // échoue au bout de 30 s (« a 30s wait failed »).
        var setupDone = false
        var importDone = false
        let observer = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                                              object: container, queue: nil) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil else { return }
            say("SCHEMA évènement \(event.type.rawValue) réussi=\(event.succeeded) \(event.error.map { "\($0)" } ?? "")")
            if event.type == .setup { setupDone = true }
            if event.type == .import { importDone = true }
        }
        let deadline = Date().addingTimeInterval(600)
        while !(setupDone && importDone), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        // Le miroir se pose un instant après la dernière importation.
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        NotificationCenter.default.removeObserver(observer)
        if !(setupDone && importDone) { say("SCHEMA miroir pas prêt au bout de 10 min") }
        // Hors du fil principal, la boucle principale tournant.
        var outcome: Result<Void, Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try container.initializeCloudKitSchema() }
            DispatchQueue.main.async { outcome = result }
        }
        while outcome == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        switch outcome {
        case .failure(let error)?:
            say("SCHEMA échec : \(error)"); exit(1)
        default:
            let names = model.entities.compactMap(\.name).sorted().joined(separator: ", ")
            say("SCHEMA ok : \(model.entities.count) entités (\(names))")
        }
        // Le verrou de la reprise de StudyTrack (`IdentityMigration.CloudLock`) : un type
        // d'enregistrement hors du miroir, créé ici avec tous ses champs, puis retiré.
        var lockDone = false
        Task.detached {
            let database = CKContainer(identifier: MacStore.cloudContainerID).privateCloudDatabase
            let record = CKRecord(recordType: IdentityMigration.CloudLock.recordType,
                                  recordID: CKRecord.ID(recordName: "schema-init-\(UUID().uuidString)"))
            record["owner"] = "schema"
            record["startedAt"] = Date()
            record["completedAt"] = Date()
            record["ids"] = IdentityMigrationPlan.encode([UUID()])
            do {
                let saved = try await database.save(record)
                _ = try? await database.deleteRecord(withID: saved.recordID)
                say("SCHEMA ok : type \(IdentityMigration.CloudLock.recordType)")
            } catch {
                say("SCHEMA échec du type \(IdentityMigration.CloudLock.recordType) : \(error)")
            }
            await MainActor.run { lockDone = true }
        }
        while !lockDone { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        if let store = container.persistentStoreCoordinator.persistentStores.first {
            try? container.persistentStoreCoordinator.remove(store)
        }
        exit(0)
    }
}

enum CloudCheck {
    static func run() -> Never {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cloudcheck-\(UUID().uuidString).store")
        let schema = PolymestreSchema.current
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .private(MacStore.cloudContainerID))
        var container: ModelContainer?
        do {
            container = try ModelContainer(for: schema, migrationPlan: PolymestreMigrationPlan.self, configurations: [configuration])
            FileHandle.standardError.write(Data("CLOUD container ok (sandbox: \(MacSandboxMigration.isSandboxed))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("CLOUD container FAILED: \(error)\n".utf8))
            exit(1)
        }
        let observer = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil else { return }
            FileHandle.standardError.write(Data("CLOUD event \(event.type.rawValue) succeeded=\(event.succeeded) error=\(String(describing: event.error))\n".utf8))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(40))
        let courses = container.map { (try? ModelContext($0).fetchCount(FetchDescriptor<Course>())) ?? -1 } ?? -1
        FileHandle.standardError.write(Data("CLOUD courses imported: \(courses)\n".utf8))
        NotificationCenter.default.removeObserver(observer)
        container = nil
        for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        exit(0)
    }
}
#endif
