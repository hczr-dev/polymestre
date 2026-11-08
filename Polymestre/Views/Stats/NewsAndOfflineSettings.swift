import SwiftUI
import SwiftData

/// Réglages des nouveautés Moodle : quoi annoncer, pour quels cours, et
/// jamais la nuit. Placés sur la page « Notifications », sous les rappels.
struct MoodleNewsSettingsSections: View {
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var allCourses: [Course]
    @State private var checking = false
    @State private var result: String?
    @State private var denied = false

    private var linkedCourses: [Course] {
        allCourses.filter { $0.isTracked && MoodleCourseMatcher.linkedID(in: $0.contentSources) != nil }
    }

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("Nouveautés Moodle", isOn: $settings.moodleNewsEnabled)
                .onChange(of: settings.moodleNewsEnabled) { _, on in
                    MoodleWatcher.schedule(settings: settings)
                    if on { askPermission() }
                }
            if settings.moodleNewsEnabled {
                ForEach(MoodleNews.Kind.allCases) { kind in
                    Toggle(isOn: Binding(get: { settings.moodleNewsKinds.contains(kind) },
                                         set: { on in
                                             var kinds = settings.moodleNewsKinds
                                             if on { kinds.insert(kind) } else { kinds.remove(kind) }
                                             settings.moodleNewsKinds = kinds
                                         })) {
                        Label(kind.label, systemImage: kind.icon)
                    }
                }
                Button {
                    Task { await checkNow() }
                } label: {
                    HStack {
                        Label("Vérifier maintenant", systemImage: "arrow.clockwise")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(checking)
            }
        } header: {
            CarnetFormHeader(String(localized: "Nouveautés des cours"))
        } footer: {
            if settings.moodleNewsEnabled {
                Text(statusLine)
            }
        }

        if settings.moodleNewsEnabled {
            Section {
                Toggle("Heures calmes", isOn: $settings.quietHoursEnabled)
                if settings.quietHoursEnabled {
                    Picker("De", selection: $settings.quietHoursStart) {
                        ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
                    }
                    Picker("À", selection: $settings.quietHoursEnd) {
                        ForEach(0..<24, id: \.self) { Text("\($0) h").tag($0) }
                    }
                }
            } footer: {
                if settings.quietHoursEnabled {
                    Text("Une nouveauté trouvée la nuit attend \(settings.quietHoursEnd) h.")
                }
            }

            if linkedCourses.count > 1 {
                Section {
                    ForEach(linkedCourses) { course in
                        Toggle(isOn: Binding(get: { !settings.moodleNewsMuted.contains(course.id) },
                                             set: { on in
                                                 var muted = settings.moodleNewsMuted
                                                 if on { muted.remove(course.id) } else { muted.insert(course.id) }
                                                 settings.moodleNewsMuted = muted
                                             })) {
                            HStack(spacing: 10) {
                                Circle().fill(Color(hex: course.colorHex)).frame(width: 8, height: 8)
                                Text(course.displayCode)
                                Text(course.name).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                            }
                        }
                    }
                } header: {
                    CarnetFormHeader(String(localized: "Cours"))
                }
            }
        }
    }

    /// « Dernier relevé il y a 2 h », ou ce qui bloque.
    private var statusLine: String {
        if denied { return String(localized: "Notifications refusées : active-les dans Réglages › Polymestre.") }
        if let result { return result }
        if linkedCourses.isEmpty { return String(localized: "Aucun cours relié à Moodle pour l'instant.") }
        switch MoodleWatcher.lastStatus {
        case .signedOut?: return String(localized: "Moodle demande de te reconnecter : ouvre « Importer du contenu ».")
        case .offline?: return String(localized: "Dernier relevé impossible : pas de réseau.")
        default:
            guard let last = MoodleWatcher.lastCheck else {
                return String(localized: "Relevé toutes les deux heures environ, quand iOS le permet.")
            }
            let ago = RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date())
            return String(localized: "Dernier relevé \(ago). iOS choisit le moment, au mieux toutes les deux heures.")
        }
    }

    private func askPermission() {
        Task {
            denied = !(await app.notifications.requestAuthorization())
        }
    }

    private func checkNow() async {
        checking = true
        result = nil
        defer { checking = false }
        // Les cookies de la session ouverte dans l'app, pas ceux du dernier
        // passage en arrière-plan.
        await CookieKeeper.save()
        let report = await MoodleWatcher.check(container: app.modelContainer, settings: app.settings)
        switch report.status {
        case .signedOut: result = String(localized: "Moodle demande de te reconnecter : ouvre « Importer du contenu ».")
        case .offline: result = String(localized: "Pas de réseau.")
        case .ok:
            let count = report.news.reduce(0) { $0 + $1.items.count }
            result = count == 0
                ? String(localized: "Rien de neuf dans \(report.courses) cours.")
                : String(localized: "\(Plural.count(count, "\(count) nouveauté", "\(count) nouveautés")) : la notification arrive.")
        }
        Haptics.tap()
    }
}

