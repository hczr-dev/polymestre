import SwiftUI
import SwiftData
import UIKit

/// « Assistant IA » : relier Claude, ChatGPT ou tout client MCP à ses études.
///
/// L'ancien serveur MCP lisait un fichier exporté à la main puis copié sur un
/// Mac : un instantané figé, en lecture seule, qu'aucun assistant du téléphone
/// ne pouvait atteindre. Ici, une adresse suffit. L'assistant lit l'état à jour
/// et **demande** des modifications que l'app applique elle-même.
struct AssistantSettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context

    @State private var syncing = false
    @State private var copied = false
    @State private var confirmingDisconnect = false
    @State private var confirmingRotate = false

    private var url: URL? { AssistantSync.serverURL(token: app.settings.assistantToken) }

    var body: some View {
        Form {
            if !SupabaseConfig.isConfigured {
                Section {
                    Label("Cette version de l'app n'a pas de serveur configuré.", systemImage: "icloud.slash")
                        .foregroundStyle(.secondary)
                }
            } else if let url {
                connectedSections(url)
            } else {
                Section {
                    VStack(alignment: .leading, spacing: Layout.control) {
                        Text("« Qu'est-ce qu'il me reste en Analyse cette semaine ? » — ton assistant le sait, et note ce que tu lui dis.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await connect() }
                        } label: {
                            HStack {
                                if syncing { ProgressView().tint(.white) }
                                Text("Relier un assistant")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Layout.tight)
                        }
                        .buttonStyle(.carnetPrimary)
                        .disabled(syncing)
                    }
                    .padding(.vertical, Layout.tight)
                } footer: {
                    Text("Claude, ChatGPT ou tout client MCP. Tes cours et ton avancement sont copiés sur le serveur pour lui ; tu peux tout effacer.")
                }
            }

            Section {
                capability("Lire", String(localized: "avancement, séries, évaluations, temps — et, si tu l'actives, fichiers et notes"))
                capability("Noter", String(localized: "exercices faits, corrections, questions"))
                capability(String(localized: "Ajouter"), String(localized: "séries, évaluations, sessions, résumés"))
            } header: {
                Text("Ce que l'assistant peut faire")
            }

            if !AssistantSync.lastApplied.isEmpty {
                Section("Dernières modifications de l'assistant") {
                    ForEach(Array(AssistantSync.lastApplied.enumerated()), id: \.offset) { _, result in
                        Label(result.message, systemImage: result.status == "applied" ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(result.status == "applied" ? Color.primary : Color.orange.accessibleInk)
                    }
                }
            }
        }
        .carnetForm()
        .navigationTitle("Assistant IA")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Déconnecter l'assistant ?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Déconnecter et tout effacer du serveur", role: .destructive) {
                Task { await AssistantSync.disconnect(settings: app.settings) }
            }
        } message: {
            Text("L'adresse cessera de fonctionner, et la copie de tes données sur le serveur sera effacée. Tes données dans l'app ne changent pas.")
        }
        .confirmationDialog("Changer d'adresse ?", isPresented: $confirmingRotate, titleVisibility: .visible) {
            Button("Changer l'adresse", role: .destructive) {
                Task {
                    await AssistantSync.disconnect(settings: app.settings)
                    await connect()
                }
            }
        } message: {
            Text("L'ancienne adresse cessera de fonctionner : il faudra coller la nouvelle dans ton assistant.")
        }
    }

    // MARK: Relié

    @ViewBuilder
    private func connectedSections(_ url: URL) -> some View {
        Section {
            Text(url.absoluteString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    copied = true
                    Haptics.success()
                    Task { try? await Task.sleep(for: .seconds(2)); copied = false }
                } label: {
                    Label(copied ? "Copiée" : "Copier l'adresse", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.carnetPrimary)
                Spacer()
                ShareLink(item: url) {
                    Label("Partager", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Text(syncLine).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        syncing = true
                        await AssistantSync.sync(context: context, settings: app.settings)
                        syncing = false
                    }
                } label: {
                    if syncing { ProgressView() } else { Text("Synchroniser") }
                }
                .font(.footnote.weight(.semibold))
                .disabled(syncing)
            }
        } header: {
            Text("Adresse du serveur MCP")
        } footer: {
            Text("Cette adresse est un **mot de passe** : qui l'a peut lire tes études et y noter des choses. Ne la colle que dans ton propre assistant.")
        }

        Section {
            Toggle("Fichiers et notes", isOn: Bindable(app.settings).assistantFiles)
        } footer: {
            Text("L'assistant lit aussi tes énoncés, corrigés, fichiers, notes et fiche déjà sur l'iPhone.")
        }

        Section("Brancher ton assistant") {
            instruction("Claude (app, web, Desktop)",
                        String(localized: "Réglages › Connecteurs › Ajouter un connecteur personnalisé. Nom : Polymestre. Colle l'adresse."))
            instruction("ChatGPT",
                        String(localized: "Réglages › Applications et connecteurs › Avancé : active le mode développeur, puis Créer. Colle l'adresse, sans authentification."))
            VStack(alignment: .leading, spacing: Layout.tight) {
                Text("Claude Code").font(.subheadline.weight(.semibold))
                let command = "claude mcp add --transport http polymestre \(url.absoluteString)"
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Button("Copier la commande") {
                    UIPasteboard.general.string = command
                    Haptics.success()
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(.vertical, Layout.micro)
        }

        Section {
            Button("Changer d'adresse…") { confirmingRotate = true }
            Button("Déconnecter l'assistant…", role: .destructive) { confirmingDisconnect = true }
        }
    }

    private var syncLine: String {
        if let error = AssistantSync.lastError { return String(localized: "Échec : \(error)") }
        guard let last = app.settings.assistantLastSync else { return String(localized: "Jamais synchronisé") }
        return String(localized: "Synchronisé \(DateUtils.relativeLabel(last).lowercased()) à \(DateUtils.time.string(from: last))")
    }

    private func capability(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.micro) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, Layout.micro)
    }

    private func instruction(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Layout.micro) {
            Text(ui: title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Layout.micro)
    }

    private func connect() async {
        syncing = true
        defer { syncing = false }
        app.settings.assistantToken = AssistantSync.makeToken()
        await AssistantSync.sync(context: context, settings: app.settings)
        Haptics.success()
    }
}
