import SwiftData
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Réglages (⌘,) : cinq pages claires, les mêmes sur l'iPhone et Windows — Général, Chrono,
/// Mode étude, Comptes, Claude — plus le temps de Claude Code. Chaque page montre l'essentiel ;
/// les réglages rares attendent dans sa ligne « Avancé », repliée.
struct MacSettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case general, chrono, study, accounts, claude, claudeCode
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .general: "Général"
            case .chrono: "Chrono"
            case .study: "Mode étude"
            case .accounts: "Comptes"
            case .claude: "Claude et IA"
            case .claudeCode: "Claude Code"
            }
        }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .chrono: "timer"
            case .study: "moon.stars"
            case .accounts: "person.crop.circle"
            case .claude: "sparkles"
            case .claudeCode: "terminal"
            }
        }
    }

    @AppStorage("settings.page") private var page = Page.general.rawValue

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { Page(rawValue: page) ?? .general }, set: { page = ($0 ?? .general).rawValue })) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(210)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch Page(rawValue: page) ?? .general {
                case .general: GeneralSettings()
                case .chrono: PomodoroSettingsPane()
                case .study: StudySettingsPane()
                case .accounts: AccountsSettings()
                case .claude: ClaudeSettingsPane()
                case .claudeCode: ClaudeMeasureSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle(Text((Page(rawValue: page) ?? .general).title))
        }
        .frame(width: 760)
        .frame(minHeight: 580, idealHeight: 580)
    }
}

private struct GeneralSettings: View {
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]
    @AppStorage("settings.advanced.general") private var advanced = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            SchoolSection()
            TimetableSettingsSection(settings: settings.shared)
            Section {
                Toggle("Ouvrir Polymestre à la connexion", isOn: Binding(
                    get: { _ = settings.launchAtLoginRevision; return settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(Carnet.wrong)
                }
                Toggle("Garder l'icône dans le Dock", isOn: $settings.keepInDock)
                Toggle("Temps dans la barre des menus", isOn: $settings.showTimeInMenuBar)
            } header: {
                Text("Sur ce Mac")
            }
            LanguageSection()
            AboutSection()
            AdvancedSettingsToggle(isOn: $advanced, summary: "Secondes dans la barre des menus, raccourci global, cahiers de notes.")
            if advanced {
                Section {
                    Toggle("Avec les secondes", isOn: $settings.menuBarSeconds)
                        .disabled(!settings.showTimeInMenuBar)
                    Toggle("Raccourci global ⌃⌥Espace", isOn: $settings.globalShortcut)
                    if settings.globalShortcut, GlobalHotKey.lastRegistrationFailed {
                        Label("⌃⌥Espace est déjà pris (Réglages Clavier › Raccourcis › Sources de saisie).", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Barre des menus et clavier")
                } footer: {
                    Text("Sans les secondes, ça use moins la batterie.")
                }
                NotesSection(courses: courses.filter(\.isTracked))
            }
        }
        .formStyle(.grouped)
    }
}

/// La version, les mises à jour (le Mac n'a pas l'App Store pour les annoncer)
/// et « Signaler un problème ».
private struct AboutSection: View {
    @State private var updater = MacUpdater.shared

    var body: some View {
        Section {
            LabeledContent("Version", value: AppDistribution.versionLabel)
            if let update = updater.available {
                HStack {
                    Text("Polymestre \(update.label) est disponible.")
                    Spacer()
                    Button("Télécharger") { updater.download() }
                }
                if let notes = update.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary)
                }
            } else if AppDistribution.siteHost != nil {
                HStack {
                    Text(updater.status ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(updater.checking ? "Recherche…" : "Rechercher une mise à jour") {
                        Task { await updater.check(manual: true) }
                    }
                    .disabled(updater.checking)
                }
            }
            if AppDistribution.feedbackAddress != nil {
                Button("Signaler un problème…") { MacFeedback.send() }
            }
        } header: {
            Text("À propos")
        } footer: {
            if AppDistribution.feedbackAddress != nil {
                Text("Le courriel joint la fin du journal de l'app : relis-le avant d'envoyer.")
            }
        }
    }
}

