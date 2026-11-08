import SwiftUI

/// Le journal de l'app : ce qui a échoué, quand, et pourquoi.
///
/// Sans lui, un défaut signalé n'a **rien** à consulter. La seule réponse possible
/// était « réessaie et dis-moi ce qui se passe ».
struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var level: LogEntry.Level?
    @State private var liveCount = 0
    /// Les activités d'examen, comptées à part : elles vivent en parallèle du chrono.
    @State private var examCount = 0

    private var liveIcon: String {
        guard StudyActivityController.isEnabledBySystem else { return "xmark.circle.fill" }
        return liveCount > 0 ? "checkmark.circle.fill" : "questionmark.circle"
    }

    private var liveTint: Color {
        guard StudyActivityController.isEnabledBySystem else { return .red.accessibleInk }
        return liveCount > 0 ? .green.accessibleMark : .secondary
    }

    private var liveTitle: String {
        guard StudyActivityController.isEnabledBySystem else {
            return String(localized: "Les activités en direct sont refusées pour Polymestre (Réglages du système).")
        }
        let total = liveCount + examCount
        if total == 0 { return String(localized: "Aucune activité en cours — l'îlot est vide, c'est normal.") }
        var text = String(localized: "\(Plural.count(total, "\(total) activité", "\(total) activités")) en cours")
        if examCount > 0 { text += String(localized: " (dont \(examCount) d'examen)") }
        return text + "."
    }
    @State private var showingClear = false

    private var shown: [LogEntry] { LogBuffer.filtered(entries, level: level) }

    var body: some View {
        List {
            Section {
                Picker("Niveau", selection: $level) {
                    Text("Tout").tag(LogEntry.Level?.none)
                    ForEach(LogEntry.Level.allCases, id: \.self) { value in
                        Text(value.label.capitalized).tag(LogEntry.Level?.some(value))
                    }
                }
                .pickerStyle(.segmented)
            }

            if shown.isEmpty {
                Section {
                    Text(entries.isEmpty
                         ? "Journal vide. Les erreurs de synchronisation, d'import et d'Anki viendront ici."
                         : "Aucune ligne à ce niveau.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section(Plural.count(shown.count, "\(shown.count) ligne", "\(shown.count) lignes")) {
                    ForEach(shown) { entry in
                        row(entry)
                    }
                }
            }

            Section {
                HStack(spacing: Layout.control) {
                    Image(systemName: liveIcon)
                        .foregroundStyle(liveTint)
                    VStack(alignment: .leading, spacing: Layout.tight) {
                        Text(liveTitle)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = StudyActivityController.lastError {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                Button {
                    StudyActivityController.startTest()
                    liveCount = StudyActivityController.liveCount
                    Haptics.tap()
                } label: {
                    Label("Lancer une activité d'essai", systemImage: "play.circle")
                }
                // L'activité d'examen se déclenche par le **temps** : sans ce
                // bouton, la vérifier demanderait d'attendre la veille d'une vraie
                // épreuve. C'est la même raison que pour l'essai du chrono.
                Button {
                    ExamActivityController.startTest()
                    examCount = ExamActivityController.liveCount
                    Haptics.tap()
                } label: {
                    Label("Essayer le jour d'examen", systemImage: "graduationcap")
                }
                Button(role: .destructive) {
                    StudyActivityController.end()
                    ExamActivityController.end()
                    liveCount = StudyActivityController.liveCount
                    examCount = ExamActivityController.liveCount
                    Haptics.removed()
                } label: {
                    Label("Fermer toute activité", systemImage: "stop.circle")
                }
                .disabled(liveCount == 0 && examCount == 0)
            } header: {
                Text("Îlot et écran verrouillé")
            } footer: {
                Text("« Activité d'essai » doit faire apparaître un chrono dans l'îlot et sur l'écran verrouillé en quelques secondes. « Jour d'examen » y met un compte à rebours. Si le compteur d'activités reste à zéro, le système refuse l'activité — regarde alors Réglages › Polymestre › Activités en direct.")
            }

            Section {
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Partager le journal", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    showingClear = true
                } label: {
                    Label("Vider le journal", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }
        }
        .carnetForm()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Vider le journal ?", isPresented: $showingClear, titleVisibility: .visible) {
            Button("Vider", role: .destructive) {
                AppLog.clear()
                entries = []
            }
            Button("Annuler", role: .cancel) {}
        }
        .onAppear {
            entries = AppLog.load()
            liveCount = StudyActivityController.liveCount
            examCount = ExamActivityController.liveCount
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: Layout.control) {
            Image(systemName: entry.level.icon)
                .font(.footnote)
                .foregroundStyle(tint(entry.level))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Layout.snug) {
                    Text(DateUtils.shortDay.string(from: entry.date))
                    Text(DateUtils.time.string(from: entry.date))
                    Text("·")
                    Text(entry.category)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let detail = entry.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.level.label), \(entry.category), \(entry.message)")
    }

    private func tint(_ level: LogEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange.accessibleInk
        case .error: return .red.accessibleInk
        }
    }

    /// Écrit le journal dans un fichier temporaire pour le partager.
    private var exportURL: URL? {
        guard !entries.isEmpty else { return nil }
        let text = LogBuffer.text(entries)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("polymestre-journal.txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }
}
