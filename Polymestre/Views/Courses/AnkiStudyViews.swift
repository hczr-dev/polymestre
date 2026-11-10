import SwiftUI
import SwiftData
import WebKit

// MARK: - Le paquet d'un cours, dans la théorie

/// Une ligne dans la théorie d'un cours : les cartes Anki à revoir, et le
/// geste qui lance la révision. Rien de plus : parcourir, créer et changer de
/// paquet sont dans son menu.
///
/// N'apparaît que si AnkiWeb est relié — l'app reste la même pour qui n'utilise
/// pas Anki.
struct AnkiCourseRow: View {
    let course: Course

    @State private var collection: AnkiCollection?
    @State private var deck: AnkiCollection.Deck?
    @State private var counts = AnkiCollection.DueCounts()
    @State private var studying = false
    @State private var browsing = false
    @State private var composing = false

    private var sync: AnkiWebSync { AnkiWebSync.shared }

    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @State private var preparing = false

    /// Affichée dès qu'AnkiWeb est relié. Avant, la ligne attendait la copie
    /// de la collection pour exister — mais cette copie n'était lue qu'au
    /// moment où la ligne apparaissait : rien n'apparaissait jamais.
    var body: some View {
        if sync.isSignedIn {
            Group {
                if let collection {
                    if let deck {
                        linkedRow(collection, deck: deck)
                    } else {
                        unlinkedRow(collection)
                    }
                } else {
                    missingCollectionRow
                }
            }
            .task { reload() }
            .sheet(isPresented: $studying, onDismiss: reload) {
                if let deck { AnkiReviewView(course: course, deck: deck) }
            }
            .sheet(isPresented: $browsing, onDismiss: reload) {
                if let deck { AnkiDeckBrowser(course: course, deck: deck) }
            }
            .sheet(isPresented: $composing, onDismiss: reload) {
                AnkiCardComposer(course: course, origin: course.displayCode, front: "", back: "",
                                 tags: [course.code.replacingOccurrences(of: " ", with: "_")])
            }
        }
    }

