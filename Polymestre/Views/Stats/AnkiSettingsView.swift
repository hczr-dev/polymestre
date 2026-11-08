import SwiftUI
import SwiftData

/// Anki, par AnkiWeb : sans ordinateur.
///
/// On se connecte avec son compte AnkiWeb, une fois. L'app garde une copie de
/// la collection (pour les paquets, les types de notes et les statistiques) et
/// y **ajoute** des cartes par une synchronisation normale — comme AnkiMobile.
/// Elle n'envoie jamais la collection entière : rien ne peut écraser ce qui
/// est sur AnkiWeb.
struct AnkiSettingsView: View {
    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Course.code) private var courses: [Course]

    @State private var email = ""
    @State private var password = ""
    @State private var collection: AnkiCollection?
    @State private var refreshToken = UUID()
    @State private var redownloading = false

    private var sync: AnkiWebSync { AnkiWebSync.shared }
    private var tracked: [Course] { courses.filter(\.isTracked) }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Group {
                if sync.isSignedIn {
                    accountSection
                    if let collection {
                        decksSection(collection)
                        notetypeSection(collection)
                    }
                    automationSection
                    pendingSection
                } else {
                    signInSection
                }
                statusSection
            }
            .listRowBackground(Carnet.sheet)
        }
        .carnetForm()
        .navigationTitle("Anki")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshToken) { reload() }
        .refreshable { await refresh() }
    }

    // MARK: Connexion

    private var signInSection: some View {
        Section {
            TextField("Adresse e-mail AnkiWeb", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Mot de passe", text: $password)
                .textContentType(.password)
            Button {
                Task {
                    if await sync.signIn(username: email, password: password) {
                        password = ""
                        refreshToken = UUID()
                        Haptics.success()
                    }
                }
            } label: {
                HStack {
                    Text("Se connecter à AnkiWeb")
                    if sync.isWorking { Spacer(); ProgressView() }
                }
            }
            .disabled(email.isEmpty || password.isEmpty || sync.isWorking)
        } header: {
            CarnetFormHeader("AnkiWeb")
        }
    }

    private var accountSection: some View {
        Section {
            HStack {
                Label(sync.username, systemImage: "person.crop.circle")
                Spacer()
                if sync.isWorking { ProgressView() }
            }
            if let date = sync.lastRefresh {
                LabeledContent("Dernière lecture", value: DateUtils.relativeLabel(date) + " " + DateUtils.time.string(from: date))
            }
            Button {
                Task { await refresh() }
            } label: {
                Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.isWorking)
            Button {
                redownloading = true
            } label: {
                Label("Retélécharger la collection", systemImage: "arrow.down.circle")
            }
            .disabled(sync.isWorking)
            .confirmationDialog("Retélécharger la collection ?", isPresented: $redownloading, titleVisibility: .visible) {
                Button(sync.unsyncedCount > 0 ? "Retélécharger et perdre \(sync.unsyncedCount) modification(s)" : "Retélécharger",
                       role: sync.unsyncedCount > 0 ? .destructive : nil) {
                    Task { try? await sync.refreshMirror(force: true); reload(); refreshToken = UUID() }
                }
            } message: {
                Text("Seulement si la synchronisation le demande.")
            }
            Button(role: .destructive) {
                sync.signOut()
                collection = nil
            } label: {
                Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } header: {
            CarnetFormHeader("AnkiWeb")
        }
    }

    // MARK: Paquets

    private func decksSection(_ collection: AnkiCollection) -> some View {
        let decks = collection.decks.filter { !$0.isFiltered }
        return Section {
            ForEach(tracked) { course in
                let current = sync.deck(for: course, in: collection)
                let stats = current.map { collection.stats(deck: $0) }
                VStack(alignment: .leading, spacing: 6) {
                    Picker(selection: Binding(
                        get: { current?.id ?? 0 },
                        set: { value in
                            var map = sync.deckMap
                            map[course.code] = value
                            sync.deckMap = map
                            refreshToken = UUID()
                        })) {
                        Text("Aucun").tag(Int64(0))
                        ForEach(decks) { deck in Text(deck.name).tag(deck.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Carnet.tint(course.colorHex)).frame(width: 8, height: 8)
                            Text(course.displayCode).foregroundStyle(Carnet.ink)
                        }
                    }
                    if let stats {
                        Text(statsLine(stats))
                            .font(.caption)
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                }
            }
        } header: {
            CarnetFormHeader(String(localized: "Un paquet par cours"))
        }
    }

    private func statsLine(_ stats: AnkiCollection.DeckStats) -> String {
        var parts = [String(localized: "\(stats.due) à revoir"), "\(stats.new) nouvelles"]
        if stats.reviewedToday > 0 { parts.append(String(localized: "\(stats.reviewedToday) révisées aujourd'hui")) }
        if let retention = stats.retention { parts.append(String(localized: "rétention \(Int((retention * 100).rounded())) %")) }
        return parts.joined(separator: " · ")
    }

    private func notetypeSection(_ collection: AnkiCollection) -> some View {
        let types = collection.notetypes.filter { !$0.isCloze && $0.fields.count >= 2 }
        return Section {
            Picker("Type de note", selection: Binding(
                get: { sync.basicNotetype(in: collection)?.id ?? 0 },
                set: { sync.notetypeID = $0; refreshToken = UUID() })) {
                ForEach(types) { type in Text(type.name).tag(type.id) }
            }
        }
    }

    // MARK: Automatique et file

    private var automationSection: some View {
        Section {
            Toggle(isOn: Binding(get: { sync.autoRedo }, set: { sync.autoRedo = $0 })) {
                Label("Exercices faux → carte", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("Un exercice faux devient une carte.")
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        let _ = refreshToken
        let unsynced = sync.unsyncedCount
        if unsynced > 0 || !sync.pending.isEmpty {
            Section {
                ForEach(sync.pending) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.origin).font(.subheadline).foregroundStyle(Carnet.ink)
                        Text(note.fields.first.map { String($0.prefix(80)) } ?? "")
                            .font(.caption)
                            .foregroundStyle(Carnet.inkSecondary)
                            .lineLimit(1)
                    }
                    .swipeActions {
                        Button("Retirer", role: .destructive) { sync.discard(note) }
                    }
                }
                if unsynced > sync.pending.count {
                    Label("\(Plural.count(unsynced - sync.pending.count, "\(unsynced - sync.pending.count) modification faite", "\(unsynced - sync.pending.count) modifications faites")) ici (révisions, cartes)",
                          systemImage: "tray.and.arrow.up")
                        .font(.subheadline)
                }
                Button {
                    Task { await sync.pushPending(); refreshToken = UUID() }
                } label: {
                    Label("Envoyer à AnkiWeb", systemImage: "paperplane")
                }
                .disabled(sync.isWorking)
            } header: {
                CarnetFormHeader(String(localized: "En attente d'envoi"))
            }
        }
    }


    @ViewBuilder
    private var statusSection: some View {
        if let error = sync.lastError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Carnet.wrong)
            }
        } else if !sync.status.isEmpty {
            Section {
                Text(sync.status).font(.footnote).foregroundStyle(Carnet.inkSecondary)
            }
        }
    }

    // MARK: Actions

    private func reload() {
        collection = sync.isSignedIn ? AnkiCollection() : nil
    }

    private func refresh() async {
        guard sync.isSignedIn else { return }
        // L'erreur est montrée par `sync.lastError` (posée par `refreshMirror`).
        _ = try? await AnkiReviewSync.sync(context: context, settings: app.settings)
        refreshToken = UUID()
    }
}

