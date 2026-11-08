import SwiftUI
import EventKit

/// Les fournisseurs de tâches : un toucher pour se connecter.
///
/// Chaque fournisseur est une ligne : son état (« connecté », « non relié »), et
/// **un** bouton — « Se connecter avec Todoist », « Autoriser Rappels ». Plus de
/// jeton à aller chercher et coller : la connexion passe par la page du
/// fournisseur (OAuth) et revient dans l'app. La saisie manuelle reste
/// possible, repliée sous « Configuration manuelle », pour une build sans
/// identifiants OAuth.
struct TaskIntegrationsView: View {
    @Environment(AppContainer.self) private var app

    @State private var working: TaskProvider?
    @State private var message: String?
    @State private var notionDatabases: [NotionDatabase] = []
    @State private var guideProvider: TaskProvider?
    @State private var manualProvider: TaskProvider?

    var body: some View {
        Form {
            Group {
                Section {
                    ForEach(TaskProvider.allCases) { provider in
                        row(provider)
                    }
                } header: {
                    CarnetFormHeader(String(localized: "Tes tâches"))
                }

                if !notionDatabases.isEmpty {
                    Section {
                        ForEach(notionDatabases) { database in
                            Button {
                                app.settings.notionDatabaseID = database.id
                                notionDatabases = []
                                message = String(localized: "Notion : base « \(database.title) » choisie.")
                                Haptics.success()
                            } label: {
                                Label(database.title, systemImage: "tablecells")
                            }
                        }
                    } header: {
                        CarnetFormHeader(String(localized: "Quelle base Notion ?"))
                    }
                }

                if let message {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    }
                }
            }
            .listRowBackground(Carnet.sheet)
        }
        .carnetForm()
        .navigationTitle("Tâches")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $guideProvider) { ProviderGuideView(provider: $0) }
        .sheet(item: $manualProvider) { provider in
            NavigationStack { ManualProviderForm(provider: provider) }
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Une ligne

    @ViewBuilder
    private func row(_ provider: TaskProvider) -> some View {
        let connected = TaskServiceFactory.shared.service(for: provider, settings: app.settings) != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: provider.icon)
                    .font(.body)
                    .foregroundStyle(connected ? Carnet.ink : Carnet.inkTertiary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.label).font(.body).foregroundStyle(Carnet.ink)
                    Text(status(provider, connected: connected))
                        .font(.caption)
                        .foregroundStyle(connected ? Carnet.correct : Carnet.inkSecondary)
                }
                Spacer()
                if working == provider {
                    ProgressView()
                } else {
                    action(provider, connected: connected)
                }
            }
            if !connected, oauth(for: provider) == nil, needsManual(provider) {
                HStack(spacing: 16) {
                    Button("Configurer") { manualProvider = provider }
                    Button("Aide") { guideProvider = provider }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
                .padding(.leading, 38)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if needsManual(provider) {
                Button { manualProvider = provider } label: {
                    Label("Configuration manuelle", systemImage: "key")
                }
            }
            Button { guideProvider = provider } label: {
                Label("Aide", systemImage: "questionmark.circle")
            }
        }
    }

    private func status(_ provider: TaskProvider, connected: Bool) -> String {
        if !connected { return provider.supportsReading ? String(localized: "non relié") : String(localized: "non relié · écriture seule") }
        if provider == .notion, app.settings.notionDatabaseID.isEmpty { return String(localized: "choisis une base") }
        return provider.supportsReading ? String(localized: "connecté") : String(localized: "connecté · écriture seule")
    }

    @ViewBuilder
    private func action(_ provider: TaskProvider, connected: Bool) -> some View {
        if connected {
            Button("Déconnecter", role: .destructive) { disconnect(provider) }
                .font(.subheadline)
                .buttonStyle(.borderless)
        } else {
            switch provider {
            case .reminders:
                Button("Autoriser") { Task { await authorizeReminders() } }
                    .buttonStyle(.carnetPrimary)
            case .things:
                Button("Activer") { app.settings.thingsEnabled = true; Haptics.success() }
                    .buttonStyle(.carnetPrimary)
            default:
                if let oauth = oauth(for: provider) {
                    Button("Se connecter") { Task { await connect(provider, via: oauth) } }
                        .buttonStyle(.carnetPrimary)
                } else if provider == .webhook {
                    Button("Configurer") { manualProvider = provider }
                        .buttonStyle(.carnetSecondary)
                }
            }
        }
    }

    private func oauth(for provider: TaskProvider) -> OAuthProvider? {
        TaskConnector.oauth(for: provider)
    }

    private func needsManual(_ provider: TaskProvider) -> Bool {
        ![.reminders, .things].contains(provider)
    }

    // MARK: Actions

    private func connect(_ provider: TaskProvider, via oauth: OAuthProvider) async {
        working = provider
        defer { working = nil }
        let outcome = await TaskConnector.connect(provider, via: oauth, settings: app.settings)
        message = outcome.message
        notionDatabases = outcome.notionDatabases
    }

    private func authorizeReminders() async {
        working = .reminders
        defer { working = nil }
        message = await TaskConnector.authorizeReminders(settings: app.settings)
    }

    private func disconnect(_ provider: TaskProvider) {
        let settings = app.settings
        switch provider {
        case .reminders:
            message = String(localized: "Pour retirer l'accès aux Rappels : Réglages › Confidentialité › Rappels.")
            return
        case .todoist: settings.todoistToken = ""
        case .things: settings.thingsEnabled = false
        case .notion: settings.notionToken = ""; settings.notionDatabaseID = ""
        case .webhook: settings.webhookURL = ""
        case .googleTasks: settings.googleRefreshToken = ""; settings.googleClientSecret = ""
        case .tickTick: settings.tickTickToken = ""
        }
        Haptics.removed()
    }
}

