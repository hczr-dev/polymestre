import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// « Personnaliser » : ce qui est propre à l'école et à l'étudiant·e, réglé au
/// même endroit sur l'iPhone et le Mac. Tout a une valeur par défaut qui
/// reproduit l'app d'avant (l'EPFL, GoodNotes, les quatre étapes) : on ne vient
/// ici que pour changer quelque chose.
///
/// La page, sur l'iPhone : le papier de l'app, les en-têtes en serif et les
/// icônes d'encre, comme le reste des réglages. Le formulaire nu, présenté tel
/// quel, gardait le fond et les en-têtes gris du système — une page d'une autre
/// app, collée dans celle-ci.
#if os(iOS)
struct PersonalizeView: View {
    var body: some View {
        PersonalizeForm()
            .carnetForm()
            .navigationTitle("Personnaliser")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif

struct PersonalizeForm: View {
    @Query(sort: \Course.code) private var courses: [Course]

    var body: some View {
        Form {
            SchoolSection()
            NotesSection(courses: courses.filter(\.isTracked))
            SessionFlowSection()
            NotebookLMSection()
            LanguageSection()
        }
        // Les lignes prennent la feuille de l'app. Posé ici, une fois, plutôt
        // que dans chaque section : la sixième section ajoutée l'aurait oublié.
        #if os(iOS)
        .listRowBackground(Carnet.sheet)
        #endif
        .formStyle(.grouped)
    }
}

// MARK: - École

/// Les en-têtes d'une page de réglages : serif et encre, comme le reste de
/// l'app (un `Text("École")` nu prenait le gris et les petites capitales du
/// système).
private func personalizeHeader(_ title: String) -> some View {
    #if os(iOS)
    CarnetFormHeader(title)
    #else
    // `ui:` : le titre se lit dans le catalogue (« École » → « School ») —
    // un `Text(title)` nu affichait le français tel quel en anglais.
    // Les en-têtes des réglages du Mac (« Session », « Sur ce Mac »…) : ceux du système, partout.
    Text(ui: title)
    #endif
}

struct SchoolSection: View {
    @State private var school = Institution.current
    @State private var email = SchoolConnect.shared.email ?? ""

    private var isBuiltIn: Bool { Institution.builtIn.contains { $0.id == school.id } }

    var body: some View {
        Section {
            Picker("École", selection: Binding(get: { school.id }, set: { id in
                school = Institution.builtIn.first { $0.id == id } ?? (id == school.id ? school : .generic)
                save()
            })) {
                ForEach(Institution.builtIn) { Text($0.name).tag($0.id) }
                Text("Autre école").tag(Institution.generic.id)
                if !isBuiltIn, school.id != Institution.generic.id {
                    Text(school.name).tag(school.id)
                }
            }
            TextField("Ton adresse de l'école", text: $email)
                .textContentTypeEmail()
                .onSubmit {
                    SchoolConnect.shared.email = email.isEmpty ? nil : email
                    if let found = Institution.detect(email: email) { school = found; save() }
                }
            // Une école hors de la liste : ses sites, dits à la main. Sur
            // l'iPhone, les adresses s'effacent en chemin (« https://… ») — le
            // profil garde la valeur complète.
            if !isBuiltIn {
                TextField("Moodle", text: Binding(get: { Self.host(school.moodle?.base) }, set: { value in
                    school.moodle = value.isEmpty ? nil : .init(base: value, oauthProviderID: nil)
                    save()
                }), prompt: Text("https://…"))
                    .urlField()
                TextField("Open edX", text: Binding(get: { Self.host(school.openEdX?.base) }, set: { value in
                    school.openEdX = value.isEmpty ? nil : .init(base: value, loginBackend: nil, ssoHost: nil, ssoIdP: nil)
                    save()
                }), prompt: Text("https://…"))
                    .urlField()
                Toggle("Ed Discussion", isOn: Binding(get: { school.ed != nil },
                                                      set: { school.ed = $0 ? .init(region: "us") : nil; save() }))
                if let ed = school.ed {
                    Picker("Région d'Ed", selection: Binding(get: { ed.region },
                                                             set: { school.ed = .init(region: $0); save() })) {
                        Text("Europe").tag("eu")
                        Text("États-Unis").tag("us")
                        Text("Australie").tag("au")
                    }
                    .pickerStyle(.menu)
                }
            }
        } header: {
            personalizeHeader(String(localized: "École"))
        } footer: {
            Text(isBuiltIn
                 ? String(localized: "Moodle, Courseware, MediaSpace et Ed se connectent tout seuls.")
                 : String(localized: "Les sites de ton école. L'adresse complète se garde : Polymestre ajoute « https:// » si tu l'as omise."))
        }
    }

    /// Une adresse de site, sans son `https://` : douze caractères qu'on
    /// n'écrit pas pour rien sur un téléphone.
    private static func host(_ base: String?) -> String {
        guard let base else { return "" }
        return base.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func save() {
        if school.id == Institution.generic.id, school.moodle != nil || school.openEdX != nil || school.ed != nil {
            school.id = "custom"
            school.name = String(localized: "Mon école")
        }
        Institution.save(school)
        school = Institution.current
    }
}

// MARK: - Notes

struct NotesSection: View {
    let courses: [Course]
    @State private var choosing = false
    private var store: NotesStore { .shared }

    var body: some View {
        Section {
            LabeledContent("Dossier") {
                HStack(spacing: 10) {
                    Text(store.root.map { $0.lastPathComponent } ?? String(localized: "introuvable"))
                        .foregroundStyle(Carnet.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choisir…") { choosing = true }
                        .buttonStyle(.borderless)
                }
            }
            ForEach(store.notebooks, id: \.self) { notebook in
                Picker(notebook, selection: Binding(get: {
                    store.rules.notebooks[notebook] ?? store.course(forNotebook: notebook, among: courses)?.code ?? ""
                }, set: { code in
                    store.rules.notebooks[notebook] = code
                })) {
                    Text("Aucun cours").tag("")
                    // Le nom que l'on reconnaît (« Analyse »), pas le code
                    // d'immatriculation de Moodle (« MATH-101 »), sauf s'il est
                    // tout ce qu'il y a.
                    ForEach(courses) { course in
                        Text(course.displayCode == course.code ? course.code : "\(course.displayCode) — \(course.code)")
                            .tag(course.code)
                    }
                }
                .pickerStyle(.menu)
            }
            // Les mots s'ajoutent avec « + » : un champ vide à la virgule
            // finale n'efface plus rien, et on voit ce qui est rangé.
            LabeledContent("Mots d'une série") { WordListEditor(list: words(\.seriesWords)) }
            LabeledContent("Mots d'une semaine") { WordListEditor(list: words(\.weekWords)) }
        } header: {
            personalizeHeader("Mes notes")
        } footer: {
            Text("La sauvegarde de GoodNotes, Notability… Chaque cahier va à un cours.")
        }
        .task { await store.refresh() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.choose(url)
                Task { await store.refresh(force: true) }
            }
        }
    }

    /// La liste de mots (une série s'appelle « Série 3 », une semaine « Semaine 3 »).
    private func words(_ path: WritableKeyPath<NotesLibrary.Rules, [String]>) -> Binding<[String]> {
        Binding(get: { store.rules[keyPath: path] }, set: { store.rules[keyPath: path] = $0 })
    }
}

/// Une liste de mots courts : les puces, puis un champ pour ajouter.
private struct WordListEditor: View {
    @Binding var list: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(list, id: \.self) { word in
                HStack(spacing: 6) {
                    Text(word).lineLimit(1)
                    Button {
                        Haptics.tap()
                        list.removeAll { $0 == word }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .tint(Carnet.inkSecondary)
                    .accessibilityLabel(String(localized: "Retirer « \(word) »"))
                }
            }
            HStack(spacing: 6) {
                TextField("Ajouter", text: $draft)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(cleaned.isEmpty)
                    .accessibilityLabel(String(localized: "Ajouter"))
            }
        }
    }

    private var cleaned: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let word = cleaned
        guard !word.isEmpty else { return }
        if !list.contains(word) { list.append(word) }
        draft = ""
        Haptics.tap()
    }
}

// MARK: - Session

/// « Ta session » : les étapes du bureau, cochées, dans l'ordre.
///
/// Les chevrons ⌃ ⌄ rangés côte à côte ne disaient pas qu'ils **déplaçaient**
/// la ligne, et ne tenaient pas dans un carré de 44 points. Un menu « Monter »
/// / « Descendre » sur la ligne fait le même travail, se lit, et s'atteint au
/// doigt comme au clavier.
struct SessionFlowSection: View {
    @State private var flow = SessionFlow.load()