    /// Relié, mais pas encore de copie sur l'appareil (ou elle a été effacée).
    private var missingCollectionRow: some View {
        HStack(spacing: 12) {
            CarnetIconTile(systemName: "rectangle.stack", tint: Carnet.tint(course.colorHex))
            VStack(alignment: .leading, spacing: 2) {
                Text("Révision Anki").font(.body).foregroundStyle(Carnet.ink)
                Text(preparing ? String(localized: "Téléchargement de ta collection…") : (sync.lastError ?? String(localized: "Ta collection n'est pas encore sur l'appareil")))
                    .font(.footnote)
                    .foregroundStyle(sync.lastError == nil ? Carnet.inkSecondary : Carnet.wrong)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if preparing {
                ProgressView()
            } else {
                Button("Préparer") {
                    preparing = true
                    let settings = app.settings, context = context
                    Task { @MainActor in
                        _ = try? await AnkiReviewSync.sync(context: context, settings: settings)
                        preparing = false
                        reload()
                    }
                }
                .buttonStyle(.carnetSecondary)
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 10)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    private func linkedRow(_ collection: AnkiCollection, deck: AnkiCollection.Deck) -> some View {
        HStack(spacing: 12) {
            CarnetIconTile(systemName: "rectangle.stack", tint: Carnet.tint(course.colorHex))
            VStack(alignment: .leading, spacing: 2) {
                Text("Révision Anki")
                    .font(.body)
                    .foregroundStyle(Carnet.ink)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Carnet.inkSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Button { browsing = true } label: { Label("Parcourir les cartes", systemImage: "list.bullet.rectangle") }
                Button { composing = true } label: { Label("Nouvelle carte", systemImage: "plus.rectangle.on.rectangle") }
                deckPicker(collection, title: String(localized: "Changer de paquet"))
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: Layout.minTouch)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Carnet.inkSecondary)
            .accessibilityLabel("Cartes Anki : plus d'actions")
            Button(counts.total > 0 ? "Réviser" : "Parcourir") {
                if counts.total > 0 { studying = true } else { browsing = true }
            }
            .buttonStyle(.carnetSecondary)
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 10)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
    }

    /// Pas de paquet reconnu : une proposition discrète de le choisir.
    private func unlinkedRow(_ collection: AnkiCollection) -> some View {
        Menu {
            deckPicker(collection, title: String(localized: "Paquet de \(course.displayCode)"))
        } label: {
            Label("Relier un paquet Anki à ce cours", systemImage: "rectangle.stack.badge.plus")
                .font(.subheadline)
                .foregroundStyle(Carnet.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(minHeight: Layout.minTouch)
        }
    }

    private func deckPicker(_ collection: AnkiCollection, title: String) -> some View {
        Picker(title, selection: Binding(
            get: { deck?.id ?? 0 },
            set: { value in
                var map = sync.deckMap
                map[course.code] = value
                sync.deckMap = map
                reload()
            })) {
            ForEach(collection.decks.filter { !$0.isFiltered }) { deck in
                Text(deck.name).tag(deck.id)
            }
        }
        .pickerStyle(.menu)
    }

    private var summary: String {
        if counts.total == 0 { return String(localized: "Rien à revoir aujourd'hui") }
        var parts: [String] = []
        if counts.review + counts.learning > 0 { parts.append(String(localized: "\(counts.review + counts.learning) à revoir")) }
        if counts.new > 0 { parts.append(Plural.count(counts.new, "\(counts.new) nouvelle", "\(counts.new) nouvelles")) }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        collection = AnkiCollection()
        guard let collection else { deck = nil; return }
        deck = sync.deck(for: course, in: collection)
        counts = deck.map { collection.dueCounts(deck: $0, clock: collection.clock()) } ?? .init()
    }
}

// MARK: - Réviser

/// La session de révision : la carte telle qu'Anki la montre, « Afficher la
/// réponse », puis les quatre boutons avec l'intervalle que chacun donnera.
/// Tout est enregistré dans la copie et part à AnkiWeb en quittant.
struct AnkiReviewView: View {
    let course: Course
    let deck: AnkiCollection.Deck

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app

    @State private var card: AnkiCollection.StudyCard?
    @State private var rendered: AnkiCollection.RenderedCard?
    @State private var showingAnswer = false
    @State private var previews: [AnkiRating: String] = [:]
    @State private var counts = AnkiCollection.DueCounts()
    @State private var shownAt = Date()
    @State private var reviewed = 0
    @State private var editing: AnkiCollection.StudyNote?
    @State private var waitUntil: Date?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let rendered, card != nil {
                    // Comme AnkiMobile : toucher la carte montre la réponse,
                    // la toucher encore répond « Bien ».
                    AnkiCardWebView(html: showingAnswer ? rendered.answer : rendered.question, css: rendered.css,
                                    onTap: tapCard)
                        .background(Carnet.sheet)
                        .accessibilityAction(named: showingAnswer ? "Bien" : String(localized: "Afficher la réponse")) { tapCard() }
                    controls
                } else {
                    finished
                }
            }
            .background(Carnet.sheet.ignoresSafeArea())
            .navigationTitle(deck.leaf)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Terminer")
                }
                ToolbarItem(placement: .principal) {
                    if card != nil { countsLabel }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let card {
                        Button {
                            editing = AnkiCollection()?.note(card.noteID)
                        } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("Modifier la carte")
                    }
                }
            }
            .sheet(item: $editing, onDismiss: refreshCurrent) { note in
                AnkiNoteEditor(note: note)
            }
        }
        .task { advance() }
        .onDisappear { syncAfterSession() }
    }

    private var countsLabel: some View {
        HStack(spacing: 10) {
            count(counts.new, Color.blue, "nouvelles")
            count(counts.learning, Carnet.wrong, String(localized: "en apprentissage"))
            count(counts.review, Carnet.correct, "à revoir")
        }
        .font(.subheadline.monospacedDigit().weight(.semibold))
    }

    private func count(_ value: Int, _ tint: Color, _ label: String) -> some View {
        Text("\(value)").foregroundStyle(tint.accessibleInk).accessibilityLabel("\(value) \(label)")
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Carnet.rule).frame(height: 1)
            if showingAnswer {
                HStack(spacing: 8) {
                    ForEach(AnkiRating.allCases) { rating in
                        Button {
                            answer(rating)
                        } label: {
                            VStack(spacing: 2) {
                                Text(previews[rating] ?? "")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Carnet.inkSecondary)
                                Text(rating.label)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(tint(rating).accessibleInk)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(tint(rating).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(rating.label), prochaine révision dans \(previews[rating] ?? "")")
                    }
                }
                .padding(12)
            } else {
                Button {
                    withAnimation(Motion.snappy) { showingAnswer = true }
                    Haptics.soft()
                } label: {
                    Text("Afficher la réponse").frame(maxWidth: .infinity)
                }
                .buttonStyle(.carnetPrimaryWide)
                .padding(12)
            }
        }
        .background(Carnet.sheet)
    }

    private func tint(_ rating: AnkiRating) -> Color {
        switch rating {
        case .again: return Carnet.wrong
        case .hard: return Carnet.review
        case .good: return Carnet.correct
        case .easy: return Color.blue
        }
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Carnet.correct)
            Text(reviewed > 0 ? Plural.count(reviewed, "\(reviewed) carte révisée", "\(reviewed) cartes révisées") : "Rien à revoir")
                .font(Carnet.serif(.title2))
                .foregroundStyle(Carnet.ink)
            if let waitUntil {
                Text("Prochaine carte en apprentissage à \(DateUtils.time.string(from: waitUntil)).")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
            } else {
                Text("C'est tout pour aujourd'hui dans ce paquet.")
                    .font(.subheadline)
                    .foregroundStyle(Carnet.inkSecondary)
            }
            Button("Terminer") { dismiss() }
                .buttonStyle(.carnetPrimary)
                .padding(.top, 8)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: Déroulé

    private func advance() {
        guard let collection = AnkiCollection() else { card = nil; return }
        let clock = collection.clock()
        let queue = collection.studyQueue(deck: deck, clock: clock)
        counts = AnkiCollection.DueCounts(learning: queue.learning.count, review: queue.review.count, new: queue.new.count)
        guard let next = queue.next, let nextCard = collection.card(next) else {
            card = nil
            rendered = nil
            waitUntil = collection.nextLearningDue(deck: deck)
            return
        }
        card = nextCard
        rendered = collection.render(nextCard)
        previews = AnkiScheduler.previews(nextCard.state, options: collection.options(forDeck: nextCard.deckID),
                                          clock: clock, useFSRS: collection.usesFSRS)
        showingAnswer = false
        shownAt = Date()
    }

    private func tapCard() {
        if showingAnswer {
            answer(.good)
        } else {
            withAnimation(Motion.snappy) { showingAnswer = true }
            Haptics.soft()
        }
    }

    private func answer(_ rating: AnkiRating) {
        guard let card, let collection = AnkiCollection(writable: true) else { return }
        let result = AnkiScheduler.answer(card.state, rating: rating, options: collection.options(forDeck: card.deckID),
                                          clock: collection.clock(), useFSRS: collection.usesFSRS)
        collection.record(result, for: card, millisecondsTaken: Int(Date().timeIntervalSince(shownAt) * 1000))
        reviewed += 1
        // Chaque réponse part à AnkiWeb quelques secondes après la dernière.
        AnkiWebSync.shared.syncSoon()
        rating == .again ? Haptics.soft() : Haptics.tap()
        withAnimation(Motion.snappy) { advance() }
    }

    private func refreshCurrent() {
        guard let card, let collection = AnkiCollection() else { return }
        if collection.card(card.id) == nil { advance(); return }
        rendered = collection.render(card)
    }

    /// En quittant : envoi à AnkiWeb, et le temps de révision rangé dans le cours.
    private func syncAfterSession() {
        guard reviewed > 0 else { return }
        let settings = app.settings
        let context = context
        Task { @MainActor in
            await AnkiWebSync.shared.syncNow()
            // Le temps de révision rangé dans le cours (relevé de l'historique).
            _ = try? await AnkiReviewSync.sync(context: context, settings: settings)
        }
    }
}