/// Une base Notion où créer les tâches.
struct NotionDatabase: Identifiable {
    let id: String
    let title: String

    /// Les bases partagées avec l'intégration lors de la connexion.
    static func list(token: String) async -> [NotionDatabase] {
        var request = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["filter": ["property": "object", "value": "database"]])
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let title = ((item["title"] as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined())
            return NotionDatabase(id: id, title: (title?.isEmpty ?? true) ? String(localized: "Sans titre") : title!)
        }
    }
}

/// La saisie manuelle d'un fournisseur (jeton, adresse), pour une build sans
/// OAuth ou un usage avancé.
private struct ManualProviderForm: View {
    let provider: TaskProvider
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                switch provider {
                case .todoist:
                    SecureField("Jeton API (Todoist › Réglages › Intégrations)", text: $settings.todoistToken)
                case .notion:
                    SecureField("Jeton d'intégration", text: $settings.notionToken)
                    TextField("ID de la base de données", text: $settings.notionDatabaseID)
                case .webhook:
                    TextField("https://…", text: $settings.webhookURL).keyboardType(.URL)
                case .googleTasks:
                    TextField("Identifiant client OAuth", text: $settings.googleClientID)
                    SecureField("Secret client (client Web uniquement)", text: $settings.googleClientSecret)
                    SecureField("Refresh token", text: $settings.googleRefreshToken)
                case .tickTick:
                    SecureField("Jeton d'accès TickTick", text: $settings.tickTickToken)
                case .reminders, .things:
                    EmptyView()
                }
            } footer: {
                Text(provider.helpText)
            }
            .listRowBackground(Carnet.sheet)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        .carnetForm()
        .navigationTitle(provider.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
        }
    }
}


/// Relier un fournisseur de tâches, d'où qu'on le fasse : l'écran Tâches et
/// l'accueil passent par ici, pour qu'une connexion faite à l'accueil soit
/// exactement celle des réglages.
@MainActor
enum TaskConnector {

    struct Outcome {
        var message: String?
        var notionDatabases: [NotionDatabase] = []
        var connected = false
    }

    /// Le fournisseur OAuth d'un service de tâches, s'il est disponible dans
    /// cette build (identifiant client compilé).
    static func oauth(for provider: TaskProvider) -> OAuthProvider? {
        let mapped: OAuthProvider? = {
            switch provider {
            case .todoist: return .todoist
            case .googleTasks: return .google
            case .tickTick: return .tickTick
            case .notion: return .notion
            default: return nil
            }
        }()
        return mapped.flatMap { OAuthConfig.isAvailable($0) ? $0 : nil }
    }

    static func isConnected(_ provider: TaskProvider, settings: SettingsStore) -> Bool {
        // Rappels existe toujours ; il n'est relié qu'une fois l'accès accordé.
        if provider == .reminders { return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
        return TaskServiceFactory.shared.service(for: provider, settings: settings) != nil
    }

    static func connect(_ provider: TaskProvider, via oauth: OAuthProvider, settings: SettingsStore) async -> Outcome {
        do {
            let tokens = try await OAuthSignIn.shared.signIn(oauth)
            var outcome = Outcome(connected: true)
            switch provider {
            case .todoist: settings.todoistToken = tokens.accessToken
            case .tickTick: settings.tickTickToken = tokens.accessToken
            case .googleTasks:
                settings.googleClientID = OAuthConfig.googleClientID
                settings.googleClientSecret = ""
                settings.googleRefreshToken = tokens.refreshToken ?? ""
            case .notion:
                settings.notionToken = tokens.accessToken
                let databases = await NotionDatabase.list(token: tokens.accessToken)
                if databases.count == 1, let only = databases.first {
                    settings.notionDatabaseID = only.id
                } else {
                    outcome.notionDatabases = databases
                }
            default: break
            }
            Haptics.success()
            outcome.message = String(localized: "\(provider.label) connecté.")
            return outcome
        } catch OAuthError.cancelled {
            return Outcome()
        } catch {
            return Outcome(message: "\(provider.label) : \(error.localizedDescription)")
        }
    }

    static func authorizeReminders(settings: SettingsStore) async -> String {
        let service = TaskServiceFactory.shared.service(for: .reminders, settings: settings)
        let granted = await service?.requestAccess() ?? false
        if granted { Haptics.success() }
        return granted ? String(localized: "Rappels autorisé.") : String(localized: "Accès refusé : autorise Polymestre dans Réglages › Rappels.")
    }
}