private struct PomodoroSettingsPane: View {
    @Environment(MacSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Stepper(settings.weeklyGoalMinutes == 0
                            ? "Objectif de la semaine : charge EPFL"
                            : "Objectif de la semaine : \(DateUtils.hoursLabel(seconds: settings.weeklyGoalMinutes * 60))",
                        value: $settings.weeklyGoalMinutes, in: 0...6000, step: 60)
                Toggle("Chrono flottant", isOn: Binding(
                    get: { settings.floatingTimer },
                    set: { settings.floatingTimer = $0; MiniTimerPanel.shared.update() }))
                Toggle("Sons", isOn: $settings.sounds)
            } header: {
                Text("Chrono")
            }
            CountingSection()
            Section {
                Toggle("Démarrer en Pomodoro", isOn: $settings.pomodoroDefault)
                Stepper("Bloc de travail : \(settings.focusMinutes) min", value: $settings.focusMinutes, in: 5...120, step: 5)
                Stepper("Pause courte : \(settings.shortBreakMinutes) min", value: $settings.shortBreakMinutes, in: 1...30)
                Stepper("Pause longue : \(settings.longBreakMinutes) min", value: $settings.longBreakMinutes, in: 5...60, step: 5)
                Stepper("Pause longue tous les \(settings.longBreakEvery) blocs", value: $settings.longBreakEvery, in: 2...8)
                Toggle("Relancer après la pause", isOn: $settings.autoStartFocus)
            } header: {
                Text("Pomodoro")
            }
        }
        .formStyle(.grouped)
        // La session ouverte prend les nouvelles durées, et l'iPhone avec elle.
        .onChange(of: settings.pomodoro) { _, _ in MacAppDelegate.timer?.cycleDidChange() }
    }
}

/// Les comptes : la synchronisation (iCloud, compte Polymestre), Spotify, Google pour NotebookLM.
private struct AccountsSettings: View {
    @Environment(MacStore.self) private var store
    @State private var notebook = NotebookLMAccount.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Base") {
                    Text(store.isCloudSynced ? "iCloud (privé)" : "locale")
                }
                LabeledContent("État") {
                    Text(SyncFooter.describe(store.syncState, synced: store.isCloudSynced, now: Date()))
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Les mêmes données que sur ton iPhone.")
            }
            MacSupabaseSyncSection()
            SpotifySettingsSection()
            Section {
                LabeledContent("Google (NotebookLM)") {
                    switch notebook.state {
                    case .ready:
                        HStack {
                            Text("Connecté").foregroundStyle(.secondary)
                            Button("Se déconnecter") { Task { await notebook.signOut() } }
                        }
                    case .checking:
                        ProgressView().controlSize(.small)
                    default:
                        Text("Se connecte depuis l'onglet « Écouter » d'une fiche").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Ton mot de passe reste chez Google.")
            }
        }
        .formStyle(.grouped)
        .task { if notebook.state == .unknown { await notebook.refresh() } }
    }
}

/// Le mode étude : la session, ce qui reste ouvert ; le verrou fin (écrans, gestes…) dans « Avancé ».
private struct StudySettingsPane: View {
    @Environment(MacSettings.self) private var settings
    @Environment(MacTimer.self) private var timer
    @AppStorage("settings.advanced.study") private var advanced = false
    @State private var newSite = ""
    @State private var siteError = false
    @State private var showingServiceSites = false