    var body: some View {
        Section {
            ForEach(Array(flow.steps.enumerated()), id: \.element) { index, step in
                SessionStepRow(step: step, order: index + 1, isFirst: index == 0, isLast: index == flow.steps.count - 1,
                               isOn: true,
                               toggle: { update { $0.toggle(step) } },
                               move: { offset in update { $0.move(step, by: offset) } })
            }
            ForEach(SessionFlow.Step.allCases.filter { !flow.contains($0) }) { step in
                SessionStepRow(step: step, order: nil, isFirst: true, isLast: true, isOn: false,
                               toggle: { update { $0.toggle(step) } },
                               move: { _ in })
            }
        } header: {
            personalizeHeader(String(localized: "Ta session"))
        } footer: {
            Text("Les étapes du bureau, sur le Mac et l'iPhone. Parmi celles qui restent, au plus une ne peut être retirée.")
        }
    }

    private func update(_ change: (inout SessionFlow) -> Void) {
        var copy = flow
        change(&copy)
        guard copy != flow else { return }
        flow = copy
        flow.save()
        Haptics.tap()
    }
}

private struct SessionStepRow: View {
    let step: SessionFlow.Step
    let order: Int?
    let isFirst: Bool
    let isLast: Bool
    let isOn: Bool
    var toggle: () -> Void
    var move: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Un bouton, pas une icône muette : VoiceOver annonce « inclure »
            // et « retirer », et la marque est le numéro d'ordre.
            Button(action: toggle) {
                ZStack {
                    Circle().fill(isOn ? Carnet.ink : .clear)
                    Circle().strokeBorder(isOn ? .clear : Carnet.inkTertiary, lineWidth: 1.5)
                    if let order {
                        Text("\(order)")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Carnet.ground)
                    }
                }
                .frame(width: 26, height: 26)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.title)
            .accessibilityValue(isOn ? Text("Incluse, \(order ?? 0)") : Text("Retirée"))
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            Text(step.title)
                .foregroundStyle(isOn ? Carnet.ink : Carnet.inkSecondary)
            Spacer(minLength: 8)
            if isOn {
                Menu {
                    Button { move(-1) } label: { Label("Monter", systemImage: "arrow.up") }
                        .disabled(isFirst)
                    Button { move(1) } label: { Label("Descendre", systemImage: "arrow.down") }
                        .disabled(isLast)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(Carnet.inkSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Déplacer « \(step.title) »"))
            }
        }
    }
}