/// « Créer une carte » : recto, verso, paquet — prérempli depuis un exercice
/// ou un élément de théorie, envoyé à AnkiWeb d'un toucher.
struct AnkiCardComposer: View {
    let course: Course?
    let origin: String
    @State var front: String
    @State var back: String
    var tags: [String] = []

    @Environment(\.dismiss) private var dismiss
    @State private var collection = AnkiCollection()
    @State private var deckID: Int64 = 0
    @State private var sending = false
    @State private var error: String?

    private var sync: AnkiWebSync { AnkiWebSync.shared }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if !sync.isSignedIn || collection == nil {
                        Section {
                            Text("Connecte d'abord ton compte AnkiWeb (Réglages › Anki).")
                                .foregroundStyle(Carnet.inkSecondary)
                        }
                    } else if let collection {
                        Section {
                            TextField("Recto", text: $front, axis: .vertical).lineLimit(3...10)
                        } header: {
                            CarnetFormHeader("Recto")
                        } footer: {
                            Text("Écris {{c1::…}} autour d'un mot pour en faire une carte à trous.")
                        }
                        if !isCloze {
                            Section {
                                TextField("Verso", text: $back, axis: .vertical).lineLimit(3...10)
                            } header: {
                                CarnetFormHeader("Verso")
                            }
                        }
                        Section {
                            Picker("Paquet", selection: $deckID) {
                                ForEach(collection.decks.filter { !$0.isFiltered }) { deck in
                                    Text(deck.name).tag(deck.id)
                                }
                            }
                        }
                        if let error {
                            Section { Text(error).font(.footnote).foregroundStyle(Carnet.wrong) }
                        }
                    }
                }
                .listRowBackground(Carnet.sheet)
            }
            .carnetForm()
            .navigationTitle("Carte Anki")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Ajouter") { Task { await add() } }
                            .fontWeight(.semibold)
                            .disabled(front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deckID == 0)
                    }
                }
            }
            .onAppear {
                if let collection, let deck = sync.deck(for: course, in: collection) { deckID = deck.id }
            }
        }
    }

    private var isCloze: Bool { !AnkiWebSync.clozeNumbers(in: front).isEmpty }

    private func add() async {
        guard let collection else { return }
        let type = isCloze ? collection.notetypes.first(where: \.isCloze) : sync.basicNotetype(in: collection)
        guard let type else {
            error = String(localized: "Aucun type de note adapté dans ta collection.")
            return
        }
        let html = { (text: String) in text.replacingOccurrences(of: "\n", with: "<br>") }
        let fields = isCloze ? [html(front), html(back)] : [html(front), html(back)]
        sending = true
        sync.enqueue(AnkiDraftNote(deckID: deckID, notetypeID: type.id, fields: fields,
                                   tags: ["polymestre"] + tags, origin: origin))
        await sync.pushPending()
        sending = false
        if let failure = sync.lastError {
            // La carte reste en file : elle partira au prochain passage.
            error = String(localized: "\(failure) La carte est gardée et sera renvoyée.")
        } else {
            Haptics.success()
            dismiss()
        }
    }
}

extension AnkiCardComposer {
    /// Recto : le cours, l'exercice et son énoncé ; verso : ce qu'il faut
    /// retenir et la solution.
    init(exercise: Exercise) {
        let course = exercise.series?.course
        var front = [course?.displayCode, exercise.displayNumber].compactMap { $0 }.joined(separator: " · ")
        let statement = exercise.statement.isEmpty ? exercise.title : exercise.statement
        if !statement.isEmpty { front += "\n\n" + statement }
        let back = [exercise.correctionNote ?? "", exercise.solution]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        self.init(course: course, origin: "\(exercise.displayNumber) · \(course?.displayCode ?? "")",
                  front: front, back: back,
                  tags: [course?.code.replacingOccurrences(of: " ", with: "_")].compactMap { $0 })
    }
}