/// Les énoncés et corrigés gardés sur l'iPhone.
struct OfflineSettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    private var library: OfflineLibrary { .shared }

    private static let limits = [200, 500, 1000, 2000]

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Group {
                Section {
                    Toggle("Garder les énoncés", isOn: $settings.offlineEnabled)
                    if settings.offlineEnabled {
                        Toggle("Corrigés aussi", isOn: $settings.offlineSolutions)
                        Toggle("En Wi-Fi seulement", isOn: $settings.offlineWifiOnly)
                        Picker("Place maximale", selection: $settings.offlineLimitMB) {
                            ForEach(Self.limits, id: \.self) { limit in
                                Text(OfflinePlan.label(bytes: limit * 1_000_000)).tag(limit)
                            }
                        }
                    }
                } footer: {
                    Text(settings.offlineEnabled
                         ? "La semaine en cours d'abord, puis les précédentes, jusqu'à la place choisie."
                         : "Les séries s'ouvrent alors sans réseau.")
                }

                if settings.offlineEnabled || library.fileCount > 0 {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Utilisé")
                                Spacer()
                                Text("\(OfflinePlan.label(bytes: library.usedBytes)) · \(Plural.count(library.fileCount, "\(library.fileCount) document", "\(library.fileCount) documents"))")
                                    .foregroundStyle(Carnet.inkSecondary)
                                    .contentTransition(.numericText())
                            }
                            ProgressView(value: Double(min(library.usedBytes, settings.offlineLimitMB * 1_000_000)),
                                         total: Double(settings.offlineLimitMB * 1_000_000))
                                .tint(Theme.accent)
                        }
                        .animation(Motion.snappy, value: library.usedBytes)
                        if settings.offlineEnabled {
                            Button {
                                Task { await library.sync(context: context, settings: settings) }
                            } label: {
                                HStack {
                                    Label(library.isSyncing ? "Téléchargement…" : "Télécharger maintenant",
                                          systemImage: "arrow.down.circle")
                                    Spacer()
                                    if library.isSyncing { ProgressView() }
                                }
                            }
                            .disabled(library.isSyncing)
                        }
                        Button(role: .destructive) {
                            library.removeAll()
                            Haptics.tap()
                        } label: {
                            Label("Supprimer les fichiers", systemImage: "trash")
                        }
                        .disabled(library.fileCount == 0 || library.isSyncing)
                    } footer: {
                        if let reason = library.waitingReason, settings.offlineEnabled { Text("En pause : \(reason).") }
                    }
                }
            }
            .listRowBackground(Carnet.sheet)
        }
        .carnetForm()
        .navigationTitle("Hors ligne")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.offlineEnabled) { _, on in
            if on {
                Task { await library.sync(context: context, settings: settings) }
            } else {
                library.removeAll()
            }
        }
        // Moins de place ou plus de corrigés : la liste se refait (et ce qui
        // ne tient plus s'en va).
        .onChange(of: settings.offlineLimitMB) { _, _ in Task { await library.sync(context: context, settings: settings) } }
        .onChange(of: settings.offlineSolutions) { _, _ in Task { await library.sync(context: context, settings: settings) } }
        .onChange(of: settings.offlineWifiOnly) { _, _ in Task { await library.sync(context: context, settings: settings) } }
    }
}