// MARK: - NotebookLM

/// NotebookLM : allumé, la fiche a un onglet « Écouter » (sources prêtes à déposer, podcast à
/// rapporter). Éteint par défaut : rien ne part de l'appareil, de toute façon — Polymestre ne parle
/// jamais à Google, il écrit des fichiers et ouvre un lien.
struct NotebookLMSection: View {
    @AppStorage("notebooklm.enabled") private var enabled = false

    var body: some View {
        Section {
            Toggle("NotebookLM", isOn: $enabled)
        } header: {
            personalizeHeader(String(localized: "Fiche de révision"))
        } footer: {
            Text("Ajoute l'onglet « Écouter » à la fiche : un podcast NotebookLM de ta fiche.")
        }
    }
}

// MARK: - Langue

/// La langue de l'app. Le changement prend effet au **prochain lancement** (le
/// catalogue est lu au démarrage) : on le dit sous le choix, parce qu'un réglage
/// qui ne change rien devant soi, sans explication, ressemble à un bug.
struct LanguageSection: View {
    @State private var language = AppLanguage.current
    @State private var pending = false

    var body: some View {
        Section {
            Picker("Langue", selection: $language) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: language) { old, value in
                AppLanguage.choose(value)
                pending = value != old
                Haptics.tap()
            }
        } header: {
            personalizeHeader(String(localized: "Langue"))
        } footer: {
            if pending {
                Text("La langue change au prochain lancement de l'app.")
            } else {
                Text("Suivant l'appareil, par défaut.")
            }
        }
    }
}

extension View {
    @ViewBuilder
    func textContentTypeEmail() -> some View {
        #if os(iOS)
        textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
        #else
        textContentType(.emailAddress)
        #endif
    }
}