    private var keepAwakeFooter: String {
        switch settings.studyKeepAwake {
        case .off:
            return String(localized: "Le Mac se met en veille comme d'habitude.")
        case .system:
            return String(localized: "Le Mac reste éveillé pendant que le chrono tourne ; en pause, il dort.")
        case .display:
            return String(localized: "Le Mac reste éveillé pendant que le chrono tourne ; l'écran peut s'éteindre en pause ou sur batterie faible.")
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            if timer.isLocked {
                // Sous verrou, la liste ne s'élargit pas : ajouter Safari aux
                // apps permises serait une sortie.
                Label("Verrouillé jusqu'à \(DateUtils.time.string(from: timer.state?.studyUntil ?? Date())). Les réglages du mode étude reviennent à la fin.",
                      systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper("Durée : \(settings.studyMinutes) min", value: $settings.studyMinutes, in: 15...240, step: 5)
                Toggle("Bloquer le reste", isOn: $settings.studyBlocking)
                Toggle("Maintenir pour finir plus tôt", isOn: $settings.studyHoldToLeave)
                Toggle("Toujours sombre", isOn: $settings.studyAlwaysDark)
                    .onChange(of: settings.studyAlwaysDark) { _, _ in StudyModeController.shared.update() }
                Picker("Garder éveillé", selection: $settings.studyKeepAwake) {
                    Text("Non").tag(KeepAwakePolicy.Mode.off)
                    Text("Le Mac").tag(KeepAwakePolicy.Mode.system)
                    Text("Le Mac et l'écran").tag(KeepAwakePolicy.Mode.display)
                }
                .onChange(of: settings.studyKeepAwake) { _, _ in StudyModeController.shared.update() }
            } header: {
                Text("Session")
            } footer: {
                Text((settings.studyBlocking ? String(localized: "Seules les apps et les sites ci-dessous restent ouverts.") : String(localized: "Rien n'est bloqué, ni ici ni sur l'iPhone.")) + " " + keepAwakeFooter)
            }

            Section {
                ForEach(settings.studyApps, id: \.self) { bundleID in
                    HStack(spacing: 10) {
                        if let icon = StudyModeController.icon(for: bundleID) {
                            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(StudyModeController.name(for: bundleID))
                            if !StudyModeController.isInstalled(bundleID) {
                                Text("pas installée").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { settings.studyApps.removeAll { $0 == bundleID } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Retirer")
                    }
                }
                Button("Ajouter une app…", action: addApp)
            } header: {
                Text("Apps permises")
            }

            Section {
                let groups = StudyMode.siteGroups(settings.studySites)
                ForEach(groups.named, id: \.self) { site in siteRow(site) }
                if !groups.service.isEmpty {
                    // Connexions et hébergeurs : une ligne, dépliable pour qui veut y toucher.
                    DisclosureGroup(isExpanded: $showingServiceSites) {
                        ForEach(groups.service, id: \.self) { site in siteRow(site) }
                    } label: {
                        HStack {
                            Image(systemName: "key").foregroundStyle(.secondary)
                            Text("Connexion et hébergement")
                            Spacer()
                            Text("\(groups.service.count) domaines").foregroundStyle(.secondary)
                        }
                    }
                    .help("Pages de connexion (edu-ID, Microsoft, Google, Apple) et hébergeurs des vidéos et des fichiers : sans eux, Moodle ou Claude ne s'ouvrent pas.")
                }
                HStack {
                    TextField("Ajouter un site", text: $newSite)
                        .onSubmit(addSite)
                    Button("Ajouter", action: addSite).disabled(newSite.isEmpty)
                }
                if siteError {
                    Text("Adresse invalide").font(.caption).foregroundStyle(Carnet.wrong)
                }
                Button("Rétablir") { settings.studySites = StudyMode.defaultSites }
                    .buttonStyle(.link)
            } header: {
                Text("Sites permis")
            } footer: {
                Text("« epfl.ch » ouvre aussi Moodle, Botafogo…")
            }

            SessionFlowSection()

            AdvancedSettingsToggle(isOn: $advanced, summary: "Verrou système, fermer les autres apps, barres flottantes, écrans, gestes du trackpad, Dock.")
            if advanced {
                Section {
                    Toggle("Verrou système (expérimental)", isOn: $settings.studySystemLock)
                        .disabled(!settings.studyBlocking)
                        .help("Éteint aussi Spotlight, ⌘Tab et Mission Control pendant un blocage, et relance Polymestre s'il est tué. Si un blocage se finit mal, « Rétablir les raccourcis du système » rallume tout.")
                    Toggle("Fermer les autres apps", isOn: $settings.studyCloseApps)
                        .disabled(!settings.studyBlocking)
                    Toggle("Poser les apps permises dans le bureau", isOn: $settings.studyPlaceApps)
                        .disabled(!settings.studyBlocking)
                        .help("GoodNotes, Claude… s'ouvrent au centre du bureau, la barre du haut et le volet d'à côté restant visibles. Demande l'Accessibilité (écran de lancement).")
                    Toggle("Autres écrans au calme", isOn: $settings.studyCalmDisplays)
                        .disabled(!settings.studyBlocking)
                    Toggle("Bloquer les gestes du trackpad", isOn: $settings.studyBlockGestures)
                        .disabled(!settings.studyBlocking)
                        .help("Mission Control, changer de bureau, Launchpad : les gestes à trois ou quatre doigts. Le Dock se relance au début et à la fin.")
                    Toggle("Cacher le Dock et la barre des menus", isOn: $settings.studyHideSystemChrome)
                        .disabled(!settings.studyBlocking)
                    Button("Rétablir les raccourcis du système") { SystemLock.release() }
                        .help("Si un blocage s'est mal fini : rallume Spotlight, ⌘Tab, Mission Control, le Dock et la barre des menus.")
                } header: {
                    Text("Blocage")
                } footer: {
                    Text(settings.studyBlocking ? "Sans « Fermer les autres apps », elles sont juste cachées." : "Ces réglages s'appliquent quand « Bloquer le reste » est activé.")
                }
                Section {
                    Toggle("Barres flottantes", isOn: $settings.studyPanels)
                        .help("La barre du haut et la colonne d'outils sont des fenêtres à part, visibles par-dessus GoodNotes et les autres apps permises ; la barre du haut recouvre la barre des menus de macOS. Au prochain mode étude.")
                    Toggle("Volet d'à côté en fenêtre à part", isOn: $settings.studySideWindow)
                        .disabled(!settings.studyPanels)
                        .help("Le volet d'à côté flotte au-dessus des apps permises : cliquer dedans ne ramène pas le bureau devant GoodNotes.")
                    Toggle("Volet d'à côté sur le second écran", isOn: $settings.studySideOnSecondDisplay)
                        .disabled(!settings.studyPanels || !settings.studySideWindow)
                } header: {
                    Text("Fenêtres")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(timer.isLocked)
    }

    private func siteRow(_ site: String) -> some View {
        HStack {
            Image(systemName: "globe").foregroundStyle(.secondary)
            Text(verbatim: site)
            Spacer()
            Button { settings.studySites.removeAll { $0 == site } } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Retirer")
        }
    }

    private func addSite() {
        guard let domain = StudyMode.normalizedDomain(newSite) else {
            siteError = true
            return
        }
        siteError = false
        if !settings.studySites.contains(domain) { settings.studySites.append(domain) }
        newSite = ""
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Permettre")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !settings.studyApps.contains(id) else { continue }
            settings.studyApps.append(id)
        }
    }
}

/// Claude et l'IA : Claude (ton abonnement), ce qui suit une série, la fiche « Écouter » ;
/// le projet Claude détaillé et les fichiers pour Claude dans « Avancé ».
private struct ClaudeSettingsPane: View {
    @Environment(MacSettings.self) private var settings
    @AppStorage("settings.advanced.claude") private var advanced = false
    @State private var editingButtons = false
    @State private var localTick = 0
    @State private var desktopError: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LabeledContent("Claude Code") {
                    if ClaudeChat.executable != nil {
                        Label("Trouvé", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else {
                        Text("absent : le tuteur gratuit répond").foregroundStyle(.secondary)
                    }
                }
                Toggle("Mon projet Claude (dossier, compétences, connecteurs)", isOn: $settings.claudeProject)
            } header: {
                Text("Claude")
            } footer: {
                Text(settings.claudeProject ? "Ta façon de travailler est dans polymestre.json (détails dans « Avancé »)." : "Passe par ton abonnement ; sans Claude Code, le tuteur gratuit prend le relais.")
            }

            Section {
                Toggle("Carnet d'erreurs", isOn: $settings.reviewMistakes)
                Toggle("File de reprise", isOn: $settings.reviewRedo)
                Toggle("Noter les indices de Claude", isOn: $settings.reviewHints)
            } header: {
                Text("Après une série")
            } footer: {
                Text("Claude compare ta copie au corrigé ; rien n'est noté sans ton accord.")
            }

            NotebookLMSection()

            AdvancedSettingsToggle(isOn: $advanced, summary: "Le projet Claude en détail (dossier, polymestre.json, boutons, serveur), les fichiers pour Claude, les paliers de reprise.")
            if advanced {
                Section {
                    LabeledContent("Exécutable") {
                        Text(ClaudeChat.executable.map { $0.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") } ?? String(localized: "introuvable"))
                            .foregroundStyle(.secondary)
                    }
                    if settings.claudeProject {
                        LabeledContent("Dossier") {
                            HStack {
                                Text(settings.claudeProjectFolder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                    .foregroundStyle(.secondary)
                                Button("Choisir…", action: chooseFolder)
                            }
                        }
                        let file = ClaudeProjectSetup.file(settings: settings)
                        LabeledContent("Fichier") {
                            HStack {
                                Text(file == nil ? "aucun" : "polymestre.json").foregroundStyle(.secondary)
                                Button(file == nil ? "Créer" : "Ouvrir") { openProjectFile(exists: file != nil) }
                            }
                        }
                        LabeledContent("Boutons") {
                            HStack {
                                Text(file.map { "\($0.commands.count)" } ?? "aucun").foregroundStyle(.secondary)
                                Button("Modifier…") { editingButtons = true }
                            }
                        }
                        LabeledContent("Compétences") {
                            let skills = ClaudeProjectSetup.linkedSkills(settings: settings)
                            Text(skills.isEmpty ? "aucune" : skills.joined(separator: ", "))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        TextField("Serveur Polymestre (https://…)", text: $settings.claudePolymestreMCP)
                        LabeledContent("Permis") {
                            Text(ClaudeProject.permissionSummary(file: file ?? ClaudeProject.File(),
                                                                 polymestre: settings.claudePolymestreMCP.hasPrefix("https://")))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        if let models = file?.models, models.tutor != nil || models.system != nil {
                            LabeledContent("Modèles") {
                                Text("indices : \(models.tutor ?? String(localized: "défaut")) · système : \(models.system ?? String(localized: "défaut"))").foregroundStyle(.secondary)
                            }
                        }
                        if settings.reviewRedo {
                            let ladder = file?.redo ?? RedoLadder.Config()
                            LabeledContent("Paliers de reprise") {
                                Text(ladder.steps.map(\.label).joined(separator: " → ") + " · \(ladder.maxPerSeries) par série au plus")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Projet Claude")
                } footer: {
                    Text("Les paliers de la reprise se changent dans polymestre.json (« redo »).")
                }

                Section {
                    Toggle("Serveur local des fichiers", isOn: $settings.localFilesServer)
                        .onChange(of: settings.localFilesServer) { _, _ in
                            Task { await MacLocalMCP.shared.reapply(settings: settings); localTick += 1 }
                        }
                    if settings.localFilesServer {
                        LabeledContent("Dossier") {
                            Text(MacLocalMCP.mirrorRoot(settings).path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .foregroundStyle(.secondary)
                        }
                        if let url = MacLocalMCP.shared.url {
                            LabeledContent("Adresse") {
                                HStack {
                                    Text(verbatim: "http://127.0.0.1:\(url.port ?? 0)/…").foregroundStyle(.secondary)
                                    Button("Copier la commande") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("claude mcp add --transport http polymestre-files \(url.absoluteString)", forType: .string)
                                    }
                                }
                            }
                        } else {
                            Text(MacLocalMCP.shared.lastError ?? String(localized: "Démarrage…")).foregroundStyle(Carnet.wrong)
                        }
                    }
                    LabeledContent("App Claude") {
                        HStack {
                            if ClaudeDesktopSetup.isInstalled {
                                Label("Installée", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                            } else if !ClaudeDesktopSetup.claudeAppFound {
                                Text("introuvable").foregroundStyle(Carnet.wrong)
                            }
                            Button(ClaudeDesktopSetup.isInstalled ? "Réinstaller" : "Ajouter à l'app Claude") {
                                Task {
                                    do { try await ClaudeDesktopSetup.install(settings: settings); desktopError = nil }
                                    catch { desktopError = error.localizedDescription }
                                    localTick += 1
                                }
                            }
                        }
                    }
                    if let desktopError { Text(desktopError).foregroundStyle(Carnet.wrong) }
                } header: {
                    Text("Fichiers pour Claude")
                } footer: {
                    Text("Tes PDF et documents de cours, lisibles par Claude (téléchargés à la demande avec ta session Moodle). L'adresse n'écoute que ce Mac.")
                        .id(localTick)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingButtons) {
            ClaudeButtonsEditor(url: ClaudeProjectSetup.fileURL(settings: settings))
        }
    }

    /// Ouvre `polymestre.json` (le crée vide d'abord).
    private func openProjectFile(exists: Bool) {
        let url = ClaudeProjectSetup.fileURL(settings: settings)
        if !exists {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? ClaudeProject.emptyFileTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.claudeProjectFolder = url.path
    }
}
