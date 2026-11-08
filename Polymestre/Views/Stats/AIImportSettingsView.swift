import SwiftUI

/// Réglages de l'analyse des PDF par un modèle de langage.
///
/// **Le modèle servi d'abord, celui de l'appareil ensuite.**
///
/// L'ordre inverse semblait prudent — gratuit, privé, hors ligne — mais il plaçait
/// un modèle de quelques milliards de paramètres devant un modèle servi, sur une
/// tâche qu'il rate souvent. Le modèle embarqué reste le filet : hors ligne, ou
/// quand la fonction n'est pas déployée.
struct AIImportSettingsView: View {
    @Environment(AppContainer.self) private var app

    /// État réel de la fonction partagée, **constaté** et non supposé.
    ///
    /// L'écran affichait « Disponible » dès que la build portait un projet
    /// Supabase — alors que la fonction `extract-series` peut très bien n'avoir
    /// jamais été déployée. C'était le cas, et c'est ce qui faisait croire à un
    /// import IA « mauvais » plutôt qu'absent.
    private enum SharedStatus: Equatable {
        case unknown
        case checking
        case ready
        /// La fonction n'existe pas : il faut la déployer.
        case notDeployed(String)
        /// La fonction répond, mais l'analyse échoue : clé, modèle ou quota.
        case failing(String)
        case unconfigured(String)
    }

    @State private var sharedStatus: SharedStatus = .unknown
    @State private var onDeviceMessage: String?
    @State private var isTestingOnDevice = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Lire les énoncés avec l'IA", isOn: $settings.aiExtractionEnabled)
            } footer: {
                Text("Tu relis toujours avant que quoi que ce soit ne soit créé.")
            }

            if settings.aiExtractionEnabled {
                Section(header: CarnetFormHeader("Moteurs")) {
                    status(title: String(localized: "En ligne"), icon: sharedIcon, tint: sharedTint,
                           value: sharedTitle, detail: sharedDetail, busy: sharedStatus == .checking)
                    if SeriesAIExtractor.isSharedAvailable, sharedStatus != .ready, sharedStatus != .checking {
                        Button("Réessayer") { Task { await checkShared() } }
                    }
                    status(title: String(localized: "Sur l'iPhone"),
                           icon: SeriesAIExtractor.isOnDeviceAvailable ? "checkmark.circle.fill" : "minus.circle",
                           tint: SeriesAIExtractor.isOnDeviceAvailable ? Color.green.accessibleMark : .secondary,
                           value: SeriesAIExtractor.isOnDeviceAvailable ? String(localized: "en secours, hors ligne") : "indisponible",
                           detail: onDeviceMessage, busy: isTestingOnDevice)
                    if SeriesAIExtractor.isOnDeviceAvailable {
                        Button("Tester") { Task { await checkOnDevice() } }
                            .disabled(isTestingOnDevice)
                    }
                }
            }
        }
        .carnetForm()
        .navigationTitle("IA de lecture")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // On constate au lieu d'affirmer : l'écran ne doit pas dire
            // « disponible » sans avoir posé la question au serveur.
            if SeriesAIExtractor.isSharedAvailable, sharedStatus == .unknown {
                await checkShared()
            }
        }
    }

    private func status(title: String, icon: String, tint: Color, value: String, detail: String?, busy: Bool) -> some View {
        VStack(alignment: .leading, spacing: Layout.tight) {
            HStack(spacing: Layout.control) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(ui: title)
                Spacer(minLength: Layout.inline)
                if busy { ProgressView() } else {
                    Text(value).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Fonction partagée

    private var sharedIcon: String {
        switch sharedStatus {
        case .ready: return "checkmark.circle.fill"
        case .checking: return "sparkles"
        // Déployée mais en échec : la fonction existe, c'est la clé ou le modèle
        // qui coince — une nuance que l'icône dit aussi.
        case .failing: return "exclamationmark.arrow.triangle.2.circlepath"
        case .notDeployed, .unconfigured: return "exclamationmark.triangle.fill"
        case .unknown: return SeriesAIExtractor.isSharedAvailable ? "questionmark.circle" : "minus.circle"
        }
    }

    private var sharedTint: Color {
        switch sharedStatus {
        case .ready: return .green.accessibleMark
        case .notDeployed: return .orange.accessibleInk
        case .failing: return .orange.accessibleInk
        case .unconfigured: return .secondary
        default: return SeriesAIExtractor.isSharedAvailable ? .secondary : .secondary
        }
    }

    /// Le détail technique, quand il y en a un.
    private var sharedDetail: String? {
        switch sharedStatus {
        case .notDeployed(let detail), .failing(let detail), .unconfigured(let detail):
            return detail
        case .unknown, .checking, .ready:
            return nil
        }
    }

    private var sharedTitle: String {
        guard SeriesAIExtractor.isSharedAvailable else { return "indisponible" }
        switch sharedStatus {
        case .ready: return String(localized: "prêt")
        case .checking: return String(localized: "vérification…")
        case .notDeployed, .failing, .unconfigured: return String(localized: "en panne")
        case .unknown: return "—"
        }
    }

    private func checkOnDevice() async {
        isTestingOnDevice = true
        onDeviceMessage = nil
        onDeviceMessage = await SeriesAIExtractor.diagnoseOnDevice()
        isTestingOnDevice = false
    }

    private func checkShared() async {
        sharedStatus = .checking
        switch await SeriesAIExtractor.diagnoseShared() {
        case .ready:
            sharedStatus = .ready
        case .notDeployed(let status):
            sharedStatus = .notDeployed(String(localized: "HTTP \(status) — la fonction n'existe pas sur le projet."))
        case .failing(let detail):
            sharedStatus = .failing(detail)
        case .unconfigured:
            sharedStatus = .unconfigured(String(localized: "Aucun projet Supabase n'est compilé dans cette version."))
        }
    }
}