/// Une carte, en HTML : le style du type de note, la typographie de l'app, les
/// formules (MathJax, comme Anki) et le mode sombre.
struct AnkiCardWebView: UIViewRepresentable {
    let html: String
    let css: String
    /// Un toucher sur la carte — pas sur un lien, un indice ou un champ.
    var onTap: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Le toucher est lu dans la page : WebKit ne déclenche un « click »
        // que pour un toucher franc (pas un défilement), et la page sait si
        // l'on a touché un lien ou un indice, qui gardent leur rôle.
        configuration.userContentController.add(context.coordinator, name: "card")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            document.addEventListener('click', function (e) {
              if (e.target.closest('a, summary, details, input, button, textarea, select')) return;
              window.webkit.messageHandlers.card.postMessage('tap');
            });
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
        let page = document
        guard context.coordinator.last != page else { return }
        context.coordinator.last = page
        view.loadHTMLString(page, baseURL: URL(string: "https://ankiweb.net/"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "card")
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var last = ""
        var onTap: (() -> Void)?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "card" { onTap?() }
        }
    }

    private var document: String {
        let dark = colorScheme == .dark
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html, body { margin: 0; background: transparent; min-height: 100%; box-sizing: border-box; }
        html { height: 100%; }
        body { font: -apple-system-body; font-size: 20px; line-height: 1.45; padding: 24px 20px 40px;
               color: \(dark ? "#ece8df" : "#1d1b18"); text-align: center; -webkit-text-size-adjust: 100%; }
        img { max-width: 100%; height: auto; }
        hr#answer { border: 0; border-top: 1px solid \(dark ? "#3a3833" : "#e2ddd2"); margin: 20px 0; }
        .cloze { font-weight: 600; color: \(dark ? "#8fb4ff" : "#2456c7"); }
        details.hint summary { color: \(dark ? "#9a958a" : "#7a756a"); }
        \(css)
        .card { background: transparent !important; color: inherit; }
        </style>
        <script>window.MathJax = { tex: { inlineMath: [['\\\\(', '\\\\)']], displayMath: [['\\\\[', '\\\\]']] }, svg: { fontCache: 'global' } };</script>
        <script async src="https://cdnjs.cloudflare.com/ajax/libs/mathjax/3.2.2/es5/tex-mml-chtml.js"></script>
        </head><body class="card\(dark ? " nightMode night_mode" : "")">\(html)</body></html>
        """
    }
}

// MARK: - Parcourir et modifier

/// Les notes d'un paquet : chercher, ouvrir pour modifier, supprimer, créer.
struct AnkiDeckBrowser: View {
    let course: Course
    let deck: AnkiCollection.Deck

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppContainer.self) private var app
    @State private var search = ""
    @State private var notes: [AnkiCollection.StudyNote] = []
    @State private var editing: AnkiCollection.StudyNote?
    @State private var composing = false
    @State private var deleting: AnkiCollection.StudyNote?
    @State private var changed = false

    var body: some View {
        NavigationStack {
            List {
                if notes.isEmpty {
                    Text(search.isEmpty ? "Aucune carte dans ce paquet." : "Aucune carte ne contient « \(search) ».")
                        .foregroundStyle(Carnet.inkSecondary)
                        .listRowBackground(Carnet.sheet)
                }
                ForEach(notes) { note in
                    Button { editing = note } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AnkiTemplate.stripHTML(note.fields.first ?? ""))
                                .font(.body)
                                .foregroundStyle(Carnet.ink)
                                .lineLimit(2)
                            let back = note.fields.dropFirst().map(AnkiTemplate.stripHTML).first { !$0.isEmpty } ?? ""
                            if !back.isEmpty {
                                Text(back).font(.footnote).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Carnet.sheet)
                    .swipeActions {
                        Button("Supprimer", role: .destructive) { deleting = note }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Carnet.ground.ignoresSafeArea())
            .searchable(text: $search, prompt: "Chercher dans les cartes")
            .navigationTitle(deck.leaf)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Nouvelle carte")
                }
            }
            .sheet(item: $editing, onDismiss: { changed = true; reload() }) { AnkiNoteEditor(note: $0) }
            .sheet(isPresented: $composing, onDismiss: { changed = true; reload() }) {
                AnkiCardComposer(course: course, origin: course.displayCode, front: "", back: "",
                                 tags: [course.code.replacingOccurrences(of: " ", with: "_")])
            }
            .confirmationDialog("Supprimer cette carte ?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { note in
                Button("Supprimer la note et ses cartes", role: .destructive) {
                    AnkiCollection(writable: true)?.delete(note: note.id)
                    changed = true
                    reload()
                }
            } message: { _ in
                Text("Elle disparaîtra aussi d'Anki.")
            }
        }
        .task(id: search) { reload() }
        .onDisappear {
            guard changed else { return }
            let settings = app.settings, context = context
            Task { @MainActor in _ = try? await AnkiReviewSync.sync(context: context, settings: settings) }
        }
    }

    private func reload() {
        guard let collection = AnkiCollection() else { notes = []; return }
        notes = collection.notes(inDecks: collection.deckTree(deck), matching: search)
    }
}

/// Modifier une note : ses champs, nommés comme dans Anki, et ses étiquettes.
struct AnkiNoteEditor: View {
    let note: AnkiCollection.StudyNote

    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String] = []
    @State private var names: [String] = []
    @State private var tags = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(names.indices, id: \.self) { index in
                    Section {
                        TextField(names[index], text: Binding(get: { fields.indices.contains(index) ? fields[index] : "" },
                                                              set: { if fields.indices.contains(index) { fields[index] = $0 } }),
                                  axis: .vertical)
                            .lineLimit(2...12)
                    } header: {
                        CarnetFormHeader(names[index])
                    }
                    .listRowBackground(Carnet.sheet)
                }
                Section {
                    TextField("Étiquettes, séparées par des espaces", text: $tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    CarnetFormHeader(String(localized: "Étiquettes"))
                } footer: {
                    Text("Formules : \\( … \\).")
                }
                .listRowBackground(Carnet.sheet)
                if let error {
                    Section { Text(error).foregroundStyle(Carnet.wrong) }.listRowBackground(Carnet.sheet)
                }
            }
            .carnetForm()
            .navigationTitle("Modifier la carte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }.fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let collection = AnkiCollection() else { return }
        names = collection.fieldNames(ofNotetype: note.notetypeID)
        fields = names.indices.map { index in
            note.fields.indices.contains(index) ? Self.editable(note.fields[index]) : ""
        }
        tags = note.tags.joined(separator: " ")
    }

    private func save() {
        guard let collection = AnkiCollection(writable: true) else { return }
        let html = fields.map { $0.replacingOccurrences(of: "\n", with: "<br>") }
        if collection.update(note: note.id, fields: html, tags: tags.split(separator: " ").map(String.init)) {
            Haptics.success()
            dismiss()
        } else {
            error = String(localized: "La carte n'a pas pu être enregistrée.")
        }
    }

    /// `<br>` → retour à la ligne pour l'édition ; le reste du HTML est gardé.
    static func editable(_ html: String) -> String {
        html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
    }
}
